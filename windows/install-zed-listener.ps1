<#
.SYNOPSIS
    Installs the Zed remote-open listener and its reverse tunnel as hidden,
    self-healing Scheduled Tasks.

.DESCRIPTION
    Copies both scripts into a stable local directory (a Scheduled Task cannot rely
    on reaching a \\wsl$ or network path), resolves the Zed CLI and ssh.exe now so
    the tasks do not depend on runtime PATH, and registers each behind a .vbs
    wrapper that runs it with no console window.

    The tunnel task owns the `-R` forward so it survives Zed projects opening and
    closing. Once it is installed, drop `-R` from the ssh_connections args in Zed's
    settings.json; leaving it there makes the two fight over the same remote port.

    Re-running is idempotent: previous instances are stopped and the tasks are
    re-registered in place.

.EXAMPLE
    .\install-zed-listener.ps1

.EXAMPLE
    .\install-zed-listener.ps1 -RemoteHost devbox -ZedExe 'C:\Tools\Zed\bin\Zed.exe'

.EXAMPLE
    .\install-zed-listener.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int]$Port = 7682,

    [string]$RemoteHost = 'desktop',

    [string]$ZedExe,

    [string]$SshExe,

    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'zed-listener'),

    [string]$TaskName = 'zed-open-listener',

    [string]$TunnelTaskName = 'zed-open-tunnel',

    [switch]$NoTunnel,

    [switch]$Uninstall,

    [switch]$NoStart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ZedCli.ps1')

$LogName = 'ZedLog.ps1'
$PlacementName = 'ZedPlacement.ps1'
$ListenerName = 'zed-open-listener.ps1'
$TunnelName = 'zed-tunnel.ps1'

# Everything the tasks need beside them in InstallDir; the listener dot-sources
# the first two from its own directory.
$ScriptNames = @($LogName, $PlacementName, $ListenerName, $TunnelName)

$LogPath = Join-Path $InstallDir $LogName
$ListenerPath = Join-Path $InstallDir $ListenerName
$TunnelPath = Join-Path $InstallDir $TunnelName

$ListenerVbs = Join-Path $InstallDir 'zed-open-listener-hidden.vbs'
$TunnelVbs = Join-Path $InstallDir 'zed-open-tunnel-hidden.vbs'

$LogFile = Join-Path $InstallDir 'zed-listener.log'
$TunnelLogFile = Join-Path $InstallDir 'zed-tunnel.log'

$Forward = '{0}:127.0.0.1:{0}' -f $Port

# Matches the wscript, cmd and pwsh layers in one pass: each .vbs and .ps1 file
# name shares a stem, so matching the stem catches all three. The tunnel also has
# an ssh.exe child, which carries none of that and has to be killed too or it keeps
# the remote port bound. That one is matched on the pair of options only we pass,
# so a Zed session still configured with the same -R is left alone.
$ListenerMatch = [regex]::Escape('zed-open-listener')
$TunnelSshMatch = '(?=.*{0})(?=.*{1})' -f
    [regex]::Escape('ExitOnForwardFailure=yes'), [regex]::Escape("-R $Forward")
$TunnelMatch = '{0}|{1}' -f [regex]::Escape('zed-tunnel'), $TunnelSshMatch

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Detail { param([string]$Message) Write-Host "    $Message" }

function Resolve-PwshExe {
    $here = Join-Path $PSHOME 'pwsh.exe'
    if (Test-Path -LiteralPath $here -PathType Leaf) { return $here }

    $onPath = Get-Command -Name 'pwsh' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($onPath) { return $onPath.Source }

    $default = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path -LiteralPath $default -PathType Leaf) { return $default }

    throw 'PowerShell 7 (pwsh.exe) is required but was not found'
}

function Resolve-SshExe {
    param([string]$Explicit)

    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit -PathType Leaf)) {
            throw "-SshExe '$Explicit' does not exist"
        }
        return (Resolve-Path -LiteralPath $Explicit).Path
    }

    # Prefer the inbox client over PATH: a Git or WSL shim there may not be able to
    # reach the same ~/.ssh, and the task needs the one that works unattended.
    $inbox = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
    if (Test-Path -LiteralPath $inbox -PathType Leaf) { return $inbox }

    $onPath = Get-Command -Name 'ssh' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($onPath) { return $onPath.Source }

    throw 'ssh.exe was not found; install the OpenSSH client or pass -SshExe'
}

