# common.sh — shared helpers for the IIIF image-conversion scripts.
#
# This file is meant to be *sourced* by a converter script, not executed.
# The sourcing script must define, before calling convert_main:
#
#   TOOL          Required command, e.g. kdu_compress / grk_compress / vips.
#   DESCRIPTION   One-line description shown in --help.
#   ALLOWED_EXTS  Space-separated allowed output extensions, e.g. "jp2" or "tiff tif ptif".
#   run_conversion <input> <output>   Performs the conversion. May read $VERBOSE (0/1).
#
# convert_main parses options/arguments, validates them, checks tool availability,
# then calls run_conversion.

# Refuse to run directly — this is a library.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "common.sh is a helper library and must be sourced, not executed." >&2
    exit 1
fi

usage() {
    local exts_display prepare_line="" requires_extra=""
    exts_display="$(printf '%s' "$ALLOWED_EXTS" | sed 's/ /|/g')"
    if [ "${SUPPORTS_PREPARE:-0}" -eq 1 ]; then
        prepare_line=$'\n  --prepare       Convert an unsupported input to an uncompressed TIFF via vips first.'
        requires_extra=" (and vips for --prepare)"
    fi
    cat <<EOF
$DESCRIPTION

Usage:
  $(basename "$0") [options] <input_file> <output_file.${exts_display}>

Arguments:
  input_file    Source image to convert.
  output_file   Destination file. Must have a .${exts_display} extension.

Options:
  -v, --verbose   Show the converter's warnings and progress output.
  -h, --help      Show this help and exit.${prepare_line}

Requires: ${TOOL}${requires_extra}
EOF
}

convert_main() {
    VERBOSE=0
    local prepare=0
    local positionals=()

    # Scan all arguments so options may appear before, after, or between the
    # filenames (e.g. "script in.tif out.jp2 --verbose").
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -v|--verbose)
                VERBOSE=1
                ;;
            --prepare)
                if [ "${SUPPORTS_PREPARE:-0}" -eq 1 ]; then
                    prepare=1
                else
                    echo "Error: unknown option '$1'." >&2
                    usage >&2
                    exit 1
                fi
                ;;
            --)
                shift
                while [ "$#" -gt 0 ]; do positionals+=("$1"); shift; done
                break
                ;;
            -*)
                echo "Error: unknown option '$1'." >&2
                usage >&2
                exit 1
                ;;
            *)
                positionals+=("$1")
                ;;
        esac
        shift
    done

    if [ "${#positionals[@]}" -ne 2 ]; then
        usage >&2
        exit 1
    fi

    local input_file="${positionals[0]}"
    local output_file="${positionals[1]}"

    if ! command -v "$TOOL" >/dev/null 2>&1; then
        echo "Error: required tool '$TOOL' not found in PATH. Please install it." >&2
        exit 1
    fi

    if [ ! -f "$input_file" ]; then
        echo "Error: input file not found: $input_file" >&2
        exit 1
    fi

    local ext="${output_file##*.}" ok=0 e
    for e in $ALLOWED_EXTS; do
        if [ "$ext" = "$e" ]; then ok=1; break; fi
    done
    if [ "$ok" -ne 1 ]; then
        echo "Error: output file must have a .$(printf '%s' "$ALLOWED_EXTS" | sed 's/ /, ./g') extension (got '$output_file')." >&2
        exit 1
    fi

    # Optional --prepare: transcode the input to an uncompressed TIFF via vips
    # first (e.g. for kdu_compress, whose demo reader only accepts uncompressed
    # TIFF). The temporary file is removed on exit.
    if [ "$prepare" -eq 1 ]; then
        if ! command -v vips >/dev/null 2>&1; then
            echo "Error: --prepare requires vips, which was not found in PATH." >&2
            exit 1
        fi
        # Not 'local': the EXIT trap below runs after this function returns, so
        # the variable must still be in scope (and :- guards it under 'set -u').
        PREPARED_TMP="$(mktemp --suffix=.tif)" || { echo "Error: could not create a temporary file." >&2; exit 1; }
        trap 'rm -f "${PREPARED_TMP:-}"' EXIT
        if [ "$VERBOSE" -ne 1 ]; then export VIPS_WARNING=1; fi
        echo "Preparing uncompressed TIFF via vips ($PREPARED_TMP) ..." >&2
        vips tiffsave "$input_file" "$PREPARED_TMP" --compression none
        input_file="$PREPARED_TMP"
    fi

    run_conversion "$input_file" "$output_file"
}
