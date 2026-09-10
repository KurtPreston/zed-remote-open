<#
.SYNOPSIS
    Opens Zed remote workspaces requested by a dev box over a reverse SSH tunnel.

.DESCRIPTION
    Binds a TCP listener on loopback only. Each connection carries exactly one
    newline-terminated ssh:// URL, which is validated against a strict pattern and
    then handed to the local Zed CLI as a single argument. See docs/PROTOCOL.md.

    Log lines go to stdout, and additionally to -LogFile when given. The listener
    opens that file itself rather than letting the wrapper redirect stdout into it;
    see the comment on Open-LogWriter in ZedLog.ps1 for why that matters.

.PARAMETER Port
    Loopback port to listen on. Must match the remote end of the SSH -R forward.

.PARAMETER ZedExe
    Absolute path to the Zed CLI. The installer bakes this in, because a
    Scheduled Task runs with a minimal PATH that does not include Zed.

.PARAMETER LogFile
    Append log lines to this file in addition to stdout.

.PARAMETER ZedDb
    Zed's own workspace database, which names the remote projects open in the
    running session and is the primary evidence for window placement. Defaults to
    the 0-stable database under %LOCALAPPDATA%\Zed (or %APPDATA%\Zed if the install
    landed there); pass this to point at another channel.

.PARAMETER StateFile
    The URLs this listener has opened, used for placement only when the workspace
    database cannot be read. See the comment on Resolve-Placement.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int]$Port = 7682,

    [string]$ZedExe,

    [string]$LogFile,

    [string]$ZedDb,

    [string]$StateFile = (Join-Path $env:LOCALAPPDATA 'zed-listener\open-projects.txt'),

    [int]$ReadTimeoutMs = 5000,

    [int]$MaxRequestBytes = 8192,

    [int]$LaunchWaitSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ZedLog.ps1')
. (Join-Path $PSScriptRoot 'ZedPlacement.ps1')

# Host, then an absolute POSIX path, then optional :line[:col]. The path charset
# excludes ';', '&', '|', quotes and control characters, so a request cannot smuggle
# shell syntax even if some future caller does interpolate it. ':' is excluded from
# the path so the line/column suffix is never ambiguous.
$UrlPattern = '^ssh://[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9 ._+@~%/-]*(?::[0-9]{1,9}(?::[0-9]{1,9})?)?$'

function Get-UrlPath {
    param([Parameter(Mandatory)][string]$Url)
    # Host off the front, any :line[:col] off the back, leaving the dev box path.
    ($Url -replace '^ssh://[^/]+', '') -replace ':[0-9]+(?::[0-9]+)?$', ''
}

function Get-UrlHost {
    param([Parameter(Mandatory)][string]$Url)
    # ssh://<host>/... -> <host>, the alias Zed's ssh_connections knows it by.
    ($Url -replace '^ssh://', '') -replace '/.*$', ''
}

# Zed's CLI cannot express "focus this project if it is open, otherwise put it in
# the window I already have". Passing no flag does the first half: an exact path
# match activates the existing workspace, but anything else opens a new window,
# because open_remote_project ignores the sidebar preference that the local path
# honours. `--reuse` does the second half by naming a target window, but it also
# turns off the already-open check, and re-opening a live project that way
# restarts its remote server underneath the running workspace and leaves the
# worktree broken.
#
# So the listener picks between them, and asks Zed's own workspace database which
# remote projects are open in the running session -- which sees the ones opened
# through Zed's UI too, not just the ones it opened itself. `open-projects.txt` is
# kept only as a fallback for when the database cannot be read. Every uncertain
# case resolves to no flag: the cost of being wrong that way is a stray window,
# against a corrupted project the other way.
#
# The `Reset` field rides along on the decision because one signal settles both:
# see the comment on Save-OpenedUrl's -Reset.
function Resolve-Placement {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$OpenedUrls,
        [Parameter(Mandatory)][string]$Database
    )

    # First, and not reorderable: Zed leaves session_id bound on its workspace rows
    # after a quit or a crash so it can restore them next launch, so with no
    # process alive the query below would name a dead session's projects as open.
    if (-not (Test-ZedRunning)) {
        return [pscustomobject]@{ Reuse = $false; Reset = $true; Reason = 'no zed process to reuse' }
    }

    if ($Url -match ':[0-9]+(?::[0-9]+)?$') {
        return [pscustomobject]@{ Reuse = $false; Reset = $false; Reason = 'a line number means a file, not a project' }
    }

    $path = Get-UrlPath -Url $Url

    try {
        $open = @(Get-ZedDbOpenPath -Database $Database -RemoteHost (Get-UrlHost -Url $Url))
        if (Test-PathIsOpen -Path $path -OpenPaths $open) {
            return [pscustomobject]@{ Reuse = $false; Reset = $false; Reason = 'open in this session' }
        }
        return [pscustomobject]@{ Reuse = $true; Reset = $false; Reason = 'not open in this session' }
    }
    catch {
        Write-Log "could not read the workspace database -- $($_.Exception.Message)" 'WARN'
    }

    # Database unreadable: fall back to what the listener recorded itself, which
    # sees only its own opens.
    $recorded = @($OpenedUrls | ForEach-Object { Get-UrlPath -Url $_ })
    if (Test-PathIsOpen -Path $path -OpenPaths $recorded) {
        return [pscustomobject]@{ Reuse = $false; Reset = $false; Reason = 'opened here already (state fallback)' }
    }
    return [pscustomobject]@{ Reuse = $true; Reset = $false; Reason = 'not known to be open (state fallback)' }
}

