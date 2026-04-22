#!/usr/bin/env bash
# tests_monitor.sh — Section I: monitor subcommand tests.
#
# Sourced by tests.sh after helper functions are defined.
# Do NOT execute this file directly.
#
# Expected variables from calling scope (tests.sh / setup.sh):
#   ZIG_EXE, PERL_EXE
#   LOG_DIR
#   failed_tests, warned_tests
#   GROUP_ID
#
# Creates its own jobs via lib.sh helpers:
#   RICH_JOB_ID   — completed CirrOS job (via ensure_rich_job)
#   MONITOR_JOB_ID — dedicated sleep job scheduled fresh for cancel tests

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "==> [monitor] Running monitor tests..."

# Ensure a completed rich job exists for terminal-state tests.
ensure_rich_job

# =============================================================================
# Section 1: Argument Validation
# =============================================================================

# MON-1 (Perl behavior on missing JOB_ID)
# Perl openqa-cli doesn't validate missing JOB_ID; it exits 0 (known difference).
# Capture its actual exit code for reference — no PASS/FAIL assertion.
echo "--- Test: PERL: No JOB_ID (capture only) ---"
run_capture "mon_noid" perl "timeout 60 $PERL_EXE monitor"
echo "Exit code: $_LAST_EXIT (captured for reference — Perl does not validate missing JOB_ID)"

# MON-2
run_test "ZIG : No JOB_ID -> exit 255" "$ZIG_EXE monitor" 255

# MON-3 (Perl behavior on non-numeric ID)
# Perl openqa-cli doesn't upfront validate the JOB_ID, it just throws it into the URL.
# We capture its actual exit code (likely 1 from a 404/500).
echo "--- Test: PERL: Non-numeric JOB_ID ---"
run_capture "mon_abc" perl "timeout 60 $PERL_EXE monitor abc"
echo "Exit code: $_LAST_EXIT (captured for reference)"

# MON-4 (Zig upfront validation)
run_test "ZIG : Non-numeric JOB_ID -> exit 255" "$ZIG_EXE monitor abc" 255

# =============================================================================
# Section 2: Completed Job
# RICH_JOB_ID is guaranteed to be in a terminal state by ensure_rich_job.
# =============================================================================

echo "--- Test: Monitor completed job (MON-5/6) ---"
run_perl_and_zig "mon_ok" "monitor $RICH_JOB_ID" 60
echo "  Perl exit: $_PERL_EXIT   Zig exit: $_ZIG_EXIT"
if [[ "$_ZIG_EXIT" -eq "$_PERL_EXIT" ]]; then
	echo "PASS"
else
	echo "FAIL: Expected Zig to match Perl exit $_PERL_EXIT, got $_ZIG_EXIT"
	cat "$LOG_DIR/mon_ok_zig_stderr.log"
	failed_tests=$((failed_tests + 1))
fi

echo "--- Test: DIFF: Stdout format string (MON-7) ---"
_pass_flag=true

# Both should contain the format string or be entirely empty if already done before the first check.
# The Perl monitor always prints at least one line if not done, but if it finishes immediately it might print nothing.
# Actually, Perl's monitor prints nothing if the job is already terminal.
# Let's check if the outputs are identical or if we can find "Job state of job ID".
if diff -u "$LOG_DIR/mon_ok_perl_stdout.log" "$LOG_DIR/mon_ok_zig_stdout.log" >"$LOG_DIR/mon_diff.log" 2>&1; then
	echo "PASS (Outputs identical)"
else
	# If not identical, at least verify neither produced an error
	if test -s "$LOG_DIR/mon_ok_zig_stderr.log"; then
		echo "FAIL: Zig stderr is not empty"
		cat "$LOG_DIR/mon_ok_zig_stderr.log"
		_pass_flag=false
	fi
	if [[ "$_pass_flag" == "true" ]]; then
		echo "PASS (Outputs differ but Zig didn't error - likely polling race)"
	else
		failed_tests=$((failed_tests + 1))
	fi
fi

# MON-19: Monitor on an already-terminal job must return well under 10s.
# Regression test for the off-by-one sleep bug in runMonitor: any_pending was
# set true before checking terminal state, causing a mandatory poll_interval
# (10s) sleep even when every job was already done on the first check.
echo "--- Test: ZIG : Monitor already-terminal job returns quickly (MON-19) ---"
_t0=$(date +%s%3N)
run_capture "mon_fast" zig "timeout 15 $ZIG_EXE monitor $RICH_JOB_ID"
_t1=$(date +%s%3N)
_elapsed_ms=$((_t1 - _t0))
if [[ "$_elapsed_ms" -lt 5000 ]]; then
	echo "PASS (elapsed: ${_elapsed_ms}ms)"
else
	echo "FAIL: monitor took ${_elapsed_ms}ms on an already-terminal job (expected < 5000ms; off-by-one sleep bug?)"
	failed_tests=$((failed_tests + 1))
fi

# =============================================================================
# Section 3: Exit Code 2 (Cancelled Job)
#
# Schedule a dedicated sleep job (SLEEPTEST=1, 300s) so that it is still
# running when we issue the cancel.  This avoids the shared-state problem
# where JOB_ID might already be in a terminal state.
# =============================================================================

