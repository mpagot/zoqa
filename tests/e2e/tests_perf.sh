#!/usr/bin/env bash
# shellcheck disable=SC2153
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
# INTERPRETER BASELINE (perf_baseline):
#   Measures the fixed overhead of loading the Perl interpreter and the
#   Mojolicious framework, using trivial Perl one-liners that do no real work.
#   This lets readers decompose openqa-cli timings into "framework startup"
#   vs. "actual HTTP + business logic".  Two measurements are collected:
#     PERF-B1: perl -e '1'                     — bare interpreter startup
#     PERF-B2: perl -MMojo::UserAgent -e '1'   — interpreter + framework load
#   Results are reported separately in the summary under "Interpreter Baseline".
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
#   GROUP_ID, OPENQA_API_KEY, OPENQA_API_SECRET

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "==> [perf] Running performance comparison tests..."

# Ensure both jobs exist (reuses from earlier suites if already set).
ensure_basic_job
ensure_rich_job

# _perf_wall_time_s, _perf_peak_rss_kb, _perf_timev_field are defined in lib.sh.

# -----------------------------------------------------------------------------
# _perf_aggregate TIMES...
#
# Computes min/avg/max of the space-separated TIMES array using awk inside the
# container.  Prints "min=%.3f  avg=%.3f  max=%.3f".
# -----------------------------------------------------------------------------
_perf_aggregate() {
	container_exec bash -c "echo \"$*\" | awk '{min=\$1; max=\$1; sum=0; for(i=1;i<=NF;i++) {if(\$i<min) min=\$i; if(\$i>max) max=\$i; sum+=\$i} printf \"min=%.3f  avg=%.3f  max=%.3f\", min, sum/NF, max}'"
}

