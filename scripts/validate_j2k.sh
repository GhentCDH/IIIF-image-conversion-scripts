#!/usr/bin/env bash
#
# Validate JPEG 2000 (.jp2) and High Throughput JPEG 2000 (.jph) files with jpylyzer.
#
# Usage:
#   ./validate_j2k.sh [options] [file-or-directory ...]
#
# With no targets, validates the project's test/output folder.
# A directory argument is searched (non-recursively) for *.jp2 and *.jph files.
# The jpylyzer validation format is chosen automatically from each file's extension.
#
# Options:
#   -h, --help   Show this help and exit.
#
# Requires: jpylyzer (install with: pipx install jpylyzer  — or: pip install jpylyzer)

set -uo pipefail

script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"

usage() {
    grep '^#' "$0" | grep -v '!/usr/bin/env' | sed 's/^# \{0,1\}//'
}

targets=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -*) echo "Error: unknown option '$1'." >&2; usage >&2; exit 1 ;;
        *) targets+=("$1") ;;
    esac
    shift
done

if [ "${#targets[@]}" -eq 0 ]; then
    targets=("$project_root/test/output")
fi

if ! command -v jpylyzer >/dev/null 2>&1; then
    echo "Error: jpylyzer not found in PATH." >&2
    echo "Install it with:  pipx install jpylyzer   (or: pip install jpylyzer)" >&2
    exit 1
fi

# Expand targets into a concrete list of files.
files=()
for t in "${targets[@]}"; do
    if [ -d "$t" ]; then
        shopt -s nullglob
        for f in "$t"/*.jp2 "$t"/*.jph; do files+=("$f"); done
        shopt -u nullglob
    elif [ -f "$t" ]; then
        files+=("$t")
    else
        echo "skip: not found: $t" >&2
    fi
done

if [ "${#files[@]}" -eq 0 ]; then
    echo "No .jp2/.jph files found to validate." >&2
    exit 1
fi

total=0; passed=0; failed=0
for f in "${files[@]}"; do
    total=$((total + 1))
    case "${f##*.}" in
        jph) fmt="jph" ;;
        *)   fmt="jp2" ;;
    esac
    # jpylyzer reports an <isValid ...>True|False</isValid> element in its XML output.
    valid="$(jpylyzer --format "$fmt" "$f" 2>/dev/null \
                | grep -oE '<isValid[^>]*>[^<]*</isValid>' \
                | grep -oE '(True|False)' | head -1)"
    if [ "$valid" = "True" ]; then
        printf '  PASS  %s\n' "$(basename "$f")"
        passed=$((passed + 1))
    else
        printf '  FAIL  %s\n' "$(basename "$f")"
        failed=$((failed + 1))
    fi
done

echo
printf 'Validated %d file(s): %d passed, %d failed.\n' "$total" "$passed" "$failed"
[ "$failed" -eq 0 ]
