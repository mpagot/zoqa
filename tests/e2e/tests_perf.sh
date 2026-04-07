#!/usr/bin/env bash
# tests_perf.sh — Section G: Performance comparison tests.
#
# Compares wall-clock execution time and peak RSS (resident set size) between
# the Perl reference implementation (openqa-cli) and zoqa (Zig).
#
# TIMING TESTS (perf_timing):
#   Logs wall-clock seconds for N repeated invocations of each implementation.
#   Results are informational only — no PASS/FAIL threshold is enforced.
#   Timing in a containerised environment is inherently noisy; the goal is to
#   have visible numbers in CI rather than to gate on them.
#
# RSS TESTS (perf_rss):
#   Measures peak RSS for each implementation using /usr/bin/time -v (GNU time).
#
#   RSS (Resident Set Size) is the portion of a process's virtual address space
#   currently backed by physical RAM — pages that are actually in memory, not
#   swapped out or mapped but not yet faulted in.  It is the standard
#   single-number proxy for "how much RAM is this process using right now".
#
#   /usr/bin/time -v uses getrusage(2) to obtain ru_maxrss, the kernel's own
#   monotonically non-decreasing high-water mark of RSS, read atomically when
#   the child exits.  This is equivalent to the VmHWM field of
#   /proc/PID/status (the kernel's internal peak tracker) but avoids any race
#   between process exit and /proc entry cleanup.  GNU time is absent from the
#   base openQA container image; setup.sh installs it with zypper.
#
#   All results are informational only — no PASS/FAIL threshold is enforced.
#   Results are collected during execution and printed in a consolidated
#   summary block at the end of this script. No PASS/FAIL counters are touched.
#
#   In addition to peak RSS, perf_rss prints the following informational
#   metrics from the /usr/bin/time -v output:
#     - Major page faults (I/O-backed: cold-start disk pressure)
#     - Minor page faults (anonymous/cached: heap growth, stack expansion)
#     - User time and system time in seconds
#     - Voluntary and involuntary context switches
#
#   Expected ballpark values:
#     - openqa-cli loads a full Perl + Mojolicious runtime (~55 MB).
#     - zoqa is a statically linked Zig binary (~4 MB).
#   If the RSS value for either process is 0 (measurement failed), a note
#   is printed and the comparison is skipped.
#
# SCENARIOS COVERED:
#   Plain request     — baseline GET with no extra flag (network + JSON decode only)
#   Config-file read  — OPENQA_CONFIG=/etc/openqa forces both impls to read
#                       /etc/openqa/client.conf from disk on every invocation
#   Env-var creds     — credentials supplied via --apikey/--apisecret CLI flags
#                       (value expanded from env on the host side at test time);
#                       exercises the credential-from-flag code path
#   Pretty-print      — --pretty forces both impls to JSON-format and re-indent
#                       the server response, exercising the formatting code path
#
# PREREQUISITES inside the container:
#   - bash          (TIMEFORMAT="%R" builtin timer for wall-clock timing)
#   - /usr/bin/time (from the 'time' package, installed in setup.sh) for peak
#                   RSS measurement via /usr/bin/time -v.  GNU time is absent
#                   from the base openQA image; setup.sh adds it with zypper.
#   - grep, cut, tr (for parsing /usr/bin/time -v output — no awk needed)
#
# Sourced by tests.sh after helper functions are defined.
# Do NOT execute this file directly.
#
# Assumes from the calling scope:
#   ZIG_EXE, PERL_EXE, LOG_DIR,
#   JOB_ID, OPENQA_API_KEY, OPENQA_API_SECRET

echo "==> [perf] Running performance comparison tests..."

# -----------------------------------------------------------------------------
# Private helpers — prefixed with _perf_ to avoid polluting the shared scope
# -----------------------------------------------------------------------------

# Measures the wall-clock execution time of a command running inside the container.
#
# Uses bash's built-in 'time' utility with TIMEFORMAT="%R" to obtain high-precision
# duration without requiring an external 'time' binary. The command's stdout and
# stderr are discarded; only the duration is printed to stdout.
#
# Arguments:
#   $1 (env_vars): A string of environment variable assignments (e.g., "VAR=val")
#                  to prepend to the command. Use "" for no variables.
#   $2 (cmd):      The command string to execute and measure.
#
# Return code:
#   Returns the exit status of the measurement process (0 on success).
#
# Environment variables:
#   TIMEFORMAT: Set to "%R" internally to force the decimal-seconds output format.
_perf_wall_time_s() {
	local env_vars=$1
	local cmd=$2
	container_exec bash -c "
TIMEFORMAT='%R'
{ time $env_vars $cmd >/dev/null 2>&1; } 2>/tmp/_perf_wall.out
cat /tmp/_perf_wall.out
" 2>/dev/null
}

