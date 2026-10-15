#!/bin/bash
# tests/manual/test_perf_clone.sh — Performance benchmark for clone-job asset
# downloads with --show-progress.
#
# Four-way comparison of zoqa-clone-job (with and without --show-progress),
# openqa-clone-job, and curl on the asset-download path.  Uses --skip-deps to
# isolate the download from the BFS/dependency walk and --export-command to
# guarantee NO job is scheduled on the source instance (the scheduling command
# is printed to stdout instead of being POSTed).  The zoqa no-progress vs
# with-progress pair measures the overhead of the native progress meter.
#
# Usage:
#   cd <project-root>
#   zig build
#
#   OPENQA_HOST=https://openqa.opensuse.org OPENQA_JOB_ID=6262303 \
#       bash tests/manual/test_perf_clone.sh
#
# See lib.sh for environment variable overrides and default configuration.
#
# Environment variables:
#   OPENQA_HOST    (required)  Base URL of the openQA instance
#   OPENQA_JOB_ID  (required)  Job ID to benchmark (should have large assets)
#   ZOQA_CLONE     (optional)  Path to zoqa-clone-job binary (default: ./zig-out/bin/zoqa-clone-job)
#   RUNS           (optional)  Number of timing repetitions per tool (default: 3)
#   SLEEP          (optional)  Seconds to sleep between individual runs (default: 0)
#   ASSET_DIR      (optional)  Base directory for downloads (default: /tmp/zoqa-clone-perf-$$)
#
# Requirements:
#   - bash 4+
#   - openqa-clone-job in PATH
#   - curl in PATH
#   - /usr/bin/time (GNU time) for RSS/CPU metrics (optional, skipped if absent)
#   - Network access to the target openQA server
#   - ~4 GB free disk space in ASSET_DIR
#
# All requests are read-only GETs; local file writes only.

set -euo pipefail

# shellcheck source=lib.sh source-path=SCRIPTDIR
source "$(dirname "$0")/lib.sh"

SLEEP="${SLEEP:-0}"
ZOQA_CLONE="${ZOQA_CLONE:-./zig-out/bin/zoqa-clone-job}"
ASSET_DIR="${ASSET_DIR:-/tmp/zoqa-clone-perf-$$}"

# =============================================================================
# Cleanup
# =============================================================================

cleanup() {
	rm -rf "$ASSET_DIR"
	rm -f /tmp/_manual_wall.tmp /tmp/_perf_timev_*.txt
}
trap cleanup EXIT

# =============================================================================
# Preflight
# =============================================================================

echo "=== Preflight ==="
echo ""

if [[ ! -x "$ZOQA_CLONE" ]]; then
	echo "FATAL: zoqa-clone-job binary not found or not executable at: $ZOQA_CLONE"
	echo "       Run 'zig build' first."
	exit 1
fi
echo "  zoqa-clone-job: $ZOQA_CLONE"

require_openqa_cli
require_curl
detect_gnu_time

echo ""
echo "  HOST:      $HOST"
echo "  JOB_ID:    $JOB_ID"
echo "  RUNS:      $RUNS"
echo "  SLEEP:     ${SLEEP}s"
echo "  ASSET_DIR: $ASSET_DIR"
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

# Disk space check
mkdir -p "$ASSET_DIR"
_avail_kb=$(df -k "$ASSET_DIR" | awk 'NR==2 {print $4}')
if [[ "$_avail_kb" -lt 4000000 ]]; then
	echo "  WARNING: Less than 4 GB available in $ASSET_DIR (${_avail_kb} kB)."
	echo "           Large-asset downloads may fail."
fi

echo ""

# =============================================================================
# Helpers
# =============================================================================

# _sanity_check LABEL CMD
#
# Runs CMD once, reports exit code and the number of files produced under
# the --dir argument (last token).  A 50x error response produces no files;
# a successful download produces at least one.
_sanity_check() {
	local label=$1 cmd=$2

	echo -n "    $label: "

	local rc=0
	bash -c "$cmd" >/dev/null 2>&1 || rc=$?

	local dir
	dir=$(echo "$cmd" | grep -oP '(?<=--dir )\S+')
	local file_count=0 total_bytes=0
	if [[ -n "$dir" && -d "$dir" ]]; then
		file_count=$(find "$dir" -type f 2>/dev/null | wc -l)
		total_bytes=$(find "$dir" -type f -exec stat -c %s {} + 2>/dev/null | awk '{s+=$1} END {print s+0}')
	fi

	local status="OK"
	[[ "$rc" -ne 0 ]] && status="FAIL"

	printf "exit=%d  files=%d  bytes=%d  → %s\n" "$rc" "$file_count" "$total_bytes" "$status"
}

