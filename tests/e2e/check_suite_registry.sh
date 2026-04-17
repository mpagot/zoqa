#!/usr/bin/env bash
# check_suite_registry.sh — Verify that every tests_*.sh file in tests/e2e/
# is properly registered in all required places.
#
# Checked locations:
#   1. tests/e2e/tests.sh    — _e2e_all_suites array
#   2. Makefile               — E2E_SCRIPTS list
#   3. tests/e2e/README.md    — File Layout code block
#
# Usage:
#   bash tests/e2e/check_suite_registry.sh          # from repo root
#   bash tests/e2e/check_suite_registry.sh --fix     # print what's missing (no auto-fix)
#
# Exit codes:
#   0 — all files are properly registered
#   1 — one or more files are missing from a registry

set -euo pipefail

# Resolve paths relative to the repo root.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
E2E_DIR="$REPO_ROOT/tests/e2e"

TESTS_SH="$E2E_DIR/tests.sh"
MAKEFILE="$REPO_ROOT/Makefile"
README="$E2E_DIR/README.md"

errors=0

# ---------------------------------------------------------------------------
# 1. Discover all tests_*.sh files on disk
# ---------------------------------------------------------------------------
declare -a on_disk=()
for f in "$E2E_DIR"/tests_*.sh; do
	[[ -f "$f" ]] || continue
	on_disk+=("$(basename "$f")")
done

if [[ ${#on_disk[@]} -eq 0 ]]; then
	echo "ERROR: No tests_*.sh files found in $E2E_DIR"
	exit 1
fi

echo "==> check_suite_registry: found ${#on_disk[@]} test suite files on disk"

# ---------------------------------------------------------------------------
# 2. Check tests/e2e/tests.sh — _e2e_all_suites array
#    Each tests_FOO.sh must have FOO in the _e2e_all_suites list.
# ---------------------------------------------------------------------------
echo "  Checking tests.sh (_e2e_all_suites)..."
for file in "${on_disk[@]}"; do
	# tests_core.sh → core
	suite_name="${file#tests_}"
	suite_name="${suite_name%.sh}"
	if ! grep -q "_e2e_all_suites=.*\b${suite_name}\b" "$TESTS_SH"; then
		echo "    MISSING: suite '$suite_name' not in _e2e_all_suites ($TESTS_SH)"
		errors=$((errors + 1))
	fi
done

# ---------------------------------------------------------------------------
# 3. Check Makefile — E2E_SCRIPTS list
#    Each tests_*.sh must appear as tests/e2e/tests_FOO.sh in E2E_SCRIPTS.
# ---------------------------------------------------------------------------
echo "  Checking Makefile (E2E_SCRIPTS)..."
for file in "${on_disk[@]}"; do
	entry="tests/e2e/$file"
	if ! grep -qF "$entry" "$MAKEFILE"; then
		echo "    MISSING: '$entry' not in E2E_SCRIPTS ($MAKEFILE)"
		errors=$((errors + 1))
	fi
done

# ---------------------------------------------------------------------------
# 4. Check tests/e2e/README.md — File Layout code block
#    Each tests_*.sh must appear somewhere in the README.
# ---------------------------------------------------------------------------
echo "  Checking README.md (File Layout)..."
for file in "${on_disk[@]}"; do
	if ! grep -qF "$file" "$README"; then
		echo "    MISSING: '$file' not mentioned in $README"
		errors=$((errors + 1))
	fi
done

# ---------------------------------------------------------------------------
# 5. Reverse check: entries in registries that don't exist on disk
# ---------------------------------------------------------------------------
echo "  Checking for stale entries..."

# _e2e_all_suites entries without a matching file
_suites_line=$(grep '_e2e_all_suites=' "$TESTS_SH" | head -1)
if [[ -n "$_suites_line" ]]; then
	# Extract words between ( and )
	_suites_content="${_suites_line#*\(}"
	_suites_content="${_suites_content%\)*}"
	for suite in $_suites_content; do
		expected_file="tests_${suite}.sh"
		if [[ ! -f "$E2E_DIR/$expected_file" ]]; then
			echo "    STALE: suite '$suite' in _e2e_all_suites but $expected_file does not exist"
			errors=$((errors + 1))
		fi
	done
fi

# E2E_SCRIPTS entries for tests_*.sh that don't exist on disk
while IFS= read -r line; do
	# Extract the filename from lines like "	tests/e2e/tests_foo.sh \"
	entry=$(echo "$line" | grep -oP 'tests/e2e/tests_\w+\.sh' || true)
	[[ -z "$entry" ]] && continue
	basename_entry=$(basename "$entry")
	if [[ ! -f "$E2E_DIR/$basename_entry" ]]; then
		echo "    STALE: '$entry' in E2E_SCRIPTS but file does not exist"
		errors=$((errors + 1))
	fi
done <"$MAKEFILE"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [[ "$errors" -gt 0 ]]; then
	echo "  FAIL: $errors registration error(s) found"
	exit 1
else
	echo "  OK: all ${#on_disk[@]} suite files are properly registered"
	exit 0
fi
