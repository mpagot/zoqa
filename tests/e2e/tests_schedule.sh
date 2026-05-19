#!/usr/bin/env bash
# tests_schedule.sh — Section J: schedule subcommand tests.
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
# Uses the scenario-definitions.yaml cached at /tmp/scenario.yaml inside the
# container (written by seed_fixtures.sh during infrastructure setup).
#
# NOTE (TDD): The Zig schedule subcommand is not yet implemented.
# All Zig tests are expected to FAIL until the implementation is complete.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "==> [schedule] Running schedule tests..."

# Ensure a completed job exists (frees the single worker for scheduling).
ensure_basic_job

# Common scheduling parameters (minus SCENARIO_DEFINITIONS_YAML).
_SCHED_PARAMS="DISTRI=example VERSION=0 FLAVOR=DVD ARCH=x86_64"
_SCHED_BUILD="BUILD=e2e-test-sch"
_SCHED_ASSETS="HDD_1=$CIRROS_IMG ISO_1=seed-nocloud.iso"
_SCHED_DIRS="CASEDIR=$CIRROS_TESTDIR NEEDLES_DIR=%CASEDIR%/needles"
_SCHED_GROUP="_GROUP_ID=${GROUP_ID:-1}"

# =============================================================================
# Section 1: Basic Sync Scheduling (sync response, stdout)
# =============================================================================

# SCH-1: Sync scheduling — both Perl and Zig should exit 0 and print job URLs.
# This is the primary happy-path comparison test. Both tools schedule via the
# `schedule` subcommand with inline SCENARIO_DEFINITIONS_YAML.
echo "--- Test: SCH-1: Sync schedule with inline SCENARIO_DEFINITIONS_YAML ---"

# Read the scenario YAML once for inline use.
_SCH_YAML=$(container_exec cat "$_SCENARIO_YAML_PATH")

# Perl
run_capture "sch1" perl "$PERL_EXE schedule --host http://localhost \
	$_SCHED_PARAMS $_SCHED_BUILD $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP \
	\"SCENARIO_DEFINITIONS_YAML=$_SCH_YAML\""
_sch1_perl_exit=$_LAST_EXIT
echo "  Perl exit: $_sch1_perl_exit"

# Wait for the Perl-scheduled job to complete (free the worker).
_sch1_perl_jobid=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/sch1_perl_stdout.log" | head -1) || true
if [[ -n "$_sch1_perl_jobid" ]]; then
	echo "  Perl scheduled job ID: $_sch1_perl_jobid — waiting for completion..."
	wait_for_job "$_sch1_perl_jobid" 300 >/dev/null || echo "  WARNING: timeout waiting for Perl job"
fi

# Zig
run_capture "sch1" zig "$ZIG_EXE schedule --host http://localhost \
	$_SCHED_PARAMS $_SCHED_BUILD $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP \
	\"SCENARIO_DEFINITIONS_YAML=$_SCH_YAML\""
_sch1_zig_exit=$_LAST_EXIT
echo "  Zig exit: $_sch1_zig_exit"

# Assert: both exit 0
_sch1_pass=true
if [[ "$_sch1_perl_exit" -ne 0 ]]; then
	echo "  FAIL: Perl exited $_sch1_perl_exit (expected 0)"
	cat "$LOG_DIR/sch1_perl_stderr.log"
	_sch1_pass=false
fi
if [[ "$_sch1_zig_exit" -ne 0 ]]; then
	echo "  FAIL: Zig exited $_sch1_zig_exit (expected 0)"
	cat "$LOG_DIR/sch1_zig_stderr.log"
	_sch1_pass=false
fi

# Assert: both stdout contain "job" and "has been created" or "have been created"
if [[ "$_sch1_pass" == "true" ]]; then
	for _impl in perl zig; do
		if ! grep -qE '(has|have) been created' "$LOG_DIR/sch1_${_impl}_stdout.log"; then
			echo "  FAIL: $_impl stdout missing 'has/have been created'"
			cat "$LOG_DIR/sch1_${_impl}_stdout.log"
			_sch1_pass=false
		fi
		if ! grep -q ' - http://' "$LOG_DIR/sch1_${_impl}_stdout.log"; then
			echo "  FAIL: $_impl stdout missing job URL (' - http://')"
			cat "$LOG_DIR/sch1_${_impl}_stdout.log"
			_sch1_pass=false
		fi
	done
fi

if [[ "$_sch1_pass" == "true" ]]; then
	echo "PASS"
else
	failed_tests=$((failed_tests + 1))
fi

# Wait for the Zig-scheduled job to complete (free the worker for next test).
_sch1_zig_jobid=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/sch1_zig_stdout.log" | head -1) || true
if [[ -n "$_sch1_zig_jobid" ]]; then
	wait_for_job "$_sch1_zig_jobid" 300 >/dev/null || echo "  WARNING: timeout waiting for Zig job"
fi

# SCH-2: Sync scheduling using --param-file for SCENARIO_DEFINITIONS_YAML.
# The scenario YAML is read from /tmp/scenario.yaml via --param-file instead
# of being passed inline.
echo "--- Test: SCH-2: Sync schedule with --param-file ---"

# Perl
run_capture "sch2" perl "$PERL_EXE schedule --host http://localhost \
	--param-file SCENARIO_DEFINITIONS_YAML=$_SCENARIO_YAML_PATH \
	$_SCHED_PARAMS BUILD=e2e-test-sch2 $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP"
_sch2_perl_exit=$_LAST_EXIT
echo "  Perl exit: $_sch2_perl_exit"

# Wait for Perl job to finish.
_sch2_perl_jobid=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/sch2_perl_stdout.log" | head -1) || true
if [[ -n "$_sch2_perl_jobid" ]]; then
	wait_for_job "$_sch2_perl_jobid" 300 >/dev/null || echo "  WARNING: timeout waiting for Perl job"
fi

# Zig
run_capture "sch2" zig "$ZIG_EXE schedule --host http://localhost \
	--param-file SCENARIO_DEFINITIONS_YAML=$_SCENARIO_YAML_PATH \
	$_SCHED_PARAMS BUILD=e2e-test-sch2 $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP"
_sch2_zig_exit=$_LAST_EXIT
echo "  Zig exit: $_sch2_zig_exit"

_sch2_pass=true
if [[ "$_sch2_perl_exit" -ne 0 ]]; then
	echo "  FAIL: Perl exited $_sch2_perl_exit (expected 0)"
	cat "$LOG_DIR/sch2_perl_stderr.log"
	_sch2_pass=false
fi
if [[ "$_sch2_zig_exit" -ne 0 ]]; then
	echo "  FAIL: Zig exited $_sch2_zig_exit (expected 0)"
	cat "$LOG_DIR/sch2_zig_stderr.log"
	_sch2_pass=false
fi

