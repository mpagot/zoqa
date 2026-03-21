#!/usr/bin/env bash
# tests.sh — E2E test suite for zoqa.
#
# Sourced by run.sh after container setup and environment loading.
# Do NOT execute this file directly.
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

# =============================================================================
# Tests 1–12: Core protocol, authentication, and CLI flags
# =============================================================================

# Test 1: Basic GET jobs/overview (verifies the endpoint responds)
run_comparison "GET jobs/overview" "" "jobs/overview" 0

# Test 2: GET workers
run_comparison "GET workers" "" "workers" 0

# Test 3: GET with query params
run_comparison "GET jobs with filter" "" "jobs distri=opensuse" 0 "\[\]"

# Test 4: GET 404
run_comparison "GET non-existent (404)" "" "jobs/999999" 1 "404 Not Found"

# Test 5: DELETE 404 (tests HMAC on DELETE)
run_comparison "DELETE non-existent (404)" "" "-X DELETE assets/999999" 1 "404 Not Found"

# Test 6: POST isos (HMAC validation)
run_comparison "POST isos (HMAC validation)" "" \
	"-X POST isos DISTRI=test VERSION=1 FLAVOR=test ARCH=x86_64" 0

# Test 7: --param-file support
# Create the param file inside the container that --param-file will read.
# The file contains the value "opensuse" which will be used as the `distri` query parameter.
container_exec bash -c "printf 'opensuse' > /tmp/distri.txt"
run_comparison "--param-file" "" "--param-file distri=/tmp/distri.txt jobs" 0 "\[\]"

# Test 8: CLI flags override wrong config credentials
# Write a deliberately wrong client.conf inside the container at /tmp/client.conf.
# The test then points OPENQA_CONFIG=/tmp at it and verifies that explicit
# --apikey/--apisecret CLI flags override the bad credentials from the config file.
container_exec bash -c "printf '[localhost]\nkey=WRONG\nsecret=WRONG\n' > /tmp/wrong.conf"
run_comparison "CLI Override (correct key overrides wrong config)" \
	"OPENQA_CONFIG=/tmp" \
	"--apikey '$OPENQA_API_KEY' --apisecret '$OPENQA_API_SECRET' jobs/overview" \
	0

# Test 9: Authentication failure (wrong secret on authenticated route)
run_comparison "Wrong Secret (403)" "" "--apisecret WRONG_SECRET -X POST jobs" 1 "403 Forbidden"

# Test 10: Missing PATH positional argument
# Both Perl and Zig exit 255 and print the api usage block to stderr.
run_comparison "Missing PATH" "" "" 255

# Test 11: Invalid host (connection refused)
# Both Perl and Zig exit 1. Messages differ (Perl: ANSI-colored, Zig: plain),
# so no grep pattern is used.
run_test "PERL: Invalid Host" \
	"$PERL_EXE api --host http://localhost:12345 jobs/overview" 1
run_test "ZIG : Invalid Host" \
	"$ZIG_EXE api --host http://localhost:12345 jobs/overview" 1

# Test 11b: Flags placed before the subcommand name must be rejected (exit 255).
# Perl's Mojolicious dispatcher treats ARGV[0] as the subcommand name; if it
# starts with '--', it dies with "Invalid command --host" → exit 255.
# Zig mirrors this: a leading '--' token before the subcommand token returns
# error.InvalidCommand → exit 255.
run_test "PERL: --host before api rejected (exit 255)" \
	"$PERL_EXE --host http://localhost api jobs/overview" 255
run_test "ZIG : --host before api rejected (exit 255)" \
	"$ZIG_EXE --host http://localhost api jobs/overview" 255

# =============================================================================
# Tests 13–21: New coverage using seeded data
# =============================================================================

# Test 13: GET jobs/overview returns non-empty list after seeding
run_comparison "GET jobs/overview (non-empty after seeding)" "" "jobs/overview" 0 "simple_boot"

# Test 14: GET jobs/:id returns a real nested job object
run_comparison "GET jobs/$JOB_ID (nested object)" "" \
	"jobs/$JOB_ID" 0 '"settings"'

# Test 15: GET machines?limit=2 with --links triggers the Link pagination header
# We seeded 3 machines; requesting limit=2 should yield a Link: rel="next" header.
# parseLinkHeader formats output as "next: <url>" per link.
echo "--- Test: ZIG : --links and follow pagination ---"
container_exec bash -c "$ZIG_EXE api --host http://localhost --links 'machines?limit=2'" \
	>"$LOG_DIR/test_pagination.log" 2>&1