# _timed_run CMD_STRING
#
# Measures wall-clock time AND captures exit code of CMD_STRING.
# Prints: "SECONDS EXIT_CODE"  (e.g., "12.345 0" or "0.045 1")
_timed_run() {
	bash -c '
		TIMEFORMAT=%R
		{ time bash -c "$1" >/dev/null 2>&1; } 2>/tmp/_manual_wall.tmp
		_rc=$?
		printf "%s %d" "$(cat /tmp/_manual_wall.tmp)" "$_rc"
	' _ "$1"
}

# _discover_largest_asset
#
# Queries the openQA API for the job's assets and prints the type and
# filename of the largest one (one per line).  Used to build the curl
# baseline command.
_discover_largest_asset() {
	local assets_json
	assets_json=$("$ZOQA" api --host "$HOST" "jobs/$JOB_ID/assets" 2>/dev/null) || {
		echo "  WARNING: could not fetch asset list; curl baseline will be skipped"
		return 1
	}

	echo "$assets_json" | python3 -c "
import json, sys
assets = json.load(sys.stdin)
if not assets:
    sys.exit(1)
largest = max(assets, key=lambda a: a.get('size', 0))
print(largest['type'])
print(largest['name'])
" 2>/dev/null
}

# =============================================================================
# Sanity check — one run per tool, verify exit code + file count
# =============================================================================

echo "=== Sanity Check (one request per tool) ==="
echo ""

ZOQA_CMD="$ZOQA_CLONE --from $HOST --skip-deps --show-progress --export-command $JOB_ID --dir $ASSET_DIR/sanity_zoqa"
PERL_CMD="openqa-clone-job --from $HOST --skip-deps --show-progress --export-command $JOB_ID --dir $ASSET_DIR/sanity_perl"

_sanity_check "zoqa-clone-job" "$ZOQA_CMD"
_sanity_check "openqa-clone-job" "$PERL_CMD"

# Discover the largest asset for the curl baseline.
CURL_ASSET_TYPE=""
CURL_ASSET_NAME=""
if _discover_largest_asset > /tmp/_perf_clone_asset.txt 2>/dev/null; then
	CURL_ASSET_TYPE=$(sed -n '1p' /tmp/_perf_clone_asset.txt)
	CURL_ASSET_NAME=$(sed -n '2p' /tmp/_perf_clone_asset.txt)
	CURL_CMD="curl -sf -o $ASSET_DIR/sanity_curl/$CURL_ASSET_NAME $HOST/tests/$JOB_ID/asset/$CURL_ASSET_TYPE/$CURL_ASSET_NAME"
	echo "  Largest asset: $CURL_ASSET_TYPE/$CURL_ASSET_NAME"
	_sanity_check "curl (largest asset)" "$CURL_CMD"
else
	echo "    curl (largest asset): SKIPPED (could not determine asset list)"
fi

rm -rf "$ASSET_DIR/sanity_zoqa" "$ASSET_DIR/sanity_perl" "$ASSET_DIR/sanity_curl"

echo ""

# =============================================================================
# Timing phase
# =============================================================================

echo "=== Timing ($RUNS runs each, ${SLEEP}s sleep between runs) ==="
echo ""

declare -a ZOQA_TIMES=()
declare -a ZOQA_NOPROG_TIMES=()
declare -a PERL_TIMES=()
declare -a CURL_TIMES=()
TIMING_FAILURES=0

_run_tool_timing() {
	local label=$1 cmd_template=$2
	local -n _times_ref=$3
	local failures=0

	for i in $(seq 1 "$RUNS"); do
		local dir="$ASSET_DIR/run_${label}_${i}"
		local cmd="${cmd_template//__DIR__/$dir}"
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
		rm -rf "$dir"
		if [[ "$i" -lt "$RUNS" && "$SLEEP" -gt 0 ]]; then
			sleep "$SLEEP"
		fi
	done

	if [[ "$failures" -gt 0 ]]; then
		echo "    WARNING: $label had $failures/$RUNS failed runs"
		TIMING_FAILURES=$((TIMING_FAILURES + failures))
	fi
}

