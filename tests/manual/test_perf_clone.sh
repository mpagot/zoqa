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
# CLI flags:
#   --strace      Trace zoqa-clone-job syscalls (network + read) with strace.
#                 Output: ASSET_DIR/traces/strace_<label>_<run>.strace
#                 No sudo required.
#   --tcpdump     Capture network traffic with tcpdump during zoqa timing runs.
#                 Output: ASSET_DIR/traces/tcpdump_<label>_<run>.pcap
#                 Requires sudo (password prompt before timing starts).
#
# Requirements:
#   - bash 4+
#   - openqa-clone-job in PATH
#   - curl in PATH
#   - /usr/bin/time (GNU time) for RSS/CPU metrics (optional, skipped if absent)
#   - strace (only for --strace)
#   - tcpdump + sudo (only for --tcpdump)
#   - Network access to the target openQA server
#   - ~4 GB free disk space in ASSET_DIR
#
# All requests are read-only GETs; local file writes only.

set -euo pipefail

# shellcheck source=lib.sh source-path=SCRIPTDIR
source "$(dirname "$0")/lib.sh"

# =============================================================================
# CLI flag parsing
# =============================================================================

DO_STRACE=false
DO_TCPDUMP=false

usage() {
	cat <<'EOF'
Usage: test_perf_clone.sh [OPTIONS]

Performance benchmark for clone-job asset downloads. Four-way comparison of
zoqa-clone-job (with and without --show-progress), openqa-clone-job, and curl.

Options:
  --strace      Trace zoqa-clone-job syscalls (network + read) with strace.
                Output: ASSET_DIR/traces/strace_<label>_<run>.strace
                No sudo required.
  --tcpdump     Capture network traffic with tcpdump during zoqa timing runs.
                Output: ASSET_DIR/traces/tcpdump_<label>_<run>.pcap
                Requires sudo (password prompt before timing starts).
  --help, -h    Show this help and exit

Environment variables:
  OPENQA_HOST    (required)  Base URL of the openQA instance
  OPENQA_JOB_ID  (required)  Job ID to benchmark (should have large assets)
  ZOQA_CLONE     (optional)  Path to zoqa-clone-job binary
                             (default: ./zig-out/bin/zoqa-clone-job)
  RUNS           (optional)  Number of timing repetitions per tool (default: 3)
  SLEEP          (optional)  Seconds to sleep between individual runs (default: 0)
  ASSET_DIR      (optional)  Base directory for downloads
                             (default: /tmp/zoqa-clone-perf-$$)

Examples:
  OPENQA_HOST=https://openqa.opensuse.org OPENQA_JOB_ID=6300310 \
      bash tests/manual/test_perf_clone.sh

  OPENQA_HOST=https://openqa.opensuse.org OPENQA_JOB_ID=6300310 \
      RUNS=5 bash tests/manual/test_perf_clone.sh --strace

  OPENQA_HOST=https://openqa.opensuse.org OPENQA_JOB_ID=6300310 \
      bash tests/manual/test_perf_clone.sh --strace --tcpdump
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--strace)
		DO_STRACE=true
		shift
		;;
	--tcpdump)
		DO_TCPDUMP=true
		shift
		;;
	--help | -h)
		usage
		exit 0
		;;
	*)
		echo "FATAL: unknown flag: $1"
		usage
		exit 1
		;;
	esac
done

SLEEP="${SLEEP:-0}"
ZOQA_CLONE="${ZOQA_CLONE:-./zig-out/bin/zoqa-clone-job}"
ASSET_DIR="${ASSET_DIR:-/tmp/zoqa-clone-perf-$$}"
TRACE_DIR="$ASSET_DIR/traces"

# =============================================================================
# Cleanup
# =============================================================================

_TCPDUMP_PID=""

