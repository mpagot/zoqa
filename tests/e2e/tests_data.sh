#!/usr/bin/env bash
# tests_data.sh — Section C: Seeded data tests.
#
# Tests against real objects created by seed_fixtures.sh: jobs, assets,
# job groups, machines.  Also covers pagination, output parity between Perl
# and Zig, and relative vs absolute URL path handling.
#
# Sourced by tests.sh after helper functions are defined.
# Do NOT execute this file directly.
#
# Assumes from the calling scope:
#   ZIG_EXE, PERL_EXE, LOG_DIR, failed_tests, warned_tests
#   JOB_ID, ASSET_ID, ZIG_ASSET_ID, GROUP_ID
#   run_test(), run_comparison(), run_diff_test()

echo "==> [data] Running seeded data tests..."

# Test 18: GET jobs/overview returns non-empty list after seeding.
run_comparison "GET jobs/overview (non-empty after seeding)" "" "jobs/overview" 0 "simple_boot"

# Test 19: GET jobs/:id returns a real nested job object.
run_comparison "GET jobs/$JOB_ID (nested object)" "" \
	"jobs/$JOB_ID" 0 '"settings"'

# Test 20: GET machines?limit=2 with --links triggers the Link pagination header.
# We seeded 3 machines; requesting limit=2 should yield a Link: rel="next" header.
# parseLinkHeader formats output as "next: <url>" per link.
echo "--- Test: ZIG : --links and follow pagination ---"
container_exec bash -c "$ZIG_EXE api --host http://localhost --links 'machines?limit=2'" \
	>"$LOG_DIR/test_pagination.log" 2>&1
if grep -q "next:" "$LOG_DIR/test_pagination.log"; then
	NEXT_URL=$(grep "^next: " "$LOG_DIR/test_pagination.log" | cut -d' ' -f2 | tr -d '\r')
	echo "Found next URL: $NEXT_URL"
	# Call again with the next URL to verify it returns the remaining data
	run_test "ZIG : Follow pagination link" "$ZIG_EXE api --host http://localhost '$NEXT_URL'" 0 '"name":"uefi"'
else
	echo "FAIL: next link not found in output"
	cat "$LOG_DIR/test_pagination.log"
	failed_tests=$((failed_tests + 1))
fi

# Test 21: DELETE a real asset (successful authenticated DELETE).
# Perl and Zig each get their own asset to avoid ordering conflicts.
if [[ "$ASSET_ID" == "SKIP" || -z "$ASSET_ID" ]]; then
	echo "--- Test: PERL: DELETE asset (skipped — no ASSET_ID from seeding) ---"
	warned_tests=$((warned_tests + 1))
else
	run_test "PERL: DELETE asset/$ASSET_ID (200)" \
		"$PERL_EXE api --host http://localhost -X DELETE assets/$ASSET_ID" 0
fi

if [[ "$ZIG_ASSET_ID" == "SKIP" || -z "$ZIG_ASSET_ID" ]]; then
	echo "--- Test: ZIG : DELETE asset (skipped — no ZIG_ASSET_ID from seeding) ---"
	warned_tests=$((warned_tests + 1))
else
	run_test "ZIG : DELETE asset/$ZIG_ASSET_ID (200)" \
		"$ZIG_EXE api --host http://localhost -X DELETE assets/$ZIG_ASSET_ID" 0
fi

# Test 22: GET job_groups returns the seeded group.
run_comparison "GET job_groups (seeded group present)" "" "job_groups" 0 '"example"'

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
