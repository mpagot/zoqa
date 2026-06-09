#!/usr/bin/env bash
# lib.sh — Shared library for openQA E2E test scripts.
#
# Source this file near the top of each script (after set -eo pipefail):
#
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
#
# Provides (directly):
#   CONTAINER_NAME  — default container name (overridable before sourcing)
#   COLLECT_LOGS    — default false (overridable before sourcing)
#   DRY_RUN         — default false (set before sourcing or via --dryrun parsing)
#   ENV_FILE        — path to the shell env file written by setup.sh
#   LOG_PREFIX      — prefix used by die() and log(); set before sourcing, e.g. "setup"
#   log()           — echo "[LOG_PREFIX] $*" to stdout
#   run_cmd()       — eval a command string, or print it in dry-run mode
#   container_exec()— run a command inside the container, or print it in dry-run mode
#   die()           — print a prefixed error to stderr and exit 1
#   cd_to_project_root() — cd to the project root; pass "${BASH_SOURCE[0]}" of the caller
#
# Auto-sourced from lib_fixtures.sh (job management):
#   schedule_job()  — POST /api/v1/isos, prints job ID
#   wait_for_job()  — poll until terminal state, prints state
#   cancel_job()    — POST cancel for a job
#   get_job_state() — query and print a job's state
#   _ensure_job()       — generic lazy-init for any named job variable
#   _E2E_JOB_COMMON_ARGS — shared schedule_job args (DISTRI/FLAVOR/ARCH/…)
#   dump_job_logs()     — fetch and print per-job diagnostics on failure
#   register_deletable_asset() — create a file-backed asset, prints asset ID
#
# Sourced on demand from lib_topology.sh (topology fixtures — tests_clone_job.sh only):
#   schedule_topology_jobs() — generic multi-job topology scheduler
#   ensure_chained_jobs()    — lazy-init CHAIN_*_ID variables
#   ensure_fanout_jobs()     — lazy-init FANOUT_*_ID variables
#   ensure_multilayer_jobs() — lazy-init LAYER_*_ID variables
#   ensure_diamond_jobs()    — lazy-init DIAMOND_*_ID variables
#   ensure_parallel_jobs()   — lazy-init PARALLEL_*_ID variables
#   assert_job_has_chained_parent() — verify chained dependency
#
# Performance helpers:
#   _perf_wall_time_s()  — measure wall-clock time of a container command
#   _perf_peak_rss_kb()  — measure peak RSS via /usr/bin/time -v
#   _perf_timev_field()  — read a field from the saved /usr/bin/time -v output
#
# Test-side capture helpers:
#   run_capture()        — run one command, capture stdout/stderr/exit
#   run_perl_and_zig()   — run the same args against PERL_EXE and ZIG_EXE
#   run_capture_both()   — like run_perl_and_zig but with explicit full commands
#   run_sigpipe_test()   — run CMD | head -c 1, capture CMD's exit via PIPESTATUS
#   assert_capture_exits() — check _PERL_EXIT/_ZIG_EXIT, PASS/FAIL
#   assert_stdout_pattern() — check both impl stdout logs for a pattern, PASS/FAIL
#
# Test runner functions (the canonical home of these; tests.sh sources lib.sh):
#   run_test()           — run one command, check exit + optional grep, PASS/FAIL
#   run_comparison_api()     — run the same api args against PERL_EXE and ZIG_EXE
#   run_diff_test()      — diff stdout of both impls, PASS/FAIL

# Guard against double-sourcing
[[ -n "${_OPENQA_E2E_LIB_LOADED:-}" ]] && return 0
_OPENQA_E2E_LIB_LOADED=1

# ---------------------------------------------------------------------------
# Defaults (callers may override before sourcing)
# ---------------------------------------------------------------------------
: "${CONTAINER_NAME:=openqa-e2e}"
: "${COLLECT_LOGS:=false}"
: "${DRY_RUN:=false}"
: "${ENV_FILE:=/tmp/openqa_e2e_env.sh}"
: "${LOG_PREFIX:=e2e}"

