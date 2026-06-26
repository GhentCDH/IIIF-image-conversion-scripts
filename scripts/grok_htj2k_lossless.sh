#!/usr/bin/env bash
set -euo pipefail

TOOL="grk_compress"
DESCRIPTION="Convert an image to a lossless High Throughput JPEG 2000 (JPH) file using Grok."
ALLOWED_EXTS="jph"

run_conversion() {
    local input="$1" output="$2"
    local verbose=""
    if [ "$VERBOSE" -eq 1 ]; then verbose="-v"; fi
    # -M 64 enables the HT (high throughput) block coder; no rate cap => lossless.
    grk_compress -i "$input" -o "$output" -n 7 -c "[256,256]" -b "64,64" -p RPCL -S --tile-parts R --plt --tlm -M 64 $verbose
}

# Locate the sibling helper independent of CWD (and symlink-safe).
script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$script_dir/common.sh"
convert_main "$@"