# _perf_peak_rss_kb ENV_VARS CMD_STR
#
# Measures peak RSS (kB) of ENV_VARS CMD_STR running inside the container
# using /usr/bin/time -v (GNU time, installed in setup.sh).
# Prints the "Maximum resident set size (kbytes)" value, or "0" if the run
# fails or the field cannot be parsed.
# ENV_VARS may be "" for none.
#
# Why /usr/bin/time -v rather than /proc/PID/status polling?
#   The previous approach polled VmRSS from /proc/PID/status in a tight
#   kill-0 busy-wait loop, manually tracking the maximum across samples.
#   This worked but had two drawbacks:
#     1. VmRSS is a point-in-time snapshot; polling at arbitrary intervals
#        can miss the true peak if the process is short-lived.
#     2. The busy-wait forks a grep subprocess on every iteration (~5000-20000
#        forks/s), creating unnecessary CPU pressure.
#   The kernel tracks the high-water mark of RSS itself in the VmHWM field
#   of /proc/PID/status, but reading it after the process exits is a narrow
#   TOCTOU race.
#
#   /usr/bin/time -v solves both problems: the kernel records the peak RSS
#   via getrusage(2) (ru_maxrss) and GNU time reads it when the child exits
#   — atomically, with no race and no polling.  The "Maximum resident set
#   size (kbytes)" field in the -v output is exactly ru_maxrss * 1024 on
#   Linux, making it the definitive peak-RSS number.
#
#   /usr/bin/time is absent from the base openQA container image; setup.sh
#   installs it with `zypper install -y time` during bootstrap.
#
# Also writes the full /usr/bin/time -v output to a per-run file:
#   /tmp/_perf_timev_<tag>.txt  (where tag = first word of $cmd)
# so the caller can extract additional metrics from it.
_perf_peak_rss_kb() {
	local env_vars=$1
	local cmd=$2

	if [[ "${DRY_RUN:-false}" == "true" ]]; then
		echo "[DRY-RUN] _perf_peak_rss_kb: $env_vars $cmd"
		echo "0"
		return
	fi

	# Derive a safe tag from the first token of cmd for the temp-file name.
	local tag
	tag=$(echo "$cmd" | cut -d' ' -f1 | tr -cs 'a-zA-Z0-9_-' '_')

	# Run under /usr/bin/time -v inside the container.  time -v writes its
	# report to stderr; stdout and the program's own stderr are discarded.
	# ENV_VARS must precede /usr/bin/time so bash parses them as assignments.
	container_exec bash -c \
		"$env_vars /usr/bin/time -v $cmd >/dev/null 2>/tmp/_perf_timev_${tag}.txt" \
		</dev/null 2>/dev/null || true

	# Extract the peak RSS field.  GNU time writes (on openSUSE):
	#   "\tMaximum resident set size (kbytes): 12345"
	container_exec bash -c \
		"grep 'Maximum resident set size' /tmp/_perf_timev_${tag}.txt | cut -d: -f2 | tr -d ' \t'" \
		</dev/null 2>/dev/null
}

# _perf_timev_field TAG FIELD_PATTERN
#
# Reads the /usr/bin/time -v output file written by a previous
# _perf_peak_rss_kb call and extracts the numeric value after FIELD_PATTERN.
# TAG must match the tag computed inside _perf_peak_rss_kb.
# Returns "" if the file or field is absent.
_perf_timev_field() {
	local tag=$1
	local field=$2
	container_exec bash -c \
		"grep '$field' /tmp/_perf_timev_${tag}.txt 2>/dev/null | cut -d: -f2 | tr -d ' \t'" \
		</dev/null 2>/dev/null
}

