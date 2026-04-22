#!/usr/bin/env bash
# tests_robustness.sh — Section E: Robustness tests.
#
# Covers broken pipe handling, non-2xx error reporting on stderr, and
# --quiet suppression of error output.
#
# Sourced by tests.sh after helper functions are defined.
# Do NOT execute this file directly.
#
# Assumes from the calling scope:
#   ZIG_EXE, PERL_EXE, LOG_DIR, failed_tests, warned_tests

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "==> [robustness] Running robustness tests..."

# Test 29: Broken pipe does not crash the CLI.
# Piping into `head -c 1` causes the reader to close the pipe after 1 byte.
# The next write from zoqa gets EPIPE (or SIGPIPE).  The `catch {}` pattern
# in printResponse must swallow this so the CLI exits cleanly (exit 0, not
# 141/SIGPIPE).
#
# run_sigpipe_test uses PIPESTATUS[0] to capture the CLI binary's own exit
# code, not head's.  Without this, a standard pipeline `cmd | head -c 1`
# always returns head's exit code (0) — silently masking a SIGPIPE crash in
# cmd.  See the run_sigpipe_test docstring in lib.sh for details.
echo "--- Test: broken pipe (stdout | head -c 1) ---"
run_sigpipe_test "bp" perl "$PERL_EXE api --host http://localhost jobs/overview"
_PERL_EXIT=$_LAST_EXIT
run_sigpipe_test "bp" zig  "$ZIG_EXE api --host http://localhost jobs/overview"
_ZIG_EXIT=$_LAST_EXIT
if [[ "$_PERL_EXIT" -eq 0 ]]; then
	echo "PASS (openqa-cli exited cleanly despite broken pipe)"
else
	echo "FAIL: Perl expected exit 0, got $_PERL_EXIT (possible SIGPIPE crash)"
	failed_tests=$((failed_tests + 1))
fi
if [[ "$_ZIG_EXIT" -eq 0 ]]; then
	echo "PASS (zoqa exited cleanly despite broken pipe)"
else
	echo "FAIL: Zig expected exit 0, got $_ZIG_EXIT (possible SIGPIPE crash)"
	failed_tests=$((failed_tests + 1))
fi

# Test 30: Non-2xx error reporting — status line must appear on stderr without --quiet.
#
# on a non-2xx response, the status line must be printed to stderr
# (unless --quiet is set).
echo "--- Test: PERL vs ZIG : non-2xx stderr without --quiet ---"
run_perl_and_zig "404" "api --host http://localhost non_existent_e2e_route"

echo "PERL exit: $_PERL_EXIT, ZIG exit: $_ZIG_EXIT"
echo "PERL stderr contains '404': $(grep -c '404' "$LOG_DIR/404_perl_stderr.log" || true)"
echo "ZIG  stderr contains '404': $(grep -c '404' "$LOG_DIR/404_zig_stderr.log" || true)"

# Hard assertion: both Perl and Zig must emit '404' on stderr without --quiet.
if grep -q "404" "$LOG_DIR/404_perl_stderr.log" && grep -q "404" "$LOG_DIR/404_zig_stderr.log"; then
	echo "PASS (both Perl and Zig report 404 on stderr without --quiet)"
else
	echo "FAIL: expected '404' on stderr from both implementations"
	failed_tests=$((failed_tests + 1))
fi

# Test 31: --quiet suppresses the non-2xx status line on stderr.
echo "--- Test: PERL vs ZIG : non-2xx stderr with --quiet ---"
run_perl_and_zig "404q" "api --host http://localhost --quiet non_existent_e2e_route"

echo "PERL exit: $_PERL_EXIT, ZIG exit: $_ZIG_EXIT"
echo "PERL stderr bytes: $(wc -c <"$LOG_DIR/404q_perl_stderr.log")"
echo "ZIG  stderr bytes: $(wc -c <"$LOG_DIR/404q_zig_stderr.log")"
echo "PERL stderr contains '404': $(grep -c '404' "$LOG_DIR/404q_perl_stderr.log" || true)"
echo "ZIG  stderr contains '404': $(grep -c '404' "$LOG_DIR/404q_zig_stderr.log" || true)"

# Hard assertion: --quiet must suppress the error output for both implementations.
if ! grep -q "404" "$LOG_DIR/404q_perl_stderr.log" && ! grep -q "404" "$LOG_DIR/404q_zig_stderr.log"; then
	echo "PASS (both Perl and Zig suppress 404 stderr with --quiet)"
else
	echo "FAIL: --quiet did not suppress stderr as expected"
	failed_tests=$((failed_tests + 1))
fi
