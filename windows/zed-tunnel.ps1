<#
.SYNOPSIS
    Keeps one reverse SSH tunnel to the dev box up for the remote-open listener.

.DESCRIPTION
    Runs `ssh -N -R <port>:127.0.0.1:<port> <host>` and restarts it whenever it
    exits, with exponential backoff so an unreachable dev box does not turn into a
    reconnect storm. Owning the forward here rather than borrowing it from a Zed
    project keeps it alive across projects opening and closing, and across having
    no project open at all.

    Windows OpenSSH cannot share one connection between processes -- it has no
    ControlMaster -- so the alternative of pointing every Zed connection at a
    shared master is not available. See the README.

    Authentication has to be non-interactive: BatchMode is on, so an encrypted key
    with no agent, or an unknown host key, fails the connection rather than
    prompting an invisible process for input.

    A run of forward failures usually means a session abandoned when this machine
    slept is still holding the port on the dev box. After several in a row the
    supervisor clears those sessions over ssh (see remote/bin/clear-stale-forwards
    and the README).

.PARAMETER Port
    Loopback port to forward. Must match the listener and the sender.

.PARAMETER RemoteHost
    ssh destination for the dev box, as named in ~/.ssh/config. This is also the
    alias Zed uses, and the one the dev box exports as ZED_SSH_HOST.

.PARAMETER SshExe
    Absolute path to ssh.exe. The installer bakes this in, because a Scheduled
    Task runs with a minimal PATH.

.PARAMETER LogFile
    Append log lines to this file in addition to stdout.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int]$Port = 7682,

    [Parameter(Mandatory)]
    [string]$RemoteHost,

    [string]$SshExe,

    [string]$LogFile,

    [int]$AliveIntervalSeconds = 30,

    [int]$AliveCountMax = 3,

    [int]$ConnectTimeoutSeconds = 15,

    [int]$MinBackoffSeconds = 5,

    # Capped low so a transient drop (VPN reconnect, wake from sleep) recovers
    # within a minute rather than sitting out a multi-minute backoff. A failed
    # connect is cheap, so a retry a minute is not a reconnect storm.
    [int]$MaxBackoffSeconds = 60,

    [int]$StableSeconds = 60,

    [int]$MaxStderrLines = 5,

    # Consecutive forward failures before the log calls the port stale.
    [int]$StaleForwardFailures = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ZedLog.ps1')

$script:Child = $null

function Resolve-SshExe {
    param([string]$Explicit)

    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit -PathType Leaf)) {
            throw "-SshExe '$Explicit' does not exist"
        }
        return (Resolve-Path -LiteralPath $Explicit).Path
    }

    # Fallback for foreground runs only; the Scheduled Task always passes -SshExe.
    $inbox = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
    if (Test-Path -LiteralPath $inbox -PathType Leaf) { return $inbox }

    $onPath = Get-Command -Name 'ssh' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($onPath) { return $onPath.Source }

    throw 'could not locate ssh.exe; pass -SshExe with an absolute path'
}

# Returns the exit code and whatever ssh wrote to stderr. Both pipes are drained
# on background tasks: ssh -N is quiet, but a full pipe buffer would wedge it for
# good, and this process is invisible.
function Invoke-Tunnel {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string[]]$SshArgs
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Exe
    foreach ($arg in $SshArgs) { $psi.ArgumentList.Add($arg) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $script:Child = [System.Diagnostics.Process]::Start($psi)
    try {
        $stdout = $script:Child.StandardOutput.ReadToEndAsync()
        $stderr = $script:Child.StandardError.ReadToEndAsync()
        $script:Child.WaitForExit()
        [void]$stdout.Result
        return [pscustomobject]@{
            ExitCode = $script:Child.ExitCode
            Stderr   = $stderr.Result
        }
    }
    finally {
        $script:Child = $null
    }
}

function Resolve-CleanupScript {
    $installed = Join-Path $PSScriptRoot 'clear-stale-forwards'
    if (Test-Path -LiteralPath $installed -PathType Leaf) { return $installed }

    $fromRepo = Join-Path (Split-Path $PSScriptRoot -Parent) 'remote\bin\clear-stale-forwards'
    if (Test-Path -LiteralPath $fromRepo -PathType Leaf) { return $fromRepo }

    return $null
}

function Invoke-ClearStaleRemoteForwards {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string]$SshDestination,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][int]$ConnectTimeoutSeconds
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Exe
    $psi.ArgumentList.Add('-o')
    $psi.ArgumentList.Add('BatchMode=yes')
    $psi.ArgumentList.Add('-o')
    $psi.ArgumentList.Add("ConnectTimeout=$ConnectTimeoutSeconds")
    $psi.ArgumentList.Add('-T')
    $psi.ArgumentList.Add($SshDestination)
    $psi.ArgumentList.Add('bash')
    $psi.ArgumentList.Add('-s')
    # '--' ends bash's own option parsing so '--quiet' reaches the piped script as
    # $1 rather than being read as a bash long option ('bash: --: invalid option').
    $psi.ArgumentList.Add('--')
    $psi.ArgumentList.Add('--quiet')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        $scriptText = [System.IO.File]::ReadAllText($ScriptPath)
        $proc.StandardInput.Write($scriptText)
        $proc.StandardInput.Close()
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        $output = ($stdout + $stderr).Trim()

        if ($proc.ExitCode -ne 0) {
            Write-Log "could not run cleanup on '$SshDestination' -- $output" 'WARN'
            return $false
        }

        if ($output -match 'cleared=(\d+)') {
            $count = [int]$Matches[1]
            if ($count -gt 0) {
                Write-Log "cleared $count abandoned session(s) on '$SshDestination'"
            }
            else {
                Write-Log "no abandoned sessions found on '$SshDestination' to clear" 'WARN'
            }
            return $true
        }

        Write-Log "unexpected cleanup output from '$SshDestination' -- $output" 'WARN'
        return $false
    }
    finally {
        if (-not $proc.HasExited) {
            try { $proc.Kill() } catch { }
        }
    }
}

