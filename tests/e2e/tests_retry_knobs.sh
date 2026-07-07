#!/usr/bin/env bash
# tests_retry_knobs.sh — Section F: Retry and timeout knob tests.
#
# Covers OPENQA_CLI_RETRIES, OPENQA_CLI_RETRY_SLEEP_TIME_S, and
# OPENQA_CLI_RETRY_FACTOR environment variables.
#
# Tests fall into two categories:
#   Smoke tests  — verify the variable is parsed without crashing; use a
#                  healthy server so exit code is the only observable signal.
#   Functional   — verify the variable actually changes behaviour by using the
#                  fault-injecting proxy so proxy hit counts are observable.
#
# Sourced by tests.sh after helper functions are defined.
# Do NOT execute this file directly.
#
# Assumes from the calling scope:
#   ZIG_EXE, PERL_EXE, LOG_DIR, failed_tests
#   run_test(), run_comparison_api(), run_capture()
#   JOB_ID (set by ensure_basic_job in tests_core.sh / tests_data.sh)

echo "==> [retry_knobs] Running retry/timeout knob tests..."

echo "==> RET-1: OPENQA_CLI_RETRIES=0 — explicit zero accepted on a good request."
run_comparison_api "OPENQA_CLI_RETRIES=0 accepted" \
	"OPENQA_CLI_RETRIES=0" \
	"jobs/overview" \
	0

echo "==> RET-2: OPENQA_CLI_RETRIES=abc — invalid value falls back to 0, no crash."
run_comparison_api "OPENQA_CLI_RETRIES=abc falls back gracefully" \
	"OPENQA_CLI_RETRIES=abc" \
	"jobs/overview" \
	0

echo "==> RET-3: OPENQA_CLI_RETRY_SLEEP_TIME_S + OPENQA_CLI_RETRY_FACTOR — valid."
run_comparison_api "OPENQA_CLI_RETRY_SLEEP_TIME_S=1 OPENQA_CLI_RETRY_FACTOR=2.0 accepted" \
	"OPENQA_CLI_RETRY_SLEEP_TIME_S=1 OPENQA_CLI_RETRY_FACTOR=2.0" \
	"jobs/overview" \
	0

echo "==> RET-4: OPENQA_CLI_RETRY_SLEEP_TIME_S + OPENQA_CLI_RETRY_FACTOR — invalid."
# Zig falls back to defaults. Perl coerces non-numeric to 0 (sleep 0).
# Both exit 0 on a healthy endpoint.
run_comparison_api "OPENQA_CLI_RETRY_SLEEP_TIME_S=bad OPENQA_CLI_RETRY_FACTOR=bad fall back gracefully" \
	"OPENQA_CLI_RETRY_SLEEP_TIME_S=bad OPENQA_CLI_RETRY_FACTOR=bad" \
	"jobs/overview" \
	0

echo "==> RET-5: --retries N as a CLI flag (overrides default / env var)."
# Both must accept --retries 0 on a healthy endpoint and exit 0.
run_comparison_api "--retries 0 CLI flag accepted" "" \
	"--retries 0 jobs/overview" \
	0

echo "==> RET-6: Valid OPENQA_CLI_CONNECT_TIMEOUT (Zig) + MOJO_CONNECT_TIMEOUT (Perl)."
run_comparison_api "connect timeout env var: valid value (exit 0)" \
	"OPENQA_CLI_CONNECT_TIMEOUT=10 MOJO_CONNECT_TIMEOUT=10" \
	"jobs/overview" \
	0

echo "==> RET-7: Invalid connect timeout — Zig falls back to 30s, Perl coerces silently."
# Both exit 0 on a healthy endpoint.
run_comparison_api "connect timeout env var: invalid value is rejected (exit 1)" \
	"OPENQA_CLI_CONNECT_TIMEOUT=bad MOJO_CONNECT_TIMEOUT=bad" \
	"jobs/overview" \
	1

echo "==> RET-8: OPENQA_CLI_RETRIES=2 functional test — verify actual retries happen."
# The fault proxy intercepts /api/v1/ paths and returns 503 for the first
# FAIL_TIMES=2 requests, then forwards normally.  With OPENQA_CLI_RETRIES=2,
# both Perl and Zig should retry twice, succeed on the third attempt, and
# exit 0.  The proxy hit count confirms retrying occurred.
#
# What we verify:
#   - Both exit 0 (retry past the 2 transient errors)
#   - Both make exactly 3 proxy hits (1 original + 2 retries)

start_faultproxy 2 503 /api/v1/

run_capture "ret8" perl \
	"bash -c \"OPENQA_CLI_RETRIES=2 OPENQA_CLI_RETRY_SLEEP_TIME_S=0 \
	${PERL_EXE} api --host http://127.0.0.1:${FAULTPROXY_PORT} jobs/${JOB_ID}\""
_RET8_PERL_EXIT=$_LAST_EXIT

# Reset proxy hit counts before running Zig via self-resetting truncation
reset_faultproxy

run_capture "ret8" zig \
	"bash -c \"OPENQA_CLI_RETRIES=2 OPENQA_CLI_RETRY_SLEEP_TIME_S=0 \
	${ZIG_EXE} api --host http://127.0.0.1:${FAULTPROXY_PORT} jobs/${JOB_ID}\""
_RET8_ZIG_EXIT=$_LAST_EXIT

stop_faultproxy

if [[ "$_RET8_PERL_EXIT" -eq 0 ]]; then
	echo "PASS: RET-8 Perl exits 0 with OPENQA_CLI_RETRIES=2 (retried past 503s)"
else
	echo "FAIL: RET-8 Perl exited $_RET8_PERL_EXIT (expected 0 — should retry)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi

if [[ "$_RET8_ZIG_EXIT" -eq 0 ]]; then
	echo "PASS: RET-8 Zig exits 0 with OPENQA_CLI_RETRIES=2 (retried past 503s)"
else
	echo "FAIL: RET-8 Zig exited $_ZIG_EXIT (expected 0 — should retry)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi

_RET8_ZIG_HITS=$(get_faultproxy_hits "/api/v1/jobs/${JOB_ID}")
if [[ "$_RET8_ZIG_HITS" -eq 3 ]]; then
	echo "PASS: RET-8 Zig made exactly 3 proxy hits (1 original + 2 retries — correct)"
else
	echo "FAIL: RET-8 Zig made $_RET8_ZIG_HITS proxy hit(s) (expected 3 for OPENQA_CLI_RETRIES=2)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi
