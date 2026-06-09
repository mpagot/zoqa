#!/usr/bin/env bash
# tests.sh — E2E test suite entry point for zoqa.
#
# Sourced by run.sh after container setup and environment loading.
# Do NOT execute this file directly.
#
# This file sources lib.sh (which defines all shared test helper functions)
# and then sources each domain-specific test file in order:
#
#   tests_core.sh        — Section A: core protocol and CLI flag tests
#   tests_auth.sh        — Section B: authentication (config file, CLI flags, env vars)
#   tests_data.sh        — Section C: seeded data, pagination, output parity
#   tests_output.sh      — Section D: output formatting (verbose, pretty, name)
#   tests_robustness.sh  — Section E: broken pipe, non-2xx stderr, --quiet
#   tests_retry_knobs.sh — Section F: OPENQA_CLI_RETRIES / SLEEP / FACTOR env vars
#   tests_archive.sh     — Section H: archive subcommand
#   tests_perf.sh        — Section G: wall-clock timing and peak RSS comparisons
#   tests_stress.sh      — Section L: large response stress tests
#
# All shared test helper functions (run_test, run_comparison_api, run_diff_test,
# run_capture, run_capture_both, assert_capture_exits, assert_stdout_pattern,
# etc.) are defined in lib.sh, which is the single authoritative source.
#
# Reads from the calling scope:
#   ZIG_EXE       — absolute path to the zoqa binary inside the container
#   PERL_EXE      — name of the openqa-cli binary inside the container
#   LOG_DIR       — directory where all log files are written
#   failed_tests  — integer counter; incremented on each FAIL
#   warned_tests  — integer counter; incremented on each WARN
#   GROUP_ID      — seeded job group ID
#   OPENQA_API_KEY    — extracted API key
#   OPENQA_API_SECRET — extracted API secret
#
# Job IDs (JOB_ID, RICH_JOB_ID) and asset IDs (ASSET_ID, ZIG_ASSET_ID) are
# created on demand by individual test suites using lib.sh helper functions
# (ensure_basic_job, ensure_rich_job, register_deletable_asset).  These
# variables are set in the shared scope and reused by subsequent suites.
#
# All functions and test variables defined here intentionally live in the
# run.sh scope (sourced, not subshell).

# shellcheck source=SCRIPTDIR/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

_E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------------------------
# Source domain test files in order
# -----------------------------------------------------------------------------
#
# If E2E_SUITES is set (comma-separated list of names, e.g. "core,auth"),
# only the matching files are sourced. If E2E_SUITES is empty, all
# domain files are sourced — the default full-suite behaviour.
#
_e2e_suite_enabled() {
	local name=$1
	# 'all' (default) → all suites enabled
	[[ "$E2E_SUITES" == "all" ]] && return 0
	# Empty string → skip all tests
	[[ -z "$E2E_SUITES" ]] && return 1
	# Check if name appears as a comma-separated token
	local suite
	IFS=',' read -ra _suites <<<"$E2E_SUITES"
	for suite in "${_suites[@]}"; do
		[[ "$suite" == "$name" ]] && return 0
	done
	return 1
}

# Run each enabled suite in order.  When E2E_SUITES is set, suites not in
# the list are skipped.  The `|| true` ensures each iteration exits 0:
# a disabled suite returns 1 from the && short-circuit, and a sourced file
# whose last command exits non-zero would otherwise propagate that code out
# of `source tests.sh` in run.sh and fire the errexit trap before the summary.
# All test outcomes are tracked via $failed_tests / $warned_tests, not exit
# codes, so nothing meaningful is hidden by this.
#
# ShellCheck cannot follow a dynamic source path; the individual tests_*.sh
# files are checked independently when `make e2e-lint` is run.
# shellcheck disable=SC1090
_e2e_all_suites=(core auth data output robustness retry_knobs archive monitor schedule help stress perf)
for _suite in "${_e2e_all_suites[@]}"; do
	if _e2e_suite_enabled "$_suite"; then
		source "$_E2E_DIR/tests_${_suite}.sh"
	fi
done
