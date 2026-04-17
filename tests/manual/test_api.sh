#!/bin/bash
# tests/manual/test_api.sh — Manual correctness and performance tests for the
# `api` subcommand of zoqa, run against a real production openQA server.
#
# Purpose:
#   Verify that zoqa behaves correctly for the most common `api` tasks a real
#   user would perform, and report wall-clock timing and peak RSS as a
#   secondary informational output.
#
# Usage:
#   cd <project-root>
#   zig build                           # ensure zig-out/bin/zoqa exists
#   bash tests/manual/test_api.sh       # run the tests
#
# See lib.sh for environment variable overrides and default configuration.
#
# Requirements (on the host):
#   - bash 4+
#   - openqa-cli  (the Perl reference implementation) in PATH
#   - /usr/bin/time (GNU time, for peak RSS measurement — optional)
#   - python3 (for JSON validation)
#   - Network access to the target openQA server
#
# All requests are read-only GETs.  Nothing is created, modified, or deleted
# on the server.

set -euo pipefail

# shellcheck source=lib.sh source-path=SCRIPTDIR
source "$(dirname "$0")/lib.sh"

# =============================================================================
# Cleanup
# =============================================================================

cleanup() {
	rm -f /tmp/_manual_wall.tmp /tmp/_perf_timev_*.txt
	rm -f /tmp/_api_zoqa_verbose.txt /tmp/_api_perl_verbose.txt
}
trap cleanup EXIT

# =============================================================================
# Preflight
# =============================================================================

echo "=== Preflight ==="
echo ""

require_zoqa
require_openqa_cli
detect_gnu_time
require_python3

echo ""
echo "  HOST:   $HOST"
echo "  JOB_ID: $JOB_ID"
echo "  RUNS:   $RUNS"
echo ""

# Connectivity check
echo -n "  Connectivity check (zoqa api --host $HOST jobs/overview)... "
if "$ZOQA" api --host "$HOST" jobs/overview >/dev/null 2>&1; then
	echo "OK"
else
	echo "FAILED"
	echo "FATAL: Cannot reach $HOST.  Check network and host availability."
	exit 1
fi

echo ""

# =============================================================================
# Test runner
# =============================================================================

