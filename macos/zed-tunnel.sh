#!/usr/bin/env bash

# Keeps one reverse SSH tunnel to the dev box up for the remote-open listener.
# Runs `ssh -N -R <port>:127.0.0.1:<port> <host>` and restarts it whenever it
# exits, with exponential backoff so an unreachable dev box does not turn into a
# reconnect storm. Owning the forward here rather than borrowing it from a Zed
# project keeps it alive across projects opening and closing, and across having
# no project open at all.
#
# Authentication has to be non-interactive: BatchMode is on, so an encrypted key
# with no agent, or an unknown host key, fails the connection rather than
# prompting this invisible launchd agent. A forward that keeps failing usually
# means a session abandoned when this machine slept is still holding the port on
# the dev box; nothing here can clear that (see the README).
#
#   zed-tunnel.sh --remote-host <host> [--port N] [--ssh-bin <path>] [--log <file>]

set -uo pipefail

PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=zed-lib.sh
. "$here/zed-lib.sh"

remote_host=""
port=$ZED_OPEN_PORT
ssh_bin=""
log_file="$ZED_LISTENER_LOG_DIR/zed-tunnel.log"

alive_interval=30
alive_count_max=3
connect_timeout=15
min_backoff=5
max_backoff=300
stable_seconds=60
max_stderr_lines=5
stale_forward_failures=3

while [[ $# -gt 0 ]]; do
    case $1 in
        --remote-host) remote_host=$2; shift 2 ;;
        --port) port=$2; shift 2 ;;
        --ssh-bin) ssh_bin=$2; shift 2 ;;
        --log) log_file=$2; shift 2 ;;
        *) shift ;;
    esac
done

mkdir -p "$(dirname "$log_file")" 2>/dev/null || true
exec >>"$log_file" 2>&1

if [[ -z $remote_host ]]; then
    zed_log FATAL "--remote-host is required"
    exit 1
fi

if [[ -z $ssh_bin ]]; then
    ssh_bin=$(resolve_ssh || true)
fi
if [[ -z $ssh_bin || ! -x $ssh_bin ]]; then
    zed_log FATAL "could not locate ssh; pass --ssh-bin with an absolute path"
    exit 1
fi

forward="${port}:127.0.0.1:${port}"
ssh_args=(
    -N                                        # forward only, no remote command
    -T
    -o BatchMode=yes                          # never prompt; nothing can answer
    -o ExitOnForwardFailure=yes               # a tunnel without the forward is useless
    -o "ServerAliveInterval=$alive_interval"
    -o "ServerAliveCountMax=$alive_count_max"
    -o "ConnectTimeout=$connect_timeout"
    -R "$forward"
    "$remote_host"
)

# Without this the forward outlives the supervisor, and the port stays bound on
# the dev box so the replacement can never take it.
child=""
cleanup() {
    if [[ -n $child ]]; then
        kill "$child" 2>/dev/null || true
    fi
    [[ -n ${stderr_tmp:-} ]] && rm -f "$stderr_tmp" 2>/dev/null
    zed_log INFO "tunnel supervisor stopped"
}
trap cleanup EXIT
trap 'exit 0' INT TERM

zed_log INFO "tunnel supervisor started (pid $$)"
zed_log INFO "ssh: $ssh_bin"
zed_log INFO "forward: -R $forward to '$remote_host'"

backoff=$min_backoff
forward_failures=0
stderr_tmp=$(mktemp "${TMPDIR:-/tmp}/zed-tunnel.XXXXXX")

while true; do
    started_at=$(date +%s)

    : >"$stderr_tmp"
    "$ssh_bin" "${ssh_args[@]}" >/dev/null 2>"$stderr_tmp" &
    child=$!
    wait "$child"
    rc=$?
    child=""

    uptime=$(( $(date +%s) - started_at ))

    # ssh -N is quiet; a handful of lines is all a failure produces.
    line_count=0
    while IFS= read -r line; do
        [[ -n ${line// /} ]] || continue
        zed_log WARN "ssh: $line"
        line_count=$((line_count + 1))
        [[ $line_count -ge $max_stderr_lines ]] && break
    done <"$stderr_tmp"

    zed_log WARN "ssh exited $rc after ${uptime}s"

    # A connection that stayed up is evidence the dev box is reachable, so a later
    # drop starts over at the short delay instead of inheriting the outage's backoff.
    if [[ $uptime -ge $stable_seconds ]]; then
        backoff=$min_backoff
    fi

    if grep -qi 'remote port forwarding failed' "$stderr_tmp"; then
        forward_failures=$((forward_failures + 1))
    else
        forward_failures=0
    fi

    # One failure is ordinary; a run of them means a session abandoned when this
    # machine slept is still holding the port, which nothing here can clear.
    # Said once per run so the log names the condition without repeating it.
    if [[ $forward_failures -eq $stale_forward_failures ]]; then
        zed_log ERROR "the port on '$remote_host' is held by an abandoned session; 'zed .' there will report success and open nothing until it is cleared (see the README)"
    fi

    zed_log INFO "reconnecting in ${backoff}s"
    # Backgrounded then waited on, rather than a foreground `sleep`: bash defers a
    # trapped signal until a foreground child returns, so a foreground sleep would
    # make launchd's SIGTERM wait out the whole backoff (up to 300s) before the
    # cleanup trap could kill the ssh child -- and launchd's own SIGKILL would then
    # orphan that child, leaving the forward bound on the dev box. `wait` is
    # interrupted by the signal at once.
    sleep "$backoff" &
    child=$!
    wait "$child"
    child=""

    backoff=$(( backoff * 2 ))
    [[ $backoff -gt $max_backoff ]] && backoff=$max_backoff
done