# ---------------------------------------------------------------------------
# CirrOS test image settings (single source of truth)
# ---------------------------------------------------------------------------
CIRROS_VERSION="0.6.3"
CIRROS_ARCH="x86_64"
CIRROS_ORIG="cirros-${CIRROS_VERSION}-${CIRROS_ARCH}-disk.img"
CIRROS_IMG="cirros-${CIRROS_VERSION}-${CIRROS_ARCH}-disk.qcow2"
CIRROS_URL="https://download.cirros-cloud.net/${CIRROS_VERSION}/${CIRROS_ORIG}"
CIRROS_TESTDIR="/var/lib/openqa/share/tests/cirros"
export CIRROS_VERSION CIRROS_ARCH CIRROS_ORIG CIRROS_IMG CIRROS_URL CIRROS_TESTDIR

# ---------------------------------------------------------------------------
# log() — print a prefixed informational message to stdout
#
# Uses $LOG_PREFIX (default: "e2e").
# Usage: log "Container is ready"
# ---------------------------------------------------------------------------
log() { echo "[$LOG_PREFIX] $*"; }

# ---------------------------------------------------------------------------
# run_cmd() — eval a command string, or print it (dry-run)
#
# Usage: run_cmd "podman rm -f $CONTAINER_NAME"
# ---------------------------------------------------------------------------
run_cmd() {
	if [[ "$DRY_RUN" == "true" ]]; then
		echo "[DRY-RUN] $*"
	else
		eval "$*"
	fi
}

# ---------------------------------------------------------------------------
# container_exec() — run a command inside the container, or print it (dry-run)
#
# Usage: container_exec cat /etc/openqa/client.conf
# ---------------------------------------------------------------------------
container_exec() {
	if [[ "$DRY_RUN" == "true" ]]; then
		echo "[DRY-RUN] podman exec $CONTAINER_NAME $*"
	else
		podman exec "$CONTAINER_NAME" "$@"
	fi
}

