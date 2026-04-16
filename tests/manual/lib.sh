# shellcheck shell=bash
# tests/manual/lib.sh — Shared helpers for manual test scripts.
#
# This file is sourced, not executed.  Each sourcing script is responsible for
# its own `set` options, cleanup trap, and test-specific logic.
#
# Required environment variables (no defaults — scripts fail immediately if unset):
#   OPENQA_HOST   — base URL of the openQA instance (e.g. https://openqa.opensuse.org)
#   OPENQA_JOB_ID — a known-good completed job ID   (e.g. 12345)
#
# Optional overrides:
#   ZOQA          — path to the zoqa binary            (default: ./zig-out/bin/zoqa)
#   RUNS          — number of timing repetitions       (default: 3)

# =============================================================================
# Default configuration
# =============================================================================

# Require OPENQA_HOST and OPENQA_JOB_ID — no hardcoded defaults.
if [[ -z "${OPENQA_HOST:-}" ]]; then
	echo "FATAL: OPENQA_HOST is not set."
	echo "       Export it before running this script, e.g.:"
	echo "         OPENQA_HOST=https://openqa.opensuse.org OPENQA_JOB_ID=12345 bash $0"
	exit 1
fi
if [[ -z "${OPENQA_JOB_ID:-}" ]]; then
	echo "FATAL: OPENQA_JOB_ID is not set."
	echo "       Export it before running this script, e.g.:"
	echo "         OPENQA_HOST=https://openqa.opensuse.org OPENQA_JOB_ID=12345 bash $0"
	exit 1
fi

# Variables below are used by sourcing scripts; shellcheck can't see that.
# shellcheck disable=SC2034
HOST="$OPENQA_HOST"
# shellcheck disable=SC2034
JOB_ID="$OPENQA_JOB_ID"
ZOQA="${ZOQA:-./zig-out/bin/zoqa}"
RUNS="${RUNS:-3}"

PASS=0
FAIL=0
_seq=0

HAS_GNU_TIME=false

# Report arrays for the summary block (consumed by sourcing scripts).
_timing_report=()
_rss_report=()

# =============================================================================
# Preflight helpers
# =============================================================================

require_zoqa() {
	if [[ ! -x "$ZOQA" ]]; then
		echo "FATAL: zoqa binary not found or not executable at: $ZOQA"
		echo "       Run 'zig build' first."
		exit 1
	fi
	echo "  zoqa:       $ZOQA"
}

require_openqa_cli() {
	if ! command -v openqa-cli &>/dev/null; then
		echo "FATAL: openqa-cli not found in PATH."
		echo "       Install it with: zypper install openQA-client"
		exit 1
	fi
	echo "  openqa-cli: $(command -v openqa-cli)"
}

require_python3() {
	if ! command -v python3 &>/dev/null; then
		echo "FATAL: python3 not found in PATH (needed for JSON validation)."
		exit 1
	fi
	echo "  python3:    $(command -v python3)"
}

detect_gnu_time() {
	if [[ -x /usr/bin/time ]]; then
		HAS_GNU_TIME=true
		echo "  /usr/bin/time: available (RSS measurement enabled)"
	else
		echo "  /usr/bin/time: NOT found (RSS measurement will be skipped)"
	fi
}

# =============================================================================
# Measurement helpers
# =============================================================================

# _wall_time CMD_STRING
#
# Measures wall-clock execution time of a command string.  stdout/stderr of
# the command are discarded; only the elapsed time in decimal seconds is
# printed.  Uses exactly two levels of bash (one for TIMEFORMAT/time capture,
# one for the command itself).
_wall_time() {
	bash -c 'TIMEFORMAT=%R; { time bash -c "$1" >/dev/null 2>&1; } 2>/tmp/_manual_wall.tmp; cat /tmp/_manual_wall.tmp' _ "$1"
}

# _peak_rss_kb TAG CMD_STRING
#
# Measures peak RSS (kB) of a command string using /usr/bin/time -v.
# Saves full output to /tmp/_perf_timev_TAG.txt for later extraction.
# Prints the "Maximum resident set size (kbytes)" value, or "0" on failure.
_peak_rss_kb() {
	local tag=$1 cmd=$2

	if [[ "$HAS_GNU_TIME" != "true" ]]; then
		echo "0"
		return
	fi

	/usr/bin/time -v bash -c "$cmd" >/dev/null 2>/tmp/_perf_timev_"${tag}".txt || true

	grep 'Maximum resident set size' /tmp/_perf_timev_"${tag}".txt 2>/dev/null |
		cut -d: -f2 | tr -d ' \t' || echo "0"
}

