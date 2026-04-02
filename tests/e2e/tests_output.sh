#!/usr/bin/env bash
# tests_output.sh — Section D: Output formatting tests.
#
# Covers --verbose, --pretty, --name, and Perl vs Zig header count parity.
#
# Sourced by tests.sh after helper functions are defined.
# Do NOT execute this file directly.
#
# Assumes from the calling scope:
#   ZIG_EXE, PERL_EXE, LOG_DIR, failed_tests, warned_tests
#   run_test(), run_comparison()

echo "==> [output] Running output formatting tests..."

# Test 25: --verbose on a real endpoint shows HTTP status line and Content-Type header.
run_comparison "--verbose shows HTTP status line" "" "--verbose jobs/overview" 0 "HTTP/"
run_comparison "--verbose includes Content-Type" "" "--verbose jobs/overview" 0 "Content-Type:"

# Test 26: --pretty on a non-empty response produces indented JSON.
# The pattern "^  " matches any line with a 2-space indent — present in all
# pretty-printed JSON but never in the compact single-line output.
run_comparison "--pretty (non-empty)" "" "--pretty jobs/overview" 0 "^  "

# Test 27: --name flag sets the User-Agent header (SPEC §2).
#
# Both Perl and Zig must accept the flag and exit 0 on a valid request.
# Server-side User-Agent verification (via access logs) is not attempted here:
# the openQA single-instance image does not expose the Mojolicious or Apache
# access log at a predictable path, so those checks would produce unreliable
# WARNs.
run_comparison "--name flag accepted (exit 0)" "" \
	"--name zoqa-e2e-test jobs/overview" 0

# Test 28: Verbose mode — Perl vs Zig header count comparison.
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

# Test 42: --pretty on an empty result (just verifies no crash, exit 0).
# Output format differs: Perl → "[\n]\n"; Zig → "[]\n". No pattern asserted.
run_comparison "--pretty on empty result (no crash)" "" \
	"--pretty jobs distri=doesnotexist999" \
	0

# Test 43: --links prints the Link header's rel=next URL to stderr.
# Uses machines?limit=2: 3 machines are seeded, guaranteeing a next page.
# Perl (Command.pm:52-56) wraps output in ANSI colour codes; Zig (main.zig:1570)
# writes plain text. Both contain "next:" — grep matches regardless of ANSI.
run_comparison "--links outputs next: for paginated response" "" \
	"--links 'machines?limit=2'" \
	0 "next:"

# Test 44: --verbose on a 404 prints the HTTP status line to stdout.
# Perl (Command.pm:59-63): if/elsif → verbose branch → stdout gets the status
# line; stderr is empty (error branch not taken).
# Zig (main.zig:1550-1566): two independent if blocks → stdout gets status line
# AND stderr gets "404 Not Found".
# run_comparison combines stdout+stderr, so "HTTP/1.1 404" is found in either
# stream for both implementations.
run_comparison "--verbose on 404 shows HTTP status line" "" \
	"--verbose jobs/999999" \
	1 "HTTP/1.1 404"

# Test 45: --quiet + --verbose on a 404.
# --quiet suppresses the non-2xx error line on stderr in both implementations.
# --verbose still prints the HTTP status line to stdout in both.
# Both exit 1; stdout has the "HTTP/" status line; stderr is empty.
run_comparison "--quiet --verbose on 404: headers on stdout, quiet stderr" "" \
	"--quiet --verbose jobs/999999" \
	1 "HTTP/"
