#!/usr/bin/env bash
# tests_clone_job.sh — Section M: clone-job command tests (TDD baseline).
#
# Sourced by tests.sh after helper functions are defined.
# Do NOT execute this file directly.
#
# Goal: every test here is a PERL vs ZIG comparison against the same input,
# using the upstream `openqa-clone-job` Perl script as the behavioural oracle
# for our new `zoqa-clone-job` Zig binary.  In this initial phase the Zig
# binary is a stub (src/clone_job_main.zig), so the ZIG: rows are EXPECTED
# to FAIL.  Each failure is a TDD checkpoint — the FAIL message names the
# behaviour that needs to be implemented next.
#
# Reference for upstream behaviour: ideas/OPENQA_CLONE_JOB_ANALYSIS.md
#
# Rough order to make these tests pass:
#   M1–M2:  --help on stdout, exit 0                        (DONE)
#   M3–M6:  Mention key flags in --help                     (DONE)
#   M7:     --help writes to stdout, not stderr              (DONE)
#   M8–M9:  No-args → error on stderr, non-zero exit        (DONE)
#   M10–M11: JOBREF error cases (bare int without --from)    (DONE - resolveJobRef)
#   M12+:   Real API interactions (requires server fixture)

echo "==> [clone_job] Running clone-job command tests..."

# Local binary handles — different from the global PERL_EXE/ZIG_EXE which
# point at openqa-cli / zoqa.
PERL_CLONE_EXE="openqa-clone-job"
ZIG_CLONE_EXE="/app/zig-out/bin/zoqa-clone-job"

# 1. --help exits 0
run_test "PERL: clone-job --help exits 0" "$PERL_CLONE_EXE --help" 0
run_test "ZIG : clone-job --help exits 0" "$ZIG_CLONE_EXE --help" 0

# 2. --help prints Usage: header on stdout
run_test "PERL: clone-job --help has Usage: header" "$PERL_CLONE_EXE --help" 0 "Usage:"
run_test "ZIG : clone-job --help has Usage: header" "$ZIG_CLONE_EXE --help" 0 "Usage:"

# 3. --help advertises --within-instance
run_test "PERL: clone-job --help mentions --within-instance" "$PERL_CLONE_EXE --help" 0 "within-instance"
run_test "ZIG : clone-job --help mentions --within-instance" "$ZIG_CLONE_EXE --help" 0 "within-instance"

# 4. --help advertises --skip-download
run_test "PERL: clone-job --help mentions --skip-download" "$PERL_CLONE_EXE --help" 0 "skip-download"
run_test "ZIG : clone-job --help mentions --skip-download" "$ZIG_CLONE_EXE --help" 0 "skip-download"

# 5. --help advertises --from
# Pattern uses [-] to match a literal '-' as the first char without grep
# treating it as an option flag, and without the stray-escape warning that
# "\\-\\-from" produces.
run_test "PERL: clone-job --help mentions --from" "$PERL_CLONE_EXE --help" 0 "[-]-from"
run_test "ZIG : clone-job --help mentions --from" "$ZIG_CLONE_EXE --help" 0 "[-]-from"

# 6. --help advertises --host
run_test "PERL: clone-job --help mentions --host" "$PERL_CLONE_EXE --help" 0 "[-]-host"
run_test "ZIG : clone-job --help mentions --host" "$ZIG_CLONE_EXE --help" 0 "[-]-host"

# 7. --help writes to stdout, not stderr
run_test "PERL: clone-job --help writes to stdout, not stderr" \
	"bash -c \"$PERL_CLONE_EXE --help > /tmp/out 2> /tmp/err; test -s /tmp/out && ! test -s /tmp/err\"" 0
run_test "ZIG : clone-job --help writes to stdout, not stderr" \
	"bash -c \"$ZIG_CLONE_EXE --help > /tmp/out 2> /tmp/err; test -s /tmp/out && ! test -s /tmp/err\"" 0

# 8. No args exits non-zero
run_test "PERL: clone-job with no args exits non-zero" \
	"bash -c \"$PERL_CLONE_EXE; exit_code=\\\$?; test \\\$exit_code -ne 0\"" 0
run_test "ZIG : clone-job with no args exits non-zero" \
	"bash -c \"$ZIG_CLONE_EXE; exit_code=\\\$?; test \\\$exit_code -ne 0\"" 0

# 9. No args writes to stderr, not stdout
run_test "PERL: clone-job with no args writes to stderr, not stdout" \
	"bash -c \"$PERL_CLONE_EXE > /tmp/out 2> /tmp/err; test -s /tmp/err && ! test -s /tmp/out\"" 0