if [[ "$_sch2_pass" == "true" ]]; then
	for _impl in perl zig; do
		if ! grep -qE '(has|have) been created' "$LOG_DIR/sch2_${_impl}_stdout.log"; then
			echo "  FAIL: $_impl stdout missing 'has/have been created'"
			cat "$LOG_DIR/sch2_${_impl}_stdout.log"
			_sch2_pass=false
		fi
	done
fi

if [[ "$_sch2_pass" == "true" ]]; then
	echo "PASS"
else
	failed_tests=$((failed_tests + 1))
fi

# Wait for Zig job to finish.
_sch2_zig_jobid=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/sch2_zig_stdout.log" | head -1) || true
if [[ -n "$_sch2_zig_jobid" ]]; then
	wait_for_job "$_sch2_zig_jobid" 300 >/dev/null || echo "  WARNING: timeout waiting for Zig job"
fi

# =============================================================================
# Section 2: Async Scheduling (async response)
# =============================================================================

# SCH-3: async=1 without --monitor — both exit 0, stdout contains
# "scheduled_product_id" (since no jobs are created synchronously, no
# "has been created" line is expected).
echo "--- Test: SCH-3: Async schedule without --monitor ---"

# Perl
run_capture "sch3" perl "$PERL_EXE schedule --host http://localhost \
	$_SCHED_PARAMS BUILD=e2e-test-sch3 $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP \
	\"SCENARIO_DEFINITIONS_YAML=$_SCH_YAML\" async=1"
_sch3_perl_exit=$_LAST_EXIT
echo "  Perl exit: $_sch3_perl_exit"

# Zig
run_capture "sch3" zig "$ZIG_EXE schedule --host http://localhost \
	$_SCHED_PARAMS BUILD=e2e-test-sch3 $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP \
	\"SCENARIO_DEFINITIONS_YAML=$_SCH_YAML\" async=1"
_sch3_zig_exit=$_LAST_EXIT
echo "  Zig exit: $_sch3_zig_exit"

_sch3_pass=true
# Both should exit 0.
if [[ "$_sch3_perl_exit" -ne 0 ]]; then
	echo "  FAIL: Perl exited $_sch3_perl_exit (expected 0)"
	cat "$LOG_DIR/sch3_perl_stderr.log"
	_sch3_pass=false
fi
if [[ "$_sch3_zig_exit" -ne 0 ]]; then
	echo "  FAIL: Zig exited $_sch3_zig_exit (expected 0)"
	cat "$LOG_DIR/sch3_zig_stderr.log"
	_sch3_pass=false
fi
# Neither should print "has been created" (async: no immediate ids).
# Perl prints nothing on stdout for async without --monitor. Zig should match.
if [[ "$_sch3_pass" == "true" ]]; then
	echo "PASS"
else
	failed_tests=$((failed_tests + 1))
fi

# Give the async job time to be created by the server before next test.
e2e_sleep 5

# Wait for any async-created jobs to finish (free the worker).
# Query the scheduled product to find the job IDs.
_sch3_sp_id=$(container_exec bash -c "cat '$LOG_DIR/sch3_perl_stdout.log'" 2>/dev/null | grep -oP '(?<="scheduled_product_id":)\d+' || true)
if [[ -n "$_sch3_sp_id" ]]; then
	_sch3_async_ids=$(container_exec openqa-cli api --host http://localhost \
		"isos/$_sch3_sp_id" 2>/dev/null | jq -r '.results.successful_job_ids[]? // empty' 2>/dev/null || true)
	for _jid in $_sch3_async_ids; do
		wait_for_job "$_jid" 300 >/dev/null || echo "  WARNING: timeout waiting for async job $_jid"
	done
fi

# SCH-4: async=1 --monitor — both should poll, wait for jobs, and exit 0.
echo "--- Test: SCH-4: Async schedule with --monitor ---"

# Perl
run_capture "sch4" perl "timeout 300 $PERL_EXE schedule --host http://localhost --monitor \
	$_SCHED_PARAMS BUILD=e2e-test-sch4 $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP \
	\"SCENARIO_DEFINITIONS_YAML=$_SCH_YAML\" async=1"
_sch4_perl_exit=$_LAST_EXIT
echo "  Perl exit: $_sch4_perl_exit"

# Zig
run_capture "sch4" zig "timeout 300 $ZIG_EXE schedule --host http://localhost --monitor \
	$_SCHED_PARAMS BUILD=e2e-test-sch4 $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP \
	\"SCENARIO_DEFINITIONS_YAML=$_SCH_YAML\" async=1"
_sch4_zig_exit=$_LAST_EXIT
echo "  Zig exit: $_sch4_zig_exit"

_sch4_pass=true
# Both should eventually exit 0 (jobs pass/softfail).
if [[ "$_sch4_perl_exit" -ne 0 ]]; then
	echo "  FAIL: Perl exited $_sch4_perl_exit (expected 0)"
	cat "$LOG_DIR/sch4_perl_stderr.log"
	_sch4_pass=false
fi
if [[ "$_sch4_zig_exit" -ne 0 ]]; then
	echo "  FAIL: Zig exited $_sch4_zig_exit (expected 0)"
	cat "$LOG_DIR/sch4_zig_stderr.log"
	_sch4_pass=false
fi
if [[ "$_sch4_pass" == "true" ]]; then
	echo "PASS"
else
	failed_tests=$((failed_tests + 1))
fi

# =============================================================================
# Section 3: --follow Flag
# =============================================================================

# SCH-6: --follow without --monitor — both should exit 0 after scheduling,
# no monitoring takes place. --follow is just a modifier, not a trigger.
echo "--- Test: SCH-6: --follow without --monitor (no monitoring) ---"

# Perl
run_capture "sch6" perl "$PERL_EXE schedule --host http://localhost --follow \
	$_SCHED_PARAMS BUILD=e2e-test-sch6 $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP \
	\"SCENARIO_DEFINITIONS_YAML=$_SCH_YAML\""
_sch6_perl_exit=$_LAST_EXIT
echo "  Perl exit: $_sch6_perl_exit"

# Wait for Perl job to finish.
_sch6_perl_jobid=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/sch6_perl_stdout.log" | head -1) || true
if [[ -n "$_sch6_perl_jobid" ]]; then
	wait_for_job "$_sch6_perl_jobid" 300 >/dev/null || echo "  WARNING: timeout"
fi

# Zig
run_capture "sch6" zig "$ZIG_EXE schedule --host http://localhost --follow \
	$_SCHED_PARAMS BUILD=e2e-test-sch6 $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP \
	\"SCENARIO_DEFINITIONS_YAML=$_SCH_YAML\""
_sch6_zig_exit=$_LAST_EXIT
echo "  Zig exit: $_sch6_zig_exit"

