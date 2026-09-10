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
    # ssh://<host><abs-path>[:line[:col]] -> <abs-path>, host and suffix removed.
    local rest=${1#ssh://}
    local path=/${rest#*/}
    printf '%s' "$path" | sed -E 's/:[0-9]+(:[0-9]+)?$//'
}

zed_url_has_position() {
    # A trailing :line[:col] means the request names a file, not a project.
    [[ $1 =~ :[0-9]+(:[0-9]+)?$ ]]
}
