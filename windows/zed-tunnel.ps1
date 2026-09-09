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

    A forward that keeps failing usually means a session abandoned when this
    machine slept is still holding the port on the dev box. Nothing here can clear
    that; see the README.

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

    [int]$MaxBackoffSeconds = 300,

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
try {
    while ($true) {
        $startedAt = Get-Date
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
            if ($uptime.TotalSeconds -ge $StableSeconds) { $backoff = $MinBackoffSeconds }

            if ($result.Stderr -match 'remote port forwarding failed') { $forwardFailures++ }
            else { $forwardFailures = 0 }
        }
        catch {
            Write-Log "could not start ssh -- $($_.Exception.Message)" 'ERROR'
        }

        # One failure is ordinary -- a connection this tunnel just lost can still be
        # shutting down on the far end. A run of them means a session abandoned when
        # this machine slept is still holding the port, which nothing here can
        # clear: the holder cannot even be identified without root on the dev box.
        # Said once per run of failures so the log names the condition without
        # repeating it on every retry.
        if ($forwardFailures -eq $StaleForwardFailures) {
            Write-Log "the port on '$RemoteHost' is held by an abandoned session; 'zed .' there will report success and open nothing until it is cleared (see the README)" 'ERROR'
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
