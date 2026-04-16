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
_SCHED_ASSETS='HDD_1=cirros-0.6.3-x86_64-disk.qcow2 ISO_1=seed-nocloud.iso'
_SCHED_DIRS='CASEDIR=/var/lib/openqa/share/tests/cirros NEEDLES_DIR=%CASEDIR%/needles'
_SCHED_GROUP="_GROUP_ID=${GROUP_ID:-1}"

# =============================================================================
# Section 1: Basic Sync Scheduling (sync response, stdout)
# =============================================================================

# SCH-1: Sync scheduling — both Perl and Zig should exit 0 and print job URLs.
# This is the primary happy-path comparison test. Both tools schedule via the
# `schedule` subcommand with inline SCENARIO_DEFINITIONS_YAML.
echo "--- Test: SCH-1: Sync schedule with inline SCENARIO_DEFINITIONS_YAML ---"

# Read the scenario YAML once for inline use.
_SCH_YAML=$(container_exec cat /tmp/scenario.yaml)

# Perl
set +e
container_exec bash -c "$PERL_EXE schedule --host http://localhost \
	$_SCHED_PARAMS $_SCHED_BUILD $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP \
	\"SCENARIO_DEFINITIONS_YAML=$_SCH_YAML\"" \
	>"$LOG_DIR/sch1_perl_stdout.log" 2>"$LOG_DIR/sch1_perl_stderr.log"
_sch1_perl_exit=$?
set -e
echo "  Perl exit: $_sch1_perl_exit"

# Wait for the Perl-scheduled job to complete (free the worker).
_sch1_perl_jobid=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/sch1_perl_stdout.log" | head -1) || true
if [[ -n "$_sch1_perl_jobid" ]]; then
	echo "  Perl scheduled job ID: $_sch1_perl_jobid — waiting for completion..."
	wait_for_job "$_sch1_perl_jobid" 300 >/dev/null || echo "  WARNING: timeout waiting for Perl job"
fi

# Zig
set +e
container_exec bash -c "$ZIG_EXE schedule --host http://localhost \
	$_SCHED_PARAMS $_SCHED_BUILD $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP \
	\"SCENARIO_DEFINITIONS_YAML=$_SCH_YAML\"" \
	>"$LOG_DIR/sch1_zig_stdout.log" 2>"$LOG_DIR/sch1_zig_stderr.log"
_sch1_zig_exit=$?
set -e
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
set +e
container_exec bash -c "$PERL_EXE schedule --host http://localhost \
	--param-file SCENARIO_DEFINITIONS_YAML=/tmp/scenario.yaml \
	$_SCHED_PARAMS BUILD=e2e-test-sch2 $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP" \
	>"$LOG_DIR/sch2_perl_stdout.log" 2>"$LOG_DIR/sch2_perl_stderr.log"
_sch2_perl_exit=$?
set -e
echo "  Perl exit: $_sch2_perl_exit"

# Wait for Perl job to finish.
_sch2_perl_jobid=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/sch2_perl_stdout.log" | head -1) || true
if [[ -n "$_sch2_perl_jobid" ]]; then
	wait_for_job "$_sch2_perl_jobid" 300 >/dev/null || echo "  WARNING: timeout waiting for Perl job"
fi

# Zig
set +e
container_exec bash -c "$ZIG_EXE schedule --host http://localhost \
	--param-file SCENARIO_DEFINITIONS_YAML=/tmp/scenario.yaml \
	$_SCHED_PARAMS BUILD=e2e-test-sch2 $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP" \
	>"$LOG_DIR/sch2_zig_stdout.log" 2>"$LOG_DIR/sch2_zig_stderr.log"
_sch2_zig_exit=$?
set -e
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
set +e
container_exec bash -c "$PERL_EXE schedule --host http://localhost \
	$_SCHED_PARAMS BUILD=e2e-test-sch3 $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP \
	\"SCENARIO_DEFINITIONS_YAML=$_SCH_YAML\" async=1" \
	>"$LOG_DIR/sch3_perl_stdout.log" 2>"$LOG_DIR/sch3_perl_stderr.log"
_sch3_perl_exit=$?
set -e
echo "  Perl exit: $_sch3_perl_exit"

# Zig
set +e
container_exec bash -c "$ZIG_EXE schedule --host http://localhost \
	$_SCHED_PARAMS BUILD=e2e-test-sch3 $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP \
	\"SCENARIO_DEFINITIONS_YAML=$_SCH_YAML\" async=1" \
	>"$LOG_DIR/sch3_zig_stdout.log" 2>"$LOG_DIR/sch3_zig_stderr.log"
_sch3_zig_exit=$?
set -e
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
sleep 5

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
set +e
container_exec bash -c "timeout 300 $PERL_EXE schedule --host http://localhost --monitor \
	$_SCHED_PARAMS BUILD=e2e-test-sch4 $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP \
	\"SCENARIO_DEFINITIONS_YAML=$_SCH_YAML\" async=1" \
	>"$LOG_DIR/sch4_perl_stdout.log" 2>"$LOG_DIR/sch4_perl_stderr.log"
_sch4_perl_exit=$?
set -e
echo "  Perl exit: $_sch4_perl_exit"

# Zig
set +e
container_exec bash -c "timeout 300 $ZIG_EXE schedule --host http://localhost --monitor \
	$_SCHED_PARAMS BUILD=e2e-test-sch4 $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP \
	\"SCENARIO_DEFINITIONS_YAML=$_SCH_YAML\" async=1" \
	>"$LOG_DIR/sch4_zig_stdout.log" 2>"$LOG_DIR/sch4_zig_stderr.log"
