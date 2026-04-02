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

echo "==> [robustness] Running robustness tests..."

# Test 29: Broken pipe does not crash the CLI.
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

# Test 30: Non-2xx error reporting — status line must appear on stderr without --quiet.
#
# on a non-2xx response, the status line must be printed to stderr
# (unless --quiet is set).
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

# Test 31: --quiet suppresses the non-2xx status line on stderr.
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