cleanup() {
	if [[ -n "$_TCPDUMP_PID" ]]; then
		kill "$_TCPDUMP_PID" 2>/dev/null || true
		wait "$_TCPDUMP_PID" 2>/dev/null || true
	fi
	# Remove downloaded assets but preserve trace files (strace/pcap) so the
	# user can inspect them after the run.  Traces stay in ASSET_DIR/traces/
	# (not moved to /tmp, which may be a small tmpfs).
	if [[ -d "$ASSET_DIR" ]]; then
		if [[ -d "$TRACE_DIR" && -n "$(find "$TRACE_DIR" -type f 2>/dev/null)" ]]; then
			# Remove everything except the traces directory
			find "$ASSET_DIR" -mindepth 1 -maxdepth 1 ! -name 'traces' -exec rm -rf {} + 2>/dev/null
			# Remove empty run dirs
			find "$ASSET_DIR" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null
		else
			rm -rf "$ASSET_DIR"
		fi
	fi
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
print_bin_info "zoqa-clone-job" "$ZOQA_CLONE"
require_zoqa
require_openqa_cli
require_curl
detect_gnu_time

echo ""
echo "  HOST:      $HOST"
echo "  JOB_ID:    $JOB_ID"
echo "  RUNS:      $RUNS"
echo "  SLEEP:     ${SLEEP}s"
echo "  ASSET_DIR: $ASSET_DIR"
if [[ "$DO_STRACE" == "true" ]]; then
	echo "  STRACE:    enabled (traces → $TRACE_DIR/)"
fi
if [[ "$DO_TCPDUMP" == "true" ]]; then
	echo "  TCPDUMP:   enabled (pcaps → $TRACE_DIR/)"
fi
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

# Disk space check — estimate the space needed for all downloads in this run.
# Each zoqa/perl run downloads the full asset set (~2.3 GB for job 6300310).
# curl downloads only the largest asset (~1.4 GB).  We need space for the
# largest single run (assets are deleted between runs), plus trace files.
mkdir -p "$ASSET_DIR"
_avail_kb=$(df -k "$ASSET_DIR" | awk 'NR==2 {print $4}')
# Estimate: 4 GB per full download (zoqa/perl) + 2 GB for curl + 2 GB for traces
_estimated_need_kb=8000000
if [[ "$DO_TCPDUMP" == "true" ]]; then
	_estimated_need_kb=$(( _estimated_need_kb + 4000000 )) # +4 GB for pcaps
fi
if [[ "$_avail_kb" -lt "$_estimated_need_kb" ]]; then
	echo "  WARNING: Only $((_avail_kb / 1024)) MB available in $ASSET_DIR."
	echo "           Estimated need: $((_estimated_need_kb / 1024)) MB."
	echo "           Consider a larger ASSET_DIR or fewer RUNS."
fi

# Trace tooling checks
if [[ "$DO_STRACE" == "true" ]]; then
	if ! command -v strace &>/dev/null; then
		echo "  WARNING: strace not found; --strace will be ignored"
	fi
fi
if [[ "$DO_TCPDUMP" == "true" ]]; then
	if ! command -v tcpdump &>/dev/null; then
		echo "  WARNING: tcpdump not found; --tcpdump will be ignored"
	elif ! command -v sudo &>/dev/null; then
		echo "  WARNING: sudo not found; --tcpdump will be ignored"
	else
		# Prompt for the sudo password NOW, before any timing starts, so the
		# interactive prompt does not skew the wall-clock measurements.
		echo -n "  sudo check (for tcpdump)... "
		if sudo -n true 2>/dev/null; then
			echo "OK (cached)"
		else
			sudo -v
			echo "OK"
		fi
	fi
fi
mkdir -p "$TRACE_DIR"

echo ""

# =============================================================================
# Helpers
# =============================================================================

# _snapshot_system_metrics LABEL
#
# Captures a one-line system metrics snapshot (load, memory, disk) before a
# timing run.  Appended to $ASSET_DIR/system_metrics.log so the user can
# correlate timing variance with local system state.
#
# Format: timestamp  label  load1  mem_used_gb  mem_avail_gb  disk_avail_gb
_snapshot_system_metrics() {
	local label=$1
	local ts load1 mem_used mem_avail disk_avail
	ts=$(date '+%Y-%m-%d %H:%M:%S')
	load1=$(awk '{print $1}' /proc/loadavg)
	mem_used=$(free -g | awk '/^Mem:/ {print $3}')
	mem_avail=$(free -g | awk '/^Mem:/ {print $7}')
	disk_avail=$(df -BG "$ASSET_DIR" | awk 'NR==2 {print $4}' | tr -d 'G')
	printf "%s  %-12s  load=%-4s  mem_used=%sG  mem_avail=%sG  disk_avail=%sG\n" \
		"$ts" "$label" "$load1" "$mem_used" "$mem_avail" "$disk_avail" \
		>> "$ASSET_DIR/system_metrics.log"
}

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
	dir=$(echo "$cmd" | grep -oP '(?<=--dir )\S+' || true)
	if [[ -z "$dir" ]]; then
		dir=$(echo "$cmd" | grep -oP '(?<=-o )\S+' | xargs -r dirname || true)
	fi
	local file_count=0 total_bytes=0
	if [[ -n "$dir" && -d "$dir" ]]; then
		file_count=$(find "$dir" -type f 2>/dev/null | wc -l)
		total_bytes=$(find "$dir" -type f -exec stat -c %s {} + 2>/dev/null | awk '{s+=$1} END {print s+0}')
		rm -rf "$dir"
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
	local job_json
	job_json=$("$ZOQA" api --host "$HOST" "jobs/$JOB_ID" 2>/dev/null) || {
		echo "  WARNING: could not fetch job details; curl baseline will be skipped"
		return 1
	}

	# Extract the assets object contents from the job JSON
	local assets_block
	assets_block=$(echo "$job_json" | grep -oP '"assets":\s*\{\K[^\}]+' || true)
	[[ -z "$assets_block" ]] && return 1

	local largest_type="" largest_name="" largest_size=0

	# Iterate over each category: "type":["file1","file2"]
	while IFS= read -r category; do
		[[ -z "$category" ]] && continue
		local type files
		type=$(echo "$category" | grep -oP '^"[^"]+"' | tr -d '"' || true)
		[[ "$type" == "repo" || -z "$type" ]] && continue

		files=$(echo "$category" | grep -oP '\[\K[^\]]+' || true)
		while IFS= read -r f; do
			local filename
			filename=$(echo "$f" | tr -d '"' | sed 's/\\//g')
			[[ -z "$filename" ]] && continue

			local sz
			sz=$(curl -sIL "$HOST/tests/$JOB_ID/asset/$type/$filename" | awk 'tolower($1) == "content-length:" {sub(/\r/, "", $2); s=$2} END {print s+0}')
			if [[ "$sz" -gt "$largest_size" ]]; then
				largest_size="$sz"
				largest_type="$type"
				largest_name="$filename"
			fi
		done < <(echo "$files" | tr ',' '\n')
	done < <(echo "$assets_block" | grep -oP '"[^"]+":\[[^\]]*\]' || true)

	if [[ -n "$largest_type" && -n "$largest_name" && "$largest_size" -gt 0 ]]; then
		echo "$largest_type"
		echo "$largest_name"
		return 0
	fi
	return 1
}

