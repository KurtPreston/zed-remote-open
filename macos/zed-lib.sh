#!/usr/bin/env bash

# Shared helpers, sourced by the handler, the tunnel, the installer and the
# doctor. Logging, the URL allowlist, Zed CLI discovery, and the paths the state
# file and workspace database live at.
#
# No `set -e` in anything that sources this: several helpers below return a
# non-zero status as their answer (the CLI is not installed, the database is not
# readable) and the caller branches on it.

# macOS ships bash 3.2, so nothing here may use bash 4 features (associative
# arrays, `mapfile`, `${x^^}`, `read -d ''` tricks). Keep it portable.

# --- paths ------------------------------------------------------------------
# All overridable from the environment so the doctor and ad-hoc tests can point
# at a different install without editing anything.
: "${ZED_OPEN_PORT:=7682}"
: "${ZED_LISTENER_LOG_DIR:=$HOME/Library/Logs/zed-listener}"
: "${ZED_LISTENER_STATE_DIR:=$HOME/Library/Application Support/zed-listener}"
: "${ZED_STATE_FILE:=$ZED_LISTENER_STATE_DIR/open-projects.txt}"
: "${ZED_DB:=$HOME/Library/Application Support/Zed/db/0-stable/db.sqlite}"
: "${ZED_REMOTE_HOST_FILE:=$ZED_LISTENER_STATE_DIR/remote-host}"

# --- remote host ------------------------------------------------------------
# There is no default dev box: the alias is specific to each workstation. The
# installer saves the one it was given so a re-install and the doctor can reuse
# it without the flag.
resolve_remote_host() {
    # resolve_remote_host [explicit]; prints the host, or returns 1 if unknown.
    local host=$1
    if [[ -z $host && -f $ZED_REMOTE_HOST_FILE ]]; then
        host=$(head -n 1 "$ZED_REMOTE_HOST_FILE" | tr -d '[:space:]')
    fi
    [[ -n $host ]] || return 1
    printf '%s\n' "$host"
}

save_remote_host() {
    # save_remote_host HOST
    mkdir -p "$(dirname "$ZED_REMOTE_HOST_FILE")" &&
        printf '%s\n' "$1" >"$ZED_REMOTE_HOST_FILE"
}

# Host, then an absolute POSIX path, then optional :line[:col]. The path charset
# excludes ';', '&', '|', quotes and control characters, so a request cannot
# smuggle shell syntax even if some caller does interpolate it, and ':' is
# excluded so the line/column suffix is never ambiguous. This is the Windows
# listener's pattern rendered as POSIX ERE for bash's `[[ =~ ]]`: the only change
# is dropping the non-capturing `(?:...)` groups, which ERE has no syntax for.
ZED_URL_PATTERN='^ssh://[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9 ._+@~%/-]*(:[0-9]{1,9}(:[0-9]{1,9})?)?$'

# --- logging ----------------------------------------------------------------
# The handler and tunnel each point their own stdout at a log file before calling
# this, so a bare printf is all it takes; see the comment in the handler on why
# the redirect happens there rather than in the plist.
zed_log() {
    # zed_log LEVEL message...
    local level=$1
    shift
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
}

# --- Zed CLI discovery ------------------------------------------------------
# The order mirrors why windows/ZedCli.ps1 puts PATH last: the CLI locates its
# own app by walking up from its executable to the first *.app, so it must be run
# from inside the bundle and never copied out, and /usr/local/bin/zed is a fixed
# name every channel's installer claims, so it may well point at Preview rather
# than the stable build a user means.
zed_cli_candidates() {
    local root name
    for root in "$HOME/Applications" "/Applications"; do
        for name in "Zed.app" "Zed Preview.app" "Zed Nightly.app" "Zed Dev.app"; do
            printf '%s\n' "$root/$name/Contents/MacOS/cli"
        done
    done
    # Spotlight, in case Zed lives somewhere unusual. Bundle id is dev.zed.Zed.
    if command -v mdfind >/dev/null 2>&1; then
        mdfind "kMDItemCFBundleIdentifier == 'dev.zed.Zed'" 2>/dev/null |
            while IFS= read -r app; do
                [[ -n $app ]] && printf '%s\n' "$app/Contents/MacOS/cli"
            done
    fi
}

resolve_zed_cli() {
    # resolve_zed_cli [explicit]; prints the path, or returns non-zero.
    local explicit=${1:-}
    if [[ -n $explicit ]]; then
        if [[ ! -x $explicit ]]; then
            zed_log FATAL "zed cli '$explicit' does not exist or is not executable" >&2
            return 1
        fi
        printf '%s\n' "$explicit"
        return 0
    fi

    local cand
    while IFS= read -r cand; do
        [[ -n $cand && -x $cand ]] || continue
        printf '%s\n' "$cand"
        return 0
    done < <(zed_cli_candidates)

    local onpath
    onpath=$(command -v zed 2>/dev/null || true)
    if [[ -n $onpath ]]; then
        printf '%s\n' "$onpath"
        return 0
    fi

    return 1
}

