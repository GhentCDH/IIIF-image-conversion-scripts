#!/usr/bin/env bash
#
# convert_folder.sh — batch/folder image conversion driven by a conversion profile.
#
# Walks a source tree, converts images with the selected profile, copies extra
# files (metadata) verbatim, and tracks which inputs are already converted so it
# only does new/changed work. Optional daemon mode polls the source tree.
#
# A *profile* is a small file (profiles/<id>) declaring:
#     ext     = <output extension>      e.g. jp2
#     command = <tool ... {in} ... {out}>
# The output extension lets this script compute the target name (image.jpeg ->
# image.<ext>) and decide whether a target already exists / is up to date.
# {in}/{out} in the command are replaced with the (quoted) input/output paths.
#
# See README.md for the full description.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PROFILES_DIR="$SELF_DIR/profiles"
SCRIPTS_DIR="$SELF_DIR/scripts"
# Make the sibling converter scripts resolvable by bare name in profile commands.
export PATH="$SCRIPTS_DIR:$PATH"

# ---- defaults -------------------------------------------------------------
PROFILE=""
INPUT_DIR=""
OUTPUT_DIR=""
CONVERT_CSV="tif,tiff,jpg,jpeg,png"
COPY_CSV="yaml,xml,txt"
SAFE_TIME=30
MODIFIED=""
PARALLEL=1
FORCE=0
SIMULATE=0
VALIDATE=0
DAEMON=0
SLEEP_TIME=60
VERBOSE=0
declare -a REQUIRE=()

usage() {
    cat <<EOF
convert_folder.sh — batch image conversion with conversion profiles.

Usage:
  $(basename "$0") --profile <id|path> -i <input_dir> -o <output_dir> [options]

Required:
  --profile <id|path>   Conversion profile. An id is looked up in
                        $PROFILES_DIR; a path to a profile file also works.
  -i, --input <dir>     Source directory (walked recursively).
  -o, --output <dir>    Destination directory (structure is mirrored).

Selection (extension lists, comma-separated, case-insensitive):
  --convert <exts>      Extensions treated as source images to convert.
                        Default: $CONVERT_CSV
  --copy <exts|all>     Extensions copied verbatim ('all' = every non-converted
                        file). Default: $COPY_CSV
                        (If an extension is in both, convert wins.)

Change tracking:
  -f, --force           Reconvert/recopy even if the target is up to date.
  --safe-time <sec>     Ignore files modified within the last <sec> seconds
                        (still being written). Default: $SAFE_TIME
  --modified <expr>     Only consider files modified after this time. Accepts
                        anything 'date -d' understands (e.g. '2 days ago').

Processing:
  -j, --parallel <n>    Max parallel conversions. Default: $PARALLEL
  -S, --simulate        Scan only; print what would happen, change nothing.
  --validate            Validate produced .jp2/.jph outputs with validate_j2k.sh.
  --require <name...>   Only process a folder if it contains one of these
                        filenames (consumes following non-option arguments).

Daemon:
  -d, --daemon          Loop forever, re-scanning each cycle.
  --sleep-time <sec>    Seconds to sleep between cycles. Default: $SLEEP_TIME

Other:
  -v, --verbose         More logging; echo each conversion's full output.
  -l, --list-profiles   List the available conversion profiles and exit.
  -h, --help            Show this help and exit.
EOF
}

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
dbg() { if [ "$VERBOSE" -eq 1 ]; then log "$@"; fi; }
die() { echo "Error: $*" >&2; exit 1; }

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

# ---- argument parsing -----------------------------------------------------
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --profile)      PROFILE="${2:?--profile needs a value}"; shift 2;;
            -i|--input)     INPUT_DIR="${2:?--input needs a value}"; shift 2;;
            -o|--output)    OUTPUT_DIR="${2:?--output needs a value}"; shift 2;;
            --convert)      CONVERT_CSV="${2:?--convert needs a value}"; shift 2;;
            --copy)         COPY_CSV="${2:?--copy needs a value}"; shift 2;;
            --safe-time)    SAFE_TIME="${2:?--safe-time needs a value}"; shift 2;;
            --modified)     MODIFIED="${2:?--modified needs a value}"; shift 2;;
            -j|--parallel)  PARALLEL="${2:?--parallel needs a value}"; shift 2;;
            -f|--force)     FORCE=1; shift;;
            -S|--simulate)  SIMULATE=1; shift;;
            --validate)     VALIDATE=1; shift;;
            -d|--daemon)    DAEMON=1; shift;;
            --sleep-time)   SLEEP_TIME="${2:?--sleep-time needs a value}"; shift 2;;
            -v|--verbose)   VERBOSE=1; shift;;
            -l|--list-profiles) list_profiles; exit 0;;
            -h|--help)      usage; exit 0;;
            --require)
                shift
                while [ "$#" -gt 0 ] && [ "${1:0:1}" != "-" ]; do
                    REQUIRE+=("$1"); shift
                done
                ;;
            --) shift; break;;
            -*) usage >&2; die "unknown option '$1'";;
            *)  usage >&2; die "unexpected argument '$1'";;
        esac
    done
}

