<#
.SYNOPSIS
    Checks that every piece of the Zed remote-open path is in place on Windows.

.DESCRIPTION
    Verifies the Zed CLI, the ssh_connections entry, both Scheduled Tasks, the
    reverse tunnel, the loopback listener, the placement inputs, and the logs.
    Nothing here changes state unless you pass -Probe.

    What it expects of Zed's args depends on which task is installed: with the
    tunnel task registered the forward belongs to it, and an -R left in Zed's args
    only competes for the same remote port.

.PARAMETER RemoteHost
    The ssh_connections host alias, and the tunnel's ssh destination.

.PARAMETER Probe
    Send a real URL through the listener. This opens a Zed window.

.PARAMETER CheckRemote
    Read-only SSH check that the dev box is listening on the tunnel port and has
    a zed sender on PATH. Requires an ssh client and a working host alias.

.PARAMETER ZedDb
    Zed's workspace database, the listener's primary evidence for window
    placement. Defaults to the same one the listener resolves.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int]$Port = 7682,

    [string]$RemoteHost = 'desktop',

    [string]$ZedExe,

    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'zed-listener'),

    [string]$TaskName = 'zed-open-listener',

    [string]$TunnelTaskName = 'zed-open-tunnel',

    [string]$ZedDb,

    [switch]$Probe,

    [switch]$CheckRemote,

    # How long the tunnel's ssh has to survive before its forward counts as bound.
    [int]$EstablishedSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ZedCli.ps1')
. (Join-Path $PSScriptRoot 'ZedPlacement.ps1')

$script:Failures = 0
$script:Warnings = 0

function Test-Ok { param([string]$Name, [string]$Detail) Write-Host "  [ ok ] $Name" -ForegroundColor Green; if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGray } }
function Test-Bad { param([string]$Name, [string]$Detail) $script:Failures++; Write-Host "  [FAIL] $Name" -ForegroundColor Red; if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGray } }
function Test-Warn { param([string]$Name, [string]$Detail) $script:Warnings++; Write-Host "  [warn] $Name" -ForegroundColor Yellow; if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGray } }

