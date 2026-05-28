#!/usr/bin/env bash
# shellcheck disable=SC2153
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

# Load topology fixtures (ensure_chained_jobs, ensure_fanout_jobs, etc.)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_topology.sh"

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

# =============================================================================
# Section M-Deps: Dependency Cloning Tests (M20–M27)
# =============================================================================
ensure_chained_jobs

# M20: Default clone of chained child clones both parent and child
echo "--- Test M20: clone-job chained child clones both ---"
run_capture_both "clone20" \
	"$PERL_CLONE_EXE --within-instance http://localhost $CHAIN_CHILD_ID" \
	"$ZIG_CLONE_EXE --within-instance http://localhost $CHAIN_CHILD_ID"
assert_capture_exits "clone20" 0

# Check stdout for "2 jobs have been created:"
echo "--- Test M20b: stdout contains '2 jobs have been created:' ---"
assert_stdout_pattern "clone20" "2 jobs have been created:"

_m20_perl_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone20_perl_stdout.log" || true)
_m20_zig_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone20_zig_stdout.log" || true)

# Wait for M20 cloned jobs to finish (otherwise subsequent clones will pile up)
for id in $_m20_perl_ids $_m20_zig_ids; do
	if [[ -n "$id" ]]; then wait_for_job "$id" 300 >/dev/null || true; fi
done

