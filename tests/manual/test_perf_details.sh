#!/bin/bash
# tests/manual/test_perf_details.sh — Performance benchmark for jobs/ID/details
#
# Three-way comparison of zoqa, openqa-cli, and curl (gzip) on the
# jobs/ID/details endpoint.  Run it twice with different OPENQA_JOB_ID values
# to compare normal-sized vs pathologically large (~1 GB) responses.
#
# Usage:
#   cd <project-root>
#   zig build
#
#   # Normal response
#   OPENQA_HOST=http://d5-21.qe.nue2.suse.org OPENQA_JOB_ID=7473 \
#       bash tests/manual/test_perf_details.sh
#
#   # Huge response (~1 GB JSON)
#   OPENQA_HOST=http://d5-21.qe.nue2.suse.org OPENQA_JOB_ID=7491 \
#       bash tests/manual/test_perf_details.sh
#
# See lib.sh for environment variable overrides and default configuration.
#
# Environment variables:
#   OPENQA_HOST   (required)  Base URL of the openQA instance
#   OPENQA_JOB_ID (required)  Job ID to benchmark
#   ZOQA          (optional)  Path to zoqa binary (default: ./zig-out/bin/zoqa)
#   RUNS          (optional)  Number of timing repetitions per tool (default: 3)
#   SLEEP         (optional)  Seconds to sleep between individual runs (default: 0)
#
# Requirements:
#   - bash 4+
#   - openqa-cli in PATH
#   - curl in PATH
#   - /usr/bin/time (GNU time) for RSS/CPU metrics (optional, skipped if absent)
#   - Network access to the target openQA server
#
# All requests are read-only GETs.

set -euo pipefail

# shellcheck source=lib.sh source-path=SCRIPTDIR
source "$(dirname "$0")/lib.sh"

SLEEP="${SLEEP:-0}"

# =============================================================================
# Cleanup
# =============================================================================

cleanup() {
	rm -f /tmp/_manual_wall.tmp /tmp/_perf_timev_*.txt
}
trap cleanup EXIT

# =============================================================================
# Preflight
# =============================================================================

echo "=== Preflight ==="
echo ""

require_zoqa
require_openqa_cli
require_curl
detect_gnu_time

echo ""
echo "  HOST:   $HOST"
echo "  JOB_ID: $JOB_ID"
echo "  RUNS:   $RUNS"
echo "  SLEEP:  ${SLEEP}s"
echo ""

# Connectivity check
echo -n "  Connectivity check (zoqa api --host $HOST jobs/$JOB_ID)... "
if "$ZOQA" api --host "$HOST" "jobs/$JOB_ID" >/dev/null 2>&1; then
	echo "OK"
else
	echo "FAILED"
	echo "FATAL: Cannot reach $HOST or job $JOB_ID does not exist."
	exit 1
fi

echo ""

# =============================================================================
# Command definitions
# =============================================================================

ZOQA_CMD="$ZOQA api --host $HOST -X GET jobs/$JOB_ID/details"
PERL_CMD="openqa-cli api --host $HOST -X GET jobs/$JOB_ID/details"
CURL_CMD="curl -sf -H 'Accept: application/json' --compressed $HOST/api/v1/jobs/$JOB_ID/details"

# =============================================================================
# Helpers
# =============================================================================

# _sanity_check LABEL CMD
#
# Runs CMD once, pipes output through wc -c to measure response size without
# storing it on disk.  Reports exit code and byte count.  A 50x error response
# is tiny (hundreds of bytes) compared to a real JSON body (millions/billions),
# so size is a clear signal even without parsing.
_sanity_check() {
	local label=$1 cmd=$2

	echo -n "    $label: "

	local rc=0 size=0
	size=$(bash -o pipefail -c "$cmd 2>/dev/null | wc -c") || rc=$?

	local status="OK"
	[[ "$rc" -ne 0 ]] && status="FAIL"

	printf "exit=%d  size=%d bytes  → %s\n" "$rc" "$size" "$status"
}

