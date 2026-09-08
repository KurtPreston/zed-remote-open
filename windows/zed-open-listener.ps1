<#
.SYNOPSIS
    Opens Zed remote workspaces requested by a dev box over a reverse SSH tunnel.

.DESCRIPTION
    Binds a TCP listener on loopback only. Each connection carries exactly one
    newline-terminated ssh:// URL, which is validated against a strict pattern and
    then handed to the local Zed CLI as a single argument. See docs/PROTOCOL.md.

    Log lines go to stdout, and additionally to -LogFile when given. The listener
    opens that file itself rather than letting the wrapper redirect stdout into it;
    see the comment on Open-LogWriter for why that matters.

.PARAMETER Port
    Loopback port to listen on. Must match the remote end of the SSH -R forward.

.PARAMETER ZedExe
    Absolute path to the Zed CLI. The installer bakes this in, because a
    Scheduled Task runs with a minimal PATH that does not include Zed.

.PARAMETER LogFile
    Append log lines to this file in addition to stdout.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int]$Port = 7682,

    [string]$ZedExe,

    [string]$LogFile,

    [int]$ReadTimeoutMs = 5000,

    [int]$MaxRequestBytes = 8192,

    [int]$LaunchWaitSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogWriter = $null

# Host, then an absolute POSIX path, then optional :line[:col]. The path charset
# excludes ';', '&', '|', quotes and control characters, so a request cannot smuggle
# shell syntax even if some future caller does interpolate it. ':' is excluded from
# the path so the line/column suffix is never ambiguous.
$UrlPattern = '^ssh://[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9 ._+@~%/-]*(?::[0-9]{1,9}(?::[0-9]{1,9})?)?$'

# The listener owns its log file instead of having the wrapper redirect stdout
# into it. When a process starts a child with UseShellExecute=false, Windows
# duplicates *every* inheritable handle into that child -- redirecting the child's
# std streams does not prevent it. A shell redirect like `>> log` produces exactly
# such an inheritable handle, so Zed, and then the long-lived ssh.exe Zed spawns
# for the remote session, would hold the log open for the whole session. The next
# restart could then never reopen it, which silently disabled the watchdog.
# A handle opened here is not inheritable, so nothing downstream can pin it.
function Open-LogWriter {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    # ReadWrite sharing so the log stays tailable while the listener runs.
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Append,
        [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $writer = [System.IO.StreamWriter]::new($stream)
    $writer.AutoFlush = $true
    return $writer
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'FATAL')][string]$Level = 'INFO'
    )
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $line = '{0} [{1}] {2}' -f $ts, $Level, $Message
    [Console]::Out.WriteLine($line)
    [Console]::Out.Flush()
    if ($null -ne $script:LogWriter) {
        try { $script:LogWriter.WriteLine($line) } catch { }
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
        [Parameter(Mandatory)][int]$WaitSeconds
    )

    # ArgumentList passes the URL as one argv entry with no shell and no string
    # interpolation, so spaces and metacharacters cannot split it into extra args.
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Exe
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
            Invoke-ZedOpen -Url $url -Exe $zedPath -WaitSeconds $LaunchWaitSeconds
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