# -----------------------------------------------------------------------------
# perf_timing LABEL ENV_VARS API_ARGS [RUNS]
#
# Runs each implementation RUNS times (default 3) and logs the wall-clock time
# for every run. Results are accumulated into _perf_timing_report for the
# end-of-suite summary block, including min/avg/max and speedup percentage.
# No PASS/FAIL counter is touched.
#
# Parameters mirror run_comparison: LABEL ENV_VARS API_ARGS.
# -----------------------------------------------------------------------------
perf_timing() {
	local label=$1
	local env_vars=$2
	local api_args=$3
	local runs=${4:-3}

	_perf_t_seq=$((_perf_t_seq + 1))
	local tid="PERF-T${_perf_t_seq}"
	echo "  $tid  $label — timing (${runs} runs)..."

	local t p_times=() z_times=()

	# Run Perl
	for _ in $(seq 1 "$runs"); do
		t=$(_perf_wall_time_s "$env_vars" "$PERL_EXE api --host http://localhost $api_args")
		p_times+=("$t")
	done

	# Run Zig
	for _ in $(seq 1 "$runs"); do
		t=$(_perf_wall_time_s "$env_vars" "$ZIG_EXE api --host http://localhost $api_args")
		z_times+=("$t")
	done

	# Use awk inside the container (always available) to aggregate
	local p_agg z_agg p_avg z_avg
	p_agg=$(container_exec bash -c "echo \"${p_times[*]}\" | awk '{min=\$1; max=\$1; sum=0; for(i=1;i<=NF;i++) {if(\$i<min) min=\$i; if(\$i>max) max=\$i; sum+=\$i} printf \"min=%.3f  avg=%.3f  max=%.3f\", min, sum/NF, max}'")
	z_agg=$(container_exec bash -c "echo \"${z_times[*]}\" | awk '{min=\$1; max=\$1; sum=0; for(i=1;i<=NF;i++) {if(\$i<min) min=\$i; if(\$i>max) max=\$i; sum+=\$i} printf \"min=%.3f  avg=%.3f  max=%.3f\", min, sum/NF, max}'")

	# Extract just the avg value for the percentage comparison
	p_avg=$(echo "$p_agg" | awk '{print $2}' | cut -d= -f2)
	z_avg=$(echo "$z_agg" | awk '{print $2}' | cut -d= -f2)

	# Calculate speedup percentage
	local cmp_msg=""
	if [[ -n "$p_avg" && -n "$z_avg" && "$p_avg" != "0.000" && "$z_avg" != "0.000" ]]; then
		cmp_msg=$(container_exec bash -c "awk 'BEGIN {
			p=$p_avg; z=$z_avg;
			if (z < p) {
				pct = (p - z) / p * 100;
				spd = p / z;
				printf \"INFO: Zig is %.1f%% faster (%.1fx speedup)\", pct, spd;
			} else {
				pct = (z - p) / p * 100;
				spd = z / p;
				printf \"INFO: Zig is %.1f%% slower (%.1fx slowdown)\", pct, spd;
			}
		}'")
	fi

	# Format the individual times list
	local p_list="" z_list=""
	for t in "${p_times[@]}"; do p_list+=" ${t}s"; done
	for t in "${z_times[@]}"; do z_list+=" ${t}s"; done

	# Store in the report array
	_perf_timing_report+=("$tid  $label")
	_perf_timing_report+=("  PERL $p_list  ($p_agg)")
	_perf_timing_report+=("  ZIG  $z_list  ($z_agg)")
	if [[ -n "$cmp_msg" ]]; then
		_perf_timing_report+=("  $cmp_msg")
	fi
	_perf_timing_report+=("")
}