function Get-ComponentProcess {
    param([Parameter(Mandatory)][string]$Pattern)
    @(
        Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='wscript.exe' OR Name='cmd.exe' OR Name='ssh.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.CommandLine -and
                $_.CommandLine -match $Pattern -and
                $_.ProcessId -ne $PID
            }
    )
}

# Retries because the watchdog trigger can start a fresh instance while we are
# killing the previous one; a single pass can leave an orphan holding the port.
function Stop-Component {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Pattern
    )

    if (Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    }

    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        # PowerShell unrolls a one-element array on return, so re-wrap it here.
        $stale = @(Get-ComponentProcess -Pattern $Pattern)
        if ($stale.Count -eq 0) { break }
        foreach ($proc in $stale) {
            try {
                Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
                Write-Detail "stopped old $($proc.Name) (pid $($proc.ProcessId))"
            }
            catch { }
        }
        Start-Sleep -Milliseconds 500
    }
}

function Write-HiddenVbs {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string]$ArgLine
    )
    # Output goes to NUL, not to the log, and each script opens the log itself.
    # A `>> file` redirect here would give cmd an inheritable handle to that file,
    # which Zed and the ssh.exe it spawns inherit and hold for the whole remote
    # session -- after which no restart could reopen it. NUL cannot be pinned.
    # cmd /c idiom for a spaced exe path plus redirection: cmd /c ""exe" args > NUL 2>&1"
    $cmd = 'cmd /c "' + '"' + $Exe + '" ' + $ArgLine + ' > NUL 2>&1' + '"'
    $literal = $cmd.Replace('"', '""')   # VBS escapes a quote by doubling it
    $content = @"
' Generated by install-zed-listener.ps1. Runs the command hidden (style 0).
Set shell = CreateObject("WScript.Shell")
shell.Run "$literal", 0, True
"@
    Set-Content -LiteralPath $Path -Value $content -Encoding ASCII
    Write-Detail "wrote $Path"
}

