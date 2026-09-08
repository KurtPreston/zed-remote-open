#!/usr/bin/env bash

# Installs the sender on a dev box by symlinking bin/zed onto PATH.
#
# A symlink rather than a copy, so a `git pull` in this checkout updates the
# installed sender. The checkout therefore has to stay where it is.
#
#   ./install-zed-sender.sh
#   ./install-zed-sender.sh --bin-dir ~/bin
#   ./install-zed-sender.sh --uninstall

set -euo pipefail

bin_dir="${HOME}/.local/bin"
uninstall=false
force=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --bin-dir)
            [[ $# -ge 2 ]] || { echo "install-zed-sender: --bin-dir needs a directory" >&2; exit 2; }
            bin_dir=$2
            shift 2
            ;;
        --uninstall)
            uninstall=true
            shift
            ;;
        --force)
            force=true
            shift
            ;;
        -h | --help)
            sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "install-zed-sender: unknown option '$1'" >&2
            exit 2
            ;;
    esac
done

step() { printf '==> %s\n' "$1"; }
detail() { printf '    %s\n' "$1"; }
warn() { printf 'warning: %s\n' "$1" >&2; }

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source_zed="$here/bin/zed"
link="$bin_dir/zed"

if [[ $uninstall == true ]]; then
    step "uninstalling $link"
    if [[ ! -L $link ]]; then
        detail "nothing installed at $link"
    elif [[ $(realpath "$link") != "$source_zed" ]]; then
        # Someone else's zed. Removing it is not ours to do.
        detail "left alone: $link points at $(realpath "$link")"
    else
        rm "$link"
        detail "removed $link"
    fi
    echo
    echo "Uninstalled."
    exit 0
fi

[[ -f $source_zed ]] || { echo "install-zed-sender: sender not found at $source_zed" >&2; exit 1; }
chmod +x "$source_zed"

step "linking into $bin_dir"
mkdir -p "$bin_dir"

if [[ -e $link || -L $link ]]; then
    if [[ -L $link && $(realpath "$link") == "$source_zed" ]]; then
        detail "already linked"
    elif [[ $force == true ]]; then
        rm "$link"
        ln -s "$source_zed" "$link"
        detail "replaced $link"
    else
        echo "install-zed-sender: $link already exists; pass --force to replace it" >&2
        exit 1
    fi
else
    ln -s "$source_zed" "$link"
    detail "linked $link -> $source_zed"
fi

step "checking the install"

case ":$PATH:" in
    *":$bin_dir:"*) detail "$bin_dir is on PATH" ;;
    *) warn "$bin_dir is not on PATH; add it in your shell rc" ;;
esac

# The sender has to win the PATH lookup for `zed .` to reach it at all, and a
# real Zed CLI earlier on PATH would quietly take every invocation instead.
resolved=$(command -v zed 2>/dev/null || true)
if [[ -z $resolved ]]; then
    warn "'zed' does not resolve yet; open a new shell or rehash"
elif [[ $(realpath "$resolved") != "$source_zed" ]]; then
    warn "'zed' resolves to $resolved, ahead of $link on PATH"
else
    detail "'zed' resolves to the sender"
fi

if [[ -z ${ZED_SSH_HOST:-} ]]; then
    warn "ZED_SSH_HOST is unset; the sender needs it and will refuse to run"
    detail "add to your shell rc: export ZED_SSH_HOST=<alias from the workstation>"
else
    detail "ZED_SSH_HOST is $ZED_SSH_HOST"
fi

echo
echo "Installed."
echo "  link : $link"
echo "  port : 127.0.0.1:${ZED_OPEN_PORT:-7682}"