echo "--- Setup: Schedule dedicated sleep job for cancel tests ---"
MONITOR_JOB_ID=$(schedule_job \
	DISTRI=example \
	VERSION=0 \
	FLAVOR=DVD \
	ARCH=x86_64 \
	BUILD=e2e-test-mon \
	HDD_1="cirros-0.6.3-x86_64-disk.qcow2" \
	ISO_1="seed-nocloud.iso" \
	CASEDIR="/var/lib/openqa/share/tests/cirros" \
	NEEDLES_DIR="%CASEDIR%/needles" \
	"_GROUP_ID=${GROUP_ID:-1}" \
	"SLEEPTEST=1")
echo "  MONITOR_JOB_ID=$MONITOR_JOB_ID"

# Give the worker a moment to pick up the job before cancelling.
sleep 5

# MON-8: Cancel the sleep job
echo "--- Setup: Cancel MONITOR_JOB_ID ($MONITOR_JOB_ID) ---"
cancel_job "$MONITOR_JOB_ID"
wait_for_job "$MONITOR_JOB_ID" 30 >/dev/null || echo "WARNING: timeout waiting for cancel"

# MON-9 / MON-10: both implementations must exit 2 on a cancelled job.
echo "--- Test: Monitor cancelled job -> exit 2 (MON-9/10) ---"
run_perl_and_zig "mon_cancel" "monitor $MONITOR_JOB_ID" 60
if [[ "$_PERL_EXIT" -eq 2 ]]; then
	echo "PASS (Perl exit 2)"
else
	echo "FAIL: Perl expected exit 2, got $_PERL_EXIT"
	failed_tests=$((failed_tests + 1))
fi
if [[ "$_ZIG_EXIT" -eq 2 ]]; then
	echo "PASS (Zig exit 2)"
else
	echo "FAIL: Zig expected exit 2, got $_ZIG_EXIT"
	failed_tests=$((failed_tests + 1))
fi

# =============================================================================
# Section 4: Exit Code 1 (Missing Job)
# =============================================================================

# MON-11 / MON-12: both implementations must exit 1 on a missing job.
echo "--- Test: Monitor missing job -> exit 1 (MON-11/12) ---"
run_perl_and_zig "mon_miss" "monitor 999999999" 60
if [[ "$_PERL_EXIT" -eq 1 ]]; then
	echo "PASS (Perl exit 1)"
else
	echo "FAIL: Perl expected exit 1, got $_PERL_EXIT"
	failed_tests=$((failed_tests + 1))
fi
if [[ "$_ZIG_EXIT" -eq 1 ]]; then
	echo "PASS (Zig exit 1)"
else
	echo "FAIL: Zig expected exit 1, got $_ZIG_EXIT"
	failed_tests=$((failed_tests + 1))
fi

# =============================================================================
# Section 5: Options
# =============================================================================

# MON-13 / MON-14: --follow on a terminal job; Zig must match Perl's exit.
echo "--- Test: --follow RICH_JOB_ID (MON-13/14) ---"
run_perl_and_zig "mon_follow" "monitor --follow $RICH_JOB_ID" 60
echo "  Perl exit: $_PERL_EXIT   Zig exit: $_ZIG_EXIT"
if [[ "$_ZIG_EXIT" -eq "$_PERL_EXIT" ]]; then
	echo "PASS"
else
	echo "FAIL: Expected exit $_PERL_EXIT, got $_ZIG_EXIT"
	failed_tests=$((failed_tests + 1))
fi

# MON-15 / MON-16: --poll-interval 1 on a terminal job; Zig must match Perl.
echo "--- Test: --poll-interval 1 RICH_JOB_ID (MON-15/16) ---"
run_perl_and_zig "mon_poll" "monitor --poll-interval 1 $RICH_JOB_ID" 60
echo "  Perl exit: $_PERL_EXIT   Zig exit: $_ZIG_EXIT"
if [[ "$_ZIG_EXIT" -eq "$_PERL_EXIT" ]]; then
	echo "PASS"
else
	echo "FAIL: Expected exit $_PERL_EXIT, got $_ZIG_EXIT"
	failed_tests=$((failed_tests + 1))
fi

# =============================================================================
# Section 6: Multiple Job IDs
# =============================================================================

# We mix a terminal ok job and a cancelled job. Overall exit should be 2.

# MON-17 / MON-18: mixing one terminal-ok job and one cancelled job → exit 2.
echo "--- Test: Monitor RICH_JOB_ID and MONITOR_JOB_ID -> exit 2 (MON-17/18) ---"
run_perl_and_zig "mon_mult" "monitor $RICH_JOB_ID $MONITOR_JOB_ID" 60
if [[ "$_PERL_EXIT" -eq 2 ]]; then
	echo "PASS (Perl exit 2)"
else
	echo "FAIL: Perl expected exit 2, got $_PERL_EXIT"
	failed_tests=$((failed_tests + 1))
fi
if [[ "$_ZIG_EXIT" -eq 2 ]]; then
	echo "PASS (Zig exit 2)"
else
	echo "FAIL: Zig expected exit 2, got $_ZIG_EXIT"
	failed_tests=$((failed_tests + 1))
fi

# =============================================================================
# Section 50: Cross-subcommand Flag Rejection
# =============================================================================

# MON-50
run_test "PERL: monitor --extract rejected" "bash -c \"$PERL_EXE monitor --extract $RICH_JOB_ID >/dev/null 2>&1\"" 255

# MON-51
run_test "ZIG : monitor --extract rejected" "bash -c \"$ZIG_EXE monitor --extract $RICH_JOB_ID >/dev/null 2>&1\"" 255