# -----------------------------------------------------------------------------
# _perf_rss_generic LABEL ENV_VARS PERL_CMD ZIG_CMD
#
# Generic peak-RSS measurement for any pair of Perl/Zig invocations.
# Accumulates results into _perf_rss_report.  No PASS/FAIL counter is touched.
#
# Both PERL_CMD and ZIG_CMD are full command strings (without env_vars prefix).
# The tag for _perf_peak_rss_kb is derived automatically from the first token
# of each command (typically the binary path).
# -----------------------------------------------------------------------------
_perf_rss_generic() {
	local label=$1
	local env_vars=$2
	local perl_cmd=$3
	local zig_cmd=$4

	_perf_r_seq=$((_perf_r_seq + 1))
	local tid="PERF-R${_perf_r_seq}"
	echo "  $tid  $label — RSS..."

	# Derive the same tags that _perf_peak_rss_kb uses internally.
	local perl_tag zig_tag
	perl_tag=$(echo "$PERL_EXE" | cut -d' ' -f1 | tr -cs 'a-zA-Z0-9_-' '_')
	zig_tag=$(echo "$ZIG_EXE" | cut -d' ' -f1 | tr -cs 'a-zA-Z0-9_-' '_')

	local perl_rss zig_rss
	perl_rss=$(_perf_peak_rss_kb "$env_vars" "$perl_cmd")
	zig_rss=$(_perf_peak_rss_kb "$env_vars" "$zig_cmd")

	if [[ "$DRY_RUN" == "false" && (-z "$perl_rss" || "$perl_rss" -eq 0) ]]; then
		die "Could not measure Perl peak RSS for $label (/usr/bin/time -v may have failed)"
	fi
	if [[ "$DRY_RUN" == "false" && (-z "$zig_rss" || "$zig_rss" -eq 0) ]]; then
		die "Could not measure Zig peak RSS for $label (/usr/bin/time -v may have failed)"
	fi

	local pct msg
	if [[ "$DRY_RUN" == "true" ]]; then
		msg="INFO: [DRY-RUN] skipping memory comparison"
	elif [[ "$zig_rss" -lt "$perl_rss" ]]; then
		pct=$(((perl_rss - zig_rss) * 100 / perl_rss))
		msg="INFO: Zig uses less memory: ${zig_rss} kB < ${perl_rss} kB (${pct}% less)"
	else
		pct=$(((zig_rss - perl_rss) * 100 / perl_rss))
		msg="INFO: Zig uses more memory: ${zig_rss} kB >= ${perl_rss} kB (${pct}% more)"
	fi

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

# -----------------------------------------------------------------------------
# perf_baseline LABEL CMD [RUNS]
#
# Measures the fixed overhead of a Perl command that does no real work.
# Collects wall-clock timing (RUNS repetitions, default 3) and peak RSS via
# _perf_peak_rss_kb (which uses /usr/bin/time -v).
#
# Results are accumulated into _perf_baseline_report for the summary block.
# No PASS/FAIL counter is touched.
# -----------------------------------------------------------------------------
perf_baseline() {
	local label=$1
	local cmd=$2
	local runs=${3:-3}

	_perf_b_seq=$((_perf_b_seq + 1))
	local tid="PERF-B${_perf_b_seq}"
	echo "  $tid  $label — baseline (${runs} runs + RSS)..."

	# --- Wall-clock timing ---
	local t times=()
	for _ in $(seq 1 "$runs"); do
		t=$(_perf_wall_time_s "" "$cmd")
		times+=("$t")
	done

	local agg
	agg=$(_perf_aggregate "${times[*]}")

	local list=""
	for t in "${times[@]}"; do list+=" ${t}s"; done

	# --- Peak RSS ---
	local rss minor_faults user_time
	rss=$(_perf_peak_rss_kb "" "$cmd")
	if [[ "${DRY_RUN:-false}" != "true" ]]; then
		# Derive tag to read additional fields from the saved time -v output.
		local tag
		tag=$(echo "$cmd" | cut -d' ' -f1 | tr -cs 'a-zA-Z0-9_-' '_')
		minor_faults=$(_perf_timev_field "$tag" 'Minor (reclaiming a frame) page faults')
		user_time=$(_perf_timev_field "$tag" 'User time')
	fi

	_perf_baseline_report+=("$tid  $label")
	_perf_baseline_report+=("  wall:$list  ($agg)")
	if [[ "${DRY_RUN:-false}" == "true" ]]; then
		_perf_baseline_report+=("  peak RSS: [DRY-RUN]   minor faults: [DRY-RUN]   user time: [DRY-RUN]")
	else
		_perf_baseline_report+=("  peak RSS: ${rss:-?} kB   minor faults: ${minor_faults:-?}   user time: ${user_time:-?}s")
	fi
	_perf_baseline_report+=("")
}

# -----------------------------------------------------------------------------
# perf_timing LABEL ENV_VARS API_ARGS [RUNS]
#
# Runs each implementation RUNS times (default 3) and logs the wall-clock time
# for every run. Results are accumulated into _perf_timing_report for the
# end-of-suite summary block, including min/avg/max and speedup percentage.
# No PASS/FAIL counter is touched.
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

	for _ in $(seq 1 "$runs"); do
		t=$(_perf_wall_time_s "$env_vars" "$PERL_EXE api --host http://localhost $api_args")
		p_times+=("$t")
	done

	for _ in $(seq 1 "$runs"); do
		t=$(_perf_wall_time_s "$env_vars" "$ZIG_EXE api --host http://localhost $api_args")
		z_times+=("$t")
	done

	local p_agg z_agg p_avg z_avg
	p_agg=$(_perf_aggregate "${p_times[*]}")
	z_agg=$(_perf_aggregate "${z_times[*]}")

	p_avg=$(echo "$p_agg" | awk '{print $2}' | cut -d= -f2)
	z_avg=$(echo "$z_agg" | awk '{print $2}' | cut -d= -f2)

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

	local p_list="" z_list=""
	for t in "${p_times[@]}"; do p_list+=" ${t}s"; done
	for t in "${z_times[@]}"; do z_list+=" ${t}s"; done

	_perf_timing_report+=("$tid  $label")
	_perf_timing_report+=("  PERL $p_list  ($p_agg)")
	_perf_timing_report+=("  ZIG  $z_list  ($z_agg)")
	[[ -n "$cmp_msg" ]] && _perf_timing_report+=("  $cmp_msg")
	_perf_timing_report+=("")
}