run_test "ZIG : clone-job with no args writes to stderr, not stdout" \
	"bash -c \"$ZIG_CLONE_EXE > /tmp/out 2> /tmp/err; test -s /tmp/err && ! test -s /tmp/out\"" 0

# 10. Bare integer JOBREF without --from exits non-zero
#     Both tools should fail because no source host is known.
run_test "PERL: bare integer without --from exits non-zero" \
	"bash -c \"$PERL_CLONE_EXE 42; exit_code=\\\$?; test \\\$exit_code -ne 0\"" 0
run_test "ZIG : bare integer without --from exits non-zero" \
	"bash -c \"$ZIG_CLONE_EXE 42; exit_code=\\\$?; test \\\$exit_code -ne 0\"" 0

# 11. Bare integer without --from — output stream routing.
# NOTE: Perl calls pod2usage(1) here (exitval 1 → stdout by default per Pod::Usage
# convention: exitval < 2 → STDOUT, exitval >= 2 → STDERR).  So Perl writes its
# usage text to stdout and nothing to stderr — same routing as --help (test 7).
# Zig writes the error message to stderr only, keeping stdout clean.
run_test "PERL: bare integer without --from writes to stdout (pod2usage quirk)" \
	"bash -c \"$PERL_CLONE_EXE 42 > /tmp/out 2> /tmp/err; test -s /tmp/out && ! test -s /tmp/err\"" 0
run_test "ZIG : bare integer without --from writes to stderr" \
	"bash -c \"$ZIG_CLONE_EXE 42 > /tmp/out 2> /tmp/err; test -s /tmp/err && ! test -s /tmp/out\"" 0

# =============================================================================
# Section M-Real: Real API Interaction Tests (M12–M17)
# =============================================================================
#
# These tests make real HTTP calls against the live openQA container seeded
# by run.sh.  All M12+ tests clone an existing completed job, verify the
# clone output, and check job settings via the API.
#
# Single-worker constraint: clone-job itself is fast (one API call); the
# CLONED job runs in the container queue.  We wait for each batch of cloned
# jobs to finish before scheduling more, so the worker is always free.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Ensure a completed base job exists (idempotent; sets and exports $JOB_ID).
ensure_basic_job

# M12: --within-instance exits 0 for a known job.
echo "--- Test M12: clone-job --within-instance exits 0 ---"
run_capture_both "clone12" \
	"$PERL_CLONE_EXE --within-instance http://localhost $JOB_ID" \
	"$ZIG_CLONE_EXE --within-instance http://localhost $JOB_ID"
assert_capture_exits "clone12" 0

# M13: stdout from M12 contains a creation message and a job URL.
echo "--- Test M13a: clone-job stdout has 'has been created' ---"
assert_stdout_pattern "clone12" "has been created"
echo "--- Test M13b: clone-job stdout has job URL ---"
assert_stdout_pattern "clone12" 'http://localhost/tests/[0-9]+'

# M14: The cloned job has CLONED_FROM = http://localhost/tests/$JOB_ID.
# Wait for both M12 clones to finish first (single worker, sequential queue).
echo "--- Test M14: cloned job CLONED_FROM setting is correct ---"

_m12_perl_new_id=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone12_perl_stdout.log" | head -1) || true
_m12_zig_new_id=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone12_zig_stdout.log" | head -1) || true

if [[ -n "$_m12_perl_new_id" ]]; then
	echo "  Perl cloned job ID: $_m12_perl_new_id — waiting..."
	wait_for_job "$_m12_perl_new_id" 300 >/dev/null ||
		echo "  WARNING: timeout waiting for Perl M12 clone"
fi
if [[ -n "$_m12_zig_new_id" ]]; then
	echo "  Zig cloned job ID: $_m12_zig_new_id — waiting..."
	wait_for_job "$_m12_zig_new_id" 300 >/dev/null ||
		echo "  WARNING: timeout waiting for Zig M12 clone"
fi

_m14_pass=true
_m14_expected="http://localhost/tests/$JOB_ID"
for _lbl_id in "perl:$_m12_perl_new_id" "zig:$_m12_zig_new_id"; do
	_impl="${_lbl_id%%:*}"
	_new_id="${_lbl_id##*:}"
	if [[ -z "$_new_id" ]]; then
		echo "  FAIL: could not determine $_impl cloned job ID from M12 stdout"
		_m14_pass=false
		continue
	fi
	_cloned_from=$(container_exec openqa-cli api --host http://localhost \
		"jobs/$_new_id" 2>/dev/null | jq -r '.job.settings.CLONED_FROM // empty')
	if [[ "$_cloned_from" != "$_m14_expected" ]]; then
		echo "  FAIL: $_impl CLONED_FROM='$_cloned_from' (expected '$_m14_expected')"
		_m14_pass=false
	fi