function Register-ComponentTask {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$VbsPath
    )
    $me = "$env:USERDOMAIN\$env:USERNAME"
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f $VbsPath)
    $atLogon = New-ScheduledTaskTrigger -AtLogOn -User $me
    # Watchdog: fires every minute and is skipped by IgnoreNew while the script
    # is alive, so it only has an effect once the script has actually died.
    $watchdog = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable -Hidden

    Register-ScheduledTask -TaskName $Name -Action $action -Trigger @($atLogon, $watchdog) `
        -Principal $principal -Settings $settings -Force | Out-Null
    Write-Detail "registered task '$Name'"
}

function Unregister-ComponentTask {
    param([Parameter(Mandatory)][string]$Name)
    if (Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false
        Write-Detail "unregistered task '$Name'"
    }
    else {
        Write-Detail "no task '$Name' registered"
    }
}

function Wait-ForListening {
    param([int]$TimeoutSeconds = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $listening = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalAddress -eq '127.0.0.1' }
        if ($listening) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Wait-ForTunnel {
    param([int]$TimeoutSeconds = 30, [int]$SettleSeconds = 5)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $ssh = @(Get-ComponentProcess -Pattern $TunnelSshMatch |
            Where-Object { $_.Name -eq 'ssh.exe' })
        if ($ssh.Count -gt 0) {
            # ExitOnForwardFailure kills a losing claimant within a second or two,
            # so an ssh that merely exists is not yet evidence of a live forward.
            Start-Sleep -Seconds $SettleSeconds
            if (Get-Process -Id $ssh[0].ProcessId -ErrorAction SilentlyContinue) { return $true }
            continue
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

if ($Uninstall) {
    Write-Step 'uninstalling'

    # Unregister before killing anything. Stopping first leaves a window in which
    # the one-minute watchdog can start a replacement that then outlives the task.
    Unregister-ComponentTask -Name $TaskName
    Unregister-ComponentTask -Name $TunnelTaskName

    Stop-Component -Name $TaskName -Pattern $ListenerMatch
    Stop-Component -Name $TunnelTaskName -Pattern $TunnelMatch

    if (Test-Path -LiteralPath $InstallDir) {
        try {
            Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction Stop
            Write-Detail "removed $InstallDir (including the logs)"
        }
        catch {
            # An old install could leave a log pinned by a Zed session. The tasks
            # are already gone, so report it rather than failing the uninstall.
            Write-Warning "could not fully remove $InstallDir -- $($_.Exception.Message)"
            Write-Detail 'the tasks are unregistered; delete the folder once Zed is closed'
        }
    }

    Write-Host ''
    Write-Host 'Uninstalled.' -ForegroundColor Green
    return
}

Write-Step 'resolving dependencies'
$zedPath = Resolve-ZedCliPath -Explicit $ZedExe
Write-Detail "zed cli : $zedPath"
$pwshPath = Resolve-PwshExe
Write-Detail "pwsh    : $pwshPath"
$sshPath = $null
if (-not $NoTunnel) {
    $sshPath = Resolve-SshExe -Explicit $SshExe
    Write-Detail "ssh     : $sshPath"
}

foreach ($name in $ScriptNames) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name) -PathType Leaf)) {
        throw "$name not found next to the installer"
    }
}

Write-Step 'stopping any running instance'
Stop-Component -Name $TaskName -Pattern $ListenerMatch
if (-not $NoTunnel) { Stop-Component -Name $TunnelTaskName -Pattern $TunnelMatch }

Write-Step "installing to $InstallDir"
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
foreach ($name in $ScriptNames) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $InstallDir $name) -Force
    Write-Detail "copied $name"
}

$listenerArgs = '-NoLogo -NoProfile -File "{0}" -Port {1} -ZedExe "{2}" -LogFile "{3}"' -f
    $ListenerPath, $Port, $zedPath, $LogFile
Write-HiddenVbs -Path $ListenerVbs -Exe $pwshPath -ArgLine $listenerArgs

if (-not $NoTunnel) {
    $tunnelArgs = '-NoLogo -NoProfile -File "{0}" -Port {1} -RemoteHost "{2}" -SshExe "{3}" -LogFile "{4}"' -f
        $TunnelPath, $Port, $RemoteHost, $sshPath, $TunnelLogFile
    Write-HiddenVbs -Path $TunnelVbs -Exe $pwshPath -ArgLine $tunnelArgs
}

Write-Step 'registering Scheduled Tasks'
Register-ComponentTask -Name $TaskName -VbsPath $ListenerVbs
if ($NoTunnel) {
    Unregister-ComponentTask -Name $TunnelTaskName
}
else {
    Register-ComponentTask -Name $TunnelTaskName -VbsPath $TunnelVbs
}

if ($NoStart) {
    Write-Host ''
    Write-Host 'Installed (not started; -NoStart was given).' -ForegroundColor Green
    return
}

Write-Step 'starting'
Start-ScheduledTask -TaskName $TaskName
if (Wait-ForListening) {
    Write-Detail "listening on 127.0.0.1:$Port"
}
else {
    Write-Warning "not listening on 127.0.0.1:$Port yet -- check $LogFile"
}

if (-not $NoTunnel) {
    Start-ScheduledTask -TaskName $TunnelTaskName
    if (Wait-ForTunnel) {
        Write-Detail "tunnel to '$RemoteHost' up"
    }
    else {
        Write-Warning "no tunnel to '$RemoteHost' yet -- check $TunnelLogFile"
    }
}

Write-Host ''
Write-Host 'Installed.' -ForegroundColor Green
Write-Host "  tasks : $TaskName$(if (-not $NoTunnel) { ", $TunnelTaskName" })"
Write-Host "  dir   : $InstallDir"
Write-Host "  logs  : $LogFile$(if (-not $NoTunnel) { ", $TunnelLogFile" })"
Write-Host "  port  : 127.0.0.1:$Port"
if (-not $NoTunnel) {
    Write-Host ''
    Write-Host "The tunnel task now owns the -R $Forward forward." -ForegroundColor Yellow
    Write-Host '  Remove -R from the ssh_connections args in Zed settings.json, or the two'
    Write-Host '  will compete for the same port on the dev box. Run check-zed-remote-open.ps1'
    Write-Host '  to confirm.'
}