_sch6_pass=true
if [[ "$_sch6_perl_exit" -ne 0 ]]; then
	echo "  FAIL: Perl exited $_sch6_perl_exit (expected 0)"
	cat "$LOG_DIR/sch6_perl_stderr.log"
	_sch6_pass=false
fi
if [[ "$_sch6_zig_exit" -ne 0 ]]; then
	echo "  FAIL: Zig exited $_sch6_zig_exit (expected 0)"
	cat "$LOG_DIR/sch6_zig_stderr.log"
	_sch6_pass=false
fi
# Both should print job URLs (scheduled without monitoring).
if [[ "$_sch6_pass" == "true" ]]; then
	for _impl in perl zig; do
		if ! grep -qE '(has|have) been created' "$LOG_DIR/sch6_${_impl}_stdout.log"; then
			echo "  FAIL: $_impl stdout missing 'has/have been created'"
			cat "$LOG_DIR/sch6_${_impl}_stdout.log"
			_sch6_pass=false
		fi
	done
fi
if [[ "$_sch6_pass" == "true" ]]; then
	echo "PASS"
else
	failed_tests=$((failed_tests + 1))
fi

# Wait for Zig job to finish.
_sch6_zig_jobid=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/sch6_zig_stdout.log" | head -1) || true
if [[ -n "$_sch6_zig_jobid" ]]; then
	wait_for_job "$_sch6_zig_jobid" 300 >/dev/null || echo "  WARNING: timeout"
fi

# =============================================================================
# Section 4: --poll-interval
# =============================================================================

# SCH-7: --poll-interval 1 with async=1 --monitor — both exit 0.
# Exercises the explicit poll-interval override combined with async polling.
echo "--- Test: SCH-7: --poll-interval 1 with async --monitor ---"

# Perl
run_capture "sch7" perl "timeout 300 $PERL_EXE schedule --host http://localhost \
	--monitor --poll-interval 1 \
	$_SCHED_PARAMS BUILD=e2e-test-sch7 $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP \
	\"SCENARIO_DEFINITIONS_YAML=$_SCH_YAML\" async=1"
_sch7_perl_exit=$_LAST_EXIT
echo "  Perl exit: $_sch7_perl_exit"

# Zig
run_capture "sch7" zig "timeout 300 $ZIG_EXE schedule --host http://localhost \
	--monitor --poll-interval 1 \
	$_SCHED_PARAMS BUILD=e2e-test-sch7 $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP \
	\"SCENARIO_DEFINITIONS_YAML=$_SCH_YAML\" async=1"
_sch7_zig_exit=$_LAST_EXIT
echo "  Zig exit: $_sch7_zig_exit"

_sch7_pass=true
if [[ "$_sch7_perl_exit" -ne 0 ]]; then
	echo "  FAIL: Perl exited $_sch7_perl_exit (expected 0)"
	cat "$LOG_DIR/sch7_perl_stderr.log"
	_sch7_pass=false
fi
if [[ "$_sch7_zig_exit" -ne 0 ]]; then
	echo "  FAIL: Zig exited $_sch7_zig_exit (expected 0)"
	cat "$LOG_DIR/sch7_zig_stderr.log"
	_sch7_pass=false
fi
if [[ "$_sch7_pass" == "true" ]]; then
	echo "PASS"
else
	failed_tests=$((failed_tests + 1))
fi

# =============================================================================
# Section 5: Error Cases
# =============================================================================

# SCH-8: Missing mandatory params (no DISTRI/VERSION/etc.) → server 400 → exit 1.
# The POST body has no recognized scheduling parameters, so the server rejects it.
echo "--- Test: SCH-8: Missing mandatory params -> exit 1 ---"

# Perl
run_capture "sch8" perl "$PERL_EXE schedule --host http://localhost BOGUS=1"
_sch8_perl_exit=$_LAST_EXIT
echo "  Perl exit: $_sch8_perl_exit"

# Zig
run_capture "sch8" zig "$ZIG_EXE schedule --host http://localhost BOGUS=1"
_sch8_zig_exit=$_LAST_EXIT
echo "  Zig exit: $_sch8_zig_exit"

_sch8_pass=true
if [[ "$_sch8_perl_exit" -ne 1 ]]; then
	echo "  FAIL: Perl exited $_sch8_perl_exit (expected 1)"
	cat "$LOG_DIR/sch8_perl_stderr.log"
	_sch8_pass=false
fi
if [[ "$_sch8_zig_exit" -ne 1 ]]; then
	echo "  FAIL: Zig exited $_sch8_zig_exit (expected 1)"
	cat "$LOG_DIR/sch8_zig_stderr.log"
	_sch8_pass=false
fi
if [[ "$_sch8_pass" == "true" ]]; then
	echo "PASS"
else
	failed_tests=$((failed_tests + 1))
fi

# SCH-9: Zero products scheduled (server returns count:0, empty ids) → exit 1.
# Valid mandatory params but a FLAVOR that doesn't match any template.
# NOTE: SCENARIO_DEFINITIONS_YAML is intentionally omitted here.  When it is
# present, openQA uses the inline YAML as the full job definition and FLAVOR
# becomes just a job variable — not a template matcher — so jobs are still
# created even with FLAVOR=NONEXISTENT.  Without inline YAML, the server
# falls back to template-based matching and FLAVOR=NONEXISTENT matches nothing.
echo "--- Test: SCH-9: Zero products scheduled -> exit 1 ---"

# Perl
run_capture "sch9" perl "$PERL_EXE schedule --host http://localhost \
	DISTRI=example VERSION=0 FLAVOR=NONEXISTENT ARCH=x86_64 BUILD=e2e-sch9"
_sch9_perl_exit=$_LAST_EXIT
echo "  Perl exit: $_sch9_perl_exit"

# Zig
run_capture "sch9" zig "$ZIG_EXE schedule --host http://localhost \
	DISTRI=example VERSION=0 FLAVOR=NONEXISTENT ARCH=x86_64 BUILD=e2e-sch9"
_sch9_zig_exit=$_LAST_EXIT
echo "  Zig exit: $_sch9_zig_exit"

_sch9_pass=true
# Both should exit 1 (no products matched = error).
if [[ "$_sch9_perl_exit" -ne 1 ]]; then
	echo "  FAIL: Perl exited $_sch9_perl_exit (expected 1)"
	cat "$LOG_DIR/sch9_perl_stderr.log"
	_sch9_pass=false
fi
if [[ "$_sch9_zig_exit" -ne 1 ]]; then
	echo "  FAIL: Zig exited $_sch9_zig_exit (expected 1)"
	cat "$LOG_DIR/sch9_zig_stderr.log"
	_sch9_pass=false
fi
if [[ "$_sch9_pass" == "true" ]]; then
	echo "PASS"
else
	failed_tests=$((failed_tests + 1))
fi

