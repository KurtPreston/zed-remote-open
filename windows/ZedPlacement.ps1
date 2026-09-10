<#
    The evidence window placement is decided from, dot-sourced by
    zed-open-listener.ps1 and check-zed-remote-open.ps1: whether a Zed process is
    alive, and which remote projects Zed's own workspace database says are open in
    the running session. This is the PowerShell peer of macos/zed-placement.sh, and
    the query is the same one.

    Windows ships no sqlite3 CLI, so the database is read through winsqlite3.dll,
    which has been in System32 since Windows 10 1803. Every import is Cdecl:
    SQLite's ABI is cdecl and the default stdcall corrupts the stack on x86.

    The database is opened read-only through a file: URI, so a WAL database with a
    live writer is read without writing anything -- not even the -shm and -wal
    housekeeping a read-write open would do. Read-only WAL access needs the
    writer's -shm file to already exist, which it does whenever Zed is running,
    and the liveness gate means that is the only case we query in.
#>

if (-not ('ZedSqlite' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class ZedSqlite {
    private const int SQLITE_OK = 0;
    private const int SQLITE_ROW = 100;
    private const int SQLITE_DONE = 101;
    private const int SQLITE_OPEN_READONLY = 0x1;
    private const int SQLITE_OPEN_URI = 0x40;

    // Tells SQLite to copy the bound text before returning, so the .NET string's
    // marshalled buffer does not have to outlive the bind call.
    private static readonly IntPtr SQLITE_TRANSIENT = new IntPtr(-1);

    // LPUTF8Str on every string: SQLite's API is UTF-8 throughout, and the
    // default ANSI marshalling would mangle any path outside the code page.
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_open_v2(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string filename, out IntPtr db, int flags, IntPtr vfs);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_prepare_v2(
        IntPtr db, [MarshalAs(UnmanagedType.LPUTF8Str)] string sql, int nByte, out IntPtr stmt, IntPtr tail);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_bind_text(
        IntPtr stmt, int index, [MarshalAs(UnmanagedType.LPUTF8Str)] string value, int nByte, IntPtr destructor);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_step(IntPtr stmt);

    // IntPtr rather than string: the return is a UTF-8 buffer SQLite owns, and
    // letting the marshaller free it would corrupt the heap.
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr sqlite3_column_text(IntPtr stmt, int column);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_finalize(IntPtr stmt);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_close_v2(IntPtr db);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr sqlite3_errmsg(IntPtr db);

    private static string Explain(IntPtr db, int code) {
        string message = db == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(sqlite3_errmsg(db));
        return string.IsNullOrEmpty(message) ? ("sqlite error " + code) : (message + " (" + code + ")");
    }

    // Runs one query and returns column 0 of every row. Throws when the database
    // cannot be read at all, which the caller treats as "fall back to the state
    // file" -- distinct from a readable database that returns no rows.
    public static List<string> Query(string uri, string sql, string[] binds) {
        List<string> rows = new List<string>();
        IntPtr db = IntPtr.Zero;
        IntPtr stmt = IntPtr.Zero;
        try {
            int rc = sqlite3_open_v2(uri, out db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, IntPtr.Zero);
            if (rc != SQLITE_OK) { throw new InvalidOperationException("open failed: " + Explain(db, rc)); }

            rc = sqlite3_prepare_v2(db, sql, -1, out stmt, IntPtr.Zero);
            if (rc != SQLITE_OK) { throw new InvalidOperationException("prepare failed: " + Explain(db, rc)); }

            for (int i = 0; binds != null && i < binds.Length; i++) {
                rc = sqlite3_bind_text(stmt, i + 1, binds[i], -1, SQLITE_TRANSIENT);
                if (rc != SQLITE_OK) { throw new InvalidOperationException("bind failed: " + Explain(db, rc)); }
            }

            while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
                IntPtr text = sqlite3_column_text(stmt, 0);
                if (text != IntPtr.Zero) { rows.Add(Marshal.PtrToStringUTF8(text)); }
            }
            if (rc != SQLITE_DONE) { throw new InvalidOperationException("step failed: " + Explain(db, rc)); }

            return rows;
        }
        finally {
            if (stmt != IntPtr.Zero) { sqlite3_finalize(stmt); }
            if (db != IntPtr.Zero) { sqlite3_close_v2(db); }
        }
    }
}
'@
}

