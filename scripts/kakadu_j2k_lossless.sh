#!/usr/bin/env bash
set -euo pipefail

TOOL="kdu_compress"
DESCRIPTION="Convert an image to a lossless JPEG 2000 (JP2) file using Kakadu."
ALLOWED_EXTS="jp2"
SUPPORTS_PREPARE=1   # kdu_compress only reads uncompressed TIFF; allow --prepare via vips

run_conversion() {
    local input="$1" output="$2"
    local quiet="-quiet"
    if [ "$VERBOSE" -eq 1 ]; then quiet=""; fi
    kdu_compress -i "$input" -o "$output" Creversible=yes Clayers=1 Clevels=6 Cprecincts="{256,256}" Corder=RPCL Cblk="{64,64}" ORGgen_plt=yes ORGplt_parts=R ORGtparts=R ORGgen_tlm=8 Cuse_sop=yes -rate - $quiet
}

# Locate the sibling helper independent of CWD (and symlink-safe).
script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$script_dir/common.sh"
convert_main "$@"