# -----------------------------------------------------------------------------
# perf_rss LABEL ENV_VARS API_ARGS
#
# Measures peak RSS for each implementation using /usr/bin/time -v.
# WARNs (immediately to stdout) if zig_rss or perl_rss == 0 (likely means
# measurement failed; GNU time should always capture a value unless the
# binary itself does not exist).
#
# Also gathers informational metrics from the /usr/bin/time -v output.
# All results are accumulated into _perf_rss_report for the end-of-suite
# summary block. No PASS/FAIL counter is touched.
#
# Parameters mirror run_comparison: LABEL ENV_VARS API_ARGS.
# -----------------------------------------------------------------------------
perf_rss() {
	local label=$1
	local env_vars=$2
	local api_args=$3

	_perf_r_seq=$((_perf_r_seq + 1))
	local tid="PERF-R${_perf_r_seq}"
	echo "  $tid  $label — RSS..."

	# Derive the same tags that _perf_peak_rss_kb uses, so we can call
	# _perf_timev_field to pull additional metrics from the saved output files.
	local perl_tag zig_tag
	perl_tag=$(echo "$PERL_EXE" | cut -d' ' -f1 | tr -cs 'a-zA-Z0-9_-' '_')
	zig_tag=$(echo "$ZIG_EXE" | cut -d' ' -f1 | tr -cs 'a-zA-Z0-9_-' '_')

	local perl_rss zig_rss
	perl_rss=$(_perf_peak_rss_kb "$env_vars" "$PERL_EXE api --host http://localhost $api_args")
	zig_rss=$(_perf_peak_rss_kb "$env_vars" "$ZIG_EXE api --host http://localhost $api_args")

	# Guard: if Perl RSS is 0 we cannot make a meaningful comparison.
	if [[ -z "$perl_rss" || "$perl_rss" -eq 0 ]]; then
		die "Could not measure Perl peak RSS for $label (/usr/bin/time -v may have failed)"
	fi

	# Guard: if Zig RSS is 0 measurement failed.
	if [[ -z "$zig_rss" || "$zig_rss" -eq 0 ]]; then
		die "Could not measure Zig peak RSS for $label (/usr/bin/time -v may have failed)"
	fi

	local pct msg
	if [[ "$zig_rss" -lt "$perl_rss" ]]; then
		pct=$(((perl_rss - zig_rss) * 100 / perl_rss))
		msg="INFO: Zig uses less memory: ${zig_rss} kB < ${perl_rss} kB (${pct}% less)"
	else
		pct=$(((zig_rss - perl_rss) * 100 / perl_rss))
		msg="INFO: Zig uses more memory: ${zig_rss} kB >= ${perl_rss} kB (${pct}% more)"
	fi

	# --- Informational metrics (no PASS/FAIL) ---
	# Extract from the /usr/bin/time -v output files written by _perf_peak_rss_kb.
	local p_maj p_min p_usr p_sys p_vcs p_ics
	local z_maj z_min z_usr z_sys z_vcs z_ics
	p_maj=$(_perf_timev_field "$perl_tag" 'Major (requiring I/O) page faults')
	p_min=$(_perf_timev_field "$perl_tag" 'Minor (reclaiming a frame) page faults')
	p_usr=$(_perf_timev_field "$perl_tag" 'User time')
	p_sys=$(_perf_timev_field "$perl_tag" 'System time')
	p_vcs=$(_perf_timev_field "$perl_tag" 'Voluntary context switches')
	p_ics=$(_perf_timev_field "$perl_tag" 'Involuntary context switches')
	z_maj=$(_perf_timev_field "$zig_tag" 'Major (requiring I/O) page faults')
	z_min=$(_perf_timev_field "$zig_tag" 'Minor (reclaiming a frame) page faults')
	z_usr=$(_perf_timev_field "$zig_tag" 'User time')
	z_sys=$(_perf_timev_field "$zig_tag" 'System time')
	z_vcs=$(_perf_timev_field "$zig_tag" 'Voluntary context switches')
	z_ics=$(_perf_timev_field "$zig_tag" 'Involuntary context switches')

	# Build report block
	_perf_rss_report+=("$tid  $label")
	_perf_rss_report+=("  PERL peak RSS: ${perl_rss} kB   ZIG peak RSS: ${zig_rss} kB")
	_perf_rss_report+=("  $msg")
	_perf_rss_report+=("  $(printf "%-36s  PERL: %6s   ZIG: %6s" "Major page faults (I/O-backed):" "${p_maj:-?}" "${z_maj:-?}")")
	_perf_rss_report+=("  $(printf "%-36s  PERL: %6s   ZIG: %6s" "Minor page faults (anon/cached):" "${p_min:-?}" "${z_min:-?}")")
	_perf_rss_report+=("  $(printf "%-36s  PERL: %8s ZIG: %8s" "User time (s):" "${p_usr:-?}" "${z_usr:-?}")")
	_perf_rss_report+=("  $(printf "%-36s  PERL: %8s ZIG: %8s" "System time (s):" "${p_sys:-?}" "${z_sys:-?}")")
	_perf_rss_report+=("  $(printf "%-36s  PERL: %6s   ZIG: %6s" "Voluntary context switches:" "${p_vcs:-?}" "${z_vcs:-?}")")
	_perf_rss_report+=("  $(printf "%-36s  PERL: %6s   ZIG: %6s" "Involuntary context switches:" "${p_ics:-?}" "${z_ics:-?}")")
	_perf_rss_report+=("")
}

