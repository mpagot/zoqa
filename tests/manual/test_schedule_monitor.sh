#!/bin/bash
# tests/manual/test_schedule_monitor.sh — Manual correctness and performance
# tests for the `schedule` and `monitor` subcommands of zoqa, run against a
# real production openQA server.
#
# ┌──────────────────────────────────────────────────────────────────────────┐
# │  WRITE ACCESS REQUIRED                                                  │
# │                                                                         │
# │  This script creates jobs via `isos POST`.  Credentials must come from  │
# │  ~/.config/openqa/client.conf or the OPENQA_API_KEY / OPENQA_API_SECRET │
# │  environment variables.  --apikey / --apisecret CLI flags are NEVER     │
# │  used.                                                                  │
# │                                                                         │
# │  POST justification: `schedule` is the primary write subcommand of      │
# │  zoqa; it cannot be tested without creating jobs.  Jobs are constrained │
# │  to a single TEST suite + unique BUILD tag so the blast radius is       │
# │  minimal.                                                               │
# └──────────────────────────────────────────────────────────────────────────┘
#
# Purpose:
#   Verify that zoqa schedule, monitor, and schedule --monitor behave
#   correctly compared to openqa-cli, and report wall-clock timing and peak
#   RSS as secondary informational output.
#
# Usage:
#   cd <project-root>
#   zig build                                         # ensure zig-out/bin/zoqa exists
#   bash tests/manual/test_schedule_monitor.sh             # live run
#   bash tests/manual/test_schedule_monitor.sh --dry-run   # no server contact
#
# --dry-run mode:
#   Prints every command the script would execute without issuing any mutating
#   request.  Auto-discovery (a read-only GET) still runs normally so that the
#   resolved parameters are accurate.  Schedule and monitor calls print a
#   placeholder and are skipped entirely.  No _check calls are emitted (summary
#   shows PASS:0 FAIL:0).
#
# How scheduling works:
#   The script triggers job creation via `zoqa schedule` / `openqa-cli schedule`,
#   which calls the openQA `POST /api/v1/isos` endpoint.  That endpoint matches
#   the supplied parameters against job templates registered in the server; a
#   matching template must exist in the target group for any jobs to be created.
#
#   By default all parameters are auto-discovered by querying GET jobs/$OPENQA_JOB_ID
#   (the reference job from lib.sh): DISTRI, VERSION, FLAVOR, ARCH,
#   and TEST are read from that job's settings, and GROUP_ID from its group.  No
#   manual preparation is required unless you want to override the target.
#
# Notes on scheduling tricks NOT used here:
#   - _GROUP_ID=0  would match all groups and produce zero jobs (no template match),
#     so this script always passes the real group ID discovered from the reference job.
#   - _GROUP=<name> selects a group by name pattern and is unnecessary here because
#     we already have the numeric ID.
#
# Server prerequisites:
#   - The DISTRI/VERSION/FLAVOR/ARCH/TEST combination must match an existing job
#     template in the target group.  If the reference job still exists and
#     its template is still active, no extra preparation is needed.
#
# What is left on the server after this script:
#   Up to 4 new jobs (2 from Phase 1, 2 from Phase 3) will appear in the job
#   history tagged with BUILD=<OPENQA_BUILD>.  They are real jobs and are NOT
#   cleaned up automatically.
#
# Environment variable overrides (in addition to those in lib.sh):
#   OPENQA_DISTRI    — DISTRI scheduling param    (auto-discovered from reference job)
#   OPENQA_VERSION   — VERSION scheduling param   (auto-discovered from reference job)
#   OPENQA_FLAVOR    — FLAVOR scheduling param    (auto-discovered from reference job)
#   OPENQA_ARCH      — ARCH scheduling param      (auto-discovered from reference job)
#   OPENQA_GROUP_ID  — job group ID               (auto-discovered from reference job)
#   OPENQA_TEST      — TEST suite name            (auto-discovered from reference job)
#   OPENQA_BUILD     — BUILD tag for created jobs (default: zoqa_VR_manual_test)
#
# See lib.sh for: OPENQA_HOST, OPENQA_JOB_ID, ZOQA, RUNS.
#
# Requirements (on the host):
#   - bash 4+
#   - openqa-cli  (the Perl reference implementation) in PATH
#   - /usr/bin/time (GNU time, for peak RSS measurement — optional)
#   - python3 (for JSON extraction)
#   - Network access to the target openQA server
#   - Valid API credentials (config file or env vars)

set -euo pipefail

