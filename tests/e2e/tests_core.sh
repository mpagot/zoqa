#!/usr/bin/env bash
# tests_core.sh — Section A: Core protocol and CLI flag tests.
#
# Sourced by tests.sh after helper functions are defined.
# Do NOT execute this file directly.
#
# Assumes from the calling scope:
#   ZIG_EXE, PERL_EXE, LOG_DIR, failed_tests, warned_tests
#   run_test(), run_comparison(), run_diff_test()

echo "==> [core] Running core protocol and CLI flag tests..."

# Test 1: Basic GET jobs/overview (verifies the endpoint responds)
run_comparison "GET jobs/overview" "" "jobs/overview" 0

# Test 2: GET workers
run_comparison "GET workers" "" "workers" 0

# Test 3: GET with query params
run_comparison "GET jobs with filter" "" "jobs distri=opensuse" 0 "\[\]"

# Test 4: GET 404
run_comparison "GET non-existent (404)" "" "jobs/999999" 1 "404 Not Found"

# Test 5: Missing PATH positional argument
# Both Perl and Zig exit 255 and print the api usage block to stderr.
run_comparison "Missing PATH" "" "" 255

# Test 6: Invalid host (connection refused)
# Both Perl and Zig exit 1. Messages differ (Perl: ANSI-colored, Zig: plain),
# so no grep pattern is used.
run_test "PERL: Invalid Host" \
	"$PERL_EXE api --host http://localhost:12345 jobs/overview" 1
run_test "ZIG : Invalid Host" \
	"$ZIG_EXE api --host http://localhost:12345 jobs/overview" 1

# Test 7: Flags placed before the subcommand name must be rejected (exit 255).
# Perl's Mojolicious dispatcher treats ARGV[0] as the subcommand name; if it
# starts with '--', it dies with "Invalid command --host" → exit 255.
# Zig mirrors this: a leading '--' token before the subcommand token returns
# error.InvalidCommand → exit 255.
run_test "PERL: --host before api rejected (exit 255)" \
	"$PERL_EXE --host http://localhost api jobs/overview" 255
run_test "ZIG : --host before api rejected (exit 255)" \
	"$ZIG_EXE --host http://localhost api jobs/overview" 255

# Test 8: -- stop flag before the API path is accepted.
# 'zoqa api --host http://localhost -- jobs/overview' — the -- terminates flag
# parsing; 'jobs/overview' is treated as the positional API path, not a flag.
# Both implementations must exit 0 and return a valid response.
run_comparison "-- stop before API path accepted (exit 0)" "" \
	"-- jobs/overview" 0

# Test 9: -- stop flag causes a dash-prefixed token to be treated as the API path.
# 'zoqa api --host http://localhost -- -X' — after --, '-X' is the literal API
# path, not the --method flag.  The server has no such route, so both
# implementations must return 404 Not Found (exit 1) rather than a flag-parsing
# error.
run_comparison "-- stop: dash-prefixed path is a 404, not a flag error" "" \
	"-- -X" 1 "404 Not Found"

# Test 10: --param-file support.
# Create the param file inside the container that --param-file will read.
# The file contains the value "opensuse" which will be used as the `distri` query parameter.
container_exec bash -c "printf 'opensuse' > /tmp/distri.txt"
run_comparison "--param-file" "" "--param-file distri=/tmp/distri.txt jobs" 0 "\[\]"