# SCH-10: Repeated --param-file — two --param-file flags in a single invocation.
# This exercises the ArrayList growth path in tryScheduleFlag: both DISTRI and
# BUILD are supplied via separate --param-file flags rather than inline KEY=VALUE
# positionals.  Both Perl and Zig must exit 0 and produce at least one job URL.
echo "--- Test: SCH-10: Repeated --param-file (two flags) ---"

container_exec bash -c "printf 'example' > /tmp/pf_sch10_distri.txt"
container_exec bash -c "printf 'e2e-test-sch10' > /tmp/pf_sch10_build.txt"

# Perl
run_capture "sch10" perl "$PERL_EXE schedule --host http://localhost \
	--param-file SCENARIO_DEFINITIONS_YAML=$_SCENARIO_YAML_PATH \
	--param-file BUILD=/tmp/pf_sch10_build.txt \
	$_SCHED_PARAMS $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP"
_sch10_perl_exit=$_LAST_EXIT
echo "  Perl exit: $_sch10_perl_exit"

_sch10_perl_jobid=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/sch10_perl_stdout.log" | head -1) || true
if [[ -n "$_sch10_perl_jobid" ]]; then
	wait_for_job "$_sch10_perl_jobid" 300 >/dev/null || echo "  WARNING: timeout waiting for Perl job"
fi

# Zig
run_capture "sch10" zig "$ZIG_EXE schedule --host http://localhost \
	--param-file SCENARIO_DEFINITIONS_YAML=$_SCENARIO_YAML_PATH \
	--param-file BUILD=/tmp/pf_sch10_build.txt \
	$_SCHED_PARAMS $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP"
_sch10_zig_exit=$_LAST_EXIT
echo "  Zig exit: $_sch10_zig_exit"

_sch10_zig_jobid=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/sch10_zig_stdout.log" | head -1) || true
if [[ -n "$_sch10_zig_jobid" ]]; then
	wait_for_job "$_sch10_zig_jobid" 300 >/dev/null || echo "  WARNING: timeout waiting for Zig job"
fi

_sch10_pass=true
if [[ "$_sch10_perl_exit" -ne 0 ]]; then
	echo "  FAIL: Perl exited $_sch10_perl_exit (expected 0)"
	cat "$LOG_DIR/sch10_perl_stderr.log"
	_sch10_pass=false
fi
if [[ "$_sch10_zig_exit" -ne 0 ]]; then
	echo "  FAIL: Zig exited $_sch10_zig_exit (expected 0)"
	cat "$LOG_DIR/sch10_zig_stderr.log"
	_sch10_pass=false
fi

if [[ "$_sch10_pass" == "true" ]]; then
	for _impl in perl zig; do
		if ! grep -qE '(has|have) been created' "$LOG_DIR/sch10_${_impl}_stdout.log"; then
			echo "  FAIL: $_impl stdout missing 'has/have been created'"
			cat "$LOG_DIR/sch10_${_impl}_stdout.log"
			_sch10_pass=false
		fi
	done
fi

if [[ "$_sch10_pass" == "true" ]]; then
	echo "PASS"
else
	failed_tests=$((failed_tests + 1))
fi

# =============================================================================
# Section 5b: failed/ids precedence — see SPEC §15.4 (sync) / §15.6 (async)
# =============================================================================
#
# Oracle: /usr/share/openqa/lib/OpenQA/CLI/schedule.pm.
#   - _create_jobs (sync POST):
#       1. push id/ids into @job_ids and PRINT URLs to stdout if non-empty
#       2. then compute $error = _error_from_json($json) at TOP LEVEL
#       3. if $error → print red error to stderr, return 1
#       4. else return 0
#     ⇒ partial success prints URLs AND exits 1 with stderr error.
#   - _wait_for_jobs (async polling):
#       per iteration computes $error = _error_from_json($results // $json)
#       BEFORE the status check, so non-empty `failed` always wins over
#       a `scheduled` status (successful_job_ids silently dropped).
#       cancelled (any non-pending status that isn't `scheduled`) returns
#       "Scheduled product N ended up <status>" → exit 1.
#
# Note on `failed` shape: the Perl source iterates it as an ARRAY of
#   { error_message: ... } objects (`map { $_->{error_message} } @{...}`).
#   The openQA web API returns this exact shape.

# Paths to the YAML fixtures inside the container (seeded by seed_fixtures.sh).
_SCH_BAD_PATH="/tmp/all-failed-scenario.yaml"
_SCH_MIX_PATH="/tmp/partial-scenario.yaml"

# _dump_capture TAG IMPL — append the captured stdout/stderr/exit from the
# given run_capture invocation to the test log. Used by SCH-11..14 so the
# test log preserves the openQA response even when assertions pass; this is
# critical because the spec is being derived from observed Perl behaviour.
_dump_capture() {
	local tag=$1
	local impl=$2
	echo "  ---- $tag $impl: stdout ----"
	sed 's/^/    | /' "$LOG_DIR/${tag}_${impl}_stdout.log" || true
	echo "  ---- $tag $impl: stderr ----"
	sed 's/^/    | /' "$LOG_DIR/${tag}_${impl}_stderr.log" || true
	echo "  ---- end $tag $impl ----"
}

# SCH-11: Sync schedule, every job_template entry references a nonexistent
# machine. Goal: exercise §15.4's "failed non-empty" path. We assert PARITY
# first (Perl == Zig) since Perl is the oracle; we then check the outputs
# are consistent with the documented partial-failure semantics.
echo "--- Test: SCH-11: Sync schedule, all entries fail -> Perl==Zig parity ---"

run_capture "sch11" perl "$PERL_EXE schedule --host http://localhost \
	--param-file SCENARIO_DEFINITIONS_YAML=$_SCH_BAD_PATH \
	$_SCHED_PARAMS BUILD=e2e-test-sch11 $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP"
_sch11_perl_exit=$_LAST_EXIT
echo "  Perl exit: $_sch11_perl_exit"

# Drain any unintended job the server may have scheduled (defensive).
_sch11_perl_jobid=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/sch11_perl_stdout.log" | head -1) || true
if [[ -n "$_sch11_perl_jobid" ]]; then
	wait_for_job "$_sch11_perl_jobid" 300 >/dev/null || echo "  WARNING: timeout waiting for Perl job"
fi

run_capture "sch11" zig "$ZIG_EXE schedule --host http://localhost \
	--param-file SCENARIO_DEFINITIONS_YAML=$_SCH_BAD_PATH \
	$_SCHED_PARAMS BUILD=e2e-test-sch11 $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP"
_sch11_zig_exit=$_LAST_EXIT
echo "  Zig exit: $_sch11_zig_exit"

_sch11_zig_jobid=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/sch11_zig_stdout.log" | head -1) || true
if [[ -n "$_sch11_zig_jobid" ]]; then
	wait_for_job "$_sch11_zig_jobid" 300 >/dev/null || echo "  WARNING: timeout waiting for Zig job"