# Zed's settings.json is JSONC: line/block comments and trailing commas. Both
# passes below track string state so a "//" inside a URL string is not mistaken
# for a comment.
function Remove-JsonComment {
    param([string]$Text)
    $sb = [System.Text.StringBuilder]::new()
    $inString = $false; $escaped = $false
    $i = 0; $n = $Text.Length
    while ($i -lt $n) {
        $ch = $Text[$i]
        if ($inString) {
            [void]$sb.Append($ch)
            if ($escaped) { $escaped = $false }
            elseif ($ch -eq '\') { $escaped = $true }
            elseif ($ch -eq '"') { $inString = $false }
            $i++; continue
        }
        if ($ch -eq '"') { $inString = $true; [void]$sb.Append($ch); $i++; continue }
        if ($ch -eq '/' -and ($i + 1) -lt $n) {
            $next = $Text[$i + 1]
            if ($next -eq '/') {
                while ($i -lt $n -and $Text[$i] -ne "`n") { $i++ }
                continue
            }
            if ($next -eq '*') {
                $i += 2
                while (($i + 1) -lt $n -and -not ($Text[$i] -eq '*' -and $Text[$i + 1] -eq '/')) { $i++ }
                $i += 2; continue
            }
        }
        [void]$sb.Append($ch)
        $i++
    }
    return $sb.ToString()
}

function Remove-TrailingComma {
    param([string]$Text)
    $sb = [System.Text.StringBuilder]::new()
    $inString = $false; $escaped = $false
    $i = 0; $n = $Text.Length
    while ($i -lt $n) {
        $ch = $Text[$i]
        if ($inString) {
            [void]$sb.Append($ch)
            if ($escaped) { $escaped = $false }
            elseif ($ch -eq '\') { $escaped = $true }
            elseif ($ch -eq '"') { $inString = $false }
            $i++; continue
        }
        if ($ch -eq '"') { $inString = $true; [void]$sb.Append($ch); $i++; continue }
        if ($ch -eq ',') {
            $j = $i + 1
            while ($j -lt $n -and [char]::IsWhiteSpace($Text[$j])) { $j++ }
            if ($j -lt $n -and ($Text[$j] -eq '}' -or $Text[$j] -eq ']')) { $i++; continue }
        }
        [void]$sb.Append($ch)
        $i++
    }
    return $sb.ToString()
}

Write-Host ''
Write-Host "zed-remote-open doctor (host '$RemoteHost', port $Port)" -ForegroundColor Cyan
Write-Host ''

$expectedForward = "{0}:127.0.0.1:{0}" -f $Port

# Set by the Tunnel section and read by the remote check, which cannot tell on its
# own whether the forward it sees on the dev box is ours or an abandoned one.
# 'starting' is not evidence either way, so it must not be read as 'not ours'.
$script:TunnelState = 'absent'   # absent | starting | bound

# Read up front: what the Zed args should look like depends on whether the tunnel
# task exists to own the forward, and that section prints further down.
$tunnelTask = Get-ScheduledTask -TaskName $TunnelTaskName -ErrorAction SilentlyContinue

# Every ssh holding the forward, whoever started it. The supervisor's is the one
# carrying ExitOnForwardFailure; anything else is a Zed connection still
# configured with -R, and the two cannot both have the port.
function Get-ForwardSshProcess {
    @(
        Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.CommandLine -and
                $_.CommandLine -match [regex]::Escape("-R $expectedForward")
            }
    )
}

# --- 1. Zed CLI -------------------------------------------------------------
Write-Host 'Zed CLI'
$zedPath = $null
try {
    $zedPath = Resolve-ZedCliPath -Explicit $ZedExe
    Test-Ok 'Zed CLI found' $zedPath
    if (-not (Get-Command -Name 'zed' -CommandType Application -ErrorAction SilentlyContinue)) {
        Test-Ok 'not on PATH (expected)' 'the installer bakes the absolute path into the task'
    }
}
catch {
    Test-Bad 'Zed CLI not found' $_.Exception.Message
}

# --- 2. Zed settings.json ---------------------------------------------------
Write-Host ''
Write-Host 'Zed settings'
$settingsPath = Join-Path $env:APPDATA 'Zed\settings.json'
if (-not (Test-Path -LiteralPath $settingsPath)) {
    Test-Bad 'settings.json missing' $settingsPath
}
else {
    Test-Ok 'settings.json' $settingsPath
    $raw = ''
    try {
        $raw = Get-Content -LiteralPath $settingsPath -Raw
        $json = (Remove-TrailingComma -Text (Remove-JsonComment -Text $raw)) | ConvertFrom-Json

        $connections = @()
        if ($json.PSObject.Properties.Name -contains 'ssh_connections') { $connections = @($json.ssh_connections) }

        if ($connections.Count -eq 0) {
            Test-Bad 'no ssh_connections entries' 'Zed cannot open ssh:// URLs without a configured host'
        }
        else {
            $entry = $connections | Where-Object { $_.host -eq $RemoteHost } | Select-Object -First 1
            if (-not $entry) {
                Test-Bad "no ssh_connections entry for '$RemoteHost'" ("found: " + (($connections | ForEach-Object { $_.host }) -join ', '))
            }
            else {
                Test-Ok "ssh_connections entry for '$RemoteHost'"
                $entryArgs = @()
                if ($entry.PSObject.Properties.Name -contains 'args') { $entryArgs = @($entry.args) }
                # Only one process can bind the port on the dev box. With the tunnel
                # task installed that process is the task's own ssh, and an -R still
                # sitting in Zed's args just races it for the same port.
                $hasForward = ($entryArgs -contains $expectedForward -and $entryArgs -contains '-R')
                if ($tunnelTask) {
                    if ($hasForward) {
                        Test-Warn 'Zed still carries the -R forward' "'$TunnelTaskName' owns it now; whichever binds first wins and the other retries -- drop -R from args"
                    }
                    else {
                        Test-Ok 'no -R in Zed args' "'$TunnelTaskName' owns the forward"
                    }
                }
                elseif ($hasForward) {
                    Test-Ok 'reverse tunnel configured' "args: $($entryArgs -join ' ')"
                    Test-Warn 'the forward rides Zed connections' 'it dies with whichever project owns it; install the tunnel task instead'
                }
                else {
                    Test-Bad 'nothing provides the reverse tunnel' "install the tunnel task, or put -R $expectedForward in args"
                }

                # Multiplexing would be the natural fix for sharing one forward
                # between projects, and is what the Linux/macOS recipes reach for,
                # but Win32-OpenSSH has never implemented it.
                $control = @($entryArgs | Where-Object { $_ -match '^(-o)?\s*Control(Master|Path|Persist)=' })
                if ($control.Count -gt 0) {
                    Test-Bad 'ControlMaster args present' "Windows OpenSSH cannot multiplex, so these fail every connection with 'getsockname failed: Not a socket' -- remove $($control -join ' ')"
                }

                # Turns the expected "already bound" warning on every connection after
                # the first into a hard connection failure.
                if ($hasForward -and ($entryArgs | Where-Object { $_ -match '^(-o)?\s*ExitOnForwardFailure=yes' })) {
                    Test-Bad 'ExitOnForwardFailure=yes' 'every connection after the first will refuse to connect; drop it'
                }
            }
        }
    }
    catch {
        # Fall back to a text match so a doctor run is still useful on exotic JSONC.
        Test-Warn 'could not parse settings.json' $_.Exception.Message
        $forwardInText = $raw -match [regex]::Escape($expectedForward)
        if ($tunnelTask) {
            if ($forwardInText) { Test-Warn 'the forward appears in settings.json (text match)' "'$TunnelTaskName' owns it; drop -R from args" }
            else { Test-Ok 'no forward in settings.json (text match)' }
        }
        elseif ($forwardInText) { Test-Ok 'reverse tunnel string present (text match)' }
        else { Test-Bad 'reverse tunnel string not found (text match)' "expected -R $expectedForward, or the tunnel task" }
    }
}

# --- 3. Scheduled Tasks -----------------------------------------------------
function Test-TaskHealth {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Microsoft.Management.Infrastructure.CimInstance]$Task
    )
    Test-Ok "task '$Name' registered" "state: $($Task.State)"
    $info = Get-ScheduledTaskInfo -TaskName $Name -ErrorAction SilentlyContinue
    if ($info) { Test-Ok 'last run' "$($info.LastRunTime) (result $($info.LastTaskResult))" }
    if ($Task.Settings.MultipleInstances -ne 'IgnoreNew') {
        Test-Warn 'MultipleInstances is not IgnoreNew' 'the watchdog may stack duplicate instances'
    }
    $hasWatchdog = @($Task.Triggers | Where-Object { $_.Repetition -and $_.Repetition.Interval }).Count -gt 0
    if ($hasWatchdog) { Test-Ok 'watchdog trigger present' } else { Test-Warn 'no repeating watchdog trigger' }
}