# -----------------------------------------------------------------------------
# perf_timing_archive LABEL ENV_VARS API_ARGS [RUNS]
#
# Like perf_timing, but for the archive subcommand. Handles per-run output
# directory creation and cleanup to ensure a clean slate for each iteration.
# -----------------------------------------------------------------------------
perf_timing_archive() {
	local label=$1
	local env_vars=$2
	local api_args=$3
	local runs=${4:-3}

	_perf_t_seq=$((_perf_t_seq + 1))
	local tid="PERF-T${_perf_t_seq}"
	echo "  $tid  $label — archive timing (${runs} runs)..."

	local t p_times=() z_times=()

	for i in $(seq 1 "$runs"); do
		container_exec rm -rf /tmp/perf_arc_perl_"$i"
		t=$(_perf_wall_time_s "$env_vars" "$PERL_EXE archive --host http://localhost $api_args /tmp/perf_arc_perl_$i")
		p_times+=("$t")
	done

	for i in $(seq 1 "$runs"); do
		container_exec rm -rf /tmp/perf_arc_zig_"$i"
		t=$(_perf_wall_time_s "$env_vars" "$ZIG_EXE archive --host http://localhost $api_args /tmp/perf_arc_zig_$i")
		z_times+=("$t")
	done

	local p_agg z_agg p_avg z_avg
	p_agg=$(_perf_aggregate "${p_times[*]}")
	z_agg=$(_perf_aggregate "${z_times[*]}")

	p_avg=$(echo "$p_agg" | awk '{print $2}' | cut -d= -f2)
	z_avg=$(echo "$z_agg" | awk '{print $2}' | cut -d= -f2)

	local cmp_msg=""
	if [[ -n "$p_avg" && -n "$z_avg" && "$p_avg" != "0.000" && "$z_avg" != "0.000" ]]; then
		cmp_msg=$(container_exec bash -c "awk 'BEGIN { p=$p_avg; z=$z_avg; if (z < p) { printf \"INFO: Zig is %.1f%% faster (%.1fx speedup)\", (p-z)/p*100, p/z; } else { printf \"INFO: Zig is %.1f%% slower (%.1fx slowdown)\", (z-p)/p*100, z/p; } }'")
	fi

	_perf_timing_report+=("$tid  $label")
	_perf_timing_report+=("  PERL ${p_times[*]}  ($p_agg)")
	_perf_timing_report+=("  ZIG  ${z_times[*]}  ($z_agg)")
	[[ -n "$cmp_msg" ]] && _perf_timing_report+=("  $cmp_msg")
	_perf_timing_report+=("")
}

# -----------------------------------------------------------------------------
# perf_rss_archive LABEL ENV_VARS API_ARGS
#
# Like perf_rss, but for the archive subcommand.
# -----------------------------------------------------------------------------
perf_rss_archive() {
	local label=$1
	local env_vars=$2
	local api_args=$3

	_perf_r_seq=$((_perf_r_seq + 1))
	local tid="PERF-R${_perf_r_seq}"
	echo "  $tid  $label — archive RSS..."

	container_exec rm -rf /tmp/perf_arc_rss_perl /tmp/perf_arc_rss_zig
	local perl_rss zig_rss
	perl_rss=$(_perf_peak_rss_kb "$env_vars" "$PERL_EXE archive --host http://localhost $api_args /tmp/perf_arc_rss_perl")
	zig_rss=$(_perf_peak_rss_kb "$env_vars" "$ZIG_EXE archive --host http://localhost $api_args /tmp/perf_arc_rss_zig")

	if [[ "$DRY_RUN" == "false" && (-z "$perl_rss" || "$perl_rss" -eq 0) ]]; then die "Perl RSS failed"; fi
	if [[ "$DRY_RUN" == "false" && (-z "$zig_rss" || "$zig_rss" -eq 0) ]]; then die "Zig RSS failed"; fi

	_perf_rss_report+=("$tid  $label")
	_perf_rss_report+=("  PERL peak RSS: ${perl_rss} kB   ZIG peak RSS: ${zig_rss} kB")
	if [[ "$DRY_RUN" == "true" ]]; then
		_perf_rss_report+=("  INFO: [DRY-RUN] skipping memory comparison")
	elif [[ "$zig_rss" -lt "$perl_rss" ]]; then
		_perf_rss_report+=("  INFO: Zig uses $(((perl_rss - zig_rss) * 100 / perl_rss))% less memory")
	else
		_perf_rss_report+=("  INFO: Zig uses $(((zig_rss - perl_rss) * 100 / perl_rss))% more memory")
	fi
	_perf_rss_report+=("")
}

# -----------------------------------------------------------------------------
# perf_rss LABEL ENV_VARS API_ARGS
#
# Measures peak RSS for each implementation using /usr/bin/time -v.
# All results are accumulated into _perf_rss_report. No PASS/FAIL counter.
# -----------------------------------------------------------------------------
perf_rss() {
	local label=$1
	local env_vars=$2
	local api_args=$3
	_perf_rss_generic "$label" "$env_vars" \
		"$PERL_EXE api --host http://localhost $api_args" \
		"$ZIG_EXE api --host http://localhost $api_args"
}

# -----------------------------------------------------------------------------
# perf_rss_monitor LABEL ENV_VARS API_ARGS
#
# Measures peak RSS for each implementation for the monitor subcommand.
# All results are accumulated into _perf_rss_report. No PASS/FAIL counter.
# -----------------------------------------------------------------------------
perf_rss_monitor() {
	local label=$1
	local env_vars=$2
	local api_args=$3
	_perf_rss_generic "$label" "$env_vars" \
		"$PERL_EXE monitor --host http://localhost $api_args" \
		"$ZIG_EXE monitor --host http://localhost $api_args"
}

# =============================================================================
# Tests
# =============================================================================