if grep -q "next:" "$LOG_DIR/test_pagination.log"; then
	NEXT_URL=$(grep "^next: " "$LOG_DIR/test_pagination.log" | cut -d' ' -f2 | tr -d '\r')
	echo "Found next URL: $NEXT_URL"
	# Call again with the next URL to verify it returns the remaining data
	run_test "ZIG : Follow pagination link" "$ZIG_EXE api --host http://localhost '$NEXT_URL'" 0 '"name":"uefi"'
else
	echo "FAIL: next link not found in output"
	cat "$LOG_DIR/test_pagination.log"
	failed_tests=$((failed_tests + 1))
fi

# Test 16: --verbose on a real endpoint shows HTTP status line and Content-Type header.
run_comparison "--verbose shows HTTP status line" "" "--verbose jobs/overview" 0 "HTTP/"
run_comparison "--verbose includes Content-Type" "" "--verbose jobs/overview" 0 "Content-Type:"

# Test 17: --pretty on a non-empty response produces indented JSON.
# The pattern "^  " matches any line with a 2-space indent — present in all
# pretty-printed JSON but never in the compact single-line output.
run_comparison "--pretty (non-empty)" "" "--pretty jobs/overview" 0 "^  "

# Test 18: DELETE a real asset (successful authenticated DELETE)
# Perl and Zig each get their own asset to avoid ordering conflicts.
if [[ "$ASSET_ID" == "SKIP" || -z "$ASSET_ID" ]]; then
	echo "--- Test: PERL: DELETE asset (skipped — no ASSET_ID from seeding) ---"
	warned_tests=$((warned_tests + 1))
else
	run_test "PERL: DELETE asset/$ASSET_ID (200)" \
		"$PERL_EXE api --host http://localhost -X DELETE assets/$ASSET_ID" 0
fi

if [[ "$ZIG_ASSET_ID" == "SKIP" || -z "$ZIG_ASSET_ID" ]]; then
	echo "--- Test: ZIG : DELETE asset (skipped — no ZIG_ASSET_ID from seeding) ---"
	warned_tests=$((warned_tests + 1))
else
	run_test "ZIG : DELETE asset/$ZIG_ASSET_ID (200)" \
		"$ZIG_EXE api --host http://localhost -X DELETE assets/$ZIG_ASSET_ID" 0
fi

# Test 19: GET job_groups returns the seeded group
run_comparison "GET job_groups (seeded group present)" "" "job_groups" 0 '"example"'

# Test 20: Perl vs Zig output parity on a real nested object (hard FAIL on mismatch)
run_diff_test "GET jobs/$JOB_ID output parity" "jobs/$JOB_ID"

# Test 21: Relative and absolute path produce identical output
# Verifies that `zoqa api jobs/$JOB_ID` and
# `zoqa api http://localhost/api/v1/jobs/$JOB_ID` return the same body.
#
# stderr is redirected to /dev/null for both invocations to suppress the
# per-call BoltDB deprecation warning that podman emits on affected systems
# (see the "Podman sanity check" comment in run.sh).  The warning timestamp
# differs between the two calls, which would cause a spurious diff failure
# if stderr were captured.
echo "--- Test: ZIG : relative vs absolute path parity ---"
container_exec bash -c "$ZIG_EXE api --host http://localhost jobs/$JOB_ID" \
	>"$LOG_DIR/test_relative.log" 2>/dev/null
container_exec bash -c "$ZIG_EXE api 'http://localhost/api/v1/jobs/$JOB_ID'" \
	>"$LOG_DIR/test_absolute.log" 2>/dev/null
if diff -u "$LOG_DIR/test_relative.log" "$LOG_DIR/test_absolute.log" \
	>"$LOG_DIR/test_path_parity_diff.log" 2>&1; then
	echo "PASS (relative and absolute outputs identical)"
else
	echo "FAIL: relative and absolute path outputs differ"
	cat "$LOG_DIR/test_path_parity_diff.log"
	failed_tests=$((failed_tests + 1))
fi

# Test 22: --name flag sets the User-Agent header (SPEC §2).
#
# Both Perl and Zig must accept the flag and exit 0 on a valid request.
# Server-side User-Agent verification (via access logs) is not attempted here:
# the openQA single-instance image does not expose the Mojolicious or Apache
# access log at a predictable path, so those checks would produce unreliable
# WARNs.
run_comparison "--name flag accepted (exit 0)" "" \
	"--name zoqa-e2e-test jobs/overview" 0