# _start_tcpdump LABEL
#
# Starts tcpdump in the background, capturing traffic to the openQA host.
# The sudo password prompt happens HERE, before any timing starts, so it does
# not affect the measurements.  The tcpdump PID is stored in _TCPDUMP_PID.
#
# Usage:
#   _start_tcpdump "zoqa_np_1"
_start_tcpdump() {
	local label=$1

	if [[ "$DO_TCPDUMP" != "true" ]]; then
		return
	fi

	if ! command -v tcpdump &>/dev/null; then
		echo "WARNING: tcpdump not found; --tcpdump ignored" >&2
		return
	fi

	local pcap_file="$TRACE_DIR/tcpdump_${label}.pcap"
	local host_domain
	host_domain=$(echo "$HOST" | sed 's|.*://||; s|/.*||')

	echo "    Starting tcpdump (sudo) → $pcap_file"
	sudo tcpdump -i any -w "$pcap_file" -C 200 "host $host_domain" 2>/dev/null &
	_TCPDUMP_PID=$!
	sleep 0.5 # wait for tcpdump to start capturing
}

# _stop_tcpdump
#
# Stops the background tcpdump started by _start_tcpdump.
_stop_tcpdump() {
	if [[ -n "$_TCPDUMP_PID" ]]; then
		kill "$_TCPDUMP_PID" 2>/dev/null || true
		wait "$_TCPDUMP_PID" 2>/dev/null || true
		_TCPDUMP_PID=""
	fi
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
	CURL_CMD="curl -sfL --create-dirs -o $ASSET_DIR/sanity_curl/$CURL_ASSET_NAME $HOST/tests/$JOB_ID/asset/$CURL_ASSET_TYPE/$CURL_ASSET_NAME"
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
declare -A FAILED_RUNS=()
TIMING_FAILURES=0

# _run_tool_timing LABEL CMD_TEMPLATE TIMES_ARRAY_NAME
#
# Only runs that exit 0 are appended to TIMES_ARRAY_NAME: a failed run may
# abort early (or late) and its wall-clock time says nothing about download
# speed.  The failure count is kept in FAILED_RUNS[LABEL].
#
# When --strace or --tcpdump is active, the zoqa runs are wrapped with the
# corresponding tracer.  The tracer adds a small overhead (strace) or runs
# concurrently (tcpdump); the timing numbers are still valid for comparison
# as long as the same tracer is used for all zoqa runs.
_run_tool_timing() {
	local label=$1 cmd_template=$2
	local -n _times_ref=$3
	local failures=0

	# Determine if this tool's runs should be traced.  Only zoqa runs are
	# traced: the bug is in zoqa's HTTP client, and tracing perl/curl would
	# add noise without diagnostic value.
	local is_zoqa=false
	case "$label" in
	zoqa_np | zoqa) is_zoqa=true ;;
	esac

	for i in $(seq 1 "$RUNS"); do
		local dir="$ASSET_DIR/run_${label}_${i}"
		local cmd="${cmd_template//__DIR__/$dir}"
		local result t rc
		local run_label="${label}_${i}"

		# Snapshot system metrics before the run
		_snapshot_system_metrics "$run_label"

		# Start tcpdump before the run (sudo already cached in preflight)
		if [[ "$is_zoqa" == "true" && "$DO_TCPDUMP" == "true" ]]; then
			_start_tcpdump "$run_label"
		fi

		if [[ "$is_zoqa" == "true" && "$DO_STRACE" == "true" ]]; then
			local trace_file="$TRACE_DIR/strace_${run_label}.strace"
			result=$(bash -c '
				TIMEFORMAT=%R
				{ time strace -f -e trace=network,read,readv,pwritev,write,writev,recv,recvfrom,sendto,sendmsg,connect,close -o "$1" bash -c "$2" >/dev/null 2>&1; } 2>/tmp/_manual_wall.tmp
				_rc=$?
				printf "%s %d" "$(cat /tmp/_manual_wall.tmp)" "$_rc"
			' _ "$trace_file" "$cmd")
		else
			result=$(_timed_run "$cmd")
		fi

		# Stop tcpdump after the run
		if [[ "$is_zoqa" == "true" && "$DO_TCPDUMP" == "true" ]]; then
			_stop_tcpdump
		fi

		t="${result% *}"
		rc="${result##* }"
		[[ "$rc" -eq 0 ]] && _times_ref+=("$t")
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

	FAILED_RUNS[$label]=$failures
	if [[ "$failures" -gt 0 ]]; then
		echo "    WARNING: $label had $failures/$RUNS failed runs (excluded from statistics)"
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
	_run_tool_timing "curl" "curl -sfL --create-dirs -o __DIR__/$CURL_ASSET_NAME $HOST/tests/$JOB_ID/asset/$CURL_ASSET_TYPE/$CURL_ASSET_NAME" CURL_TIMES
fi

echo ""

# Every tool that was timed needs at least one successful run, otherwise
# min/avg/max and the comparisons below are meaningless.  Stop here rather
# than spend another full download per tool on the resource phase.
_no_stats=()
[[ ${#ZOQA_NOPROG_TIMES[@]} -eq 0 ]] && _no_stats+=("zoqa-clone-job (no progress)")
[[ ${#ZOQA_TIMES[@]} -eq 0 ]] && _no_stats+=("zoqa-clone-job (--show-progress)")
[[ ${#PERL_TIMES[@]} -eq 0 ]] && _no_stats+=("openqa-clone-job")
if [[ -n "$CURL_ASSET_TYPE" && ${#CURL_TIMES[@]} -eq 0 ]]; then
	_no_stats+=("curl (largest asset)")
fi
if [[ ${#_no_stats[@]} -gt 0 ]]; then
	echo "FATAL: no successful timing runs for: ${_no_stats[*]}"
	echo "       Statistics are not possible; rerun with a higher RUNS or check the tool output."
	exit 1
fi

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

	# A failed run's resource figures are not comparable; leave the array
	# empty so the summary prints "(run failed)" for this tool.
	local exit_status
	exit_status=$(_timev_field "$tag" 'Exit status')
	if [[ "$exit_status" != "0" ]]; then
		echo "    WARNING: $label exited with status ${exit_status:-?}; metrics discarded"
		_rss_ref=()
		return
	fi

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
			"curl -sfL --create-dirs -o $rss_dir_curl/$CURL_ASSET_NAME $HOST/tests/$JOB_ID/asset/$CURL_ASSET_TYPE/$CURL_ASSET_NAME" CURL_RSS
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

# _print_timing_row LABEL RUN_LABEL TIME...
#
# RUN_LABEL is the _run_tool_timing label, used to look up FAILED_RUNS.
_print_timing_row() {
	local label=$1 run_label=$2
	shift 2
	local times=("$@")
	local times_str=""
	for t in "${times[@]}"; do
		times_str+="${t}s  "
	done
	local agg
	agg=$(_aggregate "${times[*]}")
	local failed=${FAILED_RUNS[$run_label]:-0}
	[[ "$failed" -gt 0 ]] && agg+="  ($failed failed, excluded)"
	printf "  %-28s  %-42s  %s\n" "$label" "$times_str" "$agg"
}

printf "  %-28s  %-42s  %s\n" "Tool" "Successful runs" "min / avg / max"
printf "  %-28s  %-42s  %s\n" "----------------------------" \
	"------------------------------------------" \
	"------------------------------"
_print_timing_row "zoqa (no progress)" zoqa_np "${ZOQA_NOPROG_TIMES[@]}"
_print_timing_row "zoqa (--show-progress)" zoqa "${ZOQA_TIMES[@]}"
_print_timing_row "openqa-clone-job" perl "${PERL_TIMES[@]}"
if [[ ${#CURL_TIMES[@]} -gt 0 ]]; then
	_print_timing_row "curl (largest)" curl "${CURL_TIMES[@]}"
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
if [[ "$HAS_GNU_TIME" == "true" ]]; then
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
			printf "  %-28s  %s\n" "$label" "(run failed or no data)"
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

# --- System metrics ---
if [[ -f "$ASSET_DIR/system_metrics.log" ]]; then
	echo "--- System metrics (per run) ---"
	echo ""
	while IFS= read -r _line; do
		echo "  $_line"
	done < "$ASSET_DIR/system_metrics.log"
	echo ""
fi

# --- Trace summary ---
if [[ "$DO_STRACE" == "true" || "$DO_TCPDUMP" == "true" ]]; then
	echo "--- Trace files ---"
	echo ""
	if [[ -d "$TRACE_DIR" ]]; then
		_trace_files=$(find "$TRACE_DIR" -type f \( -name '*.strace' -o -name '*.pcap' \) | sort)
		if [[ -n "$_trace_files" ]]; then
			while IFS= read -r _f; do
				_sz=$(stat -c %s "$_f" 2>/dev/null || echo 0)
				printf "  %-50s  %10s bytes\n" "${_f#"$ASSET_DIR"/}" "$_sz"
			done <<< "$_trace_files"
			echo ""
			echo "  Trace files are in: $TRACE_DIR/"
		else
			echo "  (no trace files produced)"
		fi
	fi
	echo ""
fi

echo "Done."