# ---- list profiles --------------------------------------------------------
# Print the available profiles (id, output extension, command) and return.
# Non-fatal: a malformed or non-profile file is skipped, not an error.
list_profiles() {
    if [ ! -d "$PROFILES_DIR" ]; then
        echo "No profiles directory found at $PROFILES_DIR" >&2
        return 1
    fi
    printf 'Available conversion profiles (%s):\n\n' "$PROFILES_DIR"
    printf '  %-26s %-5s %s\n' "ID" "EXT" "LABEL"

    local f id ext command label line key val found=0
    shopt -s nullglob
    for f in "$PROFILES_DIR"/*; do
        [ -f "$f" ] || continue
        ext=""; command=""; label=""
        while IFS= read -r line || [ -n "$line" ]; do
            line="$(trim "$line")"
            [ -z "$line" ] && continue
            [ "${line:0:1}" = "#" ] && continue
            [[ "$line" == *=* ]] || continue
            key="$(trim "${line%%=*}")"
            val="$(trim "${line#*=}")"
            case "$key" in
                ext)     ext="$val";;
                command) command="$val";;
                label)   label="$val";;
            esac
        done < "$f"
        # Skip files that carry neither key — they aren't profiles.
        [ -z "$ext" ] && [ -z "$command" ] && continue
        # Show the label; fall back to the command when a profile has none.
        printf '  %-26s %-5s %s\n' "$(basename "$f")" "${ext:-?}" "${label:-$command}"
        found=1
    done
    shopt -u nullglob

    [ "$found" -eq 0 ] && printf '  (none found)\n'
    printf '\nUse a profile with:  --profile <id|path>\n'
}

# ---- profile resolution ---------------------------------------------------
PROFILE_EXT=""
PROFILE_COMMAND=""

resolve_profile() {
    local p="$1" file=""
    if [ -f "$p" ]; then
        file="$p"
    elif [ -f "$PROFILES_DIR/$p" ]; then
        file="$PROFILES_DIR/$p"
    else
        die "profile '$p' not found (looked for a file and in $PROFILES_DIR/)"
    fi

    local line key val
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(trim "$line")"
        [ -z "$line" ] && continue
        [ "${line:0:1}" = "#" ] && continue
        [[ "$line" == *=* ]] || continue
        key="$(trim "${line%%=*}")"
        val="$(trim "${line#*=}")"
        case "$key" in
            ext)     PROFILE_EXT="${val,,}";;
            command) PROFILE_COMMAND="$val";;
        esac
    done < "$file"

    [ -n "$PROFILE_EXT" ]     || die "profile '$file' is missing 'ext ='"
    [ -n "$PROFILE_COMMAND" ] || die "profile '$file' is missing 'command ='"
    [[ "$PROFILE_COMMAND" == *"{in}"* && "$PROFILE_COMMAND" == *"{out}"* ]] \
        || die "profile command must contain both {in} and {out} placeholders"
}

# ---- extension sets -------------------------------------------------------
CONVERT_SET=" "
COPY_SET=" "
COPY_ALL=0

csv_to_set() {
    local out=" " item IFS=','
    for item in $1; do
        item="$(trim "${item,,}")"
        [ -n "$item" ] && out+="$item "
    done
    printf '%s' "$out"
}

build_sets() {
    CONVERT_SET="$(csv_to_set "$CONVERT_CSV")"
    if [ "$(trim "${COPY_CSV,,}")" = "all" ]; then
        COPY_ALL=1
    else
        COPY_SET="$(csv_to_set "$COPY_CSV")"
    fi
    # Warn once on overlap (convert wins).
    if [ "$COPY_ALL" -eq 0 ]; then
        local e
        for e in $CONVERT_SET; do
            if [[ "$COPY_SET" == *" $e "* ]]; then
                log "# Note: extension '$e' is in both --convert and --copy; it will be converted."
            fi
        done
    fi
}

in_set()    { [[ "$1" == *" $2 "* ]]; }

# ---- worker (runs in xargs subshell) --------------------------------------
# Receives one tab-separated "src<TAB>target" record. Substitutes {in}/{out}
# into the profile command and runs it, writing all output to a per-job log.
convert_one() {
    local rec="$1"
    local src="${rec%%$'\t'*}"
    local out="${rec#*$'\t'}"
    local log_file="$JOBLOG_DIR/$(basename "$out").log"

    local -a cmd=()
    local tok
    set -f   # the command may contain glob-like tokens (e.g. [256,256])
    for tok in $PROFILE_COMMAND; do
        tok="${tok//\{in\}/$src}"
        tok="${tok//\{out\}/$out}"
        cmd+=("$tok")
    done
    set +f

    local status
    {
        echo "[START] $src -> $out"
        if "${cmd[@]}"; then
            echo "[OK]    $out"; status=OK
        else
            echo "[FAIL]  $out (exit $?)"; status=FAIL
            # Drop a partial/garbage output so it isn't mistaken for success.
            [ -f "$out" ] && rm -f "$out"
        fi
    } >"$log_file" 2>&1
    # Live progress line (stdout is inherited through xargs, then prefixed with a
    # [done/total] counter by the reader in process_manifest). A single short line
    # prints atomically, so parallel workers don't interleave mid-line.
    printf '[%-4s] %s\n' "$status" "$out"
    return 0
}

# ---- scan -----------------------------------------------------------------
# Walk INPUT_DIR and emit NUL-delimited "ACTION<TAB>src<TAB>target" records.
declare -A REQ_CACHE=()

scan_to_manifest() {
    local manifest="$1"
    local n_img=0 n_copy=0 n_img_scope=0 n_copy_scope=0
    : > "$manifest"

    local path rel ext dir target_rel target action src_mtime r ok
    while IFS= read -r -d '' path; do
        # filesize > 0
        [ -s "$path" ] || { dbg "  [skip] $path (empty)"; continue; }

        rel="${path#"$INPUT_DIR"/}"
        ext="${path##*.}"; ext="${ext,,}"

        # classify by extension (convert wins over copy)
        if in_set "$CONVERT_SET" "$ext"; then
            action="IMAGE"
            target_rel="${rel%.*}.$PROFILE_EXT"
        elif [ "$COPY_ALL" -eq 1 ] || in_set "$COPY_SET" "$ext"; then
            action="COPY"
            target_rel="$rel"
        else
            continue
        fi

        # require-gate: folder must contain one of the required filenames
        if [ "${#REQUIRE[@]}" -gt 0 ]; then
            dir="$(dirname "$path")"
            if [ -z "${REQ_CACHE[$dir]:-}" ]; then
                ok=0
                for r in "${REQUIRE[@]}"; do
                    if [ -e "$dir/$r" ]; then ok=1; break; fi
                done
                REQ_CACHE[$dir]=$ok
            fi
            [ "${REQ_CACHE[$dir]}" -eq 1 ] || continue
        fi

        # in scope (non-empty, classified, not require-gated) regardless of
        # whether it still needs (re)processing
        if [ "$action" = "IMAGE" ]; then n_img_scope=$((n_img_scope+1)); else n_copy_scope=$((n_copy_scope+1)); fi

        # not modified since last run / before --modified?
        if [ "$LAST_RUN" -gt 0 ]; then
            src_mtime="$(stat -c %Y "$path")"
            if [ $((src_mtime + SAFE_TIME)) -lt "$LAST_RUN" ]; then
                dbg "  [skip] $rel (not modified)"
                continue
            fi
        fi

        target="$OUTPUT_DIR/$target_rel"

        # target already up to date?
        if [ "$FORCE" -eq 0 ] && [ -s "$target" ] && [ "$target" -nt "$path" ]; then
            dbg "  [skip] $rel (target up to date)"
            continue
        fi

        printf '%s\t%s\t%s\0' "$action" "$path" "$target" >> "$manifest"
        if [ "$action" = "IMAGE" ]; then n_img=$((n_img+1)); else n_copy=$((n_copy+1)); fi
    done < <(find "$INPUT_DIR" -type f -print0)

    log "# Scope:       $n_img_scope image(s), $n_copy_scope copyable file(s)."
    log "# New/changed: $n_img image(s), $n_copy copyable file(s)."
}

# ---- process --------------------------------------------------------------
process_manifest() {
    local manifest="$1"
    local img_manifest action rest src target

    img_manifest="$(mktemp)"
    : > "$img_manifest"

    local n_images=0
    # Create target dirs + handle copies; collect image records.
    while IFS= read -r -d '' rec; do
        action="${rec%%$'\t'*}"
        rest="${rec#*$'\t'}"
        src="${rest%%$'\t'*}"
        target="${rest#*$'\t'}"
        mkdir -p "$(dirname "$target")"
        if [ "$action" = "COPY" ]; then
            log "  [COPY]    $src -> $target"
            # Plain cp (not -p): the target gets a fresh mtime so it reads as
            # "newer than source" and is skipped on the next run until the
            # source changes — same incremental behaviour as the images.
            cp "$src" "$target"
        else
            printf '%s\t%s\0' "$src" "$target" >> "$img_manifest"
            n_images=$((n_images+1))
        fi
    done < "$manifest"

    if [ ! -s "$img_manifest" ]; then
        rm -f "$img_manifest"
        return 0
    fi

    JOBLOG_DIR="$(mktemp -d)"
    export PROFILE_COMMAND JOBLOG_DIR
    export -f convert_one

    log "# Converting $n_images image(s) (parallelism: $PARALLEL) ..."
    # Workers each print one "[OK]/[FAIL] <file>" line as they finish. Pipe the
    # stream through a single counter so every line gets a "[done/total]" prefix
    # in completion order — numbering in one process avoids parallel races.
    local width=${#n_images}
    xargs -0 -P "$PARALLEL" -I REC bash -c 'convert_one "$1"' _ REC < "$img_manifest" \
        | { count=0; while IFS= read -r line; do
                count=$((count + 1))
                printf '  [%*d/%d] %s\n' "$width" "$count" "$n_images" "$line"
            done; }

    # Tally results from the per-job logs. The live lines already showed each
    # outcome; here we additionally print the full log for failures (so the
    # reason is visible) and for all jobs under --verbose.
    local f
    local n_ok=0 n_fail=0
    while IFS= read -r f; do
        if grep -q '^\[FAIL\]' "$f"; then
            n_fail=$((n_fail+1))
            cat "$f"
        else
            n_ok=$((n_ok+1))
            [ "$VERBOSE" -eq 1 ] && cat "$f"
        fi
    done < <(find "$JOBLOG_DIR" -type f -name '*.log' | sort)
    log "# Conversion done: $n_ok ok, $n_fail failed."

    # Optional validation of produced jp2/jph outputs.
    if [ "$VALIDATE" -eq 1 ] && { [ "$PROFILE_EXT" = "jp2" ] || [ "$PROFILE_EXT" = "jph" ]; }; then
        local -a vfiles=()
        while IFS= read -r -d '' rec; do
            target="${rec#*$'\t'}"
            [ -s "$target" ] && vfiles+=("$target")
        done < "$img_manifest"
        if [ "${#vfiles[@]}" -gt 0 ]; then
            log "# Validating ${#vfiles[@]} output(s) with validate_j2k.sh ..."
            "$SCRIPTS_DIR/validate_j2k.sh" "${vfiles[@]}" || log "# Note: validation reported failures."
        fi
    fi

    rm -rf "$JOBLOG_DIR"
    rm -f "$img_manifest"
}

simulate_manifest() {
    local manifest="$1" rec action rest src target
    log "# Simulation only — no changes will be made."
    while IFS= read -r -d '' rec; do
        action="${rec%%$'\t'*}"
        rest="${rec#*$'\t'}"
        src="${rest%%$'\t'*}"
        target="${rest#*$'\t'}"
        printf '  %-7s %s -> %s\n' "$action" "$src" "$target"
    done < "$manifest"
}

run_once() {
    local manifest
    manifest="$(mktemp)"
    log "# Scanning $INPUT_DIR ..."
    scan_to_manifest "$manifest"
    if [ "$SIMULATE" -eq 1 ]; then
        simulate_manifest "$manifest"
    else
        process_manifest "$manifest"
    fi
    rm -f "$manifest"
}

# ---- main -----------------------------------------------------------------
main() {
    parse_args "$@"

    [ -n "$PROFILE" ]    || { usage >&2; die "--profile is required"; }
    [ -n "$INPUT_DIR" ]  || { usage >&2; die "--input is required"; }
    [ -n "$OUTPUT_DIR" ] || { usage >&2; die "--output is required"; }
    [ -d "$INPUT_DIR" ]  || die "input directory not found: $INPUT_DIR"

    INPUT_DIR="$(cd "$INPUT_DIR" && pwd)"
    mkdir -p "$OUTPUT_DIR"
    OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
    PARALLEL=$(( PARALLEL < 1 ? 1 : PARALLEL ))
    SAFE_TIME=$(( SAFE_TIME < 0 ? 0 : SAFE_TIME ))

    resolve_profile "$PROFILE"
    build_sets

    # --modified sets the initial "last run" boundary.
    LAST_RUN=0
    if [ -n "$MODIFIED" ]; then
        LAST_RUN="$(date -d "$MODIFIED" +%s 2>/dev/null)" || die "invalid --modified expression: $MODIFIED"
    fi

    log "# Profile      : $PROFILE (ext: $PROFILE_EXT)"
    log "# Input        : $INPUT_DIR"
    log "# Output       : $OUTPUT_DIR"
    dbg "# Command      : $PROFILE_COMMAND"
    [ "$DAEMON" -eq 1 ] && log "# Daemon mode (sleep ${SLEEP_TIME}s)"

    while true; do
        local now; now="$(date +%s)"
        run_once
        LAST_RUN="$now"
        [ "$DAEMON" -eq 1 ] || break
        log "# Sleeping ${SLEEP_TIME}s ..."
        sleep "$SLEEP_TIME"
    done
}

main "$@"
