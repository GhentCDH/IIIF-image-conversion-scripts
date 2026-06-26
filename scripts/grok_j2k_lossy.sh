#!/usr/bin/env bash
set -euo pipefail

TOOL="grk_compress"
DESCRIPTION="Convert an image to a lossy JPEG 2000 (JP2) file using Grok."
ALLOWED_EXTS="jp2"

run_conversion() {
    local input="$1" output="$2"
    local verbose=""
    if [ "$VERBOSE" -eq 1 ]; then verbose="-v"; fi
    grk_compress -i "$input" -o "$output" -r 8 -n 7 -c "[256,256]" -b "64,64" -p RPCL -S -I --tile-parts R --plt --tlm $verbose
}

# Locate the sibling helper independent of CWD (and symlink-safe).
script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$script_dir/common.sh"
convert_main "$@"