# ---------------------------------------------------------------------------
# die() — print a prefixed error message to stderr and exit 1
#
# Uses $LOG_PREFIX (default: "e2e").
# Usage: die "Could not read client.conf"
# ---------------------------------------------------------------------------
die() {
	echo "[$LOG_PREFIX] ERROR: $*" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# e2e_sleep SECONDS — sleep unless in dry-run mode
#
# Wrapper around `sleep` that skips the actual delay when DRY_RUN is true.
# Use this instead of bare `sleep` in test scripts so that dry-run completes
# instantly.
# ---------------------------------------------------------------------------
e2e_sleep() {
	if [[ "$DRY_RUN" == "true" ]]; then
		echo "[DRY-RUN] sleep $1 (skipped)"
		return 0
	fi
	sleep "$1"
}

# ---------------------------------------------------------------------------
# cd_to_project_root() — cd to the repository root from a caller's location
#
# Must be called with the caller's BASH_SOURCE[0]:
#   cd_to_project_root "${BASH_SOURCE[0]}"
#
# Assumes scripts live two levels deep under the project root
# (e.g. tests/e2e/setup.sh → project root is ../../).
# ---------------------------------------------------------------------------
cd_to_project_root() {
	local caller_script="$1"
	local caller_dir
	caller_dir="$(cd "$(dirname "$caller_script")" && pwd)"
	cd "$caller_dir/../.." || exit 1
}

# ===========================================================================
# Job Management Functions — extracted to lib_fixtures.sh
#
# Sourced automatically below.  Provides: schedule_job, wait_for_job,
# cancel_job, get_job_state, _ensure_job, ensure_basic_job, ensure_rich_job,
# ensure_stress_job, dump_job_logs, register_deletable_asset,
# _E2E_JOB_COMMON_ARGS.
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_fixtures.sh"

# ===========================================================================
# Performance Helpers
#
# Shared between tests_perf.sh and tests_stress.sh.
# All helpers run commands inside the container via container_exec.
# ===========================================================================

# ---------------------------------------------------------------------------
# _perf_wall_time_s ENV_VARS CMD
#
# Measures the wall-clock execution time of CMD running inside the container.
# ENV_VARS is a string of assignments to prepend (e.g. "VAR=val"), or "".
# Prints the elapsed time in decimal seconds to stdout.
# ---------------------------------------------------------------------------
_perf_wall_time_s() {
	local env_vars=$1
	local cmd=$2
	container_exec bash -c "
TIMEFORMAT='%R'
{ time $env_vars $cmd >/dev/null 2>&1; } 2>/tmp/_perf_wall.out
cat /tmp/_perf_wall.out
" 2>/dev/null
}

# ---------------------------------------------------------------------------
# _perf_peak_rss_kb ENV_VARS CMD [TAG]
#
# Measures peak RSS (kB) of CMD running inside the container via
# /usr/bin/time -v (GNU time, installed in setup.sh).
#
# TAG (optional) overrides the temp-file name used for the saved output.
# When absent, the tag is derived from the first token of CMD.  Use an
# explicit TAG when the same binary is invoked with different roles (e.g.
# "stress_perl" / "stress_zig") so the output files don't collide.
#
# Prints the "Maximum resident set size (kbytes)" value, or "" on failure.
# Also writes the full /usr/bin/time -v output to /tmp/_perf_timev_<tag>.txt
# inside the container so callers can retrieve additional fields.
# ---------------------------------------------------------------------------
_perf_peak_rss_kb() {
	local env_vars=$1
	local cmd=$2
	local tag="${3:-}"

	if [[ "${DRY_RUN:-false}" == "true" ]]; then
		echo "0"
		return
	fi

	# Derive a safe tag from the first token of cmd when not explicitly given.
	if [[ -z "$tag" ]]; then
		tag=$(echo "$cmd" | cut -d' ' -f1 | tr -cs 'a-zA-Z0-9_-' '_')
	fi

	container_exec bash -c \
		"$env_vars /usr/bin/time -v $cmd >/dev/null 2>/tmp/_perf_timev_${tag}.txt" \
		</dev/null 2>/dev/null || true

	container_exec bash -c \
		"grep 'Maximum resident set size' /tmp/_perf_timev_${tag}.txt | cut -d: -f2 | tr -d ' \t'" \
		</dev/null 2>/dev/null
}

# ---------------------------------------------------------------------------
# _perf_timev_field TAG FIELD_PATTERN
#
# Reads a numeric value from the /usr/bin/time -v output file written by a
# previous _perf_peak_rss_kb call.  TAG must match the tag used in that call.
# Returns "" if the file or field is absent.
# ---------------------------------------------------------------------------
_perf_timev_field() {
	local tag=$1
	local field=$2
	container_exec bash -c \
		"grep '$field' /tmp/_perf_timev_${tag}.txt 2>/dev/null | cut -d: -f2 | tr -d ' \t'" \
		</dev/null 2>/dev/null
}

# ===========================================================================
# Test-side capture helpers
#
# Eliminate the boilerplate:
#     set +e
#     container_exec bash -c "<cmd>" >stdout 2>stderr
#     exit_code=$?
#     set -e
#
# Use run_capture for a single command, or run_perl_and_zig when both
# implementations are exercised with the same arguments.
# ===========================================================================

# ---------------------------------------------------------------------------
# run_capture TAG IMPL CMD
#
# Runs CMD inside the container without aborting on non-zero exit.  Captures
# stdout to $LOG_DIR/${TAG}_${IMPL}_stdout.log and stderr to
# $LOG_DIR/${TAG}_${IMPL}_stderr.log.  The command's exit code is left in the
# global _LAST_EXIT for the caller to inspect.
#
# TAG  — short identifier shared across one logical test (e.g. "mon_cancel")
# IMPL — "perl" or "zig" (used in the log filenames; any string is accepted)
# CMD  — the full command line passed to `container_exec bash -c`
#
# Usage:
#   run_capture "mon_cancel" perl "timeout 60 $PERL_EXE monitor $JOB_ID"
#   echo "Perl exit: $_LAST_EXIT"
# ---------------------------------------------------------------------------
run_capture() {
	local tag=$1
	local impl=$2
	local cmd=$3
	set +e
	container_exec bash -c "$cmd" \
		>"$LOG_DIR/${tag}_${impl}_stdout.log" \
		2>"$LOG_DIR/${tag}_${impl}_stderr.log"
	_LAST_EXIT=$?
	set -e
}

# ---------------------------------------------------------------------------
# run_perl_and_zig TAG ARGS [TIMEOUT_S]
#
# Runs the same command tail against both PERL_EXE and ZIG_EXE inside the
# container.  Stores their exit codes in _PERL_EXIT and _ZIG_EXIT, and writes
# the four log files:
#     $LOG_DIR/${TAG}_perl_stdout.log  / _perl_stderr.log
#     $LOG_DIR/${TAG}_zig_stdout.log   / _zig_stderr.log
#
# TAG       — short identifier shared by the perl and zig invocations
# ARGS      — everything that follows the binary name
#             (e.g. "monitor $JOB_ID" or "schedule --host http://localhost …")
# TIMEOUT_S — optional; wraps each invocation in `timeout N`. Omit for none.
#
# Usage:
#   run_perl_and_zig "mon_cancel" "monitor $MONITOR_JOB_ID" 60
#   if [[ "$_PERL_EXIT" -eq 2 && "$_ZIG_EXIT" -eq 2 ]]; then
#       echo "PASS"
#   fi
#
# Note: ARGS is interpolated into a single bash -c command string, so any
# special characters must already be quoted by the caller (same constraint as
# container_exec bash -c "...").
# ---------------------------------------------------------------------------
run_perl_and_zig() {
	local tag=$1
	local args=$2
	local timeout_s=${3:-}
	local prefix=""
	[[ -n "$timeout_s" ]] && prefix="timeout $timeout_s "

	run_capture "$tag" perl "${prefix}${PERL_EXE} ${args}"
	_PERL_EXIT=$_LAST_EXIT
	run_capture "$tag" zig  "${prefix}${ZIG_EXE} ${args}"
	_ZIG_EXIT=$_LAST_EXIT
}

# ---------------------------------------------------------------------------
# run_sigpipe_test TAG IMPL CMD
#
# Tests that CMD survives a broken pipe (SIGPIPE / EPIPE) without crashing.
#
# Runs  CMD | head -c 1  inside the container and captures CMD's own exit
# code — not head's — via bash PIPESTATUS[0].  This is critical: without
# PIPESTATUS the pipeline would always return head's exit code (0),
# silently masking a SIGPIPE crash in CMD (exit 141) or an unhandled EPIPE
# propagation (exit 1).
#
# Stdout/stderr are captured to $LOG_DIR/${TAG}_${IMPL}_{stdout,stderr}.log.
# The exit code is left in _LAST_EXIT.
#
# Usage:
#   run_sigpipe_test "bp" perl "$PERL_EXE api --host http://localhost jobs/overview"
#   _PERL_EXIT=$_LAST_EXIT
#   run_sigpipe_test "bp" zig  "$ZIG_EXE api --host http://localhost jobs/overview"
#   _ZIG_EXIT=$_LAST_EXIT
# ---------------------------------------------------------------------------
run_sigpipe_test() {
	local tag=$1
	local impl=$2
	local cmd=$3
	set +e
	container_exec bash -c \
		"$cmd | head -c 1; exit \${PIPESTATUS[0]}" \
		>"$LOG_DIR/${tag}_${impl}_stdout.log" \
		2>"$LOG_DIR/${tag}_${impl}_stderr.log"
	_LAST_EXIT=$?
	set -e
}

# ---------------------------------------------------------------------------
# run_capture_both TAG PERL_CMD ZIG_CMD
#
# Runs PERL_CMD and ZIG_CMD via run_capture (IMPL=perl, then IMPL=zig).
# Stores exit codes in _PERL_EXIT and _ZIG_EXIT respectively.
#
# Analogous to run_perl_and_zig but accepts explicit full command strings
# instead of building them from the global PERL_EXE/ZIG_EXE with shared args.
# Use this when the two implementations differ in binary path or flag spelling.
#
# Usage:
#   run_capture_both "clone12" \
#       "$PERL_CLONE_EXE --within-instance http://localhost $JOB_ID" \
#       "$ZIG_CLONE_EXE --within-instance http://localhost $JOB_ID"
#   # exits now in _PERL_EXIT and _ZIG_EXIT
# ---------------------------------------------------------------------------
run_capture_both() {
	local tag=$1
	local perl_cmd=$2
	local zig_cmd=$3
	run_capture "$tag" perl "$perl_cmd"
	_PERL_EXIT=$_LAST_EXIT
	run_capture "$tag" zig "$zig_cmd"
	_ZIG_EXIT=$_LAST_EXIT
}

# ---------------------------------------------------------------------------
# assert_capture_exits TAG [EXPECTED_EXIT]
#
# Asserts that _PERL_EXIT and _ZIG_EXIT (set by run_capture_both, or set
# manually after individual run_capture calls) both equal EXPECTED_EXIT
# (default: 0).
#
# On failure: prints the failing impl's stderr log and increments failed_tests.
# On success: prints "PASS".
#
# When the two captures are interleaved with waits (e.g. single-worker jobs),
# set _PERL_EXIT and _ZIG_EXIT directly after each run_capture call and then
# call this function once at the end.
#
# Usage:
#   run_capture_both "clone12" "$PERL_CMD" "$ZIG_CMD"
#   assert_capture_exits "clone12" 0
# ---------------------------------------------------------------------------
assert_capture_exits() {
	local tag=$1
	local expected_exit=${2:-0}
	local pass=true
	if [[ "$_PERL_EXIT" -ne "$expected_exit" ]]; then
		echo "  FAIL: Perl exited $_PERL_EXIT (expected $expected_exit)"
		cat "$LOG_DIR/${tag}_perl_stderr.log"
		pass=false
	fi
	if [[ "$_ZIG_EXIT" -ne "$expected_exit" ]]; then
		echo "  FAIL: Zig exited $_ZIG_EXIT (expected $expected_exit)"
		cat "$LOG_DIR/${tag}_zig_stderr.log"
		pass=false
	fi
	if [[ "$pass" == "true" ]]; then
		echo "PASS"
	else
		failed_tests=$((failed_tests + 1))
	fi
}

# ---------------------------------------------------------------------------
# assert_stdout_pattern TAG PATTERN
#
# Checks that the stdout log for both perl and zig (written by a prior
# run_capture or run_capture_both call with the same TAG) match PATTERN via
# grep -qE.  Prints "PASS" if both match; on failure, prints the failing
# impl's stdout log and increments failed_tests.
#
# Usage:
#   assert_stdout_pattern "clone12" "has been created"
#   assert_stdout_pattern "clone12" 'http://localhost/tests/[0-9]+'
# ---------------------------------------------------------------------------
assert_stdout_pattern() {
	local tag=$1
	local pattern=$2
	local pass=true
	local _impl
	for _impl in perl zig; do
		if ! grep -qE "$pattern" "$LOG_DIR/${tag}_${_impl}_stdout.log" 2>/dev/null; then
			echo "  FAIL: $_impl stdout missing pattern '$pattern'"
			cat "$LOG_DIR/${tag}_${_impl}_stdout.log"
			pass=false
		fi
	done
	if [[ "$pass" == "true" ]]; then
		echo "PASS"
	else
		failed_tests=$((failed_tests + 1))
	fi
}

# ===========================================================================
# Test Runner Functions
#
# These were previously defined inline in tests.sh.  They live here so that
# lib.sh is the single, authoritative home for all shared test helpers.
# tests.sh sources lib.sh and then sources the per-domain suite files.
# ===========================================================================

# ---------------------------------------------------------------------------
# run_test LABEL CMD [EXPECTED_EXIT [GREP_PATTERN]]
#
# Runs CMD inside the container, checks the exit code, and optionally greps
# the combined stdout+stderr output for GREP_PATTERN.
#
# Parameters:
#   LABEL         — human-readable test name printed in the --- Test: --- line
#   CMD           — command string passed to container_exec (eval'd)
#   EXPECTED_EXIT — expected exit code (default: 0)
#   GREP_PATTERN  — optional grep pattern; FAIL if not found in output
#
# Side effects: increments failed_tests on failure.
# ---------------------------------------------------------------------------
run_test() {
	local label=$1
	local cmd=$2
	local expected_exit=${3:-0}
	local grep_pattern=$4

	echo "--- Test: $label ---"
	echo "Command: $cmd"

	set +e
	eval "container_exec $cmd" >"$LOG_DIR/test_output.log" 2>&1
	local exit_code=$?
	set -e

	echo "Exit code: $exit_code"

	if [[ "$exit_code" -ne "$expected_exit" ]]; then
		echo "FAIL: Expected exit code $expected_exit, got $exit_code"
		cat "$LOG_DIR/test_output.log"
		failed_tests=$((failed_tests + 1))
		return
	fi

	if [[ -n "$grep_pattern" ]]; then
		if ! grep -q "$grep_pattern" "$LOG_DIR/test_output.log"; then
			echo "FAIL: Output did not match pattern '$grep_pattern'"
			cat "$LOG_DIR/test_output.log"
			failed_tests=$((failed_tests + 1))
			return
		fi
	fi

	echo "PASS"
}

# ---------------------------------------------------------------------------
# run_comparison_api LABEL ENV_VARS API_ARGS [EXPECTED_EXIT [GREP_PATTERN]]
#
# Runs the same API call against both the Perl reference implementation and
# the Zig implementation, checking each one independently.  A test PASSES
# when both implementations satisfy the exit-code and grep-pattern criteria;
# each can fail independently, producing a separate FAIL line.
#
# This is the right helper when you care about whether each implementation
# behaves correctly in isolation (correct exit code, correct output pattern),
# but do NOT require the two outputs to be identical.  Use run_diff_test when
# you want to assert byte-for-byte output parity (modulo trailing newlines).
#
# Parameters:
#   LABEL         — human-readable test name (prefixed with PERL:/ZIG: automatically)
#   ENV_VARS      — space-separated env-var assignments prepended to the command
#                   (e.g. "OPENQA_CONFIG=/tmp"); pass "" for none
#   API_ARGS      — arguments passed after `api --host http://localhost`
#   EXPECTED_EXIT — expected exit code for both impls (default: 0)
#   GREP_PATTERN  — optional grep pattern checked against combined stdout+stderr
#
# Side effects: increments failed_tests once per implementation that fails.
# ---------------------------------------------------------------------------
run_comparison_api() {
	local label=$1
	local env_vars=$2
	local api_args=$3
	local expected_exit=${4:-0}
	local grep_pattern=$5

	run_test "PERL: $label" \
		"bash -c \"$env_vars $PERL_EXE api --host http://localhost $api_args\"" \
		"$expected_exit" "$grep_pattern"
	run_test "ZIG : $label" \
		"bash -c \"$env_vars $ZIG_EXE api --host http://localhost $api_args\"" \
		"$expected_exit" "$grep_pattern"
}

# ---------------------------------------------------------------------------
# run_diff_test LABEL API_ARGS
#
# Runs the same API call against both implementations and asserts that their
# stdout output is identical (after trailing-newline normalisation).  stderr is
# discarded from both sides to avoid noise from ANSI colour codes, Mojo
# warnings, and the BoltDB deprecation warning emitted by podman on some hosts.
#
# Use this helper when you want to detect regressions in the Zig output format
# relative to the Perl reference — i.e., "both must produce the same body".
# For exit-code or pattern checks use run_comparison_api instead.
#
# Parameters:
#   LABEL    — human-readable test name printed in the --- Test: DIFF --- line
#   API_ARGS — arguments passed after `api --host http://localhost`
#
# Side effects: increments failed_tests on mismatch.
# ---------------------------------------------------------------------------
run_diff_test() {
	local label=$1
	local api_args=$2

	echo "--- Test: DIFF $label ---"

	set +e
	container_exec bash -c "$PERL_EXE api --host http://localhost $api_args" \
		>"$LOG_DIR/test_output_perl.log" 2>/dev/null
	container_exec bash -c "$ZIG_EXE api --host http://localhost $api_args" \
		>"$LOG_DIR/test_output_zig.log" 2>/dev/null
	set -e

	# Normalise: strip all trailing newlines then add exactly one.
	{ printf '%s\n' "$(cat "$LOG_DIR/test_output_perl.log")"; } >"$LOG_DIR/test_output_perl_norm.log"
	{ printf '%s\n' "$(cat "$LOG_DIR/test_output_zig.log")"; } >"$LOG_DIR/test_output_zig_norm.log"

	if diff -u "$LOG_DIR/test_output_perl_norm.log" "$LOG_DIR/test_output_zig_norm.log" \
		>"$LOG_DIR/test_output_diff.log" 2>&1; then
		echo "PASS (outputs identical)"
	else
		echo "FAIL: Perl and Zig outputs differ:"
		cat "$LOG_DIR/test_output_diff.log"
		failed_tests=$((failed_tests + 1))
	fi
}

# ===========================================================================
# Audit Log Helpers
#
# Query the openQA admin audit log from the host side.  All helpers require
# an active session cookie inside the container; call audit_login once at
# the start of the test suite.
# ===========================================================================

# Container-side cookie jar used by audit helpers.
_AUDIT_COOKIE_JAR="/tmp/e2e_audit_cookies.txt"

# ---------------------------------------------------------------------------
# audit_login — Authenticate as the Demo user inside the container.
#
# Creates a session cookie at $_AUDIT_COOKIE_JAR that subsequent audit_*
# helpers reuse.  Safe to call multiple times (overwrites the cookie).
# ---------------------------------------------------------------------------
audit_login() {
	container_exec bash -c \
		"curl -s -c $_AUDIT_COOKIE_JAR -b $_AUDIT_COOKIE_JAR 'http://localhost/login?user=Demo' >/dev/null"
}

# ---------------------------------------------------------------------------
# audit_max_id — Print the highest audit event ID currently in the log.
#
# Returns "0" if the log is empty.
# ---------------------------------------------------------------------------
audit_max_id() {
	container_exec bash -c \
		"curl -s -g -b $_AUDIT_COOKIE_JAR 'http://localhost/admin/auditlog/ajax?order%5B0%5D%5Bcolumn%5D=0&order%5B0%5D%5Bdir%5D=desc&length=1' | jq -r '.data[0].id // 0'"
}

# ---------------------------------------------------------------------------
# audit_events_since SINCE_ID [EVENT_FILTER]
#
# Print audit events with id > SINCE_ID.  Each line is JSON with keys:
# id, event, event_data, event_time, user.
#
# EVENT_FILTER (optional): when provided, only events whose .event field
# equals this string are returned (e.g. "iso_create").
#
# Output: one JSON object per line, or empty if no matching events.
# ---------------------------------------------------------------------------
audit_events_since() {
	local since_id="$1"
	local event_filter="${2:-}"
	local jq_filter

	if [[ -n "$event_filter" ]]; then
		jq_filter=".data[] | select(.id > $since_id and .event == \"$event_filter\")"
	else
		jq_filter=".data[] | select(.id > $since_id)"
	fi

	container_exec bash -c \
		"curl -s -g -b $_AUDIT_COOKIE_JAR 'http://localhost/admin/auditlog/ajax?order%5B0%5D%5Bcolumn%5D=0&order%5B0%5D%5Bdir%5D=asc&length=100' | jq -c '$jq_filter'"
}

# ---------------------------------------------------------------------------
# audit_count_since SINCE_ID [EVENT_FILTER]
#
# Print the count of audit events with id > SINCE_ID.  Accepts the same
# optional EVENT_FILTER as audit_events_since.
# ---------------------------------------------------------------------------
audit_count_since() {
	local since_id="$1"
	local event_filter="${2:-}"
	local jq_filter

	if [[ -n "$event_filter" ]]; then
		jq_filter="[.data[] | select(.id > $since_id and .event == \"$event_filter\")] | length"
	else
		jq_filter="[.data[] | select(.id > $since_id)] | length"
	fi

	container_exec bash -c \
		"curl -s -g -b $_AUDIT_COOKIE_JAR 'http://localhost/admin/auditlog/ajax?order%5B0%5D%5Bcolumn%5D=0&order%5B0%5D%5Bdir%5D=asc&length=100' | jq -r '$jq_filter'"
}
