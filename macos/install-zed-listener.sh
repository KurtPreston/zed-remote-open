#!/usr/bin/env bash

# Installs the Zed remote-open listener and its reverse tunnel as launchd agents.
#
# The listener is socket-activated: launchd binds 127.0.0.1:<port> and spawns the
# handler once per connection, so the port is bound from load onward whether or
# not Zed is running -- the property the Windows install gets from a watchdog
# Scheduled Task. The tunnel is a plain agent whose own loop supervises the ssh.
#
# The plists point at the scripts in this checkout rather than copying them, so a
# `git pull` here updates the install; leave the checkout where it is. Only the
# Zed CLI and ssh paths are resolved now and baked into the plist, because a
# launchd agent starts with a minimal PATH.
#
#   ./install-zed-listener.sh
#   ./install-zed-listener.sh --remote-host devbox
#   ./install-zed-listener.sh --uninstall

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=zed-lib.sh
. "$here/zed-lib.sh"

port=$ZED_OPEN_PORT
remote_host="desktop"
zed_bin=""
ssh_bin=""
no_tunnel=false
no_start=false
uninstall=false

listener_label="zed-remote-open.listener"
tunnel_label="zed-remote-open.tunnel"
agents_dir="$HOME/Library/LaunchAgents"
listener_plist="$agents_dir/$listener_label.plist"
tunnel_plist="$agents_dir/$tunnel_label.plist"

listener_log="$ZED_LISTENER_LOG_DIR/zed-listener.log"
tunnel_log="$ZED_LISTENER_LOG_DIR/zed-tunnel.log"
launchd_out="$ZED_LISTENER_LOG_DIR/launchd.out.log"

handler_script="$here/zed-open-handler.sh"
tunnel_script="$here/zed-tunnel.sh"

domain="gui/$(id -u)"

step() { printf '==> %s\n' "$1"; }
detail() { printf '    %s\n' "$1"; }
warn() { printf 'warning: %s\n' "$1" >&2; }

while [[ $# -gt 0 ]]; do
    case $1 in
        --port) port=$2; shift 2 ;;
        --remote-host) remote_host=$2; shift 2 ;;
        --zed-bin) zed_bin=$2; shift 2 ;;
        --ssh-bin) ssh_bin=$2; shift 2 ;;
        --no-tunnel) no_tunnel=true; shift ;;
        --no-start) no_start=true; shift ;;
        --uninstall) uninstall=true; shift ;;
        -h|--help)
            sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "install-zed-listener: unknown option '$1'" >&2; exit 2 ;;
    esac
done

bootout() {
    # bootout LABEL; quiet, and not an error if it was not loaded.
    launchctl bootout "$domain/$1" 2>/dev/null || true
}

if [[ $uninstall == true ]]; then
    step "uninstalling"
    bootout "$listener_label"
    bootout "$tunnel_label"
    for p in "$listener_plist" "$tunnel_plist"; do
        if [[ -f $p ]]; then
            rm -f "$p"
            detail "removed $p"
        fi
    done
    for d in "$ZED_LISTENER_LOG_DIR" "$ZED_LISTENER_STATE_DIR"; do
        if [[ -d $d ]]; then
            rm -rf "$d"
            detail "removed $d"
        fi
    done
    echo
    echo "Uninstalled."
    exit 0
fi

step "resolving dependencies"
if ! zed_bin=$(resolve_zed_cli "$zed_bin"); then
    echo "install-zed-listener: could not locate the Zed CLI; pass --zed-bin" >&2
    exit 1
fi
detail "zed cli : $zed_bin"
if [[ $no_tunnel == false ]]; then
    if ! ssh_bin=$(resolve_ssh "$ssh_bin"); then
        echo "install-zed-listener: could not locate ssh; pass --ssh-bin" >&2
        exit 1
    fi
    detail "ssh     : $ssh_bin"
fi

for f in "$handler_script" "$tunnel_script" "$here/zed-lib.sh" "$here/zed-placement.sh"; do
    [[ -f $f ]] || { echo "install-zed-listener: missing $f" >&2; exit 1; }
done
chmod +x "$handler_script" "$tunnel_script" 2>/dev/null || true

mkdir -p "$agents_dir" "$ZED_LISTENER_LOG_DIR" "$ZED_LISTENER_STATE_DIR"

# XML-escape a value going into a plist <string>. The paths here are ours, but
# a home directory or host with an & or < would still corrupt the plist.
xml_escape() {
    printf '%s' "$1" |
        sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
            -e 's/"/\&quot;/g'
}