# shellcheck source=lib.sh source-path=SCRIPTDIR
source "$(dirname "$0")/lib.sh"

# =============================================================================
# Dryrun support
# =============================================================================

DRYRUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
	DRYRUN=1
	shift
fi

# _run CMD...
#
# In live mode, executes the command.  In dryrun mode, prints the command
# prefixed with [dryrun] and returns 0.
_run() {
	if [[ "$DRYRUN" == "1" ]]; then
		echo "  [dryrun] \$ $*"
		return 0
	fi
	"$@"
}

# _run_capture VARNAME CMD...
#
# In live mode, captures stdout of the command into the named variable.
# In dryrun mode, prints the command and sets the variable to "".
_run_capture() {
	local _varname=$1
	shift
	if [[ "$DRYRUN" == "1" ]]; then
		echo "  [dryrun] \$ $*"
		printf -v "$_varname" ""
		return 0
	fi
	local _output
	_output=$("$@")
	printf -v "$_varname" "%s" "$_output"
}

# _indent TEXT
#
# Prints each line of TEXT prefixed with four spaces.
_indent() {
	local line
	while IFS= read -r line; do
		echo "    $line"
	done <<<"$1"
}

# =============================================================================
# Scheduling parameter defaults
# =============================================================================

BUILD="${OPENQA_BUILD:-zoqa_VR_manual_test}"
DISTRI="${OPENQA_DISTRI:-}"
VERSION="${OPENQA_VERSION:-}"
FLAVOR="${OPENQA_FLAVOR:-}"
ARCH="${OPENQA_ARCH:-}"
GROUP_ID="${OPENQA_GROUP_ID:-}"
TEST_NAME="${OPENQA_TEST:-}"

# =============================================================================
# Cleanup
# =============================================================================

