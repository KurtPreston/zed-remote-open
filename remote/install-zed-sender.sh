#!/usr/bin/env bash

# Installs the dev-box tools by symlinking bin/* onto PATH.
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
tools=(zed clear-stale-forwards)

link_tool() {
    local name=$1 source=$2 dest=$3
    chmod +x "$source"
    if [[ -e $dest || -L $dest ]]; then
        if [[ -L $dest && $(realpath "$dest") == "$source" ]]; then
            detail "$name already linked"
        elif [[ $force == true ]]; then
            rm "$dest"
            ln -s "$source" "$dest"
            detail "replaced $dest"
        else
            echo "install-zed-sender: $dest already exists; pass --force to replace it" >&2
            exit 1
        fi
    else
        ln -s "$source" "$dest"
        detail "linked $dest -> $source"
    fi
}

unlink_tool() {
    local name=$1 source=$2 dest=$3
    if [[ ! -L $dest ]]; then
        detail "nothing installed at $dest"
    elif [[ $(realpath "$dest") != "$source" ]]; then
        detail "left alone: $dest points at $(realpath "$dest")"
    else
        rm "$dest"
        detail "removed $dest"
    fi
}

if [[ $uninstall == true ]]; then
    step "uninstalling from $bin_dir"
    for name in "${tools[@]}"; do
        unlink_tool "$name" "$here/bin/$name" "$bin_dir/$name"
    done
    echo
    echo "Uninstalled."
    exit 0
fi

for name in "${tools[@]}"; do
    [[ -f $here/bin/$name ]] || {
        echo "install-zed-sender: $name not found at $here/bin/$name" >&2
        exit 1
    }
done

step "linking into $bin_dir"
mkdir -p "$bin_dir"
# Absolute and slash-normalized, so comparing it against PATH entries below is
# a sound string match.
bin_dir=$(cd "$bin_dir" && pwd)
for name in "${tools[@]}"; do
    link_tool "$name" "$here/bin/$name" "$bin_dir/$name"
done

step "checking the install"

# The stock ~/.profile, and most hand-written rc files, add ~/.local/bin only
# when it already exists -- so on a first install the mkdir above lands a moment
# too late for this shell, and the directory is missing from PATH through no
# fault of the config. A fresh shell, which sees the directory, says which case
# this is: something to fix in the rc, or just a shell to restart.
case ":$PATH:" in
    *":$bin_dir:"*)
        detail "$bin_dir is on PATH"
        ;;
    *)
        fresh_path=$(bash -lc 'printf "%s" "$PATH"' 2>/dev/null || true)
        if [[ ":$fresh_path:" == *":$bin_dir:"* ]]; then
            warn "$bin_dir is missing from this shell's PATH; a new shell has it"
        else
            warn "$bin_dir is not on PATH; add to your shell rc:"
            detail "export PATH=\"$bin_dir:\$PATH\""
        fi
        ;;
esac

# The sender has to win the PATH lookup for `zed .` to reach it at all, and a
# real Zed CLI earlier on PATH would quietly take every invocation instead.
resolved=$(command -v zed 2>/dev/null || true)
if [[ -z $resolved ]]; then
    warn "'zed' does not resolve yet; open a new shell or rehash"
elif [[ $(realpath "$resolved") != "$here/bin/zed" ]]; then
    warn "'zed' resolves to $resolved, ahead of $bin_dir/zed on PATH"
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
echo "  zed    : $bin_dir/zed"
echo "  cleanup: $bin_dir/clear-stale-forwards"
echo "  port   : 127.0.0.1:${ZED_OPEN_PORT:-7682}"