resolve_ssh() {
    # resolve_ssh [explicit]; prefer the inbox client over PATH, matching the
    # installer's reasoning that a shim on PATH may not reach the same ~/.ssh.
    local explicit=${1:-}
    if [[ -n $explicit ]]; then
        if [[ ! -x $explicit ]]; then
            zed_log FATAL "ssh '$explicit' does not exist or is not executable" >&2
            return 1
        fi
        printf '%s\n' "$explicit"
        return 0
    fi
    if [[ -x /usr/bin/ssh ]]; then
        printf '%s\n' /usr/bin/ssh
        return 0
    fi
    local onpath
    onpath=$(command -v ssh 2>/dev/null || true)
    if [[ -n $onpath ]]; then
        printf '%s\n' "$onpath"
        return 0
    fi
    return 1
}

# --- url helpers ------------------------------------------------------------
zed_url_valid() {
    # zed_url_valid URL
    [[ $1 =~ $ZED_URL_PATTERN ]]
}

zed_url_host() {
    # ssh://<host>/... -> <host>
    printf '%s' "$1" | sed -E 's#^ssh://([^/]+)/.*#\1#'
}

zed_url_path() {
    # ssh://<host><abs-path>[/][:line[:col]] -> <abs-path>, with the host, the
    # position and the directory marker all removed. The marker goes because Zed
    # stores project roots unslashed in its workspace database, and placement
    # compares this against those roots. '/' keeps its slash, being the whole
    # path rather than a marker.
    local rest=${1#ssh://}
    local path=/${rest#*/}
    path=$(printf '%s' "$path" | sed -E 's/:[0-9]+(:[0-9]+)?$//')
    if [[ $path != / ]]; then
        path=${path%/}
    fi
    printf '%s' "$path"
}

zed_url_is_directory() {
    # A trailing slash means the sender stat'd a directory; without one the
    # request names a file. Only the sender can tell, so it says which -- see
    # docs/PROTOCOL.md. An unmarked path reads as a file, which is the safe way
    # round for a sender too old to mark anything.
    local rest=${1#ssh://}
    [[ /${rest#*/} == */ ]]
}

zed_url_for_cli() {
    # The URL as Zed should receive it, with the directory marker taken back off:
    # it is ours to read, and Zed's database has to keep storing roots unslashed
    # for the comparison in zed_url_path to keep matching.
    local url=$1
    local rest=${url#ssh://}
    # '/' is the one path whose trailing slash is the path itself, and stripping
    # it would leave a URL with no path at all.
    if [[ /${rest#*/} == / || $url != */ ]]; then
        printf '%s' "$url"
    else
        printf '%s' "${url%/}"
    fi
}

# --- stale forward cleanup --------------------------------------------------
# Pipes clear-stale-forwards to the dev box over ssh. The script lives in this
# checkout under remote/bin/; the tunnel supervisor calls it when a run of
# "remote port forwarding failed" errors suggests a session abandoned by sleep.
clear_stale_remote_forwards() {
    # clear_stale_remote_forwards SSH_BIN REMOTE_HOST CLEANUP_SCRIPT CONNECT_TIMEOUT
    local ssh_bin=$1 remote_host=$2 cleanup_script=$3 connect_timeout=$4
    local output rc=0

    if [[ ! -f $cleanup_script ]]; then
        zed_log WARN "cleanup script missing at $cleanup_script"
        return 1
    fi

    # '--' ends bash's own option parsing so '--quiet' reaches the piped script as
    # $1 rather than being read as a bash long option ('bash: --: invalid option').
    output=$("$ssh_bin" -o BatchMode=yes -o "ConnectTimeout=$connect_timeout" -T "$remote_host" \
        'bash -s -- --quiet' <"$cleanup_script" 2>&1) || rc=$?

    if [[ $rc -ne 0 ]]; then
        zed_log WARN "could not run cleanup on '$remote_host' -- $output"
        return "$rc"
    fi

    if [[ $output =~ cleared=([0-9]+) ]]; then
        if [[ ${BASH_REMATCH[1]} -gt 0 ]]; then
            zed_log INFO "cleared ${BASH_REMATCH[1]} abandoned session(s) on '$remote_host'"
        else
            zed_log WARN "no abandoned sessions found on '$remote_host' to clear"
        fi
    else
        zed_log WARN "unexpected cleanup output from '$remote_host' -- $output"
    fi

    return 0
}
