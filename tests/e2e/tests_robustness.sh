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

# Test ROB-1: Broken pipe does not crash the CLI.
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

# Test ROB-2: Non-2xx error reporting — status line must appear on stderr without --quiet.
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

# Test ROB-3: --quiet suppresses the non-2xx status line on stderr.
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

# ---------------------------------------------------------------------------
# ROB-4 through ROB-7: --data-file edge cases
#
# These tests exercise error conditions for --data-file that are NOT covered
# by the happy-path tests in tests_core.sh (COR-36b, COR-37, COR-39).
# Each test runs both Perl and Zig and compares their exit codes.
# ---------------------------------------------------------------------------

# Test ROB-4: --data-file with non-existent file path.
# Both implementations must exit non-zero when the file does not exist.
echo "--- Test: PERL vs ZIG : --data-file non-existent file ---"
run_perl_and_zig "df_nofile" \
	"api --host http://localhost --data-file /tmp/e2e_nonexistent_file_$(date +%s).txt jobs/overview"
echo "PERL exit: $_PERL_EXIT, ZIG exit: $_ZIG_EXIT"
if [[ "$_PERL_EXIT" -ne 0 && "$_ZIG_EXIT" -ne 0 ]]; then
	echo "PASS (both exit non-zero for non-existent --data-file)"
else
	echo "FAIL: expected non-zero exit from both implementations"
	echo "  Perl stderr: $(cat "$LOG_DIR/df_nofile_perl_stderr.log" 2>/dev/null)"
	echo "  Zig  stderr: $(cat "$LOG_DIR/df_nofile_zig_stderr.log" 2>/dev/null)"
	failed_tests=$((failed_tests + 1))
fi

# Test ROB-5: --data-file with inaccessible file (wrong permissions).
#
# IMPORTANT: the E2E CLI normally runs as root inside the container, and root
# bypasses file permission bits — a `chmod 000` file is still readable by root.
# Running this test as root would therefore NOT exercise a permission-denied
# path at all: the file would read fine and the request would proceed (this is
# exactly how the ROB-5 GET+body panic was originally masked/mis-attributed).
#
# To genuinely test EACCES we drop privileges to the non-root 'geekotest' user
# (the standard openQA container user) via runuser.  The file is owned by root
# with mode 000, so geekotest cannot read it and both implementations must fail
# on the read, before any request is sent.
echo "--- Test: PERL vs ZIG : --data-file permission denied ---"
_NOPERM_USER="geekotest"
if ! container_exec id "$_NOPERM_USER" >/dev/null 2>&1; then
	echo "--- Test: --data-file permission denied (skipped — no '$_NOPERM_USER' user to drop to) ---"
	warned_tests=$((warned_tests + 1))
else
	container_exec bash -c \
		"echo 'secret' > /tmp/e2e_noperm.txt && chown root:root /tmp/e2e_noperm.txt && chmod 000 /tmp/e2e_noperm.txt"
	run_capture "df_noperm" perl \
		"runuser -u $_NOPERM_USER -- $PERL_EXE api --host http://localhost --data-file /tmp/e2e_noperm.txt jobs/overview"
	_PERL_EXIT=$_LAST_EXIT
	run_capture "df_noperm" zig \
		"runuser -u $_NOPERM_USER -- $ZIG_EXE api --host http://localhost --data-file /tmp/e2e_noperm.txt jobs/overview"
	_ZIG_EXIT=$_LAST_EXIT
	echo "PERL exit: $_PERL_EXIT, ZIG exit: $_ZIG_EXIT"
	# Restore permissions for cleanup regardless of test outcome.
	container_exec bash -c "chmod 644 /tmp/e2e_noperm.txt && rm -f /tmp/e2e_noperm.txt" || true
	if [[ "$_PERL_EXIT" -ne 0 && "$_ZIG_EXIT" -ne 0 ]]; then
		echo "PASS (both exit non-zero for permission-denied --data-file)"
	else
		echo "FAIL: expected non-zero exit from both implementations"
		echo "  Perl stderr: $(cat "$LOG_DIR/df_noperm_perl_stderr.log" 2>/dev/null)"
		echo "  Zig  stderr: $(cat "$LOG_DIR/df_noperm_zig_stderr.log" 2>/dev/null)"
		failed_tests=$((failed_tests + 1))
	fi
fi

# Test ROB-6: --data-file with empty file.
# An empty file is a valid input: the body should be empty. Both
# implementations must succeed (exit 0) and not crash.  The server may
# return an error (e.g. 400) because the POST body is empty, but the CLI
# itself must not crash — so we only assert the same exit code from both.
echo "--- Test: PERL vs ZIG : --data-file empty file ---"
container_exec bash -c "truncate -s 0 /tmp/e2e_empty.txt"
run_perl_and_zig "df_empty" \
	"api --host http://localhost -X POST --data-file /tmp/e2e_empty.txt isos"
echo "PERL exit: $_PERL_EXIT, ZIG exit: $_ZIG_EXIT"
container_exec bash -c "rm -f /tmp/e2e_empty.txt" || true
if [[ "$_PERL_EXIT" -eq "$_ZIG_EXIT" ]]; then
	echo "PASS (both implementations agree: exit $_PERL_EXIT)"