Write-Host ''
Write-Host 'Scheduled Tasks'
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) {
    Test-Bad "task '$TaskName' not registered" 'run install-zed-listener.ps1'
}
else {
    Test-TaskHealth -Name $TaskName -Task $task
}

if (-not $tunnelTask) {
    Test-Warn "task '$TunnelTaskName' not registered" 'without it the forward depends on a Zed project staying open'
}
else {
    Test-TaskHealth -Name $TunnelTaskName -Task $tunnelTask
}

# --- 4. Listener ------------------------------------------------------------
Write-Host ''
Write-Host 'Listener'
$listening = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
$loopback = @($listening | Where-Object { $_.LocalAddress -eq '127.0.0.1' })
if ($loopback.Count -eq 0) {
    Test-Bad "nothing listening on 127.0.0.1:$Port"
}
else {
    $owner = Get-Process -Id $loopback[0].OwningProcess -ErrorAction SilentlyContinue
    Test-Ok "listening on 127.0.0.1:$Port" "pid $($loopback[0].OwningProcess) ($($owner.ProcessName))"
}
$wildcard = @($listening | Where-Object { $_.LocalAddress -notin @('127.0.0.1', '::1') })
if ($wildcard.Count -gt 0) {
    Test-Bad 'port is bound beyond loopback' (($wildcard | ForEach-Object { $_.LocalAddress }) -join ', ')
}

