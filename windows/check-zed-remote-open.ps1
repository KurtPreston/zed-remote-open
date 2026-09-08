<#
.SYNOPSIS
    Checks that every piece of the Zed remote-open path is in place on Windows.

.DESCRIPTION
    Verifies the Zed CLI, the ssh_connections entry with its reverse-forward and
    connection-sharing args, the Scheduled Task, the loopback listener, and the
    log. Nothing here changes state unless you pass -Probe.

.PARAMETER RemoteHost
    The ssh_connections host alias expected to carry the reverse forward.

.PARAMETER Probe
    Send a real URL through the listener. This opens a Zed window.

.PARAMETER CheckRemote
    Read-only SSH check that the dev box is listening on the tunnel port and has
    a zed sender on PATH. Requires an ssh client and a working host alias.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int]$Port = 7682,

    [string]$RemoteHost = 'desktop',

    [string]$ZedExe,

    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'zed-listener'),

    [string]$TaskName = 'zed-open-listener',

    [switch]$Probe,

    [switch]$CheckRemote
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ZedCli.ps1')

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
    $expectedForward = "{0}:127.0.0.1:{0}" -f $Port
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
                if ($entryArgs -contains $expectedForward -and $entryArgs -contains '-R') {
                    Test-Ok 'reverse tunnel configured' "args: $($entryArgs -join ' ')"
                }
                else {
                    Test-Bad 'reverse tunnel missing' "expected: -R $expectedForward   found: $($entryArgs -join ' ')"
                }

                # Only one connection can bind the port on the dev box, so without a
                # shared master the forward belongs to whichever project connected
                # first and dies with it. Zed's own ControlPath is a random temp dir,
                # which no other connection can find.
                $controlPath = $entryArgs | Where-Object { $_ -match '^(-o)?\s*ControlPath=' } | Select-Object -First 1
                $controlPersist = $entryArgs | Where-Object { $_ -match '^(-o)?\s*ControlPersist=' } | Select-Object -First 1
                if (-not $controlPath) {
                    Test-Warn 'no shared ControlPath' 'projects each get their own connection; the tunnel dies with whichever one owns it'
                }
                elseif (-not $controlPersist) {
                    Test-Warn 'ControlPath without ControlPersist' "$controlPath -- the tunnel still dies with the last project to close"
                }
                else {
                    Test-Ok 'connection sharing configured' "$controlPath $controlPersist"
                }

                # Turns the expected "already bound" warning on every connection after
                # the first into a hard connection failure.
                if ($entryArgs | Where-Object { $_ -match '^(-o)?\s*ExitOnForwardFailure=yes' }) {
                    Test-Bad 'ExitOnForwardFailure=yes' 'every connection after the first will refuse to connect; drop it'
                }
            }
        }
    }
    catch {
        # Fall back to a text match so a doctor run is still useful on exotic JSONC.
        Test-Warn 'could not parse settings.json' $_.Exception.Message
        if ($raw -match [regex]::Escape($expectedForward)) { Test-Ok 'reverse tunnel string present (text match)' }
        else { Test-Bad 'reverse tunnel string not found (text match)' "expected -R $expectedForward" }
    }
}

# --- 3. Scheduled Task ------------------------------------------------------
Write-Host ''
Write-Host 'Scheduled Task'
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) {
    Test-Bad "task '$TaskName' not registered" 'run install-zed-listener.ps1'
}
else {
    Test-Ok "task '$TaskName' registered" "state: $($task.State)"
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($info) { Test-Ok 'last run' "$($info.LastRunTime) (result $($info.LastTaskResult))" }
    if ($task.Settings.MultipleInstances -ne 'IgnoreNew') {
        Test-Warn 'MultipleInstances is not IgnoreNew' 'the watchdog may stack duplicate instances'
    }
    $hasWatchdog = @($task.Triggers | Where-Object { $_.Repetition -and $_.Repetition.Interval }).Count -gt 0
    if ($hasWatchdog) { Test-Ok 'watchdog trigger present' } else { Test-Warn 'no repeating watchdog trigger' }
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

# --- 5. Log -----------------------------------------------------------------
Write-Host ''
Write-Host 'Log'
$logFile = Join-Path $InstallDir 'zed-listener.log'
if (Test-Path -LiteralPath $logFile) {
    $item = Get-Item -LiteralPath $logFile
    Test-Ok 'log file' "$logFile ($([int]($item.Length / 1KB)) KB, modified $($item.LastWriteTime))"
    Get-Content -LiteralPath $logFile -Tail 3 | ForEach-Object { Write-Host "         | $_" -ForegroundColor DarkGray }
}
else {
    Test-Warn 'no log file yet' $logFile
}

# --- 6. Optional probe ------------------------------------------------------
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

# --- 7. Optional remote check ----------------------------------------------
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
            Test-Ok "remote sshd is forwarding 127.0.0.1:$Port"
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