# _timev_field TAG FIELD_PATTERN
#
# Extracts a numeric value from a saved /usr/bin/time -v output file.
_timev_field() {
	local tag=$1 field=$2
	grep "$field" /tmp/_perf_timev_"${tag}".txt 2>/dev/null |
		cut -d: -f2 | tr -d ' \t' || echo "?"
}

# _aggregate "t1 t2 t3 ..."
#
# Computes min/avg/max from a space-separated list of decimal numbers.
# Prints: "min=X.XXX  avg=X.XXX  max=X.XXX"
_aggregate() {
	echo "$1" | awk '{
		min=$1; max=$1; sum=0
		for (i=1; i<=NF; i++) {
			if ($i < min) min=$i
			if ($i > max) max=$i
			sum += $i
		}
		printf "min=%.3f  avg=%.3f  max=%.3f", min, sum/NF, max
	}'
}

# =============================================================================
# Correctness helpers
# =============================================================================

# _check LABEL RC
#
# If $2 is 0, records PASS; otherwise FAIL.
_check() {
	local label=$1 rc=$2

	if [[ "$rc" -eq 0 ]]; then
		PASS=$((PASS + 1))
		echo "    PASS: $label"
	else
		FAIL=$((FAIL + 1))
		echo "    FAIL: $label" >&2
	fi
}

# _valid_json TEXT
#
# Returns 0 if TEXT is valid JSON, 1 otherwise.
_valid_json() {
	echo "$1" | python3 -m json.tool >/dev/null 2>&1
}

# _json_field TEXT PYTHON_EXPR
#
# Evaluates a Python expression against parsed JSON.  Returns 0 if the
# expression evaluates truthy, 1 otherwise.
# Example: _json_field "$body" "d.get('job', {}).get('id') == $JOB_ID"
_json_field() {
	local text=$1 expr=$2
	echo "$text" | python3 -c "
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if ($expr) else 1)
" 2>/dev/null
}

# =============================================================================
# Performance comparison helpers
# =============================================================================

# _run_timing LABEL ZIG_CMD PERL_CMD [RUNS]
#
# Runs both command strings RUNS times, collects wall-clock times, computes
# aggregates, and stores the results in _timing_report.
_run_timing() {
	local label=$1 zig_cmd=$2 perl_cmd=$3 runs=${4:-$RUNS}

	local t z_times=() p_times=()

	for _ in $(seq 1 "$runs"); do
		t=$(_wall_time "$zig_cmd")
		z_times+=("$t")
	done

	for _ in $(seq 1 "$runs"); do
		t=$(_wall_time "$perl_cmd")
		p_times+=("$t")
	done

	local z_agg p_agg
	z_agg=$(_aggregate "${z_times[*]}")
	p_agg=$(_aggregate "${p_times[*]}")

	# Extract averages for comparison
	local z_avg p_avg
	z_avg=$(echo "$z_agg" | awk '{print $2}' | cut -d= -f2)
	p_avg=$(echo "$p_agg" | awk '{print $2}' | cut -d= -f2)

	local cmp_msg=""
	if [[ -n "$p_avg" && -n "$z_avg" && "$p_avg" != "0.000" && "$z_avg" != "0.000" ]]; then
		cmp_msg=$(awk "BEGIN {
			p=$p_avg; z=$z_avg;
			if (z < p) {
				pct = (p - z) / p * 100;
				spd = p / z;
				printf \"Zig is %.1f%% faster (%.1fx speedup)\", pct, spd;
			} else {
				pct = (z - p) / p * 100;
				spd = z / p;
				printf \"Zig is %.1f%% slower (%.1fx slowdown)\", pct, spd;
			}
		}")
	fi

	local z_list="" p_list=""
	for t in "${z_times[@]}"; do z_list+=" ${t}s"; done
	for t in "${p_times[@]}"; do p_list+=" ${t}s"; done

	_timing_report+=("$label")
	_timing_report+=("  ZIG $z_list  ($z_agg)")
	_timing_report+=("  PERL$p_list  ($p_agg)")
	[[ -n "$cmp_msg" ]] && _timing_report+=("  $cmp_msg")
	_timing_report+=("")
}