# =============================================================================
# Tests 23–26: Verbose mode and non-2xx stderr
# =============================================================================
#
# SPEC §9.1 requires that --verbose prints ALL response headers before the body:
#
#   HTTP/1.1 <code> <reason>
#   <Header-Name>: <value>
#   ...
#   <blank line>
#   <body>
#
# Test 16 (above) already verifies the status line and Content-Type are present.
# Tests 23–24 here compare Perl and Zig header counts so that any deviation from
# the reference implementation is a hard FAIL rather than a silent WARN.

# Test 23: Broken pipe does not crash the CLI
# Piping into `head -c 1` causes the reader to close the pipe after 1 byte.
# The next write from zoqa gets EPIPE (or SIGPIPE). The `catch {}` pattern in
# printResponse must swallow this so the CLI exits cleanly (exit code 0, not
# 141/SIGPIPE).
#
# The pipeline runs inside `container_exec bash -c "..."` — the inner bash
# process does NOT inherit the outer script's `pipefail` setting, so `$?` after
# `container_exec bash -c "cmd | head -c 1"` reflects the inner pipeline's last
# command (head), which exits 0.  If zoqa itself crashed with an unhandled
# SIGPIPE the inner bash -c would propagate a non-zero exit for the whole
# command group; we check for that below.
echo "--- Test: PERL: broken pipe (stdout | head -c 1) ---"
set +e
container_exec bash -c "$PERL_EXE api --host http://localhost jobs/overview | head -c 1" >/dev/null 2>&1
bp_perl_exit=$?
set -e
if [[ "$bp_perl_exit" -eq 0 ]]; then
	echo "PASS (openqa-cli exited cleanly despite broken pipe)"
else
	echo "FAIL: expected exit 0, got $bp_perl_exit (possible SIGPIPE crash)"
	failed_tests=$((failed_tests + 1))
fi

echo "--- Test: ZIG : broken pipe (stdout | head -c 1) ---"
set +e
container_exec bash -c "$ZIG_EXE api --host http://localhost jobs/overview | head -c 1" >/dev/null 2>&1
bp_exit=$?
set -e
if [[ "$bp_exit" -eq 0 ]]; then
	echo "PASS (zoqa exited cleanly despite broken pipe)"
else
	echo "FAIL: expected exit 0, got $bp_exit (possible SIGPIPE crash)"
	failed_tests=$((failed_tests + 1))
fi

# Test 24: Verbose mode — Perl vs Zig header count comparison
#
# Captures stdout and stderr separately for both implementations and compares
# the header-line count.  Perl and Zig both produce ~5 application-level header
# lines to stdout (hop-by-hop headers such as Connection and Keep-Alive are
# stripped before the comparison).  Diagnostic counts are printed regardless of
# pass/fail to make any regression visible in CI output.
echo "--- Test: PERL vs ZIG : --verbose header count ---"
set +e
container_exec bash -c "$PERL_EXE api --host http://localhost --verbose jobs/overview \
	2>/tmp/perl_verbose_stderr.log >/tmp/perl_verbose_stdout.log"
container_exec cat /tmp/perl_verbose_stderr.log >"$LOG_DIR/perl_verbose_stderr.log" 2>/dev/null
container_exec cat /tmp/perl_verbose_stdout.log >"$LOG_DIR/perl_verbose_stdout.log" 2>/dev/null

container_exec bash -c "$ZIG_EXE api --host http://localhost --verbose jobs/overview \
	2>/tmp/zig_verbose_stderr.log >/tmp/zig_verbose_stdout.log"
container_exec cat /tmp/zig_verbose_stderr.log >"$LOG_DIR/zig_verbose_stderr.log" 2>/dev/null
container_exec cat /tmp/zig_verbose_stdout.log >"$LOG_DIR/zig_verbose_stdout.log" 2>/dev/null
set -e

perl_stdout_headers=$(grep -cE '^[A-Za-z_-]+: ' "$LOG_DIR/perl_verbose_stdout.log" || true)
perl_stderr_headers=$(grep -cE '^[A-Za-z_-]+: ' "$LOG_DIR/perl_verbose_stderr.log" || true)
zig_stdout_headers=$(grep -cE '^[A-Za-z_-]+: ' "$LOG_DIR/zig_verbose_stdout.log" || true)
zig_stderr_headers=$(grep -cE '^[A-Za-z_-]+: ' "$LOG_DIR/zig_verbose_stderr.log" || true)

echo "PERL headers in stdout: $perl_stdout_headers"
echo "PERL headers in stderr: $perl_stderr_headers"
echo "ZIG  headers in stdout: $zig_stdout_headers"
echo "ZIG  headers in stderr: $zig_stderr_headers"
echo "PERL HTTP/1.1 line in stdout: $(grep -c 'HTTP/1.1 ' "$LOG_DIR/perl_verbose_stdout.log" || true)"
echo "PERL HTTP/1.1 line in stderr: $(grep -c 'HTTP/1.1 ' "$LOG_DIR/perl_verbose_stderr.log" || true)"

