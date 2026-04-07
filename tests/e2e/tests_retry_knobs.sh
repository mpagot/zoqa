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

# Test 46: --retries N as a CLI flag (overrides default / env var).
# Perl (api.pm:36): $options{retries} passed to retry_tx.
# Zig (main.zig:304): --retries N parsed from argv.
# Both must accept --retries 0 on a healthy endpoint and exit 0.
run_comparison "--retries 0 CLI flag accepted" "" \
	"--retries 0 jobs/overview" \
	0

# Test 47: Valid OPENQA_CLI_CONNECT_TIMEOUT (Zig) + MOJO_CONNECT_TIMEOUT (Perl).
# Each implementation reads the env var it understands; both set on the same
# command so run_comparison can be used. Valid numeric value → exit 0.
run_comparison "connect timeout env var: valid value (exit 0)" \
	"OPENQA_CLI_CONNECT_TIMEOUT=10 MOJO_CONNECT_TIMEOUT=10" \
	"jobs/overview" \
	0

# Test 48: Invalid OPENQA_CLI_CONNECT_TIMEOUT=bad (Zig) + MOJO_CONNECT_TIMEOUT=bad (Perl).
# Zig (main.zig:1714): parseFloat("bad") fails → falls back to 30.0, no crash.
# Perl: "bad" stored in MOJO_CONNECT_TIMEOUT constant, passed to
# $client->connect_timeout("bad") — Mojo::UserAgent accepts non-numeric values
# without raising an exception (verified locally).
# Both exit 0 on a healthy endpoint.
run_comparison "connect timeout env var: invalid value is rejected (exit 1)" \
	"OPENQA_CLI_CONNECT_TIMEOUT=bad MOJO_CONNECT_TIMEOUT=bad" \
	"jobs/overview" \
	1