# _timed_run CMD_STRING
#
# Measures wall-clock time AND captures exit code of CMD_STRING.
# Prints: "SECONDS EXIT_CODE"  (e.g., "0.299 0" or "0.045 1")
_timed_run() {
	bash -c '
		TIMEFORMAT=%R
		{ time bash -c "$1" >/dev/null 2>&1; } 2>/tmp/_manual_wall.tmp
		_rc=$?
		printf "%s %d" "$(cat /tmp/_manual_wall.tmp)" "$_rc"
	' _ "$1"
}

# =============================================================================
# Sanity check — one run per tool, verify exit code + response size
# =============================================================================

echo "=== Sanity Check (one request per tool) ==="
echo ""

_sanity_check "zoqa" "$ZOQA_CMD"
_sanity_check "openqa-cli" "$PERL_CMD"
_sanity_check "curl (gzip)" "$CURL_CMD"

echo ""

# =============================================================================
# Timing phase
# =============================================================================

echo "=== Timing ($RUNS runs each, ${SLEEP}s sleep between runs) ==="
echo ""

# Arrays to collect results per tool for the summary.
declare -a ZOQA_TIMES=()
declare -a PERL_TIMES=()
declare -a CURL_TIMES=()
TIMING_FAILURES=0

_run_tool_timing() {
	local label=$1 cmd=$2
	# nameref: caller passes the name of the array to populate
	local -n _times_ref=$3
	local failures=0

	for i in $(seq 1 "$RUNS"); do
		local result t rc
		result=$(_timed_run "$cmd")
		t="${result% *}"
		rc="${result##* }"
		_times_ref+=("$t")
		if [[ "$rc" -ne 0 ]]; then
			failures=$((failures + 1))
			echo "    $label [$i/$RUNS]: ${t}s  (exit=$rc — FAILED)"
		else
			echo "    $label [$i/$RUNS]: ${t}s"
		fi
		if [[ "$i" -lt "$RUNS" && "$SLEEP" -gt 0 ]]; then
			sleep "$SLEEP"
		fi
	done

	if [[ "$failures" -gt 0 ]]; then
		echo "    WARNING: $label had $failures/$RUNS failed runs"
		TIMING_FAILURES=$((TIMING_FAILURES + failures))
	fi
}

echo "  zoqa:"
_run_tool_timing "zoqa" "$ZOQA_CMD" ZOQA_TIMES
[[ "$SLEEP" -gt 0 ]] && sleep "$SLEEP"

echo "  openqa-cli:"
_run_tool_timing "openqa-cli" "$PERL_CMD" PERL_TIMES
[[ "$SLEEP" -gt 0 ]] && sleep "$SLEEP"

echo "  curl (gzip):"
_run_tool_timing "curl" "$CURL_CMD" CURL_TIMES

echo ""

# =============================================================================
# Resource measurement phase (single /usr/bin/time -v run per tool)
# =============================================================================

# Arrays to store formatted metric lines for each tool.
declare -a ZOQA_RSS=()
declare -a PERL_RSS=()
declare -a CURL_RSS=()

_run_tool_rss() {
	local label=$1 tag=$2 cmd=$3
	# nameref: caller passes the name of the array to populate
	local -n _rss_ref=$4

	if [[ "$HAS_GNU_TIME" != "true" ]]; then
		echo "    $label: skipped (/usr/bin/time not available)"
		return
	fi

	echo "    $label: measuring..."
	_peak_rss_kb "$tag" "$cmd" >/dev/null

	local rss usr sys maj min vcs ics
	rss=$(_timev_field "$tag" 'Maximum resident set size')
	usr=$(_timev_field "$tag" 'User time')
	sys=$(_timev_field "$tag" 'System time')
	maj=$(_timev_field "$tag" 'Major (requiring I/O) page faults')
	min=$(_timev_field "$tag" 'Minor (reclaiming a frame) page faults')
	vcs=$(_timev_field "$tag" 'Voluntary context switches')
	ics=$(_timev_field "$tag" 'Involuntary context switches')

	_rss_ref=("$rss" "$usr" "$sys" "$maj" "$min" "$vcs" "$ics")
}