# run_test [--verbose] LABEL API_ARGS [EXTRA_CHECK ...]
#
# Runs a complete test scenario:
#   1. Correctness checks (exit code, JSON validity, semantic field checks)
#   2. Wall-clock timing (RUNS repetitions each)
#   3. Peak RSS measurement (one run each)
#
# With --verbose: checks HTTP/ status line and body-after-blank-line JSON
# instead of the normal JSON-output checks.
#
# EXTRA_CHECK format: "LABEL|PYTHON_EXPR" applied to the zoqa JSON output.
run_test() {
	local verbose=false
	if [[ "${1:-}" == "--verbose" ]]; then
		verbose=true
		shift
	fi

	local label=$1 api_args=$2
	shift 2
	local extra_checks=("$@")

	_seq=$((_seq + 1))
	local tid="T${_seq}"
	echo "--- $tid: $label ---"

	local zig_cmd="$ZOQA api --host $HOST $api_args"
	local perl_cmd="openqa-cli api --host $HOST $api_args"

	# --- Correctness ---

	if [[ "$verbose" == "true" ]]; then
		# Capture full output including headers
		local zig_rc=0
		$zig_cmd >/tmp/_api_zoqa_verbose.txt 2>/dev/null || zig_rc=$?
		_check "$tid zoqa exit 0" "$zig_rc"

		local perl_rc=0
		$perl_cmd >/tmp/_api_perl_verbose.txt 2>/dev/null || perl_rc=$?
		_check "$tid openqa-cli exit 0" "$perl_rc"

		# Output starts with HTTP/
		local zig_http=1 perl_http=1
		if head -1 /tmp/_api_zoqa_verbose.txt | grep -q '^HTTP/'; then zig_http=0; fi
		if head -1 /tmp/_api_perl_verbose.txt | grep -q '^HTTP/'; then perl_http=0; fi
		_check "$tid zoqa output starts with HTTP/" "$zig_http"
		_check "$tid openqa-cli output starts with HTTP/" "$perl_http"

		# Body after blank line is valid JSON
		local zig_body perl_body
		zig_body=$(sed -n '/^[[:space:]]*$/,$ p' /tmp/_api_zoqa_verbose.txt | tail -n +2)
		perl_body=$(sed -n '/^[[:space:]]*$/,$ p' /tmp/_api_perl_verbose.txt | tail -n +2)

		local zig_json=1 perl_json=1
		if _valid_json "$zig_body"; then zig_json=0; fi
		if _valid_json "$perl_body"; then perl_json=0; fi
		_check "$tid zoqa verbose body is valid JSON" "$zig_json"
		_check "$tid openqa-cli verbose body is valid JSON" "$perl_json"
	else
		# Capture JSON output
		local zig_out zig_rc=0
		zig_out=$($zig_cmd 2>/dev/null) || zig_rc=$?
		_check "$tid zoqa exit 0" "$zig_rc"

		local perl_out perl_rc=0
		perl_out=$($perl_cmd 2>/dev/null) || perl_rc=$?
		_check "$tid openqa-cli exit 0" "$perl_rc"

		# JSON validity
		local zig_json=1 perl_json=1
		if _valid_json "$zig_out"; then zig_json=0; fi
		if _valid_json "$perl_out"; then perl_json=0; fi
		_check "$tid zoqa output is valid JSON" "$zig_json"
		_check "$tid openqa-cli output is valid JSON" "$perl_json"

		# Extra semantic checks (applied to zoqa output)
		if [[ ${#extra_checks[@]} -gt 0 ]]; then
			for chk in "${extra_checks[@]}"; do
				local chk_label="${chk%%|*}"
				local chk_expr="${chk#*|}"
				local chk_rc=1
				if _json_field "$zig_out" "$chk_expr"; then chk_rc=0; fi
				_check "$tid $chk_label" "$chk_rc"
			done
		fi
	fi

	# --- Timing ---
	echo "    Timing ($RUNS runs each)..."
	_run_timing "$tid  $label" "$zig_cmd" "$perl_cmd" "$RUNS"

	# --- RSS ---
	if [[ "$HAS_GNU_TIME" == "true" ]]; then
		echo "    RSS measurement..."
		_run_rss "$tid  $label" "$zig_cmd" "$perl_cmd"
	fi

	echo ""
}

# =============================================================================
# Test Scenarios
# =============================================================================

echo "=== Test Scenarios ==="
echo ""

# T1: jobs/overview — "Are there running jobs right now?"
# The most common dashboard-style query.
run_test \
	"jobs/overview — list running jobs" \
	"jobs/overview" \
	"zoqa returns a list|isinstance(d, list)"

# T2: jobs/$JOB_ID — "What is the status of this job?"
# Single-resource lookup, the most common per-job query.
run_test \
	"jobs/$JOB_ID — single job status" \
	"jobs/$JOB_ID" \
	"zoqa .job.id matches|d.get('job', {}).get('id') == $JOB_ID"

# T3: jobs/$JOB_ID/details — "What tests ran and what were their results?"
# Large response body; exercises JSON decode throughput.
run_test \
	"jobs/$JOB_ID/details — full job details (large body)" \
	"jobs/$JOB_ID/details" \
	"zoqa .job.testresults present|'testresults' in d.get('job', {})"

# T4: jobs id=$JOB_ID — filter job list by KEY=VALUE query param
# Tests query-string construction (GET + positional KEY=VALUE).
# Note: GET /api/v1/jobs?id=N returns the full jobs table (id= is a lower
# bound, not an exact filter), so no semantic field check is meaningful here.
# The test verifies query-string construction via exit 0 + valid JSON.
run_test \
	"jobs id=$JOB_ID — query-param filter" \
	"jobs id=$JOB_ID"

# T5: jobs limit=5 — "Show me the 5 most recent jobs"
# Tests query-param handling and verifies server respects the limit.
run_test \
	"jobs limit=5 — limited job list" \
	"jobs limit=5" \
	"zoqa .jobs has <= 5 entries|len(d.get('jobs', [])) <= 5"

# T6: --pretty jobs/$JOB_ID — human-readable JSON output
# Tests the --pretty flag (JSON parse + re-indent).
run_test \
	"--pretty jobs/$JOB_ID — pretty-printed output" \
	"--pretty jobs/$JOB_ID" \
	"zoqa .job.id matches|d.get('job', {}).get('id') == $JOB_ID"

# T7: --verbose jobs/$JOB_ID — header inspection
# Tests verbose mode: HTTP status line + headers printed before the body.
run_test --verbose \
	"--verbose jobs/$JOB_ID — verbose with headers" \
	"--verbose jobs/$JOB_ID"

# =============================================================================
# Summary
# =============================================================================

echo "=========================================="
echo "=== Summary ==="
echo "=========================================="
echo ""
echo "PASS: $PASS   FAIL: $FAIL"
echo ""

echo "--- Timing (wall-clock, $RUNS runs each) ---"
for line in "${_timing_report[@]}"; do echo "$line"; done

if [[ "$HAS_GNU_TIME" == "true" ]]; then
	echo "--- RSS & Process Metrics ---"
	for line in "${_rss_report[@]}"; do echo "$line"; done
fi

# Exit with non-zero if any test failed.
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