# --- 5. Tunnel --------------------------------------------------------------
if ($tunnelTask) {
    Write-Host ''
    Write-Host 'Tunnel'
    # PowerShell unrolls a one-element array on return, so re-wrap it here.
    $forwarders = @(Get-ForwardSshProcess)
    $signature = [regex]::Escape('ExitOnForwardFailure=yes')
    $rival = @($forwarders | Where-Object { $_.CommandLine -notmatch $signature })
    $rivalPids = ($rival | ForEach-Object { $_.ProcessId }) -join ', '

    # Existence proves nothing: ExitOnForwardFailure kills a losing claimant a
    # second or two into every retry, so merely catching one alive would report a
    # tunnel that never binds. Surviving that window is the evidence.
    $ours = @($forwarders | Where-Object { $_.CommandLine -match $signature })
    $ssh = @($ours | Where-Object { ((Get-Date) - $_.CreationDate).TotalSeconds -ge $EstablishedSeconds })

    if ($ssh.Count -gt 0) { $script:TunnelState = 'bound' }
    elseif ($ours.Count -gt 0) { $script:TunnelState = 'starting' }

    if ($ssh.Count -gt 0) {
        Test-Ok "ssh holding -R $expectedForward" "pid $($ssh[0].ProcessId)"
        if ($ssh.Count -gt 1) {
            Test-Warn 'more than one tunnel ssh' (($ssh | ForEach-Object { $_.ProcessId }) -join ', ')
        }
        if ($rival.Count -gt 0) {
            Test-Warn 'a Zed connection also asks for this forward' "pid $rivalPids -- it lost the race and is running without one"
        }
    }
    elseif ($rival.Count -gt 0) {
        Test-Bad 'the tunnel cannot bind the forward' "pid $rivalPids started while -R was still in Zed's args and most likely still holds it; reconnect those projects and the task takes the port"
    }
    elseif ($ours.Count -gt 0) {
        Test-Warn 'tunnel ssh just started' "pid $($ours[0].ProcessId), too young to tell whether the forward took"
    }
    else {
        Test-Bad "no ssh holding -R $expectedForward" "the supervisor retries with backoff; check $(Join-Path $InstallDir 'zed-tunnel.log')"
    }
}

# --- 6. Placement inputs ----------------------------------------------------
# The two things the listener decides no-flag vs --reuse from: a live Zed process,
# and what that Zed's workspace database says is open for this host.
Write-Host ''
Write-Host 'Placement'
$dbPath = Resolve-ZedDbPath -Explicit $ZedDb
$stateFile = Join-Path $InstallDir 'open-projects.txt'
if (Test-ZedRunning) {
    Test-Ok 'a Zed process is running'
}
else {
    Test-Warn 'no Zed process running' "placement resets $stateFile on the next request"
}
try {
    $sessionId = Get-ZedDbSessionId -Database $dbPath
    Test-Ok 'workspace database readable' "$dbPath (session $(if ($sessionId) { $sessionId } else { 'unset' }))"

    $openPaths = @(Get-ZedDbOpenPath -Database $dbPath -RemoteHost $RemoteHost)
    if ($openPaths.Count -gt 0) {
        Test-Ok "open remote workspaces for '$RemoteHost' this session"
        $openPaths | ForEach-Object { Write-Host "         | $_" -ForegroundColor DarkGray }
    }
    else {
        Test-Ok "no remote workspaces open for '$RemoteHost' this session" "the next 'zed .' opens with --reuse"
    }
}
catch {
    Test-Warn 'workspace database not readable' "$($_.Exception.Message) -- placement falls back to $stateFile, which sees only what the listener opened itself"
}