# _run_rss LABEL ZIG_CMD PERL_CMD
#
# Measures peak RSS for both command strings and stores in _rss_report.
# Derives unique file tags from the label to avoid temp-file collisions.
_run_rss() {
	local label=$1 zig_cmd=$2 perl_cmd=$3

	local tag
	tag=$(echo "${label}" | tr -cs 'a-zA-Z0-9' '_' | head -c 20)

	if [[ "$HAS_GNU_TIME" != "true" ]]; then
		_rss_report+=("$label")
		_rss_report+=("  (skipped — /usr/bin/time not available)")
		_rss_report+=("")
		return
	fi

	local zig_rss perl_rss
	zig_rss=$(_peak_rss_kb "${tag}_zig" "$zig_cmd")
	perl_rss=$(_peak_rss_kb "${tag}_perl" "$perl_cmd")

	local msg
	if [[ -n "$zig_rss" && -n "$perl_rss" && "$zig_rss" -gt 0 && "$perl_rss" -gt 0 ]]; then
		if [[ "$zig_rss" -lt "$perl_rss" ]]; then
			local pct=$(((perl_rss - zig_rss) * 100 / perl_rss))
			msg="Zig uses ${pct}% less memory"
		else
			local pct=$(((zig_rss - perl_rss) * 100 / perl_rss))
			msg="Zig uses ${pct}% more memory"
		fi
	else
		msg="measurement incomplete"
	fi

	# Gather extra metrics from /usr/bin/time -v output
	local z_maj z_min z_usr z_sys z_vcs z_ics
	local p_maj p_min p_usr p_sys p_vcs p_ics
	z_maj=$(_timev_field "${tag}_zig" 'Major (requiring I/O) page faults')
	z_min=$(_timev_field "${tag}_zig" 'Minor (reclaiming a frame) page faults')
	z_usr=$(_timev_field "${tag}_zig" 'User time')
	z_sys=$(_timev_field "${tag}_zig" 'System time')
	z_vcs=$(_timev_field "${tag}_zig" 'Voluntary context switches')
	z_ics=$(_timev_field "${tag}_zig" 'Involuntary context switches')
	p_maj=$(_timev_field "${tag}_perl" 'Major (requiring I/O) page faults')
	p_min=$(_timev_field "${tag}_perl" 'Minor (reclaiming a frame) page faults')
	p_usr=$(_timev_field "${tag}_perl" 'User time')
	p_sys=$(_timev_field "${tag}_perl" 'System time')
	p_vcs=$(_timev_field "${tag}_perl" 'Voluntary context switches')
	p_ics=$(_timev_field "${tag}_perl" 'Involuntary context switches')

	_rss_report+=("$label")
	_rss_report+=("  ZIG peak RSS: ${zig_rss} kB   PERL peak RSS: ${perl_rss} kB   ($msg)")
	_rss_report+=("  $(printf "%-36s  ZIG: %6s   PERL: %6s" "Major page faults (I/O-backed):" "${z_maj}" "${p_maj}")")
	_rss_report+=("  $(printf "%-36s  ZIG: %6s   PERL: %6s" "Minor page faults (anon/cached):" "${z_min}" "${p_min}")")
	_rss_report+=("  $(printf "%-36s  ZIG: %8s PERL: %8s" "User time (s):" "${z_usr}" "${p_usr}")")
	_rss_report+=("  $(printf "%-36s  ZIG: %8s PERL: %8s" "System time (s):" "${z_sys}" "${p_sys}")")
	_rss_report+=("  $(printf "%-36s  ZIG: %6s   PERL: %6s" "Voluntary context switches:" "${z_vcs}" "${p_vcs}")")
	_rss_report+=("  $(printf "%-36s  ZIG: %6s   PERL: %6s" "Involuntary context switches:" "${z_ics}" "${p_ics}")")
	_rss_report+=("")
}

# _maybe_timev CMD...
#
# Wraps a command with /usr/bin/time -v if GNU time is available;
# otherwise runs the command directly.
_maybe_timev() {
	if [[ "$HAS_GNU_TIME" == "true" ]]; then
		/usr/bin/time -v "$@"
	else
		"$@"
	fi
}
