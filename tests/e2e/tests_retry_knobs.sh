#!/usr/bin/env bash
# tests_retry_knobs.sh — Section F: Retry and timeout knob tests.
#
# Covers OPENQA_CLI_RETRIES, OPENQA_CLI_RETRY_SLEEP_TIME_S, and
# OPENQA_CLI_RETRY_FACTOR environment variables.
#
# These knobs tune retry behaviour and are not directly observable through
# request outcomes on a healthy server.  The tests here are smoke tests:
# verify the variables are parsed without crashing, and that invalid
# (non-numeric) values fall back gracefully rather than aborting.
#
# Sourced by tests.sh after helper functions are defined.
# Do NOT execute this file directly.
#
# Assumes from the calling scope:
#   ZIG_EXE, LOG_DIR, failed_tests
#   run_test()

echo "==> [retry_knobs] Running retry/timeout knob tests..."

# Test 32: OPENQA_CLI_RETRIES=0 — explicit zero accepted on a good request.
run_test "ZIG : OPENQA_CLI_RETRIES=0 accepted" \
	"bash -c \"OPENQA_CLI_RETRIES=0 $ZIG_EXE api --host http://localhost jobs/overview\"" \
	0

# Test 33: OPENQA_CLI_RETRIES=abc — invalid value falls back to 0 (no crash).
run_test "ZIG : OPENQA_CLI_RETRIES=abc falls back gracefully" \
	"bash -c \"OPENQA_CLI_RETRIES=abc $ZIG_EXE api --host http://localhost jobs/overview\"" \
	0

# Test 34: OPENQA_CLI_RETRY_SLEEP_TIME_S and OPENQA_CLI_RETRY_FACTOR — valid values accepted.
run_test "ZIG : OPENQA_CLI_RETRY_SLEEP_TIME_S=1 OPENQA_CLI_RETRY_FACTOR=2.0 accepted" \
	"bash -c \"OPENQA_CLI_RETRY_SLEEP_TIME_S=1 OPENQA_CLI_RETRY_FACTOR=2.0 \
	$ZIG_EXE api --host http://localhost jobs/overview\"" \
	0

# Test 35: OPENQA_CLI_RETRY_SLEEP_TIME_S and OPENQA_CLI_RETRY_FACTOR — invalid values fall back gracefully.
run_test "ZIG : OPENQA_CLI_RETRY_SLEEP_TIME_S=bad OPENQA_CLI_RETRY_FACTOR=bad fall back gracefully" \
	"bash -c \"OPENQA_CLI_RETRY_SLEEP_TIME_S=bad OPENQA_CLI_RETRY_FACTOR=bad \
	$ZIG_EXE api --host http://localhost jobs/overview\"" \
	0