step "writing $listener_plist"
# inetdCompatibility with Wait=false is the classic inetd-nowait shape: launchd
# owns the listening socket from Sockets and passes each accepted connection to a
# fresh handler over stdio. ThrottleInterval 1 keeps a burst of requests from
# being rate-limited into failures. No KeepAlive: inetdCompatibility does not take
# it, and the socket alone keeps the service reachable.
cat >"$listener_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$listener_label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$(xml_escape "$handler_script")</string>
        <string>--zed-bin</string>
        <string>$(xml_escape "$zed_bin")</string>
        <string>--log</string>
        <string>$(xml_escape "$listener_log")</string>
        <string>--state</string>
        <string>$(xml_escape "$ZED_STATE_FILE")</string>
    </array>
    <key>inetdCompatibility</key>
    <dict>
        <key>Wait</key>
        <false/>
    </dict>
    <key>Sockets</key>
    <dict>
        <key>Listeners</key>
        <dict>
            <key>SockNodeName</key>
            <string>127.0.0.1</string>
            <key>SockServiceName</key>
            <string>$port</string>
            <key>SockFamily</key>
            <string>IPv4</string>
            <key>SockType</key>
            <string>stream</string>
        </dict>
    </dict>
    <key>ThrottleInterval</key>
    <integer>1</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardErrorPath</key>
    <string>$(xml_escape "$launchd_out")</string>
</dict>
</plist>
PLIST
detail "wrote $listener_plist"

if [[ $no_tunnel == false ]]; then
    step "writing $tunnel_plist"
    # RunAtLoad plus KeepAlive: the script's own loop does the real supervision,
    # and KeepAlive is the backstop for the script itself dying. ThrottleInterval
    # 10 so a script that exits immediately does not spin.
    cat >"$tunnel_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$tunnel_label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$(xml_escape "$tunnel_script")</string>
        <string>--remote-host</string>
        <string>$(xml_escape "$remote_host")</string>
        <string>--port</string>
        <string>$port</string>
        <string>--ssh-bin</string>
        <string>$(xml_escape "$ssh_bin")</string>
        <string>--log</string>
        <string>$(xml_escape "$tunnel_log")</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardErrorPath</key>
    <string>$(xml_escape "$launchd_out")</string>
</dict>
</plist>
PLIST
    detail "wrote $tunnel_plist"
else
    bootout "$tunnel_label"
    rm -f "$tunnel_plist"
fi

if [[ $no_start == true ]]; then
    echo
    echo "Installed (not started; --no-start was given)."
    echo "  load with: launchctl bootstrap $domain <plist>"
    exit 0
fi

wait_for_port() {
    local deadline=$(( $(date +%s) + 30 ))
    while [[ $(date +%s) -lt $deadline ]]; do
        if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

wait_for_tunnel() {
    # ExitOnForwardFailure kills a losing claimant within a second or two, so an
    # ssh that merely exists is not yet proof of a live forward; surviving a short
    # settle is.
    local deadline=$(( $(date +%s) + 30 ))
    local pids
    while [[ $(date +%s) -lt $deadline ]]; do
        pids=$(pgrep -f "ExitOnForwardFailure=yes.*-R $port:127.0.0.1:$port" 2>/dev/null || true)
        if [[ -n $pids ]]; then
            sleep 5
            if kill -0 $pids 2>/dev/null; then
                return 0
            fi
        fi
        sleep 0.5
    done
    return 1
}

step "loading agents"
# Reload from scratch: bootout any previous instance, then bootstrap the plist.
bootout "$listener_label"
if launchctl bootstrap "$domain" "$listener_plist" 2>/dev/null; then
    detail "bootstrapped $listener_label"
else
    warn "could not bootstrap $listener_label; check $launchd_out"
fi

if wait_for_port; then
    detail "listening on 127.0.0.1:$port"
else
    warn "not listening on 127.0.0.1:$port yet -- check $listener_log"
fi

if [[ $no_tunnel == false ]]; then
    bootout "$tunnel_label"
    if launchctl bootstrap "$domain" "$tunnel_plist" 2>/dev/null; then
        detail "bootstrapped $tunnel_label"
    else
        warn "could not bootstrap $tunnel_label; check $launchd_out"
    fi
    if wait_for_tunnel; then
        detail "tunnel to '$remote_host' up"
    else
        warn "no tunnel to '$remote_host' yet -- check $tunnel_log"
    fi
fi

echo
echo "Installed."
echo "  agents : $listener_label$([[ $no_tunnel == false ]] && echo ", $tunnel_label")"
echo "  logs   : $ZED_LISTENER_LOG_DIR"
echo "  port   : 127.0.0.1:$port"
if [[ $no_tunnel == false ]]; then
    echo
    echo "The tunnel agent now owns the -R $port:127.0.0.1:$port forward."
    echo "  Remove -R from the ssh_connections args in Zed settings.json, or the two"
    echo "  will compete for the same port on the dev box. Run check-zed-remote-open.sh"
    echo "  to confirm."
fi