# --- 7. Logs ----------------------------------------------------------------
function Show-Log {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Path
    )
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path
        Test-Ok $Label "$Path ($([int]($item.Length / 1KB)) KB, modified $($item.LastWriteTime))"
        Get-Content -LiteralPath $Path -Tail 3 | ForEach-Object { Write-Host "         | $_" -ForegroundColor DarkGray }
    }
    else {
        Test-Warn "no $Label yet" $Path
    }
}

Write-Host ''
Write-Host 'Logs'
Show-Log -Label 'listener log' -Path (Join-Path $InstallDir 'zed-listener.log')
if ($tunnelTask) { Show-Log -Label 'tunnel log' -Path (Join-Path $InstallDir 'zed-tunnel.log') }

# --- 8. Optional probe ------------------------------------------------------
if ($Probe) {
    Write-Host ''
    Write-Host 'Probe (opens a Zed window)'
    try {
        $client = [System.Net.Sockets.TcpClient]::new('127.0.0.1', $Port)
        $writer = [System.IO.StreamWriter]::new($client.GetStream())
        $writer.WriteLine("ssh://$RemoteHost/")
        $writer.Flush(); $client.Close()
        Test-Ok 'probe URL delivered' "ssh://$RemoteHost/"
    }
    catch {
        Test-Bad 'probe failed' $_.Exception.Message
    }
}

# --- 9. Optional remote check ----------------------------------------------
if ($CheckRemote) {
    Write-Host ''
    Write-Host "Remote ($RemoteHost)"
    if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
        Test-Warn 'no ssh client on PATH'
    }
    else {
        $remoteProbe = "command -v zed >/dev/null && echo SENDER_OK || echo SENDER_MISSING; (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -q '127.0.0.1:$Port' && echo TUNNEL_OK || echo TUNNEL_MISSING"
        $result = & ssh.exe -o BatchMode=yes -o ConnectTimeout=10 $RemoteHost $remoteProbe 2>&1
        $text = ($result | Out-String)
        if ($text -match 'SENDER_OK') { Test-Ok 'zed sender on remote PATH' } else { Test-Warn 'no zed sender on remote PATH' }
        if ($text -match 'TUNNEL_OK') {
            # Something listens there, which is not the same as it reaching here.
            # A session abandoned when this machine slept holds the port open and
            # accepts connections while the bytes go nowhere, so the sender
            # reports success and no window ever appears.
            if ($script:TunnelState -eq 'bound' -or -not $tunnelTask) {
                Test-Ok "remote sshd is forwarding 127.0.0.1:$Port"
            }
            elseif ($script:TunnelState -eq 'starting') {
                Test-Warn "cannot tell whose forward holds 127.0.0.1:$Port" 'the tunnel ssh is too young to have proven itself; re-run in a few seconds'
            }
            else {
                Test-Bad "a stale forward holds 127.0.0.1:$Port" "it still accepts connections and drops them, so 'zed .' will look like it worked; see the README for how to clear it"
            }
        }
        elseif ($tunnelTask) {
            Test-Bad "remote is not listening on 127.0.0.1:$Port" "'$TunnelTaskName' should keep it bound at all times"
        }
        else {
            Test-Warn "remote is not listening on 127.0.0.1:$Port" 'expected unless a Zed remote session is currently connected'
        }
    }
}

Write-Host ''
if ($script:Failures -eq 0) {
    Write-Host "All checks passed ($script:Warnings warning(s))." -ForegroundColor Green
    exit 0
}
Write-Host "$script:Failures check(s) failed, $script:Warnings warning(s)." -ForegroundColor Red
exit 1
