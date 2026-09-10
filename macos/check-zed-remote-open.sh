#!/usr/bin/env bash

# Checks that every piece of the Zed remote-open path is in place on macOS: the
# Zed CLI, the ssh_connections entry, both launchd agents, the loopback listener,
# the reverse tunnel, the logs, and the placement inputs. Nothing here changes
# state unless you pass --probe.
#
#   ./check-zed-remote-open.sh [--remote-host desktop] [--probe] [--check-remote]

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=zed-lib.sh
. "$here/zed-lib.sh"
# shellcheck source=zed-placement.sh
. "$here/zed-placement.sh"

port=$ZED_OPEN_PORT
remote_host="desktop"
probe=false
check_remote=false
established_seconds=10

listener_label="zed-remote-open.listener"
tunnel_label="zed-remote-open.tunnel"
settings_path="$HOME/.config/zed/settings.json"
domain="gui/$(id -u)"

while [[ $# -gt 0 ]]; do
    case $1 in
        --port) port=$2; shift 2 ;;
        --remote-host) remote_host=$2; shift 2 ;;
        --probe) probe=true; shift ;;
        --check-remote) check_remote=true; shift ;;
        *) echo "check-zed-remote-open: unknown option '$1'" >&2; exit 2 ;;
    esac
done

failures=0
warnings=0
ok()   { printf '  [ ok ] %s\n' "$1"; [[ $# -ge 2 ]] && printf '         %s\n' "$2"; return 0; }
bad()  { failures=$((failures + 1)); printf '  [FAIL] %s\n' "$1"; [[ $# -ge 2 ]] && printf '         %s\n' "$2"; return 0; }
warn() { warnings=$((warnings + 1)); printf '  [warn] %s\n' "$1"; [[ $# -ge 2 ]] && printf '         %s\n' "$2"; return 0; }

forward="$port:127.0.0.1:$port"

echo
echo "zed-remote-open doctor (host '$remote_host', port $port)"

# --- 1. Zed CLI -------------------------------------------------------------
echo
echo "Zed CLI"
if zed_bin=$(resolve_zed_cli); then
    ok "Zed CLI found" "$zed_bin"
    if ! command -v zed >/dev/null 2>&1; then
        ok "not on PATH (expected)" "the agent uses the absolute in-bundle path"
    fi
else
    bad "Zed CLI not found" "pass --zed-bin, or install Zed"
fi

# --- 2. Zed settings --------------------------------------------------------
# bash has no JSONC parser and plutil rejects the comments Zed's settings allow,
# so this is a deliberately loose text match rather than the Windows doctor's
# JSONC state machine: enough to catch a missing host or a stray forward.
echo
echo "Zed settings"
if [[ ! -f $settings_path ]]; then
    bad "settings.json missing" "$settings_path"
else
    ok "settings.json" "$settings_path"
    if grep -q "\"$remote_host\"" "$settings_path"; then
        ok "host '$remote_host' appears in settings (text match)"
    else
        warn "host '$remote_host' not found in settings (text match)" "Zed needs an ssh_connections entry for it"
    fi
    if grep -qF "$forward" "$settings_path"; then
        warn "settings still mention the -R $forward forward" "the tunnel agent owns it now; drop -R from the ssh_connections args"
    fi
fi

# --- 3. launchd agents ------------------------------------------------------
echo
echo "launchd agents"
check_agent() {
    local label=$1
    if launchctl print "$domain/$label" >/dev/null 2>&1; then
        local pid state
        pid=$(launchctl print "$domain/$label" 2>/dev/null | sed -n 's/^[[:space:]]*pid = \([0-9]*\).*/\1/p' | head -1)
        state=$(launchctl print "$domain/$label" 2>/dev/null | sed -n 's/^[[:space:]]*state = \(.*\)/\1/p' | head -1)
        ok "agent '$label' loaded" "state: ${state:-unknown}${pid:+, pid $pid}"
    else
        bad "agent '$label' not loaded" "run install-zed-listener.sh"
    fi
}
check_agent "$listener_label"
if launchctl print "$domain/$tunnel_label" >/dev/null 2>&1; then
    check_agent "$tunnel_label"
else
    warn "agent '$tunnel_label' not loaded" "without it the forward depends on a Zed project staying open"
fi

# --- 4. Listener ------------------------------------------------------------
# lsof cannot see a launchd socket-activated listener without privileges -- the
# fd belongs to launchd, not a running process, and the handler only exists for
# the length of a connection -- so this reads netstat, which shows the bind
# regardless of owner, and confirms reachability with an actual connect.
echo
echo "Listener"
listen_addrs=$(netstat -an -p tcp 2>/dev/null | awk -v p="$port" '$NF=="LISTEN" && $4 ~ ("\\."p"$") {print $4}')
loopback=$(printf '%s\n' "$listen_addrs" | grep -E '^(127\.0\.0\.1|::1|\[::1\])\.' || true)
wildcard=$(printf '%s\n' "$listen_addrs" | grep -E '^(\*|0\.0\.0\.0|::)\.' || true)
if [[ -n $wildcard ]]; then
    bad "port is bound beyond loopback" "$(printf '%s' "$wildcard" | tr '\n' ' ')"
elif [[ -n $loopback ]]; then
    ok "bound on 127.0.0.1:$port"
elif nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
    ok "reachable on 127.0.0.1:$port" "not shown by netstat, but a connect succeeds"
else
    bad "nothing listening on 127.0.0.1:$port"
fi
if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
    ok "loopback connect succeeds"
else
    bad "loopback connect to 127.0.0.1:$port refused"
fi

# --- 5. Tunnel --------------------------------------------------------------
tunnel_loaded=false
launchctl print "$domain/$tunnel_label" >/dev/null 2>&1 && tunnel_loaded=true
tunnel_state="absent"   # absent | starting | bound
if [[ $tunnel_loaded == true ]]; then
    echo
    echo "Tunnel"
    # Every ssh holding the forward, whoever started it. Ours carries
    # ExitOnForwardFailure; anything else is a Zed connection still configured
    # with -R, and the two cannot both have the port.
    all_pids=$(pgrep -f -- "-R $forward" 2>/dev/null || true)
    ours=""
    rivals=""
    for pid in $all_pids; do
        cmd=$(ps -o command= -p "$pid" 2>/dev/null || true)
        [[ -n $cmd ]] || continue
        if printf '%s' "$cmd" | grep -q 'ExitOnForwardFailure=yes'; then
            # Surviving the settle window is the evidence, not mere existence.
            elapsed=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
            if [[ -n $elapsed && $elapsed -ge $established_seconds ]]; then
                ours="$ours $pid"
            elif [[ -z $ours ]]; then
                tunnel_state="starting"
            fi
        else
            rivals="$rivals $pid"
        fi
    done
    ours=${ours# }
    rivals=${rivals# }

    if [[ -n $ours ]]; then
        tunnel_state="bound"
        ok "ssh holding -R $forward" "pid ${ours%% *}"
        [[ -n $rivals ]] && warn "a Zed connection also asks for this forward" "pid $rivals -- it lost the race and runs without one"
    elif [[ -n $rivals ]]; then
        bad "the tunnel cannot bind the forward" "pid $rivals started while -R was still in Zed's args and most likely still holds it; reconnect those projects"
    elif [[ $tunnel_state == starting ]]; then
        warn "tunnel ssh just started" "too young to tell whether the forward took; re-run in a few seconds"
    else
        bad "no ssh holding -R $forward" "the supervisor retries with backoff; check $ZED_LISTENER_LOG_DIR/zed-tunnel.log"
    fi
fi

# --- 6. Placement inputs ----------------------------------------------------
echo
echo "Placement"
if zed_is_running; then
    ok "a Zed process is running"
else
    warn "no Zed process running" "placement resets the state file on the next request"
fi
if sid=$(zed_db_session_id) && [[ -n $sid ]]; then
    ok "workspace database readable" "session $sid"
    openpaths=$(zed_db_open_paths "$remote_host" || true)
    if [[ -n $openpaths ]]; then
        ok "open remote workspaces for '$remote_host' this session"
        printf '%s\n' "$openpaths" | while IFS= read -r p; do [[ -n $p ]] && printf '         | %s\n' "$p"; done
    else
        ok "no remote workspaces open for '$remote_host' this session" "the next 'zed .' opens with --reuse"
    fi
else
    warn "workspace database not readable" "placement falls back to $ZED_STATE_FILE (Windows-level behaviour); a launchd App Data TCC denial looks like this"
fi

# --- 7. Logs ----------------------------------------------------------------
echo
echo "Logs"
show_log() {
    local label=$1 path=$2
    if [[ -f $path ]]; then
        ok "$label" "$path"
        tail -n 3 "$path" 2>/dev/null | while IFS= read -r l; do printf '         | %s\n' "$l"; done
    else
        warn "no $label yet" "$path"
    fi
}
show_log "listener log" "$ZED_LISTENER_LOG_DIR/zed-listener.log"
[[ $tunnel_loaded == true ]] && show_log "tunnel log" "$ZED_LISTENER_LOG_DIR/zed-tunnel.log"

# --- 8. Unattended ssh ------------------------------------------------------
# A launchd agent depends on the GUI session's SSH_AUTH_SOCK and cannot answer a
# passphrase prompt, so the tunnel only works if key auth is non-interactive.
echo
echo "Unattended ssh"
if ! command -v ssh >/dev/null 2>&1; then
    warn "no ssh client on PATH"
elif ssh -o BatchMode=yes -o ConnectTimeout=10 "$remote_host" true >/dev/null 2>&1; then
    ok "ssh -o BatchMode=yes '$remote_host' succeeds"
else
    bad "ssh -o BatchMode=yes '$remote_host' fails" "key auth must work with no prompt; an encrypted key needs an agent the GUI session can reach"
fi

# --- 9. Optional probe ------------------------------------------------------
if [[ $probe == true ]]; then
    echo
    echo "Probe (opens a Zed window)"
    if printf 'ssh://%s/\n' "$remote_host" | nc -w 2 127.0.0.1 "$port" >/dev/null 2>&1; then
        ok "probe URL delivered" "ssh://$remote_host/"
    else
        bad "probe failed" "nothing accepted the connection on 127.0.0.1:$port"
    fi
fi

# --- 10. Optional remote check ---------------------------------------------
if [[ $check_remote == true ]]; then
    echo
    echo "Remote ($remote_host)"
    if ! command -v ssh >/dev/null 2>&1; then
        warn "no ssh client on PATH"
    else
        remote_probe="command -v zed >/dev/null && echo SENDER_OK || echo SENDER_MISSING; (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -q '127.0.0.1:$port' && echo TUNNEL_OK || echo TUNNEL_MISSING"
        result=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$remote_host" "$remote_probe" 2>&1 || true)
        printf '%s' "$result" | grep -q SENDER_OK && ok "zed sender on remote PATH" || warn "no zed sender on remote PATH"
        if printf '%s' "$result" | grep -q TUNNEL_OK; then
            # Something listens there, which is not the same as it reaching here. A
            # session abandoned when this machine slept holds the port open and
            # accepts connections while the bytes go nowhere.
            if [[ $tunnel_state == bound || $tunnel_loaded == false ]]; then
                ok "remote sshd is forwarding 127.0.0.1:$port"
            elif [[ $tunnel_state == starting ]]; then
                warn "cannot tell whose forward holds 127.0.0.1:$port" "the tunnel ssh is too young; re-run in a few seconds"
            else
                bad "a stale forward holds 127.0.0.1:$port" "it accepts connections and drops them, so 'zed .' looks like it worked; see the README"
            fi
        elif [[ $tunnel_loaded == true ]]; then
            bad "remote is not listening on 127.0.0.1:$port" "'$tunnel_label' should keep it bound"
        else
            warn "remote is not listening on 127.0.0.1:$port" "expected unless a Zed remote session is connected"
        fi
    fi
fi

echo
if [[ $failures -eq 0 ]]; then
    echo "All checks passed ($warnings warning(s))."
    exit 0
fi
echo "$failures check(s) failed, $warnings warning(s)."
exit 1