# Zed keeps its data directory under LOCALAPPDATA on Windows; APPDATA is checked
# as well so an install that landed there still resolves. The channel suffix is
# 0-stable, 0-preview or 0-nightly -- pass -ZedDb to point at another one.
function Resolve-ZedDbPath {
    [CmdletBinding()]
    param([string]$Explicit)

    if ($Explicit) { return $Explicit }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Zed\db\0-stable\db.sqlite'),
        (Join-Path $env:APPDATA 'Zed\db\0-stable\db.sqlite')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    # Neither exists: name the usual one anyway, so the log and the doctor report
    # the path that was looked for rather than an empty string.
    return $candidates[0]
}

# The liveness gate, and it cannot be skipped. Zed deliberately leaves session_id
# bound on the workspace rows after a quit or a crash so it can restore them next
# launch, and kv_store.session_id is not replaced until that launch -- so the
# query alone would report a quit Zed's last projects as still open.
function Test-ZedRunning {
    return @(Get-Process -Name 'Zed' -ErrorAction SilentlyContinue).Count -gt 0
}

# A Windows path is not a URI: the separators have to turn round, the drive letter
# must not be read as a scheme, and '?' would start the query string early.
function ConvertTo-SqliteUri {
    param([Parameter(Mandatory)][string]$Path)

    $slashed = ($Path -replace '\\', '/') -replace '^/+', ''
    $escaped = [regex]::Replace($slashed, '[%?# ]', {
            param($match) '%{0:X2}' -f [int][char]$match.Value[0]
        })
    return "file:///$escaped`?mode=ro"
}

# Throws when the database cannot be read, with the path and SQLite's own reason.
# PowerShell would otherwise wrap that reason in a MethodInvocationException whose
# message is mostly about argument counts.
function Invoke-ZedDbQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Sql,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Binds
    )

    try {
        return [ZedSqlite]::Query((ConvertTo-SqliteUri -Path $Database), $Sql, $Binds)
    }
    catch {
        $reason = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        throw "${Database}: $reason"
    }
}

function Get-ZedDbSessionId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Database)

    $rows = @(Invoke-ZedDbQuery -Database $Database -Binds @() `
            -Sql "SELECT value FROM kv_store WHERE key = 'session_id';")
    if ($rows.Count -eq 0) { return $null }
    return $rows[0]
}

# The remote projects open in the *current* session for one host. The host is
# bound rather than interpolated, so no quoting question arises even though the
# URL pattern already excludes quotes.
#
# session_id is the only liveness column in the row: window_id is written on every
# serialize and never nulled, so it lingers on workspaces that were closed long
# ago and must not be filtered on. A multi-root workspace stores its roots as one
# newline-joined string, so each row is split and its paths matched on their own.
#
# Throws when the database cannot be read; returns an empty array when it reads
# fine and nothing is open for the host.
function Get-ZedDbOpenPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$RemoteHost
    )

    $sql = @'
SELECT w.paths FROM workspaces w
  JOIN remote_connections c ON c.id = w.remote_connection_id
 WHERE c.kind = 'ssh' AND c.host = ?
   AND w.session_id = (SELECT value FROM kv_store WHERE key = 'session_id');
'@

    $rows = @(Invoke-ZedDbQuery -Database $Database -Sql $sql -Binds @($RemoteHost))

    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($row in $rows) {
        if (-not $row) { continue }
        foreach ($path in ($row -split "`r?`n")) {
            if ($path) { $paths.Add($path) }
        }
    }
    return $paths.ToArray()
}

# A path equal to an open one, or nested inside it, counts as open. Ordinal and
# case-sensitive: these are POSIX paths on the dev box.
function Test-PathIsOpen {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$OpenPaths
    )

    foreach ($open in $OpenPaths) {
        if (-not $open) { continue }
        if ([string]::Equals($Path, $open, [StringComparison]::Ordinal)) { return $true }
        if ($Path.StartsWith($open.TrimEnd('/') + '/', [StringComparison]::Ordinal)) { return $true }
    }
    return $false
}