cleanup() {
	rm -f /tmp/_schedule_*.txt /tmp/_manual_wall.tmp /tmp/_perf_timev_*.txt
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

# ---- Auto-discovery ----
# Query the reference job to discover scheduling parameters.
# This is a read-only GET request, safe to run in --dry-run mode.
if [[ -z "$DISTRI" || -z "$VERSION" || -z "$FLAVOR" || -z "$ARCH" || -z "$GROUP_ID" || -z "$TEST_NAME" ]]; then
	echo "  Auto-discovering scheduling params from jobs/$JOB_ID ..."
	local_job_json=""
	local_job_json=$("$ZOQA" api --host "$HOST" "jobs/$JOB_ID" 2>/dev/null)

	if [[ -z "$local_job_json" ]]; then
		echo "  FATAL: Could not fetch jobs/$JOB_ID from $HOST."
		exit 1
	fi

	# Extract fields with python3
	_extract_field() {
		echo "$local_job_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
$1
" 2>/dev/null
	}

	[[ -z "$DISTRI" ]] && DISTRI=$(_extract_field "print(d['job']['settings']['DISTRI'])")
	[[ -z "$VERSION" ]] && VERSION=$(_extract_field "print(d['job']['settings']['VERSION'])")
	[[ -z "$FLAVOR" ]] && FLAVOR=$(_extract_field "print(d['job']['settings']['FLAVOR'])")
	[[ -z "$ARCH" ]] && ARCH=$(_extract_field "print(d['job']['settings']['ARCH'])")
	[[ -z "$GROUP_ID" ]] && GROUP_ID=$(_extract_field "print(d['job']['group_id'])")
	[[ -z "$TEST_NAME" ]] && TEST_NAME=$(_extract_field "print(d['job']['test'])")

	echo "  Auto-discovery complete."
else
	echo "  All scheduling params provided via env vars; skipping auto-discovery."
fi

echo ""

# ---- Connectivity check ----
if [[ "$DRYRUN" == "0" ]]; then
	echo -n "  Connectivity check (zoqa api --host $HOST jobs/overview)... "
	if "$ZOQA" api --host "$HOST" jobs/overview >/dev/null 2>&1; then
		echo "OK"
	else
		echo "FAILED"
		echo "  FATAL: Cannot reach $HOST.  Check network and host availability."
		exit 1
	fi
else
	echo "  [dryrun] Skipping connectivity check"
fi

echo ""

# ---- Print resolved parameters ----
echo "  HOST:       $HOST"
echo "  JOB_ID:     $JOB_ID (reference job)"
echo "  DISTRI:     $DISTRI"
echo "  VERSION:    $VERSION"
echo "  FLAVOR:     $FLAVOR"
echo "  ARCH:       $ARCH"
echo "  GROUP_ID:   $GROUP_ID"
echo "  TEST_NAME:  $TEST_NAME"
echo "  BUILD:      $BUILD"
echo "  RUNS:       $RUNS"
echo "  DRYRUN:     $DRYRUN"
echo ""

# Common scheduling params (array — each KEY=VALUE is a separate element).
SCHED_PARAMS=(
	"DISTRI=$DISTRI"
	"VERSION=$VERSION"
	"FLAVOR=$FLAVOR"
	"ARCH=$ARCH"
	"TEST=$TEST_NAME"
	"_GROUP_ID=$GROUP_ID"
	"BUILD=$BUILD"
)

# =============================================================================
# Phase 1 — schedule (no --monitor)
# =============================================================================

echo "=== Phase 1: schedule (no --monitor) ==="
echo ""
echo "  Scheduling one job each (zoqa + openqa-cli) ..."
echo "  Params: ${SCHED_PARAMS[*]}"
echo ""

ZIG_JOB_IDS=""
PERL_JOB_IDS=""

zig_sched_time_ms=0
perl_sched_time_ms=0

# -- zoqa schedule --
if [[ "$DRYRUN" == "0" ]]; then
	zig_sched_out=""
	zig_sched_rc=0

	t_start=$(date +%s%3N)
	zig_sched_out=$("$ZOQA" schedule --host "$HOST" "${SCHED_PARAMS[@]}" 2>/dev/null) || zig_sched_rc=$?
	t_end=$(date +%s%3N)
	zig_sched_time_ms=$((t_end - t_start))

	echo "  zoqa schedule output:"
	_indent "$zig_sched_out"
	echo ""

	_check "P1 zoqa schedule exit 0" "$zig_sched_rc"

	# Check stdout mentions job creation
	p1_zig_created=1
	if echo "$zig_sched_out" | grep -qi 'have been created\|has been created'; then p1_zig_created=0; fi
	_check "P1 zoqa stdout mentions job creation" "$p1_zig_created"

	p1_zig_url=1
	if echo "$zig_sched_out" | grep -q ' - http'; then p1_zig_url=0; fi
	_check "P1 zoqa stdout contains job URL" "$p1_zig_url"

	# Extract job IDs
	ZIG_JOB_IDS=$(echo "$zig_sched_out" | grep -oP '(?<=/tests/)\d+' || true)
	echo "  zoqa scheduled job IDs: ${ZIG_JOB_IDS:-<none>}"
else
	echo "  [dryrun] \$ $ZOQA schedule --host $HOST ${SCHED_PARAMS[*]}"
fi

echo ""

# -- openqa-cli schedule --
if [[ "$DRYRUN" == "0" ]]; then
	perl_sched_out=""
	perl_sched_rc=0

	t_start=$(date +%s%3N)
	perl_sched_out=$(openqa-cli schedule --host "$HOST" "${SCHED_PARAMS[@]}" 2>/dev/null) || perl_sched_rc=$?
	t_end=$(date +%s%3N)
	perl_sched_time_ms=$((t_end - t_start))

	echo "  openqa-cli schedule output:"
	_indent "$perl_sched_out"
	echo ""

	_check "P1 openqa-cli schedule exit 0" "$perl_sched_rc"

	p1_perl_created=1
	if echo "$perl_sched_out" | grep -qi 'have been created\|has been created'; then p1_perl_created=0; fi
	_check "P1 openqa-cli stdout mentions job creation" "$p1_perl_created"

	p1_perl_url=1
	if echo "$perl_sched_out" | grep -q ' - http'; then p1_perl_url=0; fi
	_check "P1 openqa-cli stdout contains job URL" "$p1_perl_url"

	PERL_JOB_IDS=$(echo "$perl_sched_out" | grep -oP '(?<=/tests/)\d+' || true)
	echo "  openqa-cli scheduled job IDs: ${PERL_JOB_IDS:-<none>}"
else
	echo "  [dryrun] \$ openqa-cli schedule --host $HOST ${SCHED_PARAMS[*]}"
fi

echo ""

# -- Phase 1 timing (single-run, manual entry) --
if [[ "$DRYRUN" == "0" ]]; then
	zig_sched_sec=$(awk "BEGIN { printf \"%.3f\", $zig_sched_time_ms / 1000 }")
	perl_sched_sec=$(awk "BEGIN { printf \"%.3f\", $perl_sched_time_ms / 1000 }")

	_timing_report+=("P1  schedule (no --monitor)")
	_timing_report+=("  ZIG  ${zig_sched_sec}s  (single run)")
	_timing_report+=("  PERL ${perl_sched_sec}s  (single run)")
	_timing_report+=("")
fi

# =============================================================================
# Phase 2a — monitor (blocking, wait for scheduled jobs)
# =============================================================================

echo "=== Phase 2a: monitor (blocking — wait for jobs to finish) ==="
echo ""

if [[ "$DRYRUN" == "1" ]]; then
	echo "  [dryrun] \$ $ZOQA monitor --host $HOST <ZOQA_JOB_IDS>"
	echo "  [dryrun] \$ openqa-cli monitor --host $HOST <PERL_JOB_IDS>"
else
	# -- Monitor zoqa-scheduled jobs --
	if [[ -n "$ZIG_JOB_IDS" ]]; then
		echo "  Monitoring zoqa-scheduled jobs: $ZIG_JOB_IDS"
		echo "  (This blocks until all jobs finish.  Ctrl+C to abort.)"
		echo ""

		zig_mon_rc=0
		# shellcheck disable=SC2086
		"$ZOQA" monitor --host "$HOST" $ZIG_JOB_IDS || zig_mon_rc=$?

		# Exit 0 = all passed; exit 2 = some failed/incomplete; exit 1 = error
		if [[ "$zig_mon_rc" -le 2 ]]; then
			_check "P2a zoqa monitor exit acceptable (0 or 2)" 0
		else
			_check "P2a zoqa monitor exit acceptable (0 or 2)" 1
		fi
	else
		echo "  Skipping zoqa monitor — no jobs were scheduled in Phase 1."
	fi

	echo ""

	# -- Monitor openqa-cli-scheduled jobs --
	if [[ -n "$PERL_JOB_IDS" ]]; then
		echo "  Monitoring openqa-cli-scheduled jobs: $PERL_JOB_IDS"
		echo "  (This blocks until all jobs finish.  Ctrl+C to abort.)"
		echo ""

		perl_mon_rc=0
		# shellcheck disable=SC2086
		openqa-cli monitor --host "$HOST" $PERL_JOB_IDS || perl_mon_rc=$?

		if [[ "$perl_mon_rc" -le 2 ]]; then
			_check "P2a openqa-cli monitor exit acceptable (0 or 2)" 0
		else
			_check "P2a openqa-cli monitor exit acceptable (0 or 2)" 1
		fi
	else
		echo "  Skipping openqa-cli monitor — no jobs were scheduled in Phase 1."
	fi
fi

echo ""

# =============================================================================
# Phase 2b — monitor benchmark (terminal jobs, repeatable)
# =============================================================================

echo "=== Phase 2b: monitor benchmark (terminal jobs — $RUNS runs each) ==="
echo ""

if [[ "$DRYRUN" == "1" ]]; then
	echo "  [dryrun] \$ $ZOQA monitor --host $HOST <ZOQA_JOB_IDS + PERL_JOB_IDS (all terminal)>  (x$RUNS)"
	echo "  [dryrun] \$ openqa-cli monitor --host $HOST <ZOQA_JOB_IDS + PERL_JOB_IDS (all terminal)>  (x$RUNS)"
else
	# Combine all job IDs from Phase 1 (both tools)
	ALL_JOB_IDS=""
	[[ -n "$ZIG_JOB_IDS" ]] && ALL_JOB_IDS="$ZIG_JOB_IDS"
	[[ -n "$PERL_JOB_IDS" ]] && ALL_JOB_IDS="${ALL_JOB_IDS:+$ALL_JOB_IDS }$PERL_JOB_IDS"

	if [[ -n "$ALL_JOB_IDS" ]]; then
		echo "  Job IDs (all terminal after Phase 2a): $ALL_JOB_IDS"
		echo ""

		zig_bench_cmd="$ZOQA monitor --host $HOST $ALL_JOB_IDS"
		perl_bench_cmd="openqa-cli monitor --host $HOST $ALL_JOB_IDS"

		echo "  Timing ($RUNS runs each)..."
		_run_timing "P2b monitor (terminal jobs)" "$zig_bench_cmd" "$perl_bench_cmd" "$RUNS"

		if [[ "$HAS_GNU_TIME" == "true" ]]; then
			echo "  RSS measurement..."
			_run_rss "P2b monitor (terminal jobs)" "$zig_bench_cmd" "$perl_bench_cmd"
		fi
	else
		echo "  Skipping — no jobs available from Phase 1."
	fi
fi

echo ""

# =============================================================================
# Phase 3 — schedule --monitor (combined flag, blocking)
# =============================================================================

echo "=== Phase 3: schedule --monitor (combined, blocking) ==="
echo ""
echo "  Scheduling + monitoring one job each (zoqa + openqa-cli) ..."
echo "  Params: ${SCHED_PARAMS[*]}"
echo ""

zig_sm_time_ms=0
perl_sm_time_ms=0

# -- zoqa schedule --monitor --
if [[ "$DRYRUN" == "0" ]]; then
	zig_sm_out=""
	zig_sm_rc=0

	echo "  Running zoqa schedule --monitor (blocks until job finishes) ..."
	echo "  (Ctrl+C to abort.)"

	t_start=$(date +%s%3N)
	zig_sm_out=$("$ZOQA" schedule --monitor --host "$HOST" "${SCHED_PARAMS[@]}" 2>/dev/null) || zig_sm_rc=$?
	t_end=$(date +%s%3N)
	zig_sm_time_ms=$((t_end - t_start))

	echo "  zoqa schedule --monitor output:"
	_indent "$zig_sm_out"
	echo ""

	# Exit 0 = all passed; exit 2 = some failed/incomplete; acceptable
	if [[ "$zig_sm_rc" -le 2 ]]; then
		_check "P3 zoqa schedule --monitor exit acceptable (0 or 2)" 0
	else
		_check "P3 zoqa schedule --monitor exit acceptable (0 or 2)" 1
	fi

	p3_zig_url=1
	if echo "$zig_sm_out" | grep -q ' - http'; then p3_zig_url=0; fi
	_check "P3 zoqa stdout contains job URL" "$p3_zig_url"
else
	echo "  [dryrun] \$ $ZOQA schedule --monitor --host $HOST ${SCHED_PARAMS[*]}"
fi

echo ""

# -- openqa-cli schedule --monitor --
if [[ "$DRYRUN" == "0" ]]; then
	perl_sm_out=""
	perl_sm_rc=0

	echo "  Running openqa-cli schedule --monitor (blocks until job finishes) ..."
	echo "  (Ctrl+C to abort.)"

	t_start=$(date +%s%3N)
	perl_sm_out=$(openqa-cli schedule --monitor --host "$HOST" "${SCHED_PARAMS[@]}" 2>/dev/null) || perl_sm_rc=$?
	t_end=$(date +%s%3N)
	perl_sm_time_ms=$((t_end - t_start))

	echo "  openqa-cli schedule --monitor output:"
	_indent "$perl_sm_out"
	echo ""

	if [[ "$perl_sm_rc" -le 2 ]]; then
		_check "P3 openqa-cli schedule --monitor exit acceptable (0 or 2)" 0
	else
		_check "P3 openqa-cli schedule --monitor exit acceptable (0 or 2)" 1
	fi

	p3_perl_url=1
	if echo "$perl_sm_out" | grep -q ' - http'; then p3_perl_url=0; fi
	_check "P3 openqa-cli stdout contains job URL" "$p3_perl_url"
else
	echo "  [dryrun] \$ openqa-cli schedule --monitor --host $HOST ${SCHED_PARAMS[*]}"
fi

echo ""

# -- Phase 3 timing (single-run, manual entry) --
if [[ "$DRYRUN" == "0" ]]; then
	zig_sm_sec=$(awk "BEGIN { printf \"%.3f\", $zig_sm_time_ms / 1000 }")
	perl_sm_sec=$(awk "BEGIN { printf \"%.3f\", $perl_sm_time_ms / 1000 }")

	_timing_report+=("P3  schedule --monitor (combined)")
	_timing_report+=("  ZIG  ${zig_sm_sec}s  (single run)")
	_timing_report+=("  PERL ${perl_sm_sec}s  (single run)")
	_timing_report+=("")
fi

# =============================================================================
# Summary
# =============================================================================

echo "=========================================="
echo "=== Summary ==="
echo "=========================================="
echo ""
echo "PASS: $PASS   FAIL: $FAIL"
echo ""

if [[ ${#_timing_report[@]} -gt 0 ]]; then
	echo "--- Timing ---"
	for line in "${_timing_report[@]}"; do echo "$line"; done
fi

if [[ "$HAS_GNU_TIME" == "true" && ${#_rss_report[@]} -gt 0 ]]; then
	echo "--- RSS & Process Metrics ---"
	for line in "${_rss_report[@]}"; do echo "$line"; done
fi

# Exit with non-zero if any test failed.
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
