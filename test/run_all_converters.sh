#!/usr/bin/env bash
#
# Batch-convert every image in test/input with every conversion script.
#
# For each input image and each converter, an output file is written to
# test/output named:
#
#     <image-basename>_<converter-name>.<ext>
#
# e.g. Berchem(1852).tif + kakadu_j2k_lossy.sh -> Berchem(1852)_kakadu_j2k_lossy.jp2
#
# The output extension is chosen per converter (jph for HT scripts, tif for
# vips scripts, jp2 otherwise). Each conversion is timed and a summary is
# printed at the end. A failing conversion is reported but does not stop the run.
#
# Usage:
#   ./run_all_converters.sh [--validate] [converter.sh ...]
#
# Options:
#   --validate     After converting, run validate_j2k.sh on the jp2/jph outputs.
#
# Arguments:
#   converter.sh   Optional list of converter scripts to run instead of all of
#                  them (names are matched relative to this script's folder).

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
converters_dir="$project_root/scripts"
input_dir="$script_dir/input"
output_dir="$script_dir/output"

usage() {
    grep '^#' "$0" | grep -v '!/usr/bin/env' | sed 's/^# \{0,1\}//'
}

# Parse options; anything else is treated as a converter name.
validate=0
selected=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --validate) validate=1 ;;
        -*) echo "Error: unknown option '$1'." >&2; usage >&2; exit 1 ;;
        *) selected+=("$1") ;;
    esac
    shift
done

# Converters to run: command-line list if given, otherwise all of them.
if [ "${#selected[@]}" -gt 0 ]; then
    converters=("${selected[@]}")
else
    converters=(
        grok_j2k_lossy.sh
        grok_j2k_lossless.sh
        grok_htj2k_lossless.sh
        kakadu_j2k_lossy.sh
        kakadu_j2k_lossless.sh
        kakadu_htj2k_lossy.sh
        kakadu_htj2k_lossless.sh
        vips_ptiff_lossy_jpeg.sh
        vips_ptiff_lossless.sh
    )
fi

# Pick the output extension that a converter expects.
output_ext() {
    case "$1" in
        *htj2k*|*ht2k*) echo "jph" ;;
        *vips*|*ptiff*) echo "tif" ;;
        *)              echo "jp2" ;;
    esac
}

if [ ! -d "$input_dir" ]; then
    echo "Error: input directory not found: $input_dir" >&2
    exit 1
fi
mkdir -p "$output_dir"

shopt -s nullglob
inputs=("$input_dir"/*)
shopt -u nullglob
if [ "${#inputs[@]}" -eq 0 ]; then
    echo "Error: no input images found in $input_dir" >&2
    exit 1
fi

total=0
ok=0
failed=0
run_start="$(date +%s.%N)"

for input in "${inputs[@]}"; do
    [ -f "$input" ] || continue
    image="$(basename "$input")"
    base="${image%.*}"

    for converter in "${converters[@]}"; do
        script_path="$converters_dir/$converter"
        if [ ! -x "$script_path" ]; then
            echo "skip: converter not found or not executable: $converter" >&2
            continue
        fi

        ext="$(output_ext "$converter")"
        output="$output_dir/${base}_${converter%.sh}.${ext}"

        total=$((total + 1))
        printf '==> %s | %s\n' "$image" "$converter"

        start="$(date +%s.%N)"
        if "$script_path" "$input" "$output"; then
            status="ok"
            ok=$((ok + 1))
        else
            status="FAILED"
            failed=$((failed + 1))
        fi
        end="$(date +%s.%N)"

        elapsed="$(awk "BEGIN {printf \"%.2f\", $end - $start}")"
        size="-"
        [ -f "$output" ] && size="$(du -h "$output" | cut -f1)"
        printf '    %-7s %8ss  %6s  %s\n' "$status" "$elapsed" "$size" "$(basename "$output")"
    done
done

run_end="$(date +%s.%N)"
run_elapsed="$(awk "BEGIN {printf \"%.2f\", $run_end - $run_start}")"

echo
printf 'Done: %d conversion(s), %d ok, %d failed in %ss\n' "$total" "$ok" "$failed" "$run_elapsed"

validate_failed=0
if [ "$validate" -eq 1 ]; then
    echo
    echo "Validating jp2/jph outputs with jpylyzer..."
    "$converters_dir/validate_j2k.sh" "$output_dir" || validate_failed=1
fi

[ "$failed" -eq 0 ] && [ "$validate_failed" -eq 0 ]