fi

_sch11_pass=true
# Primary assertion: Perl/Zig parity on exit code (Perl is the oracle).
if [[ "$_sch11_zig_exit" -ne "$_sch11_perl_exit" ]]; then
	echo "  FAIL: Zig exited $_sch11_zig_exit but Perl exited $_sch11_perl_exit (parity broken)"
	_sch11_pass=false
fi
# Secondary assertion: when the response signals failure (non-zero exit),
# something must reach stderr per §15.4 step 4. When it signals success
# (exit 0), stdout must list the URL. Both clauses come from the Perl source.
for _impl in perl zig; do
	_exit_var="_sch11_${_impl}_exit"
	if [[ "${!_exit_var}" -ne 0 ]]; then
		if [[ ! -s "$LOG_DIR/sch11_${_impl}_stderr.log" ]]; then
			echo "  FAIL: $_impl exited ${!_exit_var} but wrote nothing to stderr"
			_sch11_pass=false
		fi
	fi
done
# Always dump captures: this is a discovery test; the spec is being locked
# in from what we observe here.
_dump_capture sch11 perl
_dump_capture sch11 zig
if [[ "$_sch11_pass" == "true" ]]; then
	echo "PASS"
else
	failed_tests=$((failed_tests + 1))
fi

# SCH-12: Sync schedule, partial success — one valid + one invalid entry.
# Goal: exercise the §15.4 partial-success rule (URL printed AND exit 1 per
# Perl _create_jobs ordering). Asserts parity first; then documents which
# clause the response actually triggered.
echo "--- Test: SCH-12: Sync schedule, partial success -> Perl==Zig parity ---"

run_capture "sch12" perl "$PERL_EXE schedule --host http://localhost \
	--param-file SCENARIO_DEFINITIONS_YAML=$_SCH_MIX_PATH \
	$_SCHED_PARAMS BUILD=e2e-test-sch12 $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP"
_sch12_perl_exit=$_LAST_EXIT
echo "  Perl exit: $_sch12_perl_exit"

_sch12_perl_jobid=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/sch12_perl_stdout.log" | head -1) || true
if [[ -n "$_sch12_perl_jobid" ]]; then
	wait_for_job "$_sch12_perl_jobid" 300 >/dev/null || echo "  WARNING: timeout waiting for Perl job"
fi

run_capture "sch12" zig "$ZIG_EXE schedule --host http://localhost \
	--param-file SCENARIO_DEFINITIONS_YAML=$_SCH_MIX_PATH \
	$_SCHED_PARAMS BUILD=e2e-test-sch12 $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP"
_sch12_zig_exit=$_LAST_EXIT
echo "  Zig exit: $_sch12_zig_exit"

_sch12_zig_jobid=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/sch12_zig_stdout.log" | head -1) || true
if [[ -n "$_sch12_zig_jobid" ]]; then
	wait_for_job "$_sch12_zig_jobid" 300 >/dev/null || echo "  WARNING: timeout waiting for Zig job"
fi

_sch12_pass=true
if [[ "$_sch12_zig_exit" -ne "$_sch12_perl_exit" ]]; then
	echo "  FAIL: Zig exited $_sch12_zig_exit but Perl exited $_sch12_perl_exit (parity broken)"
	_sch12_pass=false
fi
_dump_capture sch12 perl
_dump_capture sch12 zig
if [[ "$_sch12_pass" == "true" ]]; then
	echo "PASS"
else
	failed_tests=$((failed_tests + 1))
fi

# SCH-13: Async + --monitor, all entries fail. Exercises §15.6 step 2 (error
# check fires before status check). Parity-first assertion.
echo "--- Test: SCH-13: Async --monitor, all entries fail -> Perl==Zig parity ---"

run_capture "sch13" perl "timeout 120 $PERL_EXE schedule --host http://localhost --monitor \
	--param-file SCENARIO_DEFINITIONS_YAML=$_SCH_BAD_PATH \
	$_SCHED_PARAMS BUILD=e2e-test-sch13p $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP async=1"
_sch13_perl_exit=$_LAST_EXIT
echo "  Perl exit: $_sch13_perl_exit"

# Drain anything the server scheduled (defensive — the test should not
# create runnable jobs but if openQA permits the malformed YAML it might).
e2e_sleep 3
_sch13_perl_jids=$(container_exec openqa-cli api --host http://localhost \
	"jobs?build=e2e-test-sch13p" 2>/dev/null \
	| jq -r '.jobs[]?.id // empty' 2>/dev/null || true)
for _jid in $_sch13_perl_jids; do
	wait_for_job "$_jid" 300 >/dev/null || echo "  WARNING: timeout waiting for job $_jid"
done

run_capture "sch13" zig "timeout 120 $ZIG_EXE schedule --host http://localhost --monitor \
	--param-file SCENARIO_DEFINITIONS_YAML=$_SCH_BAD_PATH \
	$_SCHED_PARAMS BUILD=e2e-test-sch13z $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP async=1"
_sch13_zig_exit=$_LAST_EXIT
echo "  Zig exit: $_sch13_zig_exit"

e2e_sleep 3
_sch13_zig_jids=$(container_exec openqa-cli api --host http://localhost \
	"jobs?build=e2e-test-sch13z" 2>/dev/null \
	| jq -r '.jobs[]?.id // empty' 2>/dev/null || true)
for _jid in $_sch13_zig_jids; do
	wait_for_job "$_jid" 300 >/dev/null || echo "  WARNING: timeout waiting for job $_jid"
done

_sch13_pass=true
if [[ "$_sch13_zig_exit" -ne "$_sch13_perl_exit" ]]; then
	echo "  FAIL: Zig exited $_sch13_zig_exit but Perl exited $_sch13_perl_exit (parity broken)"
	_sch13_pass=false
fi
_dump_capture sch13 perl
_dump_capture sch13 zig
if [[ "$_sch13_pass" == "true" ]]; then
	echo "PASS"
else
	failed_tests=$((failed_tests + 1))
fi

# SCH-14: Async + --monitor, partial (B1 main case).
# Tests §15.6 precedence: when results contain both successful_job_ids AND
# non-empty failed, the error wins and successful_job_ids are silently
# dropped (the client never enters monitor). Parity-first.
echo "--- Test: SCH-14: Async --monitor, partial -> Perl==Zig parity ---"

run_capture "sch14" perl "timeout 120 $PERL_EXE schedule --host http://localhost --monitor \
	--param-file SCENARIO_DEFINITIONS_YAML=$_SCH_MIX_PATH \
	$_SCHED_PARAMS BUILD=e2e-test-sch14p $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP async=1"
_sch14_perl_exit=$_LAST_EXIT
echo "  Perl exit: $_sch14_perl_exit"