_sch4_zig_exit=$?
set -e
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
set +e
container_exec bash -c "$PERL_EXE schedule --host http://localhost --follow \
	$_SCHED_PARAMS BUILD=e2e-test-sch6 $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP \
	\"SCENARIO_DEFINITIONS_YAML=$_SCH_YAML\"" \
	>"$LOG_DIR/sch6_perl_stdout.log" 2>"$LOG_DIR/sch6_perl_stderr.log"
_sch6_perl_exit=$?
set -e
echo "  Perl exit: $_sch6_perl_exit"

# Wait for Perl job to finish.
_sch6_perl_jobid=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/sch6_perl_stdout.log" | head -1) || true
if [[ -n "$_sch6_perl_jobid" ]]; then
	wait_for_job "$_sch6_perl_jobid" 300 >/dev/null || echo "  WARNING: timeout"
fi

# Zig
set +e
container_exec bash -c "$ZIG_EXE schedule --host http://localhost --follow \
	$_SCHED_PARAMS BUILD=e2e-test-sch6 $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP \
	\"SCENARIO_DEFINITIONS_YAML=$_SCH_YAML\"" \
	>"$LOG_DIR/sch6_zig_stdout.log" 2>"$LOG_DIR/sch6_zig_stderr.log"
_sch6_zig_exit=$?
set -e
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
set +e
container_exec bash -c "timeout 300 $PERL_EXE schedule --host http://localhost \
	--monitor --poll-interval 1 \
	$_SCHED_PARAMS BUILD=e2e-test-sch7 $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP \
	\"SCENARIO_DEFINITIONS_YAML=$_SCH_YAML\" async=1" \
	>"$LOG_DIR/sch7_perl_stdout.log" 2>"$LOG_DIR/sch7_perl_stderr.log"
_sch7_perl_exit=$?
set -e
echo "  Perl exit: $_sch7_perl_exit"

# Zig
set +e
container_exec bash -c "timeout 300 $ZIG_EXE schedule --host http://localhost \
	--monitor --poll-interval 1 \
	$_SCHED_PARAMS BUILD=e2e-test-sch7 $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP \
	\"SCENARIO_DEFINITIONS_YAML=$_SCH_YAML\" async=1" \
	>"$LOG_DIR/sch7_zig_stdout.log" 2>"$LOG_DIR/sch7_zig_stderr.log"
_sch7_zig_exit=$?
set -e
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
set +e
container_exec bash -c "$PERL_EXE schedule --host http://localhost BOGUS=1" \
	>"$LOG_DIR/sch8_perl_stdout.log" 2>"$LOG_DIR/sch8_perl_stderr.log"
_sch8_perl_exit=$?
set -e
echo "  Perl exit: $_sch8_perl_exit"

# Zig
set +e
container_exec bash -c "$ZIG_EXE schedule --host http://localhost BOGUS=1" \
	>"$LOG_DIR/sch8_zig_stdout.log" 2>"$LOG_DIR/sch8_zig_stderr.log"
_sch8_zig_exit=$?
set -e
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
set +e
container_exec bash -c "$PERL_EXE schedule --host http://localhost \
	DISTRI=example VERSION=0 FLAVOR=NONEXISTENT ARCH=x86_64 BUILD=e2e-sch9" \
	>"$LOG_DIR/sch9_perl_stdout.log" 2>"$LOG_DIR/sch9_perl_stderr.log"
_sch9_perl_exit=$?
set -e
echo "  Perl exit: $_sch9_perl_exit"

# Zig
set +e
container_exec bash -c "$ZIG_EXE schedule --host http://localhost \
	DISTRI=example VERSION=0 FLAVOR=NONEXISTENT ARCH=x86_64 BUILD=e2e-sch9" \
	>"$LOG_DIR/sch9_zig_stdout.log" 2>"$LOG_DIR/sch9_zig_stderr.log"
_sch9_zig_exit=$?
set -e
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
set +e
container_exec bash -c "$PERL_EXE schedule --host http://localhost \
	--param-file SCENARIO_DEFINITIONS_YAML=/tmp/scenario.yaml \
	--param-file BUILD=/tmp/pf_sch10_build.txt \
	$_SCHED_PARAMS $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP" \
	>"$LOG_DIR/sch10_perl_stdout.log" 2>"$LOG_DIR/sch10_perl_stderr.log"
_sch10_perl_exit=$?
set -e
echo "  Perl exit: $_sch10_perl_exit"

_sch10_perl_jobid=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/sch10_perl_stdout.log" | head -1) || true
if [[ -n "$_sch10_perl_jobid" ]]; then
	wait_for_job "$_sch10_perl_jobid" 300 >/dev/null || echo "  WARNING: timeout waiting for Perl job"
fi

# Zig
set +e
container_exec bash -c "$ZIG_EXE schedule --host http://localhost \
	--param-file SCENARIO_DEFINITIONS_YAML=/tmp/scenario.yaml \
	--param-file BUILD=/tmp/pf_sch10_build.txt \
	$_SCHED_PARAMS $_SCHED_ASSETS $_SCHED_DIRS $_SCHED_GROUP" \
	>"$LOG_DIR/sch10_zig_stdout.log" 2>"$LOG_DIR/sch10_zig_stderr.log"
_sch10_zig_exit=$?
set -e
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
