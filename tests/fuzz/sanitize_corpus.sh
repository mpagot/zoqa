#!/usr/bin/env bash
# sanitize_corpus.sh — Rename AFL++ corpus files to Windows-safe names.
#
# AFL++ generates filenames containing colons (e.g. id:000002,time:0,...) which
# are invalid on Windows (NTFS). This script replaces Windows-unsafe characters
# (: * ? " < > |) with underscores in all files under tests/fuzz/corpus_*/.
#
# Example:
#   id:000002,time:0,execs:0,orig:id:000009,src:000001,time:0,execs:65,op:(null),pos:0,+cov
#   → id_000002,time_0,execs_0,orig_id_000009,src_000001,time_0,execs_65,op_(null),pos_0,+cov
#
# The script is idempotent: already-safe filenames are left untouched.
#
# Usage:
#   bash tests/fuzz/sanitize_corpus.sh           # check only (exit 1 if unsafe names found)
#   bash tests/fuzz/sanitize_corpus.sh --fix     # rename in-place (plain mv)
#   bash tests/fuzz/sanitize_corpus.sh --print0 | xargs -0 -n2 git mv --  # rename via git mv

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--fix | --print0 | --help]

Scan tests/fuzz/corpus_*/ for filenames containing Windows-unsafe characters
and optionally rename them by replacing unsafe chars with underscores.

Options:
  (none)    Report files with unsafe names; exit 1 if any found (default).
  --fix     Actually rename the files in-place (using mv).
  --print0  Output null-separated old/new path pairs for piping into git mv:
              bash tests/fuzz/sanitize_corpus.sh --print0 | xargs -0 -n2 git mv --
  --help    Show this help message and exit.
EOF
}

MODE=check

case "${1:-}" in
    --fix)    MODE=fix ;;
    --print0) MODE=print0 ;;
    --help|-h)
        usage
        exit 0
        ;;
    "")      MODE=check ;;
    *)
        echo "Error: unknown option '$1'" >&2
        usage >&2
        exit 2
        ;;
esac

# Characters forbidden on Windows: \ / : * ? " < > |
# (\ and / are path separators and won't appear in basenames from the glob)
UNSAFE_RE='[:\\*?"<>|]'

dirty=0
renamed=0

for corpus_dir in "$SCRIPT_DIR"/corpus_*; do
    [[ -d "$corpus_dir" ]] || continue

    dir_count=0

    for f in "$corpus_dir"/*; do
        [[ -f "$f" ]] || continue
        old_basename="$(basename "$f")"

        # Skip files that are already safe.
        if ! [[ "$old_basename" =~ $UNSAFE_RE ]]; then
            continue
        fi

        dir_count=$(( dir_count + 1 ))

        if [[ "$MODE" == "check" ]]; then
            continue
        fi

        # Replace all unsafe chars with underscores.
        new_basename="${old_basename//:/_}"
        new_basename="${new_basename//\*/_}"
        new_basename="${new_basename//\?/_}"
        new_basename="${new_basename//\"/_}"
        new_basename="${new_basename//</_}"
        new_basename="${new_basename//>/_}"
        new_basename="${new_basename//|/_}"

        new_path="$corpus_dir/$new_basename"

        # Handle unlikely collision: append _N suffix.
        if [[ -e "$new_path" && "$new_path" != "$f" ]]; then
            n=1
            while [[ -e "${new_path}_${n}" ]]; do
                n=$(( n + 1 ))
            done
            new_path="${new_path}_${n}"
        fi

        if [[ "$MODE" == "print0" ]]; then
            printf '%s\0%s\0' "$f" "$new_path"
        else
            mv -- "$f" "$new_path"
            renamed=$(( renamed + 1 ))
        fi
    done

    if (( dir_count > 0 )) && [[ "$MODE" == "check" ]]; then
        echo "FAIL: $(basename "$corpus_dir") has ${dir_count} file(s) with Windows-unsafe names"
        dirty=1
    fi
done

if [[ "$MODE" == "check" ]]; then
    if (( dirty > 0 )); then
        echo ""
        echo "Run 'bash tests/fuzz/sanitize_corpus.sh --fix' to rename them."
        exit 1
    else
        echo "OK: all corpus filenames are already Windows-safe"
    fi
else
    if (( renamed > 0 )); then
        echo "OK: renamed ${renamed} file(s)"
    else
        echo "OK: all corpus filenames are already Windows-safe"
    fi
fi