if [[ "$HAS_GNU_TIME" == "true" ]]; then
	echo "=== Resource Metrics (single /usr/bin/time -v run) ==="
	echo ""

	_run_tool_rss "zoqa" "details_zoqa" "$ZOQA_CMD" ZOQA_RSS
	[[ "$SLEEP" -gt 0 ]] && sleep "$SLEEP"

	_run_tool_rss "openqa-cli" "details_perl" "$PERL_CMD" PERL_RSS
	[[ "$SLEEP" -gt 0 ]] && sleep "$SLEEP"

	_run_tool_rss "curl" "details_curl" "$CURL_CMD" CURL_RSS

	echo ""
fi

# =============================================================================
# Summary
# =============================================================================

echo "=========================================="
echo "=== Summary: jobs/$JOB_ID/details ==="
echo "=========================================="
echo ""

# --- Timing table ---
echo "--- Wall-clock timing (seconds, $RUNS runs) ---"
echo ""

_print_timing_row() {
	local label=$1
	shift
	local times=("$@")
	local times_str=""
	for t in "${times[@]}"; do
		times_str+="${t}s  "
	done
	local agg
	agg=$(_aggregate "${times[*]}")
	printf "  %-14s  %-42s  %s\n" "$label" "$times_str" "$agg"
}

printf "  %-14s  %-42s  %s\n" "Tool" "Runs" "min / avg / max"
printf "  %-14s  %-42s  %s\n" "--------------" \
	"------------------------------------------" \
	"------------------------------"
_print_timing_row "zoqa" "${ZOQA_TIMES[@]}"
_print_timing_row "openqa-cli" "${PERL_TIMES[@]}"
_print_timing_row "curl (gzip)" "${CURL_TIMES[@]}"
echo ""

# --- Comparison ---
z_avg=$(echo "${ZOQA_TIMES[*]}" | awk '{s=0; for(i=1;i<=NF;i++) s+=$i; printf "%.3f", s/NF}')
p_avg=$(echo "${PERL_TIMES[*]}" | awk '{s=0; for(i=1;i<=NF;i++) s+=$i; printf "%.3f", s/NF}')
c_avg=$(echo "${CURL_TIMES[*]}" | awk '{s=0; for(i=1;i<=NF;i++) s+=$i; printf "%.3f", s/NF}')

echo "  Averages:  zoqa=${z_avg}s  openqa-cli=${p_avg}s  curl=${c_avg}s"

if awk "BEGIN { exit ($z_avg > $p_avg) ? 0 : 1 }" 2>/dev/null; then
	ratio=$(awk "BEGIN { printf \"%.1f\", $z_avg / $p_avg }")
	echo "  zoqa is ${ratio}x slower than openqa-cli"
else
	ratio=$(awk "BEGIN { printf \"%.1f\", $p_avg / $z_avg }")
	echo "  zoqa is ${ratio}x faster than openqa-cli"
fi
echo ""

if [[ "$TIMING_FAILURES" -gt 0 ]]; then
	echo "  WARNING: $TIMING_FAILURES total failed runs detected during timing"
	echo ""
fi

# --- Resource table ---
if [[ "$HAS_GNU_TIME" == "true" && ${#ZOQA_RSS[@]} -gt 0 ]]; then
	echo "--- Resource usage (/usr/bin/time -v, single run) ---"
	echo ""
	printf "  %-14s  %12s  %10s  %10s  %12s  %12s  %8s  %8s\n" \
		"Tool" "RSS (kB)" "User (s)" "Sys (s)" "Maj faults" "Min faults" "Vol CS" "Invol CS"
	printf "  %-14s  %12s  %10s  %10s  %12s  %12s  %8s  %8s\n" \
		"--------------" "------------" "----------" "----------" \
		"------------" "------------" "--------" "--------"

	_print_rss_row() {
		local label=$1
		shift
		local m=("$@")
		if [[ ${#m[@]} -lt 7 ]]; then
			printf "  %-14s  %s\n" "$label" "(no data)"
			return
		fi
		printf "  %-14s  %12s  %10s  %10s  %12s  %12s  %8s  %8s\n" \
			"$label" "${m[0]}" "${m[1]}" "${m[2]}" "${m[3]}" "${m[4]}" "${m[5]}" "${m[6]}"
	}

	_print_rss_row "zoqa" "${ZOQA_RSS[@]}"
	_print_rss_row "openqa-cli" "${PERL_RSS[@]}"
	_print_rss_row "curl (gzip)" "${CURL_RSS[@]}"
	echo ""
fi

echo "Done."