try {
    $script:LogWriter = Open-LogWriter -Path $LogFile
}
catch {
    # Console-only logging is still better than refusing to run.
    Write-Log "could not open log file '$LogFile' -- $($_.Exception.Message)" 'WARN'
}

if ($PSVersionTable.PSVersion.Major -lt 6) {
    Write-Log 'requires PowerShell 7+ (ProcessStartInfo.ArgumentList is unavailable on 5.1)' 'FATAL'
    exit 1
}

$sshPath = $null
try {
    $sshPath = Resolve-SshExe -Explicit $SshExe
}
catch {
    Write-Log $_.Exception.Message 'FATAL'
    exit 1
}

$cleanupScript = Resolve-CleanupScript
if (-not $cleanupScript) {
    Write-Log 'clear-stale-forwards script not found beside the tunnel or under remote/bin' 'WARN'
}

$forward = '{0}:127.0.0.1:{0}' -f $Port
$sshArgs = @(
    '-N'                                            # forward only, no remote command
    '-T'
    '-o', 'BatchMode=yes'                           # never prompt; nothing can answer
    '-o', 'ExitOnForwardFailure=yes'                # a tunnel without the forward is useless
    '-o', "ServerAliveInterval=$AliveIntervalSeconds"
    '-o', "ServerAliveCountMax=$AliveCountMax"
    '-o', "ConnectTimeout=$ConnectTimeoutSeconds"
    '-R', $forward
    $RemoteHost
)

Write-Log "tunnel supervisor started (pid $PID)"
Write-Log "ssh: $sshPath"
Write-Log "forward: -R $forward to '$RemoteHost'"

$backoff = $MinBackoffSeconds
$forwardFailures = 0
# A healthy session has existed since the last time we cleared the remote port.
# When one drops and the very next connect cannot bind the forward, the holder is
# almost always our own just-abandoned session -- the VPN-reconnect and wake-from-
# sleep case -- so that first failure is enough to justify clearing, without
# waiting out $StaleForwardFailures more rounds of backoff.
$sawStableConnection = $false
try {
    while ($true) {
        $startedAt = Get-Date
        $forwardFailedThisRun = $false
        try {
            $result = Invoke-Tunnel -Exe $sshPath -SshArgs $sshArgs
            $uptime = (Get-Date) - $startedAt

            foreach ($line in @($result.Stderr -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First $MaxStderrLines)) {
                Write-Log "ssh: $($line.Trim())" 'WARN'
            }
            Write-Log ("ssh exited {0} after {1:n0}s" -f $result.ExitCode, $uptime.TotalSeconds) 'WARN'

            # A connection that stayed up is evidence the dev box is reachable, so
            # a later drop starts over at the short delay instead of inheriting the
            # backoff from whatever outage came before it.
            if ($uptime.TotalSeconds -ge $StableSeconds) {
                $backoff = $MinBackoffSeconds
                $sawStableConnection = $true
            }

            if ($result.Stderr -match 'remote port forwarding failed') {
                $forwardFailures++
                $forwardFailedThisRun = $true
            }
            else { $forwardFailures = 0 }
        }
        catch {
            Write-Log "could not start ssh -- $($_.Exception.Message)" 'ERROR'
        }

        # Clear the remote's stale forward when a forward-failure either follows a
        # previously healthy session (our own abandoned session almost certainly
        # still holds the port) or has piled up to the threshold (the slower path
        # for outages that never had a healthy session to begin with). Then retry
        # at the short delay instead of backing off further.
        $shouldClear = $forwardFailedThisRun -and ($sawStableConnection -or $forwardFailures -ge $StaleForwardFailures)
        if ($shouldClear) {
            Write-Log "the port on '$RemoteHost' looks held by an abandoned session; clearing" 'WARN'
            if ($cleanupScript -and (Invoke-ClearStaleRemoteForwards -Exe $sshPath -SshDestination $RemoteHost -ScriptPath $cleanupScript -ConnectTimeoutSeconds $ConnectTimeoutSeconds)) {
                $forwardFailures = 0
                $sawStableConnection = $false
                $backoff = $MinBackoffSeconds
            }
            else {
                # Clear it off so a failed cleanup does not fire on every retry.
                $sawStableConnection = $false
                Write-Log "'zed .' on '$RemoteHost' may report success and open nothing until the port is free (see the README)" 'ERROR'
            }
        }

        Write-Log "reconnecting in ${backoff}s"
        Start-Sleep -Seconds $backoff
        $backoff = [Math]::Min($backoff * 2, $MaxBackoffSeconds)
    }
}
finally {
    # Without this the forward outlives the supervisor, and the port stays bound on
    # the dev box so the replacement can never take it.
    if ($null -ne $script:Child) {
        try { $script:Child.Kill() } catch { }
    }
    Write-Log 'tunnel supervisor stopped'
}