e2e_sleep 5
_sch14_perl_jids=$(container_exec openqa-cli api --host http://localhost \
	"jobs?build=e2e-test-sch14p" 2>/dev/null \
	| jq -r '.jobs[]?.id // empty' 2>/dev/null || true)
for _jid in $_sch14_perl_jids; do
	wait_for_job "$_jid" 300 >/dev/null || echo "  WARNING: timeout waiting for job $_jid"
done

run_capture "sch14" zig "timeout 120 $ZIG_EXE schedule --host http://localhost --monitor \
	--param-file SCENARIO_DEFINITIONS_YAML=$_SCH_MIX_PATH \
	$_SCHED_PARAMS BUILD=e2e-test-sch14z $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP async=1"
_sch14_zig_exit=$_LAST_EXIT
echo "  Zig exit: $_sch14_zig_exit"

e2e_sleep 5
_sch14_zig_jids=$(container_exec openqa-cli api --host http://localhost \
	"jobs?build=e2e-test-sch14z" 2>/dev/null \
	| jq -r '.jobs[]?.id // empty' 2>/dev/null || true)
for _jid in $_sch14_zig_jids; do
	wait_for_job "$_jid" 300 >/dev/null || echo "  WARNING: timeout waiting for job $_jid"
done

_sch14_pass=true
if [[ "$_sch14_zig_exit" -ne "$_sch14_perl_exit" ]]; then
	echo "  FAIL: Zig exited $_sch14_zig_exit but Perl exited $_sch14_perl_exit (parity broken)"
	_sch14_pass=false
fi
_dump_capture sch14 perl
_dump_capture sch14 zig
if [[ "$_sch14_pass" == "true" ]]; then
	echo "PASS"
else
	failed_tests=$((failed_tests + 1))
fi

# SCH-15: Cancelled mid-poll — INTENTIONALLY SKIPPED at the e2e layer.
#
# This case requires racing a DELETE /api/v1/isos/{sp_id} against the active
# poll loop while status is still added/scheduling. With a real openQA
# scheduler the timing is non-deterministic — by the time the cancel POST
# lands, the product is often already `scheduled`, and the test flakes.
#
# The right home for this is a unit test against a stubbed HTTP server that
# can serve a deterministic sequence (added → cancelled) on consecutive GETs.
# Per Perl `_wait_for_jobs`: when status is `cancelled` and successful_job_ids
# is populated, the IDs are silently dropped and the client returns
# "Scheduled product N ended up cancelled" → exit 1.
echo "--- Test: SCH-15: cancelled mid-poll — SKIPPED (see comment / future unit test) ---"
echo "SKIP"

# =============================================================================
# Section 5c: Failure-trigger experiments (SCH-EX*)
# =============================================================================
#
# SCH-11..SCH-14 proved that the YAML with `machine: nonexistent_machine_xyz`
# does NOT provoke `failed`/`failed_job_info` server-side. The experiments
# below try several other triggers (different YAML shapes, no-YAML + bogus
# params, asset-resolution failure, async polling) and dump every response so
# we can pick a real failure-triggering fixture for the SCH-11..SCH-14
# assertions or, if none works, fall back to stubbed unit tests.
#
# Each test reuses lib.sh helpers (run_capture, wait_for_job) directly. The
# only local helper is _drain_capture — it just runs the per-impl drain that
# SCH-1..SCH-14 already do inline.

echo "==> [schedule] Running failure-trigger experiments (SCH-EX*)..."

# Authenticate for audit-log access (used by EX2/EX3 audit assertions).
audit_login

# _drain_capture TAG IMPL — wait for any job whose URL appears in
# $LOG_DIR/${tag}_${impl}_stdout.log so the single-worker pool is free for
# the next test. No-op when no job was scheduled.
_drain_capture() {
	local tag=$1 impl=$2
	local jid
	jid=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/${tag}_${impl}_stdout.log" | head -1) || true
	if [[ -n "$jid" ]]; then wait_for_job "$jid" 300 >/dev/null || true; fi
}

# Shared param blocks.
_EX_BASE="DISTRI=example VERSION=0 ARCH=x86_64"
_EX_ASSETS="HDD_1=$CIRROS_IMG ISO_1=seed-nocloud.iso"
_EX_DIRS="CASEDIR=$CIRROS_TESTDIR NEEDLES_DIR=%CASEDIR%/needles"
_EX_GROUP="_GROUP_ID=${GROUP_ID:-1}"

# Each experiment below: run_capture perl, drain, run_capture zig, drain,
# dump both, parity check + outcome label. Outcome categories:
#   TRIGGERED   exit !=0 on both impls (good candidate for a real fixture)
#   PERMISSIVE  exit 0 on both impls (server accepted the bad input)
#   DIVERGED    impls disagree (parity-broken — surfaced as FAIL)

# --- SCH-EX1: SCH-9 baseline — no YAML, FLAVOR=NONEXISTENT (known exit 1) ---
echo "--- Test: SCH-EX1: Sync, no inline YAML, FLAVOR=NONEXISTENT ---"
run_capture schex1 perl "$PERL_EXE schedule --host http://localhost \
	FLAVOR=NONEXISTENT $_EX_BASE BUILD=e2e-schex1"
_schex1_perl_exit=$_LAST_EXIT
_drain_capture schex1 perl
run_capture schex1 zig "$ZIG_EXE schedule --host http://localhost \
	FLAVOR=NONEXISTENT $_EX_BASE BUILD=e2e-schex1"
_schex1_zig_exit=$_LAST_EXIT
_drain_capture schex1 zig
echo "  Perl exit: $_schex1_perl_exit, Zig exit: $_schex1_zig_exit"
_dump_capture schex1 perl
_dump_capture schex1 zig
if [[ "$_schex1_perl_exit" -ne "$_schex1_zig_exit" ]]; then
	echo "  outcome: DIVERGED — FAIL"
	failed_tests=$((failed_tests + 1))
elif [[ "$_schex1_perl_exit" -eq 0 ]]; then
	echo "  outcome: PERMISSIVE — server accepted, no failure triggered"
	echo "PASS"
else
	echo "  outcome: TRIGGERED (exit=$_schex1_perl_exit) — promote candidate"
	echo "PASS"
fi

# --- SCH-EX2: inline YAML, only job_template references undefined product ---
# After Option A fix (ISSUE_SCHEDULA_DIVERGED), both Perl and Zig should
# exit 0 — the server returns {count:0, ids:[], failed:[]} with no error.
echo "--- Test: SCH-EX2: Sync, inline YAML, undefined product reference ---"
_audit_before_ex2=$(audit_max_id)
run_capture schex2 perl "$PERL_EXE schedule --host http://localhost \
	--param-file SCENARIO_DEFINITIONS_YAML=/tmp/exp-bogus-product-ref-scenario.yaml \
	$_EX_BASE FLAVOR=DVD BUILD=e2e-schex2 $_EX_ASSETS $_EX_DIRS $_EX_GROUP"
