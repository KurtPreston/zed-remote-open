#!/usr/bin/env bash

# Decides whether a request opens as-is or with --reuse, and is sourced by both
# the handler and the doctor. Assumes zed-lib.sh is already sourced.
#
# Zed's CLI cannot express "focus this project if it is open, otherwise put it in
# the window I already have". No flag does the first half -- an already-open
# remote workspace is activated -- but opens a new window for anything else,
# because open_remote_project reads requesting_window and never the sidebar
# preference. --reuse does the second half by naming a window, but it turns the
# already-open check off, and re-opening a live project that way restarts its
# remote server underneath the running workspace and leaves the worktree broken.
#
# So we pick between them. Every uncertain case resolves to no flag: a stray
# window is cheaper than a corrupted project. The evidence is Zed's own workspace
# database, which names the remote projects open in the running session --
# including ones opened through Zed's own UI. The Windows listener reads the same
# database through winsqlite3, since it has no sqlite3 command to call. The state
# file is kept only as a fallback for when the database cannot be read.

# Is a Zed GUI process alive? This gate has to come first and cannot be skipped:
# Zed deliberately leaves session_id bound on the workspace rows after a quit or
# crash so it can restore them next launch, and kv_store.session_id is not
# replaced until that next launch, so the database query alone would report a
# quit Zed's last projects as open.
zed_is_running() {
    pgrep -x zed >/dev/null 2>&1 || pgrep -x Zed >/dev/null 2>&1
}

# The remote workspaces open in the *current* session for this host. Prints one
# path per line (a multi-root workspace's newline-joined paths become several
# lines, which is fine -- each is matched on its own). Returns non-zero only when
# the database cannot be read, which the caller treats as "fall back to the state
# file", distinct from a readable-but-empty result.
zed_db_open_paths() {
    local host=$1
    local esc=${host//\'/\'\'}
    sqlite3 "file:$ZED_DB?mode=ro" \
        "SELECT w.paths FROM workspaces w
           JOIN remote_connections c ON c.id = w.remote_connection_id
          WHERE c.kind = 'ssh' AND c.host = '$esc'
            AND w.session_id = (SELECT value FROM kv_store WHERE key = 'session_id');" \
        2>/dev/null
}

zed_db_session_id() {
    sqlite3 "file:$ZED_DB?mode=ro" \
        "SELECT value FROM kv_store WHERE key = 'session_id';" 2>/dev/null
}

# The paths recorded in the state file for this host, the fallback source.
zed_state_open_paths() {
    local host=$1 line
    [[ -r $ZED_STATE_FILE ]] || return 0
    while IFS= read -r line; do
        [[ -n $line ]] || continue
        [[ $line == "ssh://$host/"* ]] || continue
        # zed_url_path prints no trailing newline, so add one per path here or
        # the reader collapses them onto a single line.
        printf '%s\n' "$(zed_url_path "$line")"
    done <"$ZED_STATE_FILE"
}

# Given the target path on stdin's list of open paths, is it already open? A path
# equal to an open one, or nested inside it, counts as open.
zed_path_is_open() {
    # zed_path_is_open TARGET  < open-paths
    local target=$1 open base
    while IFS= read -r open; do
        [[ -n $open ]] || continue
        if [[ $target == "$open" ]]; then
            return 0
        fi
        base=${open%/}
        if [[ $target == "$base"/* ]]; then
            return 0
        fi
    done
    return 1
}

# Prints three tab-separated fields: decision (reuse|noflag), reset (yes|no), and
# a reason for the log. `reset` tells the handler to truncate the state file
# before recording, because a Zed the CLI cold-starts opens only the path it was
# given and never restores the previous session, so anything remembered is stale.
zed_resolve_placement() {
    local url=$1

    if zed_url_has_position "$url"; then
        printf 'noflag\tno\ta line number means a file, not a project\n'
        return
    fi

    if ! zed_is_running; then
        printf 'noflag\tyes\tno zed process to reuse\n'
        return
    fi

    local host path
    host=$(zed_url_host "$url")
    path=$(zed_url_path "$url")

    local rows
    if rows=$(zed_db_open_paths "$host"); then
        if printf '%s\n' "$rows" | zed_path_is_open "$path"; then
            printf 'noflag\tno\topen in this session\n'
        else
            printf 'reuse\tno\tnot open in this session\n'
        fi
        return
    fi

    # Database unreadable (missing, locked, or a TCC denial): fall back to what we
    # have recorded ourselves, which lands at Windows-level behaviour.
    if zed_state_open_paths "$host" | zed_path_is_open "$path"; then
        printf 'noflag\tno\topened here already (state fallback)\n'
    else
        printf 'reuse\tno\tnot known to be open (state fallback)\n'
    fi
}

# Records a URL as opened. With -reset the state file is truncated first.
zed_state_record() {
    # zed_state_record URL RESET(yes|no)
    local url=$1 reset=$2 dir
    dir=$(dirname "$ZED_STATE_FILE")
    mkdir -p "$dir" 2>/dev/null || return 0
    if [[ $reset == yes ]]; then
        printf '%s\n' "$url" >"$ZED_STATE_FILE" 2>/dev/null || true
    elif ! grep -qxF "$url" "$ZED_STATE_FILE" 2>/dev/null; then
        printf '%s\n' "$url" >>"$ZED_STATE_FILE" 2>/dev/null || true
    fi
}
