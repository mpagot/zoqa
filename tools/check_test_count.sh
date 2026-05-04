#!/usr/bin/env bash
# check_test_count.sh — verify every `test` block in src/*.zig is actually
# discovered by `zig build test`.
#
# Why this exists: Zig's lazy semantic analysis silently skips test blocks
# in files that aren't reached from a test root. Tests can sit in the source
# tree for months without ever running. This script counts test declarations
# by string-matching the source files, then runs the test suite and parses
# the runner's "X passed" output. If the two numbers disagree, it fails with
# a per-file breakdown of where the gap is.
#
# Background:
#   - ideas/UNIT_TESTS_DOES_NOT_RUN.md
#   - https://github.com/ziglang/zig/issues/10018
#   - "Nested Container Tests" in the Zig Language Reference
#
# Usage:
#   ./check_test_count.sh            # check repo at script's location
#   ./check_test_count.sh /path/...  # check a different repo root
#
# Exit codes:
#   0  — counts match
#   1  — counts disagree (lists the files that lost tests)
#   2  — `zig build test` itself failed (compile or test failure)
#   3  — usage error / src/ not found

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${1:-$SCRIPT_DIR}"

if [[ ! -d "$REPO_ROOT/src" ]]; then
    echo "error: $REPO_ROOT/src not found" >&2
    exit 3
fi

cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Step 1 — count `test` declarations per file.
#
# Matches lines that begin with `test` (no leading whitespace) followed by
# either a string literal (`test "name"`), an identifier (`test foo`), or
# an opening brace (`test {`). Doesn't try to handle nested or commented-out
# tests; if you need that level of fidelity, run `zig ast-check` instead.
# ---------------------------------------------------------------------------

declare -A SRC_COUNT
TOTAL_SRC=0

while IFS= read -r -d '' file; do
    # `^test\b` ensures we don't match identifiers like "test_foo" or
    # comments. Matches `test "..."`, `test foo {`, `test {`.
    n=$(grep -cE '^test[[:space:]]*("|\{|[A-Za-z_])' "$file" || true)
    if [[ $n -gt 0 ]]; then
        rel="${file#./}"
        SRC_COUNT[$rel]=$n
        TOTAL_SRC=$((TOTAL_SRC + n))
    fi
done < <(find src -name '*.zig' -type f -print0)

# ---------------------------------------------------------------------------
# Step 2 — run the test suite, parse the runner output.
#
# `zig build test --summary all` prints lines like:
#   +- run test 30 passed 28ms MaxRSS:2M
#   +- run test 76 passed 19ms MaxRSS:2M
# We sum the digits before "passed" across all such lines. The trailing
# "X/Y tests passed" summary line is also captured for the human-readable
# report.
# ---------------------------------------------------------------------------

echo "Running zig build test --summary all ..."
TEST_LOG="$(mktemp)"
trap 'rm -f "$TEST_LOG"' EXIT

if ! zig build test --summary all > "$TEST_LOG" 2>&1; then
    echo "error: \`zig build test\` failed:" >&2
    tail -20 "$TEST_LOG" >&2
    exit 2
fi

# Sum every "run test N passed" line. The runner emits one per addTest step.
TOTAL_RUN=$(grep -oE 'run test [0-9]+ passed' "$TEST_LOG" \
            | awk '{sum += $3} END {print sum+0}')

SUMMARY_LINE=$(grep -oE '[0-9]+/[0-9]+ tests passed' "$TEST_LOG" | head -1 || true)

# ---------------------------------------------------------------------------
# Step 3 — compare and report.
# ---------------------------------------------------------------------------

printf '\nPer-file source counts:\n'
for f in $(printf '%s\n' "${!SRC_COUNT[@]}" | sort); do
    printf '  %-25s %3d\n' "$f" "${SRC_COUNT[$f]}"
done

printf '\nSource total : %d\n' "$TOTAL_SRC"
printf 'Runner total : %d\n' "$TOTAL_RUN"
[[ -n "$SUMMARY_LINE" ]] && printf 'Runner summary: %s\n' "$SUMMARY_LINE"

if [[ "$TOTAL_SRC" -eq "$TOTAL_RUN" ]]; then
    printf '\nOK — every declared test block was discovered and executed.\n'
    exit 0
fi

# ---------------------------------------------------------------------------
# Mismatch — surface the gap.
# ---------------------------------------------------------------------------

GAP=$((TOTAL_SRC - TOTAL_RUN))
printf '\nFAIL — %d test block(s) declared in src/ are NOT discovered by the runner.\n' "$GAP"
printf 'This is usually Zig issue #10018 (lazy analysis silently skips test blocks\n'
printf 'in files that are imported but never fully analyzed). Add\n'
printf '    test { _ = @import("FILE.zig"); }\n'
printf 'to your test-root file (typically src/root.zig) for each missing file,\n'
printf 'or restructure the imports so referenced files are reached eagerly.\n'

exit 1
