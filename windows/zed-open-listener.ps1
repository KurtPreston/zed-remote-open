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

.PARAMETER StateFile
    Remembers which URLs this listener has opened, so a project that is already
    open is focused rather than added to the window a second time. See the comment
    on Resolve-Placement for why the listener has to track this itself.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int]$Port = 7682,

    [string]$ZedExe,

    [string]$LogFile,

    [string]$StateFile = (Join-Path $env:LOCALAPPDATA 'zed-listener\open-projects.txt'),

    [int]$ReadTimeoutMs = 5000,

    [int]$MaxRequestBytes = 8192,

    [int]$LaunchWaitSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ZedLog.ps1')

# Host, then an absolute POSIX path, then optional :line[:col]. The path charset
# excludes ';', '&', '|', quotes and control characters, so a request cannot smuggle
# shell syntax even if some future caller does interpolate it. ':' is excluded from
# the path so the line/column suffix is never ambiguous.
$UrlPattern = '^ssh://[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9 ._+@~%/-]*(?::[0-9]{1,9}(?::[0-9]{1,9})?)?$'

# One Zed process owns every window, so Process.MainWindowTitle only ever reports
# one of them. Enumerating gives the active project of each window, which is the
# only cheap evidence of a project someone opened through Zed's own UI.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class ZedWindows {
    private delegate bool EnumProc(IntPtr window, IntPtr param);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumProc callback, IntPtr param);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextW(IntPtr window, StringBuilder text, int count);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    public static List<string> Titles(uint[] processIds) {
        List<string> titles = new List<string>();
        EnumWindows(delegate(IntPtr window, IntPtr param) {
            if (!IsWindowVisible(window)) { return true; }
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            if (Array.IndexOf(processIds, processId) < 0) { return true; }
            StringBuilder text = new StringBuilder(512);
            GetWindowTextW(window, text, text.Capacity);
            if (text.Length > 0) { titles.Add(text.ToString()); }
            return true;
        }, IntPtr.Zero);
        return titles;
    }
}
'@

function Get-ZedWindowTitle {
    $procIds = @(
        Get-Process -Name 'Zed' -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Id
    )
    if ($procIds.Count -eq 0) { return @() }
    return @([ZedWindows]::Titles([uint32[]]$procIds))
}

function Get-UrlPath {
    param([Parameter(Mandatory)][string]$Url)
    # Host off the front, any :line[:col] off the back, leaving the dev box path.
    ($Url -replace '^ssh://[^/]+', '') -replace ':[0-9]+(?::[0-9]+)?$', ''
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
# So the listener picks between them, and every uncertain case resolves to no
# flag: the cost of being wrong that way is a stray window, against a corrupted
# project the other way.
function Resolve-Placement {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$WindowTitles,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$OpenedUrls
    )

    if ($WindowTitles.Count -eq 0) {
        return [pscustomobject]@{ Reuse = $false; Reason = 'no zed window to reuse' }
    }

    if ($Url -match ':[0-9]+(?::[0-9]+)?$') {
        return [pscustomobject]@{ Reuse = $false; Reason = 'a line number means a file, not a project' }
    }

    $path = Get-UrlPath -Url $Url
    foreach ($opened in $OpenedUrls) {
        $openedPath = Get-UrlPath -Url $opened
        if ($path -eq $openedPath) {
            return [pscustomobject]@{ Reuse = $false; Reason = 'opened here already' }
        }
        if ($openedPath -and $path.StartsWith($openedPath.TrimEnd('/') + '/', [StringComparison]::Ordinal)) {
            return [pscustomobject]@{ Reuse = $false; Reason = "inside $openedPath, opened here already" }
        }
    }

    $leaf = ($path -split '/')[-1]
    if ($leaf -and $WindowTitles -contains $leaf) {
        return [pscustomobject]@{ Reuse = $false; Reason = "a window is titled '$leaf'" }
    }

    return [pscustomobject]@{ Reuse = $true; Reason = 'not known to be open' }
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

$zedPath = $null
try {
    $zedPath = Resolve-ZedExe -Explicit $ZedExe
}
catch {
    Write-Log $_.Exception.Message 'FATAL'
    exit 1
}

if ($PSVersionTable.PSVersion.Major -lt 6) {
    Write-Log 'requires PowerShell 7+ (ProcessStartInfo.ArgumentList is unavailable on 5.1)' 'FATAL'
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
Write-Log "state  : $StateFile ($($script:OpenedUrls.Count) open)"

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

            $titles = @(Get-ZedWindowTitle)
            $placement = Resolve-Placement -Url $url -WindowTitles $titles -OpenedUrls $script:OpenedUrls
            Write-Log "$(if ($placement.Reuse) { 'adding to the open window' } else { 'opening as-is' }) -- $($placement.Reason)"

            Invoke-ZedOpen -Url $url -Exe $zedPath -WaitSeconds $LaunchWaitSeconds -Reuse:$placement.Reuse
            Save-OpenedUrl -Url $url -Reset:($titles.Count -eq 0)
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