function Get-OpenedUrl {
    param([string]$Path)

    $opened = [System.Collections.Generic.List[string]]::new()
    if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        try {
            foreach ($line in Get-Content -LiteralPath $Path -ErrorAction Stop) {
                $trimmed = $line.Trim()
                if ($trimmed -and -not $opened.Contains($trimmed)) { $opened.Add($trimmed) }
            }
        }
        catch {
            Write-Log "could not read '$Path' -- $($_.Exception.Message)" 'WARN'
        }
    }
    return , $opened
}

function Save-OpenedUrl {
    param(
        [Parameter(Mandatory)][string]$Url,
        # A Zed started by this listener opens only the path it was given: the CLI
        # never restores the previous session, so anything remembered from the last
        # run is gone and keeping it would strand the list permanently "open".
        [switch]$Reset
    )

    if ($Reset) { $script:OpenedUrls.Clear() }
    if (-not $script:OpenedUrls.Contains($Url)) { $script:OpenedUrls.Add($Url) }

    if (-not $StateFile) { return }
    try {
        $dir = Split-Path -Parent $StateFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Set-Content -LiteralPath $StateFile -Value $script:OpenedUrls.ToArray() -Encoding UTF8
    }
    catch {
        Write-Log "could not write '$StateFile' -- $($_.Exception.Message)" 'WARN'
    }
}

function Resolve-ZedExe {
    param([string]$Explicit)

    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit -PathType Leaf)) {
            throw "-ZedExe '$Explicit' does not exist"
        }
        return (Resolve-Path -LiteralPath $Explicit).Path
    }

    # Fallback for foreground runs only; the Scheduled Task always passes -ZedExe.
    $onPath = Get-Command -Name 'zed' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($onPath) { return $onPath.Source }

    foreach ($candidate in @(
            (Join-Path $env:LOCALAPPDATA 'Programs\Zed\bin\Zed.exe'),
            (Join-Path $env:ProgramFiles 'Zed\bin\Zed.exe')
        )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }

    throw 'could not locate the Zed CLI; pass -ZedExe with an absolute path'
}

# Reads up to the first LF. The sender closes its end right after writing, so EOF
# without a newline is also a complete request.
function Read-RequestLine {
    param(
        [Parameter(Mandatory)][System.Net.Sockets.TcpClient]$Client,
        [Parameter(Mandatory)][int]$TimeoutMs,
        [Parameter(Mandatory)][int]$MaxBytes
    )

    $stream = $Client.GetStream()
    $stream.ReadTimeout = $TimeoutMs
    $buffer = [byte[]]::new(1024)
    $collected = [System.IO.MemoryStream]::new()

    try {
        while ($true) {
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }

            $newlineAt = -1
            for ($i = 0; $i -lt $read; $i++) {
                if ($buffer[$i] -eq 10) { $newlineAt = $i; break }
            }

            # The cap has to be checked on every chunk, including the one holding
            # the newline; otherwise an oversized single line slips through intact.
            $take = if ($newlineAt -ge 0) { $newlineAt } else { $read }
            if ($collected.Length + $take -gt $MaxBytes) {
                throw "request exceeded $MaxBytes bytes"
            }

            $collected.Write($buffer, 0, $take)
            if ($newlineAt -ge 0) { break }
        }
        return [System.Text.Encoding]::UTF8.GetString($collected.ToArray())
    }
    finally {
        $collected.Dispose()
    }
}

