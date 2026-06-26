#!/usr/bin/env bash
#
# Install (or uninstall) the IIIF converter scripts as commands by symlinking
# them into a bin directory. Symlinks are safe: each script resolves its helper
# (common.sh) relative to its *real* location, so the link works from anywhere.
#
# Usage:
#   ./install.sh [--global] [--uninstall]
#
# Options:
#   --global      Install into /usr/local/bin (system-wide; may require sudo).
#                 The default target is ~/.local/bin (per-user, no sudo).
#   --uninstall   Remove previously installed symlinks instead of creating them.
#   -h, --help    Show this help and exit.
#
# Installed commands are prefixed and hyphenated, e.g.
#   scripts/kakadu_j2k_lossy.sh -> iiif-kakadu-j2k-lossy
#   scripts/validate_j2k.sh     -> iiif-validate-j2k
#
# The sourced helper common.sh is not installed; run_all_converters.sh is not
# either (it calls converters by relative path, not via PATH).

set -euo pipefail

script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
converters_dir="$script_dir/scripts"
prefix="iiif-"

usage() {
    grep '^#' "$0" | grep -v '!/usr/bin/env' | sed 's/^# \{0,1\}//'
}

target_dir="$HOME/.local/bin"
uninstall=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --global) target_dir="/usr/local/bin" ;;
        --uninstall) uninstall=1 ;;
        *) echo "Error: unknown option '$1'." >&2; usage >&2; exit 1 ;;
    esac
    shift
done

# Command name for a script path: drop .sh, turn _ into -, add the prefix.
cmd_name() {
    local base
    base="$(basename "$1" .sh)"
    printf '%s%s' "$prefix" "${base//_/-}"
}

# Scripts exposed as commands: every script under scripts/ except the sourced
# helper common.sh.
scripts=()
for f in "$converters_dir"/*.sh; do
    [ "$(basename "$f")" = "common.sh" ] && continue
    scripts+=("$f")
done

if [ "$uninstall" -eq 1 ]; then
    removed=0
    for f in "${scripts[@]}"; do
        link="$target_dir/$(cmd_name "$f")"
        # Only remove a link that actually points at our script.
        if [ -L "$link" ] && [ "$(readlink -f "$link")" = "$(readlink -f "$f")" ]; then
            rm -f "$link"
            echo "removed $link"
            removed=$((removed + 1))
        fi
    done
    echo "Uninstalled $removed command(s) from $target_dir."
    exit 0
fi

if [ ! -d "$target_dir" ]; then
    mkdir -p "$target_dir" 2>/dev/null || {
        echo "Error: cannot create $target_dir. For a system-wide install run: sudo $0 --global" >&2
        exit 1
    }
fi
if [ ! -w "$target_dir" ]; then
    echo "Error: $target_dir is not writable. For a system-wide install run: sudo $0 --global" >&2
    exit 1
fi

count=0
for f in "${scripts[@]}"; do
    link="$target_dir/$(cmd_name "$f")"
    ln -sf "$f" "$link"
    echo "linked $(cmd_name "$f") -> $f"
    count=$((count + 1))
done
echo "Installed $count command(s) into $target_dir."

case ":$PATH:" in
    *":$target_dir:"*) ;;
    *)
        echo
        echo "Note: $target_dir is not on your PATH. Add it, e.g.:"
        echo "  export PATH=\"$target_dir:\$PATH\""
        ;;
esac
