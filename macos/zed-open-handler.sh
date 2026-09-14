#!/usr/bin/env bash

# Handles one remote-open request, spawned per connection by launchd in
# inetd-compatible mode: the accepted socket is on stdin/stdout/stderr. Reads one
# newline-terminated ssh:// URL, validates it against a strict pattern, decides
# window placement, and hands the URL to the local Zed CLI as a single argument.
# See docs/PROTOCOL.md.
#
# One process per connection is the whole safety story for "a bad request must
# never stop the service": there is no accept loop to wedge, so a malformed
# request, a slow sender, or a crash takes down only its own short-lived process
# and launchd serves the next connection regardless.
#
#   zed-open-handler.sh --zed-bin <path> [--log <file>] [--state <file>]

set -uo pipefail  # not -e: read returns non-zero at EOF, which is a valid frame

# A Scheduled Task's minimal PATH is the Windows analogue; a launchd agent gets
# little more, so name the system tools' directories explicitly.
PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=zed-lib.sh
. "$here/zed-lib.sh"
# shellcheck source=zed-placement.sh
. "$here/zed-placement.sh"

zed_bin=""
log_file="$ZED_LISTENER_LOG_DIR/zed-listener.log"
read_timeout=5
max_bytes=8192

while [[ $# -gt 0 ]]; do
    case $1 in
        --zed-bin) zed_bin=$2; shift 2 ;;
        --log) log_file=$2; shift 2 ;;
        --state) ZED_STATE_FILE=$2; shift 2 ;;
        --read-timeout) read_timeout=$2; shift 2 ;;
        --max-bytes) max_bytes=$2; shift 2 ;;
        *) shift ;;
    esac
done

# stdout is the socket, and the protocol forbids writing anything back, so point
# our own output at the log before emitting a single line. It has to be an open
# on our side rather than a `>> file` redirect baked into the plist: launchd
# would hand that inheritable handle to the CLI and the ssh it spawns, which keep
# it open for the whole remote session, after which no restart could reopen it.
mkdir -p "$(dirname "$log_file")" 2>/dev/null || true
exec >>"$log_file" 2>&1

# Read one line: the sender writes the URL then closes, so EOF without a trailing
# newline is a complete frame, and -n caps an oversized request rather than
# reading it whole. IFS= keeps the spaces a path may legitimately contain.
#
# bash 3.2 returns 1 both when read times out and when it hits EOF, so the two
# cannot be told apart by exit status; elapsed time is the only signal, and it is
# used purely to label the log. Either way an empty request is rejected and a
# complete one is served, so the control flow does not depend on the distinction.
request=""
SECONDS=0
IFS= read -r -t "$read_timeout" -n "$max_bytes" request
elapsed=$SECONDS

url=${request%$'\r'}

if [[ -z $url ]]; then
    if [[ $elapsed -ge $read_timeout ]]; then
        zed_log WARN "read timed out after ${read_timeout}s with no complete request"
    else
        zed_log WARN "rejected empty request"
    fi
    exit 0
fi

if ! zed_url_valid "$url"; then
    # Single-lined and truncated so a hostile payload cannot forge log entries.
    shown=$(printf '%s' "$url" | tr '\r\n\t' '   ')
    if [[ ${#shown} -gt 200 ]]; then
        shown=${shown:0:200}...
    fi
    zed_log WARN "rejected malformed url: '$shown'"
    exit 0
fi

if [[ -z $zed_bin ]]; then
    zed_bin=$(resolve_zed_cli || true)
fi
if [[ -z $zed_bin || ! -x $zed_bin ]]; then
    zed_log FATAL "no Zed CLI; pass --zed-bin with an absolute path"
    exit 0
fi

zed_log INFO "opening $url"

placement=$(zed_resolve_placement "$url")
decision=$(printf '%s' "$placement" | cut -f1)
reset=$(printf '%s' "$placement" | cut -f2)
reason=$(printf '%s' "$placement" | cut -f3)

if [[ $decision == reuse ]]; then
    zed_log INFO "adding to the open window -- $reason"
else
    zed_log INFO "opening as-is -- $reason"
fi

# The URL is one argv entry with no shell and no interpolation, so spaces and
# metacharacters cannot split it. --reuse, when used, is a literal chosen here.
# stdin is closed off the socket so the CLI never reads from it. The directory
# marker comes off first: it was addressed to us, and Zed has to go on storing
# project roots unslashed for the placement query to keep finding them.
cli_url=$(zed_url_for_cli "$url")

args=()
if [[ $decision == reuse ]]; then
    args+=(--reuse)
fi
args+=("$cli_url")

"$zed_bin" "${args[@]}" </dev/null
launch_rc=$?

# For a URL argument the CLI exits 0 as soon as Zed acknowledges the request:
# --wait is ignored and the remote open is detached, so a later SSH failure never
# reaches this exit code. This logs that the launch was accepted, not that the
# workspace opened -- the Windows "opened (zed exited 0)" line reads as more.
if [[ $launch_rc -eq 0 ]]; then
    zed_log INFO "handed to zed (launch accepted; open proceeds asynchronously)"
else
    zed_log ERROR "zed cli exited $launch_rc"
fi

zed_state_record "$cli_url" "$reset"
exit 0