function Invoke-ZedOpen {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][int]$WaitSeconds,
        [switch]$Reuse
    )

    # ArgumentList passes the URL as one argv entry with no shell and no string
    # interpolation, so spaces and metacharacters cannot split it into extra args.
    # The flag is a literal chosen here, never anything the request supplied.
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Exe
    if ($Reuse) { $psi.ArgumentList.Add('--reuse') }
    $psi.ArgumentList.Add($Url)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = [System.IO.Path]::GetDirectoryName($Exe)

    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($proc.WaitForExit($WaitSeconds * 1000)) {
        if ($proc.ExitCode -eq 0) {
            Write-Log "opened (zed exited 0)"
        }
        else {
            Write-Log "zed exited $($proc.ExitCode)" 'ERROR'
        }
    }
    else {
        Write-Log "launched zed (pid $($proc.Id)), still running"
    }
}

try {
    $script:LogWriter = Open-LogWriter -Path $LogFile
}
catch {
    # Console-only logging is still better than refusing to run.
    Write-Log "could not open log file '$LogFile' -- $($_.Exception.Message)" 'WARN'
}

$script:OpenedUrls = Get-OpenedUrl -Path $StateFile
$dbPath = Resolve-ZedDbPath -Explicit $ZedDb

$zedPath = $null
try {
    $zedPath = Resolve-ZedExe -Explicit $ZedExe
}
catch {
    Write-Log $_.Exception.Message 'FATAL'
    exit 1
}

if ($PSVersionTable.PSVersion.Major -lt 6) {
    # ArgumentList is unavailable on 5.1, and so is the UTF-8 string marshalling
    # the winsqlite3 imports in ZedPlacement.ps1 need.
    Write-Log 'requires PowerShell 7+' 'FATAL'
    exit 1
}

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
try {
    $listener.Start()
}
catch {
    Write-Log "cannot bind 127.0.0.1:$Port -- $($_.Exception.Message)" 'FATAL'
    exit 1
}

Write-Log "listening on 127.0.0.1:$Port (pid $PID)"
Write-Log "zed cli: $zedPath"
Write-Log "zed db : $dbPath"
Write-Log "state  : $StateFile ($($script:OpenedUrls.Count) open, fallback only)"

try {
    while ($true) {
        # Poll rather than block in AcceptTcpClient so Ctrl+C stays responsive
        # when this is run in the foreground for testing.
        if (-not $listener.Pending()) {
            Start-Sleep -Milliseconds 100
            continue
        }

        $client = $null
        try {
            $client = $listener.AcceptTcpClient()
            $peer = $client.Client.RemoteEndPoint.ToString()

            if (-not $client.Client.RemoteEndPoint.Address.Equals([System.Net.IPAddress]::Loopback)) {
                Write-Log "rejected non-loopback peer $peer" 'WARN'
                continue
            }

            $raw = Read-RequestLine -Client $client -TimeoutMs $ReadTimeoutMs -MaxBytes $MaxRequestBytes
            $url = $raw.Trim()

            if ([string]::IsNullOrWhiteSpace($url)) {
                Write-Log "rejected empty request from $peer" 'WARN'
                continue
            }

            if ($url -notmatch $UrlPattern) {
                # Truncated and single-lined so a hostile payload cannot forge log entries.
                $shown = $url -replace '[\r\n\t]', ' '
                if ($shown.Length -gt 200) { $shown = $shown.Substring(0, 200) + '...' }
                Write-Log "rejected malformed url from ${peer}: '$shown'" 'WARN'
                continue
            }

            Write-Log "opening $url"

            $placement = Resolve-Placement -Url $url -OpenedUrls $script:OpenedUrls -Database $dbPath
            Write-Log "$(if ($placement.Reuse) { 'adding to the open window' } else { 'opening as-is' }) -- $($placement.Reason)"

            Invoke-ZedOpen -Url $url -Exe $zedPath -WaitSeconds $LaunchWaitSeconds -Reuse:$placement.Reuse
            Save-OpenedUrl -Url $url -Reset:$placement.Reset
        }
        catch {
            # One bad request must never take down the loop.
            Write-Log "request failed: $($_.Exception.Message)" 'ERROR'
        }
        finally {
            if ($null -ne $client) {
                try { $client.Dispose() } catch { }
            }
        }
    }
}
finally {
    try { $listener.Stop() } catch { }
    Write-Log 'listener stopped'
}