# --- Interpreter baseline ----------------------------------------------------
#
# These measure the fixed overhead of starting Perl — with and without loading
# the Mojolicious framework — using trivial one-liners that do no real work.
# The results let readers decompose openqa-cli timings: of the ~0.7 s a typical
# openqa-cli api call takes, how much is Perl interpreter startup and how much
# is Mojolicious module loading?  The remainder is actual HTTP + business logic
# — which is on the same order of magnitude as zoqa.

# Test PERF-B1: bare Perl interpreter startup.
# 'perl -e 1' loads only the interpreter core: argument parsing, bytecode
# compilation of a trivial program, and immediate exit.  Expected: ~15-30 ms.
perf_baseline "perl bare startup (perl -e '1')" "perl -e '1'" 5

# Test PERF-B2: Perl + Mojolicious framework load.
# 'perl -MMojo::UserAgent -e 1' forces Perl to locate and compile the full
# Mojolicious dependency tree (UA, JSON, IOLoop, etc.) before exiting.
# This is the minimum cost openqa-cli pays before executing a single line of
# application code.  Expected: ~400-600 ms, ~45-55 MB RSS.
perf_baseline "perl + Mojo::UserAgent load (perl -MMojo::UserAgent -e '1')" "perl -MMojo::UserAgent -e '1'" 5

# --- Scenario: plain request (baseline) --------------------------------------
#
# No config file, no extra flags.  Exercises the minimal code path: argument
# parsing → HTTP GET → JSON decode → stdout write.

# Test PERF-T1: Wall-clock timing — jobs/overview (list endpoint).
# openqa-cli loads the full Perl + Mojolicious runtime on every invocation;
# most of its wall-clock time is framework startup (see PERF-B2 above).
# zoqa is a statically linked binary with near-instant startup.
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

# --- Scenario: archive overhead (dummy job) ----------------------------------
#
# Fixed overhead: parsing, initial API call, dir creation, cleanup.
perf_timing_archive "archive baseline (dummy job)" "" "$JOB_ID" 3
perf_rss_archive "archive baseline (dummy job)" "" "$JOB_ID"

# --- Scenario: archive skip overhead -----------------------------------------
#
# Isolates overhead by skipping assets.
perf_timing_archive "archive --asset-size-limit 1 (skip assets)" "" "--asset-size-limit 1 $JOB_ID" 3
perf_rss_archive "archive --asset-size-limit 1 (skip assets)" "" "--asset-size-limit 1 $JOB_ID"

# --- Scenario: archive streaming (rich job) ----------------------------------
#
# Real I/O throughput and memory pressure.
perf_timing_archive "archive rich job (~21MB image + artifacts)" "" "$RICH_JOB_ID" 3
perf_rss_archive "archive rich job (~21MB image + artifacts)" "" "$RICH_JOB_ID"

# --- Scenario: monitor 5 completed jobs (RSS) --------------------------------
#
# Schedules 5 fast simple_boot jobs, waits for all to complete, then measures
# peak RSS of monitoring all 5 simultaneously.  All jobs are already terminal,
# so monitor does 5 API calls and exits — no polling loop, isolating the
# per-job overhead.

echo "  [perf] Scheduling 5 monitor jobs..."
_PERF_MON_IDS=()
for i in $(seq 1 5); do
	_id=$(schedule_job \
		DISTRI=example \
		VERSION=0 \
		FLAVOR=DVD \
		ARCH=x86_64 \
		BUILD="perf-mon-$i" \
		HDD_1="$CIRROS_IMG" \
		ISO_1="seed-nocloud.iso" \
		CASEDIR="$CIRROS_TESTDIR" \
		NEEDLES_DIR="%CASEDIR%/needles" \
		"_GROUP_ID=${GROUP_ID:-1}")
	echo "    Scheduled job $i: $_id" >&2
	_PERF_MON_IDS+=("$_id")
done
echo "  [perf] Waiting for all 5 jobs to complete..."
for _id in "${_PERF_MON_IDS[@]}"; do
	wait_for_job "$_id" 300 >/dev/null || die "perf monitor: timeout on job $_id"
done

perf_rss_monitor "monitor 5 completed jobs" "" "${_PERF_MON_IDS[*]}"

# =============================================================================
# Summary Report
# =============================================================================
echo ""
echo "=== [perf] Performance Summary ==="
echo ""
echo "--- Interpreter Baseline (Perl-only, no network) ---"
for line in "${_perf_baseline_report[@]}"; do echo "$line"; done
echo "--- Timing (wall-clock seconds) ---"
for line in "${_perf_timing_report[@]}"; do echo "$line"; done
echo "--- RSS & Process Metrics ---"
for line in "${_perf_rss_report[@]}"; do echo "$line"; done