# =============================================================================
# Tests
# =============================================================================

# --- Scenario: plain request (baseline) --------------------------------------
#
# No config file, no extra flags.  Exercises the minimal code path: argument
# parsing → HTTP GET → JSON decode → stdout write.

# Test PERF-T1: Wall-clock timing — jobs/overview (list endpoint).
# openqa-cli loads the full Perl + Mojolicious runtime on every invocation.
# zoqa is a statically linked binary; startup is typically 30-50× faster.
perf_timing "plain jobs/overview" "" "jobs/overview" 3

# Test PERF-T2: Wall-clock timing — jobs/:id (single-resource endpoint).
# Single-resource GETs are cheaper server-side than list queries; the timing
# gap between Perl and Zig is still dominated by startup overhead, not I/O.
perf_timing "plain jobs/:id" "" "jobs/$JOB_ID" 3

# Test PERF-R1: Peak RSS — jobs/overview.
# Expected: Perl ~50-60 MB (full Mojolicious stack), Zig ~3-8 MB.
perf_rss "plain jobs/overview" "" "jobs/overview"

# Test PERF-R2: Peak RSS — jobs/:id.
perf_rss "plain jobs/:id" "" "jobs/$JOB_ID"

# --- Scenario: config-file read ----------------------------------------------
#
# OPENQA_CONFIG=/etc/openqa forces both implementations to locate and parse
# /etc/openqa/client.conf on every invocation.  This adds a disk read + INI
# parse on top of the baseline, exercising the config-file code path.

# Test PERF-T3: Wall-clock timing — config-file credential resolution.
perf_timing "config-file creds jobs/overview" "OPENQA_CONFIG=/etc/openqa" "jobs/overview" 3

# Test PERF-R3: Peak RSS — config-file credential resolution.
# Perl loads the config parser as part of its already-large runtime; the delta
# vs baseline is small.  Zig's RSS increases only by the config-file buffer.
perf_rss "config-file creds jobs/overview" "OPENQA_CONFIG=/etc/openqa" "jobs/overview"

# --- Scenario: env-var credentials (CLI flags) -------------------------------
#
# Credentials are supplied via --apikey / --apisecret CLI flags whose values
# are taken from $OPENQA_API_KEY / $OPENQA_API_SECRET (expanded on the host
# before being passed to the container).  Both implementations support these
# flags.  This exercises the argument-parser credential path: no config file
# is read; the key/secret come directly from the process's argument vector.
#
# run_comparison is not used here because we need to capture raw timings rather
# than checking exit codes.

# Test PERF-T4: Wall-clock timing — CLI-flag credential passing.
perf_timing "CLI-flag creds jobs/overview" \
	"" \
	"--apikey $OPENQA_API_KEY --apisecret $OPENQA_API_SECRET jobs/overview" \
	3

# Test PERF-R4: Peak RSS — CLI-flag credential passing.
perf_rss "CLI-flag creds jobs/overview" \
	"" \
	"--apikey $OPENQA_API_KEY --apisecret $OPENQA_API_SECRET jobs/overview"

# --- Scenario: pretty-print --------------------------------------------------
#
# --pretty instructs both implementations to JSON-format and re-indent the
# server response before writing it to stdout.  This adds a JSON parse +
# serialise step on top of the baseline, exercising the output-formatting path.

# Test PERF-T5: Wall-clock timing — pretty-printed jobs/overview.
perf_timing "--pretty jobs/overview" "" "--pretty jobs/overview" 3

# Test PERF-R5: Peak RSS — pretty-printed jobs/overview.
# Perl's RSS is dominated by the Mojolicious runtime regardless of formatting.
# Zig allocates a temporary buffer to hold and re-format the JSON body; RSS
# grows slightly relative to the plain baseline but remains far below Perl.
perf_rss "--pretty jobs/overview" "" "--pretty jobs/overview"

# =============================================================================
# Summary Report
# =============================================================================
echo ""
echo "=== [perf] Performance Summary ==="
echo ""
echo "--- Timing (wall-clock seconds) ---"
for line in "${_perf_timing_report[@]}"; do echo "$line"; done
echo "--- RSS & Process Metrics ---"
for line in "${_perf_rss_report[@]}"; do echo "$line"; done
