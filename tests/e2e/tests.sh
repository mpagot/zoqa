#!/usr/bin/env bash
# tests.sh — E2E test suite entry point for zoqa.
#
# Sourced by run.sh after container setup and environment loading.
# Do NOT execute this file directly.
#
# This file defines the shared test helper functions and then sources each
# domain-specific test file in order:
#
#   tests_core.sh        — Section A: core protocol and CLI flag tests
#   tests_auth.sh        — Section B: authentication (config file, CLI flags, env vars)
#   tests_data.sh        — Section C: seeded data, pagination, output parity
#   tests_output.sh      — Section D: output formatting (verbose, pretty, name)
#   tests_robustness.sh  — Section E: broken pipe, non-2xx stderr, --quiet
#   tests_retry_knobs.sh — Section F: OPENQA_CLI_RETRIES / SLEEP / FACTOR env vars
#
# Reads from the calling scope:
#   ZIG_EXE       — absolute path to the zoqa binary inside the container
#   PERL_EXE      — name of the openqa-cli binary inside the container
#   LOG_DIR       — directory where all log files are written
#   failed_tests  — integer counter; incremented on each FAIL
#   warned_tests  — integer counter; incremented on each WARN
#   JOB_ID        — seeded job ID
#   ASSET_ID      — seeded asset ID (for Perl DELETE test)
#   ZIG_ASSET_ID  — seeded asset ID (for Zig DELETE test)
#   GROUP_ID      — seeded job group ID
#   OPENQA_API_KEY    — extracted API key
#   OPENQA_API_SECRET — extracted API secret
#
# All functions and test variables defined here intentionally live in the
# run.sh scope (sourced, not subshell).

# shellcheck source=SCRIPTDIR/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

_E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------------------------
# Test helper functions
# -----------------------------------------------------------------------------

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

# run_comparison LABEL ENV_VARS API_ARGS [EXPECTED_EXIT [GREP_PATTERN]]
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
run_comparison() {
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

# run_diff_test LABEL API_ARGS
#
# Runs the same API call against both implementations and asserts that their
# stdout output is identical (after trailing-newline normalisation).  stderr is
# discarded from both sides to avoid noise from ANSI colour codes, Mojo
# warnings, and the BoltDB deprecation warning emitted by podman on some hosts.
#
# Use this helper when you want to detect regressions in the Zig output format
# relative to the Perl reference — i.e., "both must produce the same body".
# For exit-code or pattern checks use run_comparison instead.
#
# Parameters:
#   LABEL    — human-readable test name printed in the --- Test: DIFF --- line
#   API_ARGS — arguments passed after `api --host http://localhost`
#
# Side effects: increments failed_tests on mismatch.
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

# -----------------------------------------------------------------------------
# Source domain test files in order
# -----------------------------------------------------------------------------

# shellcheck source=SCRIPTDIR/tests_core.sh
source "$_E2E_DIR/tests_core.sh"

# shellcheck source=SCRIPTDIR/tests_auth.sh
source "$_E2E_DIR/tests_auth.sh"

# shellcheck source=SCRIPTDIR/tests_data.sh
source "$_E2E_DIR/tests_data.sh"

# shellcheck source=SCRIPTDIR/tests_output.sh
source "$_E2E_DIR/tests_output.sh"

# shellcheck source=SCRIPTDIR/tests_robustness.sh
source "$_E2E_DIR/tests_robustness.sh"

# shellcheck source=SCRIPTDIR/tests_retry_knobs.sh
source "$_E2E_DIR/tests_retry_knobs.sh"
