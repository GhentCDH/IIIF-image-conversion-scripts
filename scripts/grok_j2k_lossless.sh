#!/usr/bin/env bash
set -euo pipefail

TOOL="grk_compress"
DESCRIPTION="Convert an image to a lossless JPEG 2000 (JP2) file using Grok."
ALLOWED_EXTS="jp2"

run_conversion() {
    local input="$1" output="$2"
    local verbose=""
    if [ "$VERBOSE" -eq 1 ]; then verbose="-v"; fi
    # No -r/-q rate cap and no -I (reversible 5-3 wavelet) => fully lossless.
    grk_compress -i "$input" -o "$output" -n 7 -c "[256,256]" -b "64,64" -p RPCL -S --tile-parts R --plt --tlm $verbose
}

# Locate the sibling helper independent of CWD (and symlink-safe).
script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$script_dir/common.sh"
convert_main "$@"