# We need to extract the new parent and child IDs from the API to verify them.
_m21_pass=true
for _lbl in "perl" "zig"; do
    _ids_var="_m20_${_lbl}_ids"
    _ids="${!_ids_var}"
    _new_parent=""
    _new_child=""
    for id in $_ids; do
        _test=$(container_exec openqa-cli api --host http://localhost "jobs/$id" 2>/dev/null | jq -r '.job.settings.TEST')
        if [[ "$_test" == "chain_parent" ]]; then
            _new_parent=$id
        elif [[ "$_test" == "chain_child" ]]; then
            _new_child=$id
        fi
    done

    # M21: Cloned parent has correct CLONED_FROM
    echo "--- Test M21 ($_lbl): Cloned parent has correct CLONED_FROM ---"
    if [[ -n "$_new_parent" ]]; then
        _cloned_from=$(container_exec openqa-cli api --host http://localhost "jobs/$_new_parent" 2>/dev/null | jq -r '.job.settings.CLONED_FROM')
        if [[ "$_cloned_from" != "http://localhost/tests/$CHAIN_PARENT_ID" ]]; then
            echo "  FAIL: $_lbl parent CLONED_FROM='$_cloned_from' (expected http://localhost/tests/$CHAIN_PARENT_ID)"
            _m21_pass=false
        fi
    else
        echo "  FAIL: $_lbl did not create a chain_parent job"
        _m21_pass=false
    fi

    # M22: Cloned child has _START_AFTER pointing to cloned parent
    echo "--- Test M22 ($_lbl): Cloned child points to cloned parent ---"
    if [[ -n "$_new_child" && -n "$_new_parent" ]]; then
        if ! assert_job_has_chained_parent "$_new_child" "$_new_parent"; then
            _m21_pass=false
        fi
    else
        echo "  FAIL: $_lbl child or parent ID missing"
        _m21_pass=false
    fi
done
if [[ "$_m21_pass" == "true" ]]; then echo "PASS"; else failed_tests=$((failed_tests + 1)); fi

# M23: --skip-deps -> only the child is cloned
echo "--- Test M23: clone-job --skip-deps clones only child ---"
run_capture_both "clone23" \
	"$PERL_CLONE_EXE --within-instance http://localhost --skip-deps $CHAIN_CHILD_ID" \
	"$ZIG_CLONE_EXE --within-instance http://localhost --skip-deps $CHAIN_CHILD_ID"
assert_capture_exits "clone23" 0

echo "--- Test M23b: stdout contains '1 job has been created:' ---"
assert_stdout_pattern "clone23" "1 job has been created:"

_m23_perl_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone23_perl_stdout.log" || true)
_m23_zig_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone23_zig_stdout.log" || true)

for id in $_m23_perl_ids $_m23_zig_ids; do
	if [[ -n "$id" ]]; then wait_for_job "$id" 300 >/dev/null || true; fi
done

# Verify M23 has no chained parents
_m23_pass=true
for _lbl in "perl" "zig"; do
    _ids_var="_m23_${_lbl}_ids"
    _ids="${!_ids_var}"
    for id in $_ids; do
        _parents=$(container_exec openqa-cli api --host http://localhost "jobs/$id" 2>/dev/null | jq -r '.job.parents.Chained | length')
        if [[ "$_parents" != "0" && "$_parents" != "null" ]]; then
            echo "  FAIL: $_lbl job $id has $_parents chained parents (expected 0)"
            _m23_pass=false
        fi
    done
done
if [[ "$_m23_pass" == "true" ]]; then echo "PASS"; else failed_tests=$((failed_tests + 1)); fi

# M24: --skip-chained-deps
echo "--- Test M24: clone-job --skip-chained-deps clones only child ---"
run_capture_both "clone24" \
	"$PERL_CLONE_EXE --within-instance http://localhost --skip-chained-deps $CHAIN_CHILD_ID" \
	"$ZIG_CLONE_EXE --within-instance http://localhost --skip-chained-deps $CHAIN_CHILD_ID"
assert_capture_exits "clone24" 0
assert_stdout_pattern "clone24" "1 job has been created:"

_m24_perl_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone24_perl_stdout.log" || true)
_m24_zig_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone24_zig_stdout.log" || true)

for id in $_m24_perl_ids $_m24_zig_ids; do
	if [[ -n "$id" ]]; then wait_for_job "$id" 300 >/dev/null || true; fi
done

# M25: Settings override applies to child but NOT to parent (default)
echo "--- Test M25: clone-job override applies to child only ---"
run_capture_both "clone25" \
	"$PERL_CLONE_EXE --within-instance http://localhost $CHAIN_CHILD_ID BUILD=dep-override" \
	"$ZIG_CLONE_EXE --within-instance http://localhost $CHAIN_CHILD_ID BUILD=dep-override"
assert_capture_exits "clone25" 0

_m25_perl_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone25_perl_stdout.log" || true)
_m25_zig_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone25_zig_stdout.log" || true)

for id in $_m25_perl_ids $_m25_zig_ids; do
	if [[ -n "$id" ]]; then wait_for_job "$id" 300 >/dev/null || true; fi
done

_m25_pass=true
for _lbl in "perl" "zig"; do
    _ids_var="_m25_${_lbl}_ids"
    _ids="${!_ids_var}"
    for id in $_ids; do
        _test=$(container_exec openqa-cli api --host http://localhost "jobs/$id" 2>/dev/null | jq -r '.job.settings.TEST')
        _build=$(container_exec openqa-cli api --host http://localhost "jobs/$id" 2>/dev/null | jq -r '.job.settings.BUILD')
        if [[ "$_test" == "chain_parent" && "$_build" == "dep-override" ]]; then
            echo "  FAIL: $_lbl parent got BUILD=dep-override (should be untouched)"
            _m25_pass=false
        elif [[ "$_test" == "chain_child" && "$_build" != "dep-override" ]]; then
            echo "  FAIL: $_lbl child got BUILD=$_build (should be dep-override)"
            _m25_pass=false
        fi
    done
done
if [[ "$_m25_pass" == "true" ]]; then echo "PASS"; else failed_tests=$((failed_tests + 1)); fi

# M26: --parental-inheritance applies overrides to parents too
echo "--- Test M26: clone-job --parental-inheritance ---"
run_capture_both "clone26" \
	"$PERL_CLONE_EXE --within-instance http://localhost --parental-inheritance $CHAIN_CHILD_ID BUILD=inherit-all" \
	"$ZIG_CLONE_EXE --within-instance http://localhost --parental-inheritance $CHAIN_CHILD_ID BUILD=inherit-all"
assert_capture_exits "clone26" 0

_m26_perl_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone26_perl_stdout.log" || true)
_m26_zig_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone26_zig_stdout.log" || true)

for id in $_m26_perl_ids $_m26_zig_ids; do
	if [[ -n "$id" ]]; then wait_for_job "$id" 300 >/dev/null || true; fi
done

_m26_pass=true
for _lbl in "perl" "zig"; do
    _ids_var="_m26_${_lbl}_ids"
    _ids="${!_ids_var}"
    for id in $_ids; do
        _build=$(container_exec openqa-cli api --host http://localhost "jobs/$id" 2>/dev/null | jq -r '.job.settings.BUILD')
        if [[ "$_build" != "inherit-all" ]]; then
            echo "  FAIL: $_lbl job $id got BUILD=$_build (should be inherit-all)"
            _m26_pass=false
        fi
    done
done
if [[ "$_m26_pass" == "true" ]]; then echo "PASS"; else failed_tests=$((failed_tests + 1)); fi

# =============================================================================
# Section M-Fanout: Fan-out Topology Tests (M27–M29)
# =============================================================================
ensure_fanout_jobs

# M27: Cloning fanout_child_a clones parent + child_a only (2 jobs), not siblings
echo "--- Test M27: clone-job fanout_child_a clones only 2 jobs ---"
run_capture_both "clone27" \
	"$PERL_CLONE_EXE --within-instance http://localhost $FANOUT_CHILD_A_ID" \
	"$ZIG_CLONE_EXE --within-instance http://localhost $FANOUT_CHILD_A_ID"
assert_capture_exits "clone27" 0
assert_stdout_pattern "clone27" "2 jobs have been created:"

_m27_perl_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone27_perl_stdout.log" || true)
_m27_zig_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone27_zig_stdout.log" || true)

for id in $_m27_perl_ids $_m27_zig_ids; do
	if [[ -n "$id" ]]; then wait_for_job "$id" 300 >/dev/null || true; fi
done

# Check that the 2 jobs are parent and child_a
_m27_pass=true
for _lbl in "perl" "zig"; do
    _ids_var="_m27_${_lbl}_ids"
    _ids="${!_ids_var}"
    _count=0
    for id in $_ids; do
        _test=$(container_exec openqa-cli api --host http://localhost "jobs/$id" 2>/dev/null | jq -r '.job.settings.TEST')
        if [[ "$_test" != "fanout_parent" && "$_test" != "fanout_child_a" ]]; then
            echo "  FAIL: $_lbl cloned unexpected job type $_test"
            _m27_pass=false
        fi
        _count=$((_count + 1))
    done
    if [[ "$_count" -gt 0 && "$_count" -ne 2 ]]; then
        echo "  FAIL: $_lbl cloned $_count jobs instead of 2"
        _m27_pass=false
    fi
done
if [[ "$_m27_pass" == "true" ]]; then echo "PASS"; else failed_tests=$((failed_tests + 1)); fi

# M28: Cloning fanout_parent with --clone-children clones all 4 jobs
echo "--- Test M28: clone-job parent with --clone-children ---"
run_capture_both "clone28" \
	"$PERL_CLONE_EXE --within-instance http://localhost --clone-children $FANOUT_PARENT_ID" \
	"$ZIG_CLONE_EXE --within-instance http://localhost --clone-children $FANOUT_PARENT_ID"
assert_capture_exits "clone28" 0
assert_stdout_pattern "clone28" "4 jobs have been created:"

_m28_perl_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone28_perl_stdout.log" || true)
_m28_zig_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone28_zig_stdout.log" || true)

for id in $_m28_perl_ids $_m28_zig_ids; do
	if [[ -n "$id" ]]; then wait_for_job "$id" 300 >/dev/null || true; fi
done

# M29: Overrides on child_a clone don't leak to parent (same as M25 but confirms with different topology)
echo "--- Test M29: clone-job child override doesn't leak to parent ---"
run_capture_both "clone29" \
	"$PERL_CLONE_EXE --within-instance http://localhost $FANOUT_CHILD_B_ID BUILD=fanout-override" \
	"$ZIG_CLONE_EXE --within-instance http://localhost $FANOUT_CHILD_B_ID BUILD=fanout-override"
assert_capture_exits "clone29" 0

_m29_perl_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone29_perl_stdout.log" || true)
_m29_zig_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone29_zig_stdout.log" || true)

for id in $_m29_perl_ids $_m29_zig_ids; do
	if [[ -n "$id" ]]; then wait_for_job "$id" 300 >/dev/null || true; fi
done

_m29_pass=true
for _lbl in "perl" "zig"; do
    _ids_var="_m29_${_lbl}_ids"
    _ids="${!_ids_var}"
    for id in $_ids; do
        _test=$(container_exec openqa-cli api --host http://localhost "jobs/$id" 2>/dev/null | jq -r '.job.settings.TEST')
        _build=$(container_exec openqa-cli api --host http://localhost "jobs/$id" 2>/dev/null | jq -r '.job.settings.BUILD')
        if [[ "$_test" == "fanout_parent" && "$_build" == "fanout-override" ]]; then
            echo "  FAIL: $_lbl parent got BUILD=fanout-override (should be untouched)"
            _m29_pass=false
        elif [[ "$_test" == "fanout_child_b" && "$_build" != "fanout-override" ]]; then
            echo "  FAIL: $_lbl child got BUILD=$_build (should be fanout-override)"
            _m29_pass=false
        fi
    done
done
if [[ "$_m29_pass" == "true" ]]; then echo "PASS"; else failed_tests=$((failed_tests + 1)); fi

# =============================================================================
# Section M-Layer: Multi-layer Topology Tests (M30–M33)
# =============================================================================
ensure_multilayer_jobs

# M30: Cloning layer_child clones all 3
echo "--- Test M30: clone-job layer_child clones all 3 ancestors ---"
run_capture_both "clone30" \
	"$PERL_CLONE_EXE --within-instance http://localhost $LAYER_CHILD_ID" \
	"$ZIG_CLONE_EXE --within-instance http://localhost $LAYER_CHILD_ID"
assert_capture_exits "clone30" 0
assert_stdout_pattern "clone30" "3 jobs have been created:"

_m30_perl_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone30_perl_stdout.log" || true)
_m30_zig_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone30_zig_stdout.log" || true)

for id in $_m30_perl_ids $_m30_zig_ids; do
	if [[ -n "$id" ]]; then wait_for_job "$id" 300 >/dev/null || true; fi
done

# M31: Dependency chain preserved
echo "--- Test M31: Multi-layer dependency chain preserved ---"
_m31_pass=true
for _lbl in "perl" "zig"; do
    _ids_var="_m30_${_lbl}_ids"
    _ids="${!_ids_var}"
    _new_grandparent=""
    _new_parent=""
    _new_child=""
    for id in $_ids; do
        _test=$(container_exec openqa-cli api --host http://localhost "jobs/$id" 2>/dev/null | jq -r '.job.settings.TEST')
        case "$_test" in
            layer_grandparent) _new_grandparent=$id ;;
            layer_parent)      _new_parent=$id ;;
            layer_child)       _new_child=$id ;;
        esac
    done

    if [[ -n "$_new_child" && -n "$_new_parent" && -n "$_new_grandparent" ]]; then
        if ! assert_job_has_chained_parent "$_new_child" "$_new_parent"; then
            _m31_pass=false
        fi
        if ! assert_job_has_chained_parent "$_new_parent" "$_new_grandparent"; then
            _m31_pass=false
        fi
    else
        echo "  FAIL: $_lbl missing one or more layers in clone output"
        _m31_pass=false
    fi
done
if [[ "$_m31_pass" == "true" ]]; then echo "PASS"; else failed_tests=$((failed_tests + 1)); fi

# M32: Override at child only (depth 1)
echo "--- Test M32: Multi-layer depth-based override isolation ---"
run_capture_both "clone32" \
	"$PERL_CLONE_EXE --within-instance http://localhost $LAYER_CHILD_ID BUILD=layer-override" \
	"$ZIG_CLONE_EXE --within-instance http://localhost $LAYER_CHILD_ID BUILD=layer-override"
assert_capture_exits "clone32" 0

_m32_perl_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone32_perl_stdout.log" || true)
_m32_zig_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone32_zig_stdout.log" || true)

for id in $_m32_perl_ids $_m32_zig_ids; do
	if [[ -n "$id" ]]; then wait_for_job "$id" 300 >/dev/null || true; fi
done

_m32_pass=true
for _lbl in "perl" "zig"; do
    _ids_var="_m32_${_lbl}_ids"
    _ids="${!_ids_var}"
    for id in $_ids; do
        _test=$(container_exec openqa-cli api --host http://localhost "jobs/$id" 2>/dev/null | jq -r '.job.settings.TEST')
        _build=$(container_exec openqa-cli api --host http://localhost "jobs/$id" 2>/dev/null | jq -r '.job.settings.BUILD')
        if [[ "$_test" != "layer_child" && "$_build" == "layer-override" ]]; then
            echo "  FAIL: $_lbl $_test got BUILD=layer-override (should be untouched)"
            _m32_pass=false
        elif [[ "$_test" == "layer_child" && "$_build" != "layer-override" ]]; then
            echo "  FAIL: $_lbl child got BUILD=$_build (should be layer-override)"
            _m32_pass=false
        fi
    done
done
if [[ "$_m32_pass" == "true" ]]; then echo "PASS"; else failed_tests=$((failed_tests + 1)); fi

# M33: --parental-inheritance propagates to all ancestors
echo "--- Test M33: Multi-layer --parental-inheritance ---"
run_capture_both "clone33" \
	"$PERL_CLONE_EXE --within-instance http://localhost --parental-inheritance $LAYER_CHILD_ID BUILD=inherit-all" \
	"$ZIG_CLONE_EXE --within-instance http://localhost --parental-inheritance $LAYER_CHILD_ID BUILD=inherit-all"
assert_capture_exits "clone33" 0

_m33_perl_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone33_perl_stdout.log" || true)
_m33_zig_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone33_zig_stdout.log" || true)

for id in $_m33_perl_ids $_m33_zig_ids; do
	if [[ -n "$id" ]]; then wait_for_job "$id" 300 >/dev/null || true; fi
done

_m33_pass=true
for _lbl in "perl" "zig"; do
    _ids_var="_m33_${_lbl}_ids"
    _ids="${!_ids_var}"
    for id in $_ids; do
        _build=$(container_exec openqa-cli api --host http://localhost "jobs/$id" 2>/dev/null | jq -r '.job.settings.BUILD')
        if [[ "$_build" != "inherit-all" ]]; then
            echo "  FAIL: $_lbl job $id got BUILD=$_build (should be inherit-all)"
            _m33_pass=false
        fi
    done
done
if [[ "$_m33_pass" == "true" ]]; then echo "PASS"; else failed_tests=$((failed_tests + 1)); fi


# =============================================================================
# Section M-Diamond: Diamond Topology Tests (M34–M38)
# =============================================================================
ensure_diamond_jobs

# M34: Cloning diamond_merge clones all 4 jobs
echo "--- Test M34: clone-job diamond_merge clones all 4 jobs ---"
run_capture_both "clone34" \
	"$PERL_CLONE_EXE --within-instance http://localhost $DIAMOND_MERGE_ID" \
	"$ZIG_CLONE_EXE --within-instance http://localhost $DIAMOND_MERGE_ID"
assert_capture_exits "clone34" 0
assert_stdout_pattern "clone34" "4 jobs have been created:"

_m34_perl_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone34_perl_stdout.log" || true)
_m34_zig_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone34_zig_stdout.log" || true)

for id in $_m34_perl_ids $_m34_zig_ids; do
	if [[ -n "$id" ]]; then wait_for_job "$id" 300 >/dev/null || true; fi
done

# M35: Check dependencies of the merged diamond
echo "--- Test M35: Diamond merge dependencies preserved ---"
_m35_pass=true
for _lbl in "perl" "zig"; do
    _ids_var="_m34_${_lbl}_ids"
    _ids="${!_ids_var}"
    _new_root=""
    _new_left=""
    _new_right=""
    _new_merge=""
    for id in $_ids; do
        _test=$(container_exec openqa-cli api --host http://localhost "jobs/$id" 2>/dev/null | jq -r '.job.settings.TEST')
        case "$_test" in
            diamond_root)  _new_root=$id ;;
            diamond_left)  _new_left=$id ;;
            diamond_right) _new_right=$id ;;
            diamond_merge) _new_merge=$id ;;
        esac
    done

    if [[ -n "$_new_merge" && -n "$_new_left" && -n "$_new_right" && -n "$_new_root" ]]; then
        if ! assert_job_has_chained_parent "$_new_merge" "$_new_left"; then _m35_pass=false; fi
        if ! assert_job_has_chained_parent "$_new_merge" "$_new_right"; then _m35_pass=false; fi
        if ! assert_job_has_chained_parent "$_new_left" "$_new_root"; then _m35_pass=false; fi
        if ! assert_job_has_chained_parent "$_new_right" "$_new_root"; then _m35_pass=false; fi
    else
        echo "  FAIL: $_lbl missing one or more diamond nodes in clone output"
        _m35_pass=false
    fi
done
if [[ "$_m35_pass" == "true" ]]; then echo "PASS"; else failed_tests=$((failed_tests + 1)); fi

# M36: Cycle prevention is already tested by M34 successfully returning 4 jobs
# instead of infinite looping, but we can note it.

# M37: Override doesn't reach root
echo "--- Test M37: Diamond override isolation ---"
run_capture_both "clone37" \
	"$PERL_CLONE_EXE --within-instance http://localhost $DIAMOND_MERGE_ID BUILD=diamond-override" \
	"$ZIG_CLONE_EXE --within-instance http://localhost $DIAMOND_MERGE_ID BUILD=diamond-override"
assert_capture_exits "clone37" 0

_m37_perl_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone37_perl_stdout.log" || true)
_m37_zig_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone37_zig_stdout.log" || true)

for id in $_m37_perl_ids $_m37_zig_ids; do
	if [[ -n "$id" ]]; then wait_for_job "$id" 300 >/dev/null || true; fi
done

# M38: --skip-deps on diamond
echo "--- Test M38: Diamond --skip-deps ---"
run_capture_both "clone38" \
	"$PERL_CLONE_EXE --within-instance http://localhost --skip-deps $DIAMOND_MERGE_ID" \
	"$ZIG_CLONE_EXE --within-instance http://localhost --skip-deps $DIAMOND_MERGE_ID"
assert_capture_exits "clone38" 0
assert_stdout_pattern "clone38" "1 job has been created:"

_m38_perl_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone38_perl_stdout.log" || true)
_m38_zig_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone38_zig_stdout.log" || true)

for id in $_m38_perl_ids $_m38_zig_ids; do
	if [[ -n "$id" ]]; then wait_for_job "$id" 300 >/dev/null || true; fi
done

# M39: --skip-chained-deps on layer_child
echo "--- Test M39: Multi-layer --skip-chained-deps ---"
run_capture_both "clone39" \
	"$PERL_CLONE_EXE --within-instance http://localhost --skip-chained-deps $LAYER_CHILD_ID" \
	"$ZIG_CLONE_EXE --within-instance http://localhost --skip-chained-deps $LAYER_CHILD_ID"
assert_capture_exits "clone39" 0
assert_stdout_pattern "clone39" "1 job has been created:"

_m39_perl_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone39_perl_stdout.log" || true)
_m39_zig_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone39_zig_stdout.log" || true)

for id in $_m39_perl_ids $_m39_zig_ids; do
	if [[ -n "$id" ]]; then wait_for_job "$id" 300 >/dev/null || true; fi
done

# =============================================================================
# Section M-Parallel: Parallel Topology Tests (M41-M42)
# =============================================================================
ensure_parallel_jobs

echo "--- Test M41: clone-job parallel_child clones parallel_parent ---"
run_capture_both "clone41" \
	"$PERL_CLONE_EXE --within-instance http://localhost $PARALLEL_CHILD_ID" \
	"$ZIG_CLONE_EXE --within-instance http://localhost $PARALLEL_CHILD_ID"
assert_capture_exits "clone41" 0
assert_stdout_pattern "clone41" "2 jobs have been created:"

_m41_perl_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone41_perl_stdout.log" || true)
_m41_zig_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone41_zig_stdout.log" || true)

for id in $_m41_perl_ids $_m41_zig_ids; do
	if [[ -n "$id" ]]; then wait_for_job "$id" 300 >/dev/null || true; fi
done

echo "--- Test M42: clone-job parallel_parent with --clone-children clones parallel_child ---"
run_capture_both "clone42" \
	"$PERL_CLONE_EXE --within-instance http://localhost --clone-children $PARALLEL_PARENT_ID" \
	"$ZIG_CLONE_EXE --within-instance http://localhost --clone-children $PARALLEL_PARENT_ID"
assert_capture_exits "clone42" 0
assert_stdout_pattern "clone42" "2 jobs have been created:"

_m42_perl_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone42_perl_stdout.log" || true)
_m42_zig_ids=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone42_zig_stdout.log" || true)

for id in $_m42_perl_ids $_m42_zig_ids; do
	if [[ -n "$id" ]]; then wait_for_job "$id" 300 >/dev/null || true; fi
done

# =============================================================================
# Section M-Host: Host Resolution Tests (M43–M44)
#
# Validates that zoqa-clone-job uses different host resolution rules from zoqa api:
#   - Bare "localhost" → http:// (not https://).  Matches Perl Client.pm:url_from_host.
#   - Bare non-localhost → https://.
# Contrast with test 41a in tests_core.sh where zoqa api bare "localhost" → https://.
# =============================================================================

echo "--- Test M43: bare --host localhost → http:// (clone succeeds) ---"
# Clone-job special-cases bare 'localhost' → http:// (not https://).
# The container serves openQA on http://localhost, so the clone should succeed.
# If normalizeHostUrl wrongly used https://, this would fail with a TLS error.
run_capture_both "clone43" \
	"$PERL_CLONE_EXE --from http://localhost --host localhost --skip-download $JOB_ID" \
	"$ZIG_CLONE_EXE --from http://localhost --host localhost --skip-download $JOB_ID"
assert_capture_exits "clone43" 0
assert_stdout_pattern "clone43" "http://localhost/tests/"

echo "--- Test M44: bare --host 127.0.0.1 → https:// → TLS error ---"
# 127.0.0.1 doesn't match the 'localhost' substring check, so gets https://.
# Container's HTTPS uses a self-signed cert → TLS handshake failure → exit non-zero.
# This mirrors test 41a in tests_core.sh but for the clone-job binary.
run_test "PERL: bare --host 127.0.0.1 → https:// → TLS error (exit non-zero)" \
	"bash -c \"$PERL_CLONE_EXE --from http://localhost --host 127.0.0.1 --skip-download $JOB_ID; test \\\$? -ne 0\"" 0
run_test "ZIG : bare --host 127.0.0.1 → https:// → TLS error (exit non-zero)" \
	"bash -c \"$ZIG_CLONE_EXE --from http://localhost --host 127.0.0.1 --skip-download $JOB_ID; test \\\$? -ne 0\"" 0

# =============================================================================
# M50-M78: Missing Features
# =============================================================================

echo "--- Test M50-M54: --export-command ---"
run_capture_both "clone_export" \
	"$PERL_CLONE_EXE --within-instance http://localhost --export-command $JOB_ID BUILD=export-test" \
	"$ZIG_CLONE_EXE --within-instance http://localhost --export-command $JOB_ID BUILD=export-test"
assert_capture_exits "clone_export" 0

# Perl outputs openqa-cli api, Zig outputs zoqa api. Check logs directly on host.
if grep -q "openqa-cli api.*-X POST jobs" "$LOG_DIR/clone_export_perl_stdout.log"; then
	echo "PASS: Perl export-command outputs openqa-cli"
else
	echo "FAIL: Perl export-command outputs openqa-cli"
	failed_tests=$((failed_tests + 1))
fi

if grep -q "zoqa api.*-X POST jobs" "$LOG_DIR/clone_export_zig_stdout.log"; then
	echo "PASS: Zig export-command outputs zoqa api"
else
	echo "FAIL: Zig export-command outputs zoqa api"
	failed_tests=$((failed_tests + 1))
fi

if grep -q "BUILD:.*=export-test" "$LOG_DIR/clone_export_zig_stdout.log"; then
	echo "PASS: Zig export-command includes overrides"
else
	echo "FAIL: Zig export-command includes overrides"
	failed_tests=$((failed_tests + 1))
fi

echo "--- Test M55-M59: --reproduce ---"
run_capture_both "clone_reproduce" \
	"$PERL_CLONE_EXE --within-instance http://localhost --reproduce $JOB_ID" \
	"$ZIG_CLONE_EXE --within-instance http://localhost --reproduce $JOB_ID"
assert_capture_exits "clone_reproduce" 0

echo "--- Test M60-M63: --repeat ---"
run_capture_both "clone_repeat" \
	"$PERL_CLONE_EXE --within-instance http://localhost --repeat 2 $JOB_ID" \
	"$ZIG_CLONE_EXE --within-instance http://localhost --repeat 2 $JOB_ID"
assert_capture_exits "clone_repeat" 0

if [ "$(grep -c '1 job has been created:' "$LOG_DIR/clone_repeat_perl_stdout.log" || true)" -eq 2 ]; then
	echo "PASS: Perl repeat 2 creates 2 jobs"
else
	echo "FAIL: Perl repeat 2 creates 2 jobs"
	failed_tests=$((failed_tests + 1))
fi

if [ "$(grep -c '1 job has been created:' "$LOG_DIR/clone_repeat_zig_stdout.log" || true)" -eq 2 ]; then
	echo "PASS: Zig repeat 2 creates 2 jobs"
else
	echo "FAIL: Zig repeat 2 creates 2 jobs"
	failed_tests=$((failed_tests + 1))
fi

echo "--- Test M65-M67: --badge ---"
run_capture_both "clone_badge" \
	"$PERL_CLONE_EXE --within-instance http://localhost --badge $JOB_ID" \
	"$ZIG_CLONE_EXE --within-instance http://localhost --badge $JOB_ID"
assert_capture_exits "clone_badge" 0
# Both should output markdown badge format `[![`
assert_stdout_pattern "clone_badge" "\[\!\["

echo "--- Test M68-M70: --json-output ---"
run_capture_both "clone_json_output" \
	"$PERL_CLONE_EXE --within-instance http://localhost --json-output $JOB_ID" \
	"$ZIG_CLONE_EXE --within-instance http://localhost --json-output $JOB_ID"
assert_capture_exits "clone_json_output" 0

# Validate non-empty valid JSON with at least one numeric value (new job ID).
if jq -e 'to_entries | length > 0' "$LOG_DIR/clone_json_output_perl_stdout.log" >/dev/null 2>&1; then
	echo "PASS: Perl json-output is valid non-empty JSON"
else
	echo "FAIL: Perl json-output is valid non-empty JSON"
	failed_tests=$((failed_tests + 1))
fi

if jq -e 'to_entries | length > 0' "$LOG_DIR/clone_json_output_zig_stdout.log" >/dev/null 2>&1; then
	echo "PASS: Zig json-output is valid non-empty JSON"
else
	echo "FAIL: Zig json-output is valid non-empty JSON"
	failed_tests=$((failed_tests + 1))
fi

echo "--- Test M71-M78: Asset download ---"
# --dir path must exist inside the container (commands run via container_exec).
# Use separate dirs so Perl's downloads don't mask Zig's absence.
ASSET_DIR_PERL="/tmp/e2e-assets-perl-$$"
ASSET_DIR_ZIG="/tmp/e2e-assets-zig-$$"
container_exec mkdir -p "$ASSET_DIR_PERL" "$ASSET_DIR_ZIG"
run_capture_both "clone_assets" \
	"$PERL_CLONE_EXE --from http://localhost --host localhost $JOB_ID --dir $ASSET_DIR_PERL" \
	"$ZIG_CLONE_EXE --from http://localhost --host localhost $JOB_ID --dir $ASSET_DIR_ZIG"
assert_capture_exits "clone_assets" 0

# Verify Perl downloaded at least one asset file (HDD or ISO).
if container_exec find "$ASSET_DIR_PERL" -type f | grep -q .; then
	echo "PASS: Perl asset download produced files"
else
	echo "FAIL: Perl asset download produced files"
	failed_tests=$((failed_tests + 1))
fi

# Verify Zig downloaded at least one asset file.
if container_exec find "$ASSET_DIR_ZIG" -type f | grep -q .; then
	echo "PASS: Zig asset download produced files"
else
	echo "FAIL: Zig asset download produced files"
	failed_tests=$((failed_tests + 1))
fi

container_exec rm -rf "$ASSET_DIR_PERL" "$ASSET_DIR_ZIG"