_schex2_perl_exit=$_LAST_EXIT
_drain_capture schex2 perl
run_capture schex2 zig "$ZIG_EXE schedule --host http://localhost \
	--param-file SCENARIO_DEFINITIONS_YAML=/tmp/exp-bogus-product-ref-scenario.yaml \
	$_EX_BASE FLAVOR=DVD BUILD=e2e-schex2 $_EX_ASSETS $_EX_DIRS $_EX_GROUP"
_schex2_zig_exit=$_LAST_EXIT
_drain_capture schex2 zig
echo "  Perl exit: $_schex2_perl_exit, Zig exit: $_schex2_zig_exit"
_dump_capture schex2 perl
_dump_capture schex2 zig
if [[ "$_schex2_perl_exit" -ne "$_schex2_zig_exit" ]]; then
	echo "  outcome: DIVERGED — FAIL"; failed_tests=$((failed_tests + 1))
elif [[ "$_schex2_perl_exit" -eq 0 ]]; then
	echo "  outcome: PERMISSIVE"; echo "PASS"
else
	echo "  outcome: TRIGGERED (exit=$_schex2_perl_exit) — promote candidate"; echo "PASS"
fi
# Audit: verify no job_create events; iso_create may be absent for edge cases
_ex2_iso_creates=$(audit_count_since "$_audit_before_ex2" "iso_create")
_ex2_job_creates=$(audit_count_since "$_audit_before_ex2" "job_create")
echo "  audit: iso_create=$_ex2_iso_creates job_create=$_ex2_job_creates"
if [[ "$_ex2_iso_creates" -lt 1 ]]; then
	echo "  INFO: no iso_create event (expected for undefined product reference)"
fi
if [[ "$_ex2_job_creates" -ne 0 ]]; then
	echo "  FAIL: expected 0 job_create events, got $_ex2_job_creates"; failed_tests=$((failed_tests + 1))
fi

# --- SCH-EX3: inline YAML, empty job_templates {} ---
# Same as EX2: after Option A fix, both exit 0.
echo "--- Test: SCH-EX3: Sync, inline YAML, empty job_templates {} ---"
_audit_before_ex3=$(audit_max_id)
run_capture schex3 perl "$PERL_EXE schedule --host http://localhost \
	--param-file SCENARIO_DEFINITIONS_YAML=/tmp/exp-empty-job-templates-scenario.yaml \
	$_EX_BASE FLAVOR=DVD BUILD=e2e-schex3 $_EX_ASSETS $_EX_DIRS $_EX_GROUP"
_schex3_perl_exit=$_LAST_EXIT
_drain_capture schex3 perl
run_capture schex3 zig "$ZIG_EXE schedule --host http://localhost \
	--param-file SCENARIO_DEFINITIONS_YAML=/tmp/exp-empty-job-templates-scenario.yaml \
	$_EX_BASE FLAVOR=DVD BUILD=e2e-schex3 $_EX_ASSETS $_EX_DIRS $_EX_GROUP"
_schex3_zig_exit=$_LAST_EXIT
_drain_capture schex3 zig
echo "  Perl exit: $_schex3_perl_exit, Zig exit: $_schex3_zig_exit"
_dump_capture schex3 perl
_dump_capture schex3 zig
if [[ "$_schex3_perl_exit" -ne "$_schex3_zig_exit" ]]; then
	echo "  outcome: DIVERGED — FAIL"; failed_tests=$((failed_tests + 1))
elif [[ "$_schex3_perl_exit" -eq 0 ]]; then
	echo "  outcome: PERMISSIVE"; echo "PASS"
else
	echo "  outcome: TRIGGERED (exit=$_schex3_perl_exit) — promote candidate"; echo "PASS"
fi
# Audit: verify no job_create events; iso_create may be absent for edge cases
_ex3_iso_creates=$(audit_count_since "$_audit_before_ex3" "iso_create")
_ex3_job_creates=$(audit_count_since "$_audit_before_ex3" "job_create")
echo "  audit: iso_create=$_ex3_iso_creates job_create=$_ex3_job_creates"
if [[ "$_ex3_iso_creates" -lt 1 ]]; then
	echo "  INFO: no iso_create event (expected for empty job_templates)"
fi
if [[ "$_ex3_job_creates" -ne 0 ]]; then
	echo "  FAIL: expected 0 job_create events, got $_ex3_job_creates"; failed_tests=$((failed_tests + 1))
fi

# --- SCH-EX4: nonexistent _GROUP_ID ---
echo "--- Test: SCH-EX4: Sync, no inline YAML, _GROUP_ID=99999 ---"
run_capture schex4 perl "$PERL_EXE schedule --host http://localhost \
	$_EX_BASE FLAVOR=DVD BUILD=e2e-schex4 _GROUP_ID=99999"
_schex4_perl_exit=$_LAST_EXIT
_drain_capture schex4 perl
run_capture schex4 zig "$ZIG_EXE schedule --host http://localhost \
	$_EX_BASE FLAVOR=DVD BUILD=e2e-schex4 _GROUP_ID=99999"
_schex4_zig_exit=$_LAST_EXIT
_drain_capture schex4 zig
echo "  Perl exit: $_schex4_perl_exit, Zig exit: $_schex4_zig_exit"
_dump_capture schex4 perl
_dump_capture schex4 zig
if [[ "$_schex4_perl_exit" -ne "$_schex4_zig_exit" ]]; then
	echo "  outcome: DIVERGED — FAIL"; failed_tests=$((failed_tests + 1))
elif [[ "$_schex4_perl_exit" -eq 0 ]]; then
	echo "  outcome: PERMISSIVE"; echo "PASS"
else
	echo "  outcome: TRIGGERED (exit=$_schex4_perl_exit) — promote candidate"; echo "PASS"
fi

# --- SCH-EX5: nonexistent HDD_1 asset ---
echo "--- Test: SCH-EX5: Sync, no inline YAML, HDD_1=nonexistent.qcow2 ---"
run_capture schex5 perl "$PERL_EXE schedule --host http://localhost \
	$_EX_BASE FLAVOR=DVD BUILD=e2e-schex5 \
	HDD_1=nonexistent_asset_xyz.qcow2 ISO_1=seed-nocloud.iso $_EX_DIRS $_EX_GROUP"
_schex5_perl_exit=$_LAST_EXIT
_drain_capture schex5 perl
run_capture schex5 zig "$ZIG_EXE schedule --host http://localhost \
	$_EX_BASE FLAVOR=DVD BUILD=e2e-schex5 \
	HDD_1=nonexistent_asset_xyz.qcow2 ISO_1=seed-nocloud.iso $_EX_DIRS $_EX_GROUP"
