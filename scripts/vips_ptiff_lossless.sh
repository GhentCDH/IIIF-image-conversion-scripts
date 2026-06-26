#!/usr/bin/env bash
set -euo pipefail

TOOL="vips"
DESCRIPTION="Convert an image to a lossless pyramidal TIFF (Zstandard) using vips."
ALLOWED_EXTS="tiff tif ptif"

run_conversion() {
    local input="$1" output="$2"
    # Silence libvips warnings (e.g. truncated TIFF metadata) unless verbose.
    if [ "$VERBOSE" -ne 1 ]; then export VIPS_WARNING=1; fi
    vips tiffsave "$input" "$output" --tile --pyramid --compression zstd --level 9 --tile-width 256 --tile-height 256
}

# Locate the sibling helper independent of CWD (and symlink-safe).
script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$script_dir/common.sh"
convert_main "$@"
