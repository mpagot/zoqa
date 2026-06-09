#!/usr/bin/env bash
# tests_data.sh — Section C: Seeded data tests.
#
# Tests against real objects created by ensure_basic_job(): jobs, assets,
# job groups, machines.  Also covers pagination, output parity between Perl
# and Zig, and relative vs absolute URL path handling.
#
# Sourced by tests.sh after helper functions are defined.
# Do NOT execute this file directly.
#
# Assumes from the calling scope:
#   ZIG_EXE, PERL_EXE, LOG_DIR, failed_tests, warned_tests, GROUP_ID
#   run_test(), run_comparison_api(), run_diff_test()

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "==> [data] Running seeded data tests..."

# Ensure a basic job exists (reuses JOB_ID from tests_core.sh if already set).
ensure_basic_job

# Register two deletable assets (one for Perl DELETE test, one for Zig).
echo "  [data] Registering deletable assets..."
ASSET_ID=$(register_deletable_asset "delete-me-perl.tar.gz")
ZIG_ASSET_ID=$(register_deletable_asset "delete-me-zig.tar.gz")

# Test DAT-18: GET jobs/overview returns non-empty list after seeding.
run_comparison_api "GET jobs/overview (non-empty after seeding)" "" "jobs/overview" 0 "simple_boot"

# Test DAT-19: GET jobs/:id returns a real nested job object.
run_comparison_api "GET jobs/$JOB_ID (nested object)" "" \
	"jobs/$JOB_ID" 0 '"settings"'

# Test DAT-20: GET machines?limit=2 with --links triggers the Link pagination header.
# We seeded 3 machines; requesting limit=2 should yield a Link: rel="next" header.
# Both implementations parse the Link header and emit "next: <url>" to stderr.
#
# Intentional behavioral difference: Perl wraps link lines in ANSI colour codes
# (e.g. "\e[32mnext: <url>\e[0m"); Zig emits plain text.  The helper always
# strips ANSI escape sequences — this is a no-op for Zig output — so both code
# paths are identical and the grep pattern is consistent.
#
# Stream separation is also asserted here: next: must appear on stderr, not
# stdout.  This subsumes the check that was previously in Test 43b
# (tests_output.sh), and fixes that test's missing ANSI strip on the Zig block.
_run_pagination_test() {
	local label=$1   # "PERL" or "ZIG " — used verbatim in test output lines
	local exe=$2     # binary to invoke
	local log_tag=$3 # "perl" or "zig" — prefix for log filenames

	echo "--- Test: ${label}: --links and follow pagination ---"
	container_exec bash -c "$exe api --host http://localhost --links 'machines?limit=2'" \
		>"$LOG_DIR/test_pagination_${log_tag}_stdout.log" \
		2>"$LOG_DIR/test_pagination_${log_tag}_stderr.log"
	sed 's/\x1b\[[0-9;]*m//g' "$LOG_DIR/test_pagination_${log_tag}_stderr.log" \
		>"$LOG_DIR/test_pagination_${log_tag}_clean.log"

	# Assert stream separation: next: must appear on stderr, not stdout.
	if grep -q "^next: " "$LOG_DIR/test_pagination_${log_tag}_clean.log" &&
		! grep -q "next:" "$LOG_DIR/test_pagination_${log_tag}_stdout.log"; then
		echo "PASS (next: on stderr, not on stdout)"
	else
		echo "FAIL: --links stream routing incorrect for ${label}"
		cat "$LOG_DIR/test_pagination_${log_tag}_stderr.log"
		failed_tests=$((failed_tests + 1))
	fi

	if grep -q "^next: " "$LOG_DIR/test_pagination_${log_tag}_clean.log"; then
		local next_url
		next_url=$(grep "^next: " "$LOG_DIR/test_pagination_${log_tag}_clean.log" |
			cut -d' ' -f2 | tr -d '\r')
		echo "Found next URL: $next_url"
		run_test "${label}: Follow pagination link" \
			"$exe api --host http://localhost '$next_url'" 0 '"name":"uefi"'
	else
		echo "SKIP: Cannot follow pagination link (stream routing failed)"
	fi
}

_run_pagination_test "PERL" "$PERL_EXE" "perl"
_run_pagination_test "ZIG " "$ZIG_EXE" "zig"

# Test 21: DELETE a real asset (successful authenticated DELETE).
# Perl and Zig each get their own asset to avoid ordering conflicts.
if [[ "$ASSET_ID" == "SKIP" || -z "$ASSET_ID" ]]; then
	echo "--- Test: PERL: DELETE asset (skipped — no ASSET_ID available) ---"
	warned_tests=$((warned_tests + 1))
else
	run_test "PERL: DELETE asset/$ASSET_ID (200)" \
		"$PERL_EXE api --host http://localhost -X DELETE assets/$ASSET_ID" 0
fi

if [[ "$ZIG_ASSET_ID" == "SKIP" || -z "$ZIG_ASSET_ID" ]]; then
	echo "--- Test: ZIG : DELETE asset (skipped — no ZIG_ASSET_ID available) ---"
	warned_tests=$((warned_tests + 1))
else
	run_test "ZIG : DELETE asset/$ZIG_ASSET_ID (200)" \
		"$ZIG_EXE api --host http://localhost -X DELETE assets/$ZIG_ASSET_ID" 0
fi

# Test DAT-22: GET job_groups returns the seeded group.
run_comparison_api "GET job_groups (seeded group present)" "" "job_groups" 0 '"example"'

# Test 23: Perl vs Zig output parity on a real nested object (hard FAIL on mismatch).
run_diff_test "GET jobs/$JOB_ID output parity" "jobs/$JOB_ID"

# Test 24: Relative and absolute path produce identical output.
# Verifies that `zoqa api jobs/$JOB_ID` and
# `zoqa api http://localhost/api/v1/jobs/$JOB_ID` return the same body.
#
# stderr is redirected to /dev/null for both invocations to suppress the
# per-call BoltDB deprecation warning that podman emits on affected systems
# (see the "Podman sanity check" comment in run.sh).  The warning timestamp
# differs between the two calls, which would cause a spurious diff failure
# if stderr were captured.
echo "--- Test: ZIG : relative vs absolute path parity ---"
container_exec bash -c "$ZIG_EXE api --host http://localhost jobs/$JOB_ID" \
	>"$LOG_DIR/test_relative.log" 2>/dev/null
container_exec bash -c "$ZIG_EXE api 'http://localhost/api/v1/jobs/$JOB_ID'" \
	>"$LOG_DIR/test_absolute.log" 2>/dev/null
if diff -u "$LOG_DIR/test_relative.log" "$LOG_DIR/test_absolute.log" \
	>"$LOG_DIR/test_path_parity_diff.log" 2>&1; then
	echo "PASS (relative and absolute outputs identical)"
else
	echo "FAIL: relative and absolute path outputs differ"
	cat "$LOG_DIR/test_path_parity_diff.log"
	failed_tests=$((failed_tests + 1))
fi
