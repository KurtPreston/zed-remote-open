<#
    Shared logging, dot-sourced by zed-open-listener.ps1 and zed-tunnel.ps1.

    Both run under a hidden wrapper whose stdout goes to NUL, so the log file is
    the only record of what they did. Each opens its own file here rather than
    having the wrapper redirect into it; see the comment on Open-LogWriter.
#>

$script:LogWriter = $null

# A script opens its log itself instead of having the wrapper redirect stdout
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
    # ReadWrite sharing so the log stays tailable while the script runs.
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