else
	echo "FAIL: exit code mismatch (Perl=$_PERL_EXIT, Zig=$_ZIG_EXIT)"
	echo "  Perl stdout: $(cat "$LOG_DIR/df_empty_perl_stdout.log" 2>/dev/null)"
	echo "  Zig  stdout: $(cat "$LOG_DIR/df_empty_zig_stdout.log" 2>/dev/null)"
	echo "  Perl stderr: $(cat "$LOG_DIR/df_empty_perl_stderr.log" 2>/dev/null)"
	echo "  Zig  stderr: $(cat "$LOG_DIR/df_empty_zig_stderr.log" 2>/dev/null)"
	failed_tests=$((failed_tests + 1))
fi

# Test ROB-7: --data-file with file exceeding the 10 MiB cap.
#
# DELIBERATE DIVERGENCE FROM THE PERL CLIENT (documented in ideas/SPEC.md §7.2):
#   * Zig (zoqa) enforces a 10 MiB limit on readFileAlloc and must exit
#     non-zero when the file is too large.
#   * Perl (openqa-cli) has NO such limit — it reads the entire file. On this
#     GET route the oversized body is sent and ignored by the server, so Perl
#     exits 0.
#
# This test asserts BOTH sides of the divergence: Zig rejects the oversized
# file (non-zero) while Perl accepts it (exit 0). Perl's success is the direct
# evidence that it applies no cap.
#
# We create an 11 MiB sparse file (fast, minimal disk usage) inside the
# container. The E2E_STORAGE_KEEP_FREE_RATIO guard in run.sh protects
# against disk-full scenarios, but sparse files cost almost nothing.
echo "--- Test: PERL vs ZIG : --data-file exceeds 10 MiB cap ---"
container_exec bash -c "truncate -s 11M /tmp/e2e_oversized.txt"
run_perl_and_zig "df_oversized" \
	"api --host http://localhost --data-file /tmp/e2e_oversized.txt jobs/overview"
echo "PERL exit: $_PERL_EXIT (expected 0, no cap), ZIG exit: $_ZIG_EXIT (expected non-zero, cap enforced)"
container_exec bash -c "rm -f /tmp/e2e_oversized.txt" || true
if [[ "$_ZIG_EXIT" -ne 0 && "$_PERL_EXIT" -eq 0 ]]; then
	echo "PASS (Zig rejects oversized --data-file; Perl accepts it — divergence confirmed)"
else
	echo "FAIL: expected Zig non-zero (cap) and Perl 0 (no cap)"
	echo "  Perl stderr: $(cat "$LOG_DIR/df_oversized_perl_stderr.log" 2>/dev/null)"
	echo "  Zig  stderr: $(cat "$LOG_DIR/df_oversized_zig_stderr.log" 2>/dev/null)"
	failed_tests=$((failed_tests + 1))
fi

# ---------------------------------------------------------------------------
# Test ROB-8: readable --data-file on a GET route (no -X POST).
#
# This is a DELIBERATE behavioural divergence between the two implementations,
# documented in ideas/SPEC.md and in src/http_client.zig (execute()):
#
#   * Perl (openqa-cli) silently sends the body on a GET and exits 0 — the
#     server ignores the body and returns 200.
#   * Zig (zoqa) rejects the request up front with a clean non-zero exit
#     (error.BodyOnBodilessMethod), because std.http.Client asserts that the
#     method permits a body; sending a body on GET would otherwise abort the
#     process with a panic (SIGABRT / exit 134) in safe builds.
#
# The critical regression guard here is: Zig must FAIL CLEANLY, i.e. exit
# non-zero WITHOUT crashing (exit code must NOT be 134 and stderr must not
# contain a panic).  We assert Zig's behaviour directly rather than requiring
# parity with Perl.  A readable file is used on purpose so the read succeeds
# and the GET+body code path is actually reached (unlike ROB-4/5/7, where the
# read fails first).
echo "--- Test: ZIG : readable --data-file on GET route rejected cleanly (no panic) ---"
container_exec bash -c "echo 'hello' > /tmp/e2e_getbody.txt && chmod 644 /tmp/e2e_getbody.txt"
run_capture "df_getbody" zig \
	"$ZIG_EXE api --host http://localhost --data-file /tmp/e2e_getbody.txt jobs/overview"
_ZIG_EXIT=$_LAST_EXIT
# Also capture Perl for the record, to document the divergence in the logs.
run_capture "df_getbody" perl \
	"$PERL_EXE api --host http://localhost --data-file /tmp/e2e_getbody.txt jobs/overview"
_PERL_EXIT=$_LAST_EXIT
echo "ZIG exit: $_ZIG_EXIT (expected non-zero, NOT 134) | PERL exit: $_PERL_EXIT (documented: 0)"
container_exec bash -c "rm -f /tmp/e2e_getbody.txt" || true
if [[ "$_ZIG_EXIT" -ne 0 && "$_ZIG_EXIT" -ne 134 ]] \
	&& ! grep -qi "panic" "$LOG_DIR/df_getbody_zig_stderr.log"; then
	echo "PASS (Zig rejects body-on-GET cleanly, no panic)"
else
	echo "FAIL: Zig must reject body-on-GET with a clean non-zero exit (got $_ZIG_EXIT)"
	echo "  Zig stderr: $(cat "$LOG_DIR/df_getbody_zig_stderr.log" 2>/dev/null)"
	failed_tests=$((failed_tests + 1))
fi