echo "  zoqa-clone-job (no progress):"
_run_tool_timing "zoqa_np" "$ZOQA_CLONE --from $HOST --skip-deps --export-command $JOB_ID --dir __DIR__" ZOQA_NOPROG_TIMES
[[ "$SLEEP" -gt 0 ]] && sleep "$SLEEP"

echo "  zoqa-clone-job (--show-progress):"
_run_tool_timing "zoqa" "$ZOQA_CLONE --from $HOST --skip-deps --show-progress --export-command $JOB_ID --dir __DIR__" ZOQA_TIMES
[[ "$SLEEP" -gt 0 ]] && sleep "$SLEEP"

echo "  openqa-clone-job:"
_run_tool_timing "perl" "openqa-clone-job --from $HOST --skip-deps --show-progress --export-command $JOB_ID --dir __DIR__" PERL_TIMES
[[ "$SLEEP" -gt 0 ]] && sleep "$SLEEP"

if [[ -n "$CURL_ASSET_TYPE" && -n "$CURL_ASSET_NAME" ]]; then
	echo "  curl (largest asset):"
	_run_tool_timing "curl" "curl -sf -o __DIR__/$CURL_ASSET_NAME $HOST/tests/$JOB_ID/asset/$CURL_ASSET_TYPE/$CURL_ASSET_NAME" CURL_TIMES
fi

echo ""

# =============================================================================
# Resource measurement phase (single /usr/bin/time -v run per tool)
# =============================================================================

declare -a ZOQA_RSS=()
declare -a ZOQA_NOPROG_RSS=()
declare -a PERL_RSS=()
declare -a CURL_RSS=()

_run_tool_rss() {
	local label=$1 tag=$2 cmd=$3
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

	rss_dir_zoqa_np="$ASSET_DIR/rss_zoqa_np"
	rss_dir_zoqa="$ASSET_DIR/rss_zoqa"
	rss_dir_perl="$ASSET_DIR/rss_perl"
	rss_dir_curl="$ASSET_DIR/rss_curl"

	_run_tool_rss "zoqa-clone-job (no progress)" "clone_zoqa_np" \
		"$ZOQA_CLONE --from $HOST --skip-deps --export-command $JOB_ID --dir $rss_dir_zoqa_np" ZOQA_NOPROG_RSS
	rm -rf "$rss_dir_zoqa_np"
	[[ "$SLEEP" -gt 0 ]] && sleep "$SLEEP"

	_run_tool_rss "zoqa-clone-job (--show-progress)" "clone_zoqa" \
		"$ZOQA_CLONE --from $HOST --skip-deps --show-progress --export-command $JOB_ID --dir $rss_dir_zoqa" ZOQA_RSS
	rm -rf "$rss_dir_zoqa"
	[[ "$SLEEP" -gt 0 ]] && sleep "$SLEEP"

	_run_tool_rss "openqa-clone-job" "clone_perl" \
		"openqa-clone-job --from $HOST --skip-deps --show-progress --export-command $JOB_ID --dir $rss_dir_perl" PERL_RSS
	rm -rf "$rss_dir_perl"
	[[ "$SLEEP" -gt 0 ]] && sleep "$SLEEP"

	if [[ -n "$CURL_ASSET_TYPE" && -n "$CURL_ASSET_NAME" ]]; then
		_run_tool_rss "curl" "clone_curl" \
			"curl -sf -o $rss_dir_curl/$CURL_ASSET_NAME $HOST/tests/$JOB_ID/asset/$CURL_ASSET_TYPE/$CURL_ASSET_NAME" CURL_RSS
		rm -rf "$rss_dir_curl"
	fi

	echo ""
fi

# =============================================================================
# Summary
# =============================================================================

echo "=========================================="
echo "=== Summary: clone-job $JOB_ID (skip-deps, show-progress) ==="
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
	printf "  %-28s  %-42s  %s\n" "$label" "$times_str" "$agg"
}