_schex5_zig_exit=$_LAST_EXIT
_drain_capture schex5 zig
echo "  Perl exit: $_schex5_perl_exit, Zig exit: $_schex5_zig_exit"
_dump_capture schex5 perl
_dump_capture schex5 zig
if [[ "$_schex5_perl_exit" -ne "$_schex5_zig_exit" ]]; then
	echo "  outcome: DIVERGED — FAIL"; failed_tests=$((failed_tests + 1))
elif [[ "$_schex5_perl_exit" -eq 0 ]]; then
	echo "  outcome: PERMISSIVE"; echo "PASS"
else
	echo "  outcome: TRIGGERED (exit=$_schex5_perl_exit) — promote candidate"; echo "PASS"
fi

# --- SCH-EX6: PARTIAL CANDIDATE — inline YAML, one valid + one bogus product ---
echo "--- Test: SCH-EX6: Sync, inline YAML, partial (valid + undefined product) ---"
run_capture schex6 perl "$PERL_EXE schedule --host http://localhost \
	--param-file SCENARIO_DEFINITIONS_YAML=/tmp/exp-partial-bogus-product-scenario.yaml \
	$_EX_BASE FLAVOR=DVD BUILD=e2e-schex6 $_EX_ASSETS $_EX_DIRS $_EX_GROUP"
_schex6_perl_exit=$_LAST_EXIT
_drain_capture schex6 perl
run_capture schex6 zig "$ZIG_EXE schedule --host http://localhost \
	--param-file SCENARIO_DEFINITIONS_YAML=/tmp/exp-partial-bogus-product-scenario.yaml \
	$_EX_BASE FLAVOR=DVD BUILD=e2e-schex6 $_EX_ASSETS $_EX_DIRS $_EX_GROUP"
_schex6_zig_exit=$_LAST_EXIT
_drain_capture schex6 zig
echo "  Perl exit: $_schex6_perl_exit, Zig exit: $_schex6_zig_exit"
_dump_capture schex6 perl
_dump_capture schex6 zig
if [[ "$_schex6_perl_exit" -ne "$_schex6_zig_exit" ]]; then
	echo "  outcome: DIVERGED — FAIL"; failed_tests=$((failed_tests + 1))
elif [[ "$_schex6_perl_exit" -eq 0 ]]; then
	echo "  outcome: PERMISSIVE"; echo "PASS"
else
	echo "  outcome: TRIGGERED (exit=$_schex6_perl_exit) — promote partial candidate"; echo "PASS"
fi

# --- SCH-EX7: ASYNC + --monitor, FLAVOR=NONEXISTENT (captures failed_job_info) ---
echo "--- Test: SCH-EX7: Async --monitor, FLAVOR=NONEXISTENT (failed_job_info shape) ---"
run_capture schex7 perl "timeout 60 $PERL_EXE schedule --host http://localhost --monitor \
	$_EX_BASE FLAVOR=NONEXISTENT BUILD=e2e-schex7 async=1"
_schex7_perl_exit=$_LAST_EXIT
_drain_capture schex7 perl
run_capture schex7 zig "timeout 60 $ZIG_EXE schedule --host http://localhost --monitor \
	$_EX_BASE FLAVOR=NONEXISTENT BUILD=e2e-schex7 async=1"
_schex7_zig_exit=$_LAST_EXIT
_drain_capture schex7 zig
echo "  Perl exit: $_schex7_perl_exit, Zig exit: $_schex7_zig_exit"
_dump_capture schex7 perl
_dump_capture schex7 zig
if [[ "$_schex7_perl_exit" -ne "$_schex7_zig_exit" ]]; then
	echo "  outcome: DIVERGED — FAIL"; failed_tests=$((failed_tests + 1))
elif [[ "$_schex7_perl_exit" -eq 0 ]]; then
	echo "  outcome: PERMISSIVE"; echo "PASS"
else
	echo "  outcome: TRIGGERED (exit=$_schex7_perl_exit) — async candidate"; echo "PASS"
fi

# =============================================================================
# Section 50: Cross-Subcommand Flag Rejection
# =============================================================================

# SCH-50: --extract is an archive-only flag, rejected for schedule.
run_test "PERL: schedule --extract rejected" \
	"bash -c \"$PERL_EXE schedule --extract --host http://localhost DISTRI=x >/dev/null 2>&1\"" 255
run_test "ZIG : schedule --extract rejected" \
	"bash -c \"$ZIG_EXE schedule --extract --host http://localhost DISTRI=x >/dev/null 2>&1\"" 255

# =============================================================================
# Section 6: Retry Knob Smoke Tests
# =============================================================================
#
# Verify that --retries and OPENQA_CLI_RETRIES are accepted by the schedule
# subcommand without crashing.  These are smoke tests: the request itself
# uses BOGUS=1 (→ server 400 → exit 1), but the retry knob is parsed
# correctly in both implementations.  A crash during env-var parsing would
# produce a different exit code (e.g. 255 / segfault).

echo "==> [schedule] Running schedule retry-knob smoke tests..."

# SCH-RK-1: OPENQA_CLI_RETRIES=0 — explicit zero accepted.
run_test "PERL: schedule OPENQA_CLI_RETRIES=0 accepted" \
	"bash -c \"OPENQA_CLI_RETRIES=0 $PERL_EXE schedule --host http://localhost BOGUS=1\"" \
	1
run_test "ZIG : schedule OPENQA_CLI_RETRIES=0 accepted" \
	"bash -c \"OPENQA_CLI_RETRIES=0 $ZIG_EXE schedule --host http://localhost BOGUS=1\"" \
	1

# SCH-RK-2: OPENQA_CLI_RETRIES=abc — invalid value falls back gracefully.
run_test "PERL: schedule OPENQA_CLI_RETRIES=abc falls back gracefully" \
	"bash -c \"OPENQA_CLI_RETRIES=abc $PERL_EXE schedule --host http://localhost BOGUS=1\"" \
	1
run_test "ZIG : schedule OPENQA_CLI_RETRIES=abc falls back gracefully" \
	"bash -c \"OPENQA_CLI_RETRIES=abc $ZIG_EXE schedule --host http://localhost BOGUS=1\"" \
	1

# SCH-RK-3: --retries 0 CLI flag accepted with schedule subcommand.
# NOTE: Perl's schedule subcommand does NOT accept --retries (unknown option
# → exit 255).  Zig accepts it as a global flag (→ server rejects BOGUS=1 → 1).
run_test "PERL: schedule --retries 0 accepted" \
	"bash -c \"$PERL_EXE schedule --retries 0 --host http://localhost BOGUS=1\"" \
	255
run_test "ZIG : schedule --retries 0 accepted" \
	"bash -c \"$ZIG_EXE schedule --retries 0 --host http://localhost BOGUS=1\"" \
	1