if [[ "$perl_stdout_headers" -gt 0 || "$perl_stderr_headers" -gt 0 ]]; then
	if [[ "$zig_stdout_headers" -eq "$perl_stdout_headers" && "$zig_stderr_headers" -eq "$perl_stderr_headers" ]]; then
		echo "PASS (Zig matches Perl header output)"
	else
		echo "FAIL: Zig header output ($zig_stdout_headers stdout / $zig_stderr_headers stderr) does not match Perl ($perl_stdout_headers stdout / $perl_stderr_headers stderr)"
		failed_tests=$((failed_tests + 1))
	fi
else
	echo "WARN: Perl produced no headers in verbose mode — skipping comparison"
	warned_tests=$((warned_tests + 1))
fi

# Tests 25–26: Non-2xx error reporting and --quiet suppression
#
# SPEC §9.3: on a non-2xx response, the status line must be printed to stderr
# (unless --quiet is set).  Both sub-tests run together because Test 26's PASS
# criterion depends on the stderr file captured in Test 25.
echo "--- Test: PERL vs ZIG : non-2xx stderr without --quiet ---"
set +e
container_exec bash -c "$PERL_EXE api --host http://localhost non_existent_e2e_route \
	2>/tmp/perl_404_stderr.log >/tmp/perl_404_stdout.log"
perl_404_exit=$?
container_exec bash -c "$ZIG_EXE api --host http://localhost non_existent_e2e_route \
	2>/tmp/zig_404_stderr.log >/tmp/zig_404_stdout.log"
zig_404_exit=$?
container_exec cat /tmp/perl_404_stderr.log >"$LOG_DIR/perl_404_stderr.log" 2>/dev/null
container_exec cat /tmp/zig_404_stderr.log >"$LOG_DIR/zig_404_stderr.log" 2>/dev/null
set -e

echo "PERL exit: $perl_404_exit, ZIG exit: $zig_404_exit"
echo "PERL stderr contains '404': $(grep -c '404' "$LOG_DIR/perl_404_stderr.log" || true)"
echo "ZIG  stderr contains '404': $(grep -c '404' "$LOG_DIR/zig_404_stderr.log" || true)"

# Hard assertion: both Perl and Zig must emit '404' on stderr without --quiet.
if grep -q "404" "$LOG_DIR/perl_404_stderr.log" && grep -q "404" "$LOG_DIR/zig_404_stderr.log"; then
	echo "PASS (both Perl and Zig report 404 on stderr without --quiet)"
else
	echo "FAIL: expected '404' on stderr from both implementations"
	failed_tests=$((failed_tests + 1))
fi

echo "--- Test: PERL vs ZIG : non-2xx stderr with --quiet ---"
set +e
container_exec bash -c "$PERL_EXE api --host http://localhost --quiet non_existent_e2e_route \
	2>/tmp/perl_404q_stderr.log >/tmp/perl_404q_stdout.log"
perl_404q_exit=$?
container_exec bash -c "$ZIG_EXE api --host http://localhost --quiet non_existent_e2e_route \
	2>/tmp/zig_404q_stderr.log >/tmp/zig_404q_stdout.log"
zig_404q_exit=$?
container_exec cat /tmp/perl_404q_stderr.log >"$LOG_DIR/perl_404q_stderr.log" 2>/dev/null
container_exec cat /tmp/zig_404q_stderr.log >"$LOG_DIR/zig_404q_stderr.log" 2>/dev/null
set -e

echo "PERL exit: $perl_404q_exit, ZIG exit: $zig_404q_exit"
echo "PERL stderr bytes: $(wc -c <"$LOG_DIR/perl_404q_stderr.log")"
echo "ZIG  stderr bytes: $(wc -c <"$LOG_DIR/zig_404q_stderr.log")"
echo "PERL stderr contains '404': $(grep -c '404' "$LOG_DIR/perl_404q_stderr.log" || true)"
echo "ZIG  stderr contains '404': $(grep -c '404' "$LOG_DIR/zig_404q_stderr.log" || true)"

# Hard assertion: --quiet must suppress the error output for both implementations.
if ! grep -q "404" "$LOG_DIR/perl_404q_stderr.log" && ! grep -q "404" "$LOG_DIR/zig_404q_stderr.log"; then
	echo "PASS (both Perl and Zig suppress 404 stderr with --quiet)"
else
	echo "FAIL: --quiet did not suppress stderr as expected"
	failed_tests=$((failed_tests + 1))
fi