printf "  %-28s  %-42s  %s\n" "Tool" "Runs" "min / avg / max"
printf "  %-28s  %-42s  %s\n" "----------------------------" \
	"------------------------------------------" \
	"------------------------------"
_print_timing_row "zoqa (no progress)" "${ZOQA_NOPROG_TIMES[@]}"
_print_timing_row "zoqa (--show-progress)" "${ZOQA_TIMES[@]}"
_print_timing_row "openqa-clone-job" "${PERL_TIMES[@]}"
if [[ ${#CURL_TIMES[@]} -gt 0 ]]; then
	_print_timing_row "curl (largest)" "${CURL_TIMES[@]}"
fi
echo ""

# --- Progress overhead ---
z_np_avg=$(echo "${ZOQA_NOPROG_TIMES[*]}" | awk '{s=0; for(i=1;i<=NF;i++) s+=$i; printf "%.3f", s/NF}')
z_avg=$(echo "${ZOQA_TIMES[*]}" | awk '{s=0; for(i=1;i<=NF;i++) s+=$i; printf "%.3f", s/NF}')

echo "  --- --show-progress overhead (zoqa-clone-job) ---"
echo "  no progress:    ${z_np_avg}s"
echo "  with progress:  ${z_avg}s"
awk "BEGIN {
	d = $z_avg - $z_np_avg;
	if ($z_np_avg > 0) {
		pct = d / $z_np_avg * 100;
		if (d >= 0)
			printf \"  overhead:       +%.3fs (%+.1f%%)\n\", d, pct;
		else
			printf \"  overhead:       %+.3fs (%+.1f%%)\n\", d, pct;
	}
}"
echo ""

# --- Comparison ---
p_avg=$(echo "${PERL_TIMES[*]}" | awk '{s=0; for(i=1;i<=NF;i++) s+=$i; printf "%.3f", s/NF}')

echo "  Averages:  zoqa-clone-job=${z_avg}s  openqa-clone-job=${p_avg}s"

if awk "BEGIN { exit ($z_avg > $p_avg) ? 0 : 1 }" 2>/dev/null; then
	ratio=$(awk "BEGIN { printf \"%.1f\", $z_avg / $p_avg }")
	echo "  zoqa-clone-job is ${ratio}x slower than openqa-clone-job"
else
	ratio=$(awk "BEGIN { printf \"%.1f\", $p_avg / $z_avg }")
	echo "  zoqa-clone-job is ${ratio}x faster than openqa-clone-job"
fi

if [[ ${#CURL_TIMES[@]} -gt 0 ]]; then
	c_avg=$(echo "${CURL_TIMES[*]}" | awk '{s=0; for(i=1;i<=NF;i++) s+=$i; printf "%.3f", s/NF}')
	echo "  curl (largest asset only) average: ${c_avg}s"
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
	printf "  %-28s  %12s  %10s  %10s  %12s  %12s  %8s  %8s\n" \
		"Tool" "RSS (kB)" "User (s)" "Sys (s)" "Maj faults" "Min faults" "Vol CS" "Invol CS"
	printf "  %-28s  %12s  %10s  %10s  %12s  %12s  %8s  %8s\n" \
		"----------------------------" "------------" "----------" "----------" \
		"------------" "------------" "--------" "--------"

	_print_rss_row() {
		local label=$1
		shift
		local m=("$@")
		if [[ ${#m[@]} -lt 7 ]]; then
			printf "  %-28s  %s\n" "$label" "(no data)"
			return
		fi
		printf "  %-28s  %12s  %10s  %10s  %12s  %12s  %8s  %8s\n" \
			"$label" "${m[0]}" "${m[1]}" "${m[2]}" "${m[3]}" "${m[4]}" "${m[5]}" "${m[6]}"
	}

	_print_rss_row "zoqa (no progress)" "${ZOQA_NOPROG_RSS[@]}"
	_print_rss_row "zoqa (--show-progress)" "${ZOQA_RSS[@]}"
	_print_rss_row "openqa-clone-job" "${PERL_RSS[@]}"
	if [[ ${#CURL_RSS[@]} -gt 0 ]]; then
		_print_rss_row "curl (largest)" "${CURL_RSS[@]}"
	fi
	echo ""
fi

echo "Done."