done
if [[ "$_m14_pass" == "true" ]]; then
	echo "PASS"
else
	failed_tests=$((failed_tests + 1))
fi

# M15: Setting override — BUILD=e2e-clone-override is applied to the cloned job.
# Perl clone runs first and its job waits before Zig starts (single worker).
echo "--- Test M15: clone-job with BUILD override exits 0 ---"
run_capture "clone15" perl \
	"$PERL_CLONE_EXE --within-instance http://localhost $JOB_ID BUILD=e2e-clone-override"
_PERL_EXIT=$_LAST_EXIT
_m15_perl_new_id=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone15_perl_stdout.log" | head -1) || true
if [[ -n "$_m15_perl_new_id" ]]; then
	wait_for_job "$_m15_perl_new_id" 300 >/dev/null ||
		echo "  WARNING: timeout waiting for Perl M15 clone"
fi

run_capture "clone15" zig \
	"$ZIG_CLONE_EXE --within-instance http://localhost $JOB_ID BUILD=e2e-clone-override"
_ZIG_EXIT=$_LAST_EXIT
_m15_zig_new_id=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone15_zig_stdout.log" | head -1) || true
if [[ -n "$_m15_zig_new_id" ]]; then
	wait_for_job "$_m15_zig_new_id" 300 >/dev/null ||
		echo "  WARNING: timeout waiting for Zig M15 clone"
fi

assert_capture_exits "clone15" 0

echo "--- Test M15b: BUILD override is reflected in cloned job settings ---"
_m15b_pass=true
for _lbl_id in "perl:$_m15_perl_new_id" "zig:$_m15_zig_new_id"; do
	_impl="${_lbl_id%%:*}"
	_new_id="${_lbl_id##*:}"
	if [[ -z "$_new_id" ]]; then
		echo "  FAIL: could not determine $_impl cloned job ID from M15 stdout"
		_m15b_pass=false
		continue
	fi
	_build=$(container_exec openqa-cli api --host http://localhost \
		"jobs/$_new_id" 2>/dev/null | jq -r '.job.settings.BUILD // empty')
	if [[ "$_build" != "e2e-clone-override" ]]; then
		echo "  FAIL: $_impl clone BUILD='$_build' (expected 'e2e-clone-override')"
		_m15b_pass=false
	fi
done
if [[ "$_m15b_pass" == "true" ]]; then
	echo "PASS"
else
	failed_tests=$((failed_tests + 1))
fi

# M16: Cloning a non-existent job exits non-zero.
echo "--- Test M16: clone-job non-existent job 999999 exits non-zero ---"
run_test "PERL: clone-job non-existent job exits non-zero" \
	"bash -c \"$PERL_CLONE_EXE --within-instance http://localhost 999999; exit_code=\\\$?; test \\\$exit_code -ne 0\"" 0
run_test "ZIG : clone-job non-existent job exits non-zero" \
	"bash -c \"$ZIG_CLONE_EXE --within-instance http://localhost 999999; exit_code=\\\$?; test \\\$exit_code -ne 0\"" 0

# M17: Explicit --from --host --skip-download flags (long-form equivalent of
# --within-instance).  Exercises flag parsing for the three-flag form.
echo "--- Test M17: clone-job --from --host --skip-download exits 0 ---"
run_capture_both "clone17" \
	"$PERL_CLONE_EXE --from http://localhost --host http://localhost --skip-download $JOB_ID" \
	"$ZIG_CLONE_EXE --from http://localhost --host http://localhost --skip-download $JOB_ID"
assert_capture_exits "clone17" 0

# Wait for M17 clones to avoid leaving running jobs that would block future suites.
_m17_perl_new_id=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone17_perl_stdout.log" | head -1) || true
if [[ -n "$_m17_perl_new_id" ]]; then
	wait_for_job "$_m17_perl_new_id" 300 >/dev/null ||
		echo "  WARNING: timeout waiting for Perl M17 clone"
fi
_m17_zig_new_id=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone17_zig_stdout.log" | head -1) || true
if [[ -n "$_m17_zig_new_id" ]]; then
	wait_for_job "$_m17_zig_new_id" 300 >/dev/null ||
		echo "  WARNING: timeout waiting for Zig M17 clone"
fi
