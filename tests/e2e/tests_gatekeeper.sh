#!/usr/bin/env bash
# shellcheck disable=SC2153
# tests_gatekeeper.sh — Gatekeeper and rate-limit robustness tests (GAT-1 to GAT-44).
#
# Verifies the three real gaps found against openqa.opensuse.org (o3), whose
# traffic is routed through the Anubis bot gatekeeper plus NGINX rate
# limiting (429 + Retry-After):
#
#   R1  Every request (and every redirect hop) carries an Accept header.
#   R2  A 200 text/html response to an asset download is a permanent
#       error (bot challenge), not a truncated transfer; no file is kept.
#       Exception: assets named *.htm/*.html (GAT-42; known gap GAT-43).
#   R3  Retry on 408, 429, 500, 502, 503, 504 (assets: 408, 429, 5xx).
#   R4  A retried response's Retry-After header (integer seconds)
#       replaces the computed backoff delay; non-integer values (e.g. HTTP dates)
#       are ignored and fall back to computed delay.
#
# Pattern: Perl leg first (openqa-cli / openqa-clone-job as the behavioural
# oracle), then reset_faultproxy, then the Zig leg.  Both exit code and
# proxy hit count are asserted for both implementations.
#
# Sourced by tests.sh after helper functions are defined.
# Do NOT execute this file directly.
#
# Assumes from the calling scope:
#   ZIG_EXE, PERL_EXE, ZIG_CLONE_EXE (local), PERL_CLONE_EXE (local),
#   LOG_DIR, failed_tests, DRY_RUN
#   run_capture(), assert_impl_log_pattern(), assert_downloaded_assets_md5()
#   start_faultproxy(), stop_faultproxy(), reset_faultproxy(),
#   get_faultproxy_hits(), get_faultproxy_headers(),
#   assert_all_requests_have_accept(), elapsed_since(), dump_faultproxy_logs()
#   ensure_rich_job() (sets RICH_JOB_ID)
#   ensure_html_asset_job() (sets GAT_HTML_JOB_ID, GAT_HTML_ASSET)

echo "==> [gatekeeper] Running gatekeeper / rate-limit tests (GAT-1 to GAT-44)..."

# Local binary handles — same convention as tests_clone_single.sh.
PERL_CLONE_EXE="openqa-clone-job"
ZIG_CLONE_EXE="/app/zig-out/bin/zoqa-clone-job"

# -----------------------------------------------------------------------------
# _gat_run_both TAG MODE FAIL_TIMES PATH RETRY_AFTER -- PERL_CMD -- ZIG_CMD
#
# Runs the same fault scenario against both implementations:
#   1. start_faultproxy FAIL_TIMES MODE PATH RETRY_AFTER
#   2. run_capture TAG perl  PERL_CMD
#   3. reset_faultproxy
#   4. run_capture TAG zig   ZIG_CMD
#   5. stop_faultproxy
#
# Exit codes are left in _GAT_PERL_EXIT / _GAT_ZIG_EXIT, hit counts in
# _GAT_PERL_HITS / _GAT_ZIG_HITS (captured after each leg, before the reset
# clears the count file).
#
# NOTE: start_faultproxy (pkill + truncate + podman exec -d + sleep 1) takes
# several seconds.  For tests that assert on wall-clock elapsed time, the
# caller must start the proxy BEFORE taking the timestamp — otherwise the
# proxy startup is counted as client delay and the assertion measures
# harness overhead, not client behaviour.
# -----------------------------------------------------------------------------
_gat_run_both() {
	local tag=$1
	local mode=$2
	local fail_times=$3
	local path=$4
	local retry_after=$5
	shift 5
	[[ "${1:-}" == "--" ]] && shift

	local perl_cmd=$1
	shift
	[[ "${1:-}" == "--" ]] && shift
	local zig_cmd=$1

	start_faultproxy "$fail_times" "$mode" "$path" 64 "$retry_after"
	run_capture "$tag" perl "$perl_cmd"
	_GAT_PERL_EXIT=$_LAST_EXIT
	_GAT_PERL_HITS=$(get_faultproxy_hits "$path")
	reset_faultproxy
	run_capture "$tag" zig "$zig_cmd"
	_GAT_ZIG_EXIT=$_LAST_EXIT
	_GAT_ZIG_HITS=$(get_faultproxy_hits "$path")
	stop_faultproxy
}

# -----------------------------------------------------------------------------
# _gat_run_leg TAG IMPL CMD
#
# Runs one implementation's leg against an ALREADY-RUNNING fault proxy and
# stops the proxy afterwards.  For timed tests: start the proxy, take the
# timestamp, then call this — so the measured window covers only the client
# run, not proxy startup.
#
# Exit code in _GAT_LEG_EXIT, hit count for PATH in _GAT_LEG_HITS.
# -----------------------------------------------------------------------------
_gat_run_leg() {
	local tag=$1
	local impl=$2
	local cmd=$3
	local path=$4
	run_capture "$tag" "$impl" "$cmd"
	_GAT_LEG_EXIT=$_LAST_EXIT
	_GAT_LEG_HITS=$(get_faultproxy_hits "$path")
	stop_faultproxy
}

# =============================================================================
# Part A — zoqa api ↔ openqa-cli api (GAT-1 to GAT-12)
# =============================================================================
#
# All Part A tests run against the live container API through the fault
# proxy.  The proxy's fault path is /api/v1/ so the faulted route is the
# one the api subcommand hits.

# GAT-1: R1 — every request carries an Accept header.
# Test GAT-1: api request header log shows Accept on every request
#
# The header log records one line per request: "METHOD PATH accept=<v|->".
# Both implementations must send Accept: application/json on the request.
start_faultproxy 0 503 /api/v1/ 64 "" "--header-log"
run_capture "gat1" perl \
	"bash -c \"${PERL_EXE} api --host http://127.0.0.1:${FAULTPROXY_PORT} jobs/${JOB_ID}\""
_GAT1_PERL_EXIT=$_LAST_EXIT
assert_all_requests_have_accept "/api/v1/jobs/${JOB_ID}" "GAT-1 Perl sends Accept on every request"
reset_faultproxy
run_capture "gat1" zig \
	"bash -c \"${ZIG_EXE} api --host http://127.0.0.1:${FAULTPROXY_PORT} jobs/${JOB_ID}\""
_GAT1_ZIG_EXIT=$_LAST_EXIT
assert_all_requests_have_accept "/api/v1/jobs/${JOB_ID}" "GAT-1 Zig sends Accept on every request"
stop_faultproxy

if [[ "$_GAT1_PERL_EXIT" -eq 0 && "$_GAT1_ZIG_EXIT" -eq 0 ]]; then
	echo "PASS: GAT-1 both exit 0"
else
	echo "FAIL: GAT-1 exits perl=$_GAT1_PERL_EXIT zig=$_GAT1_ZIG_EXIT (expected 0/0)"
	failed_tests=$((failed_tests + 1))
fi

# GAT-2: R1 — caller-supplied Accept replaces the default (exactly one).
# Test GAT-2: caller-supplied Accept header wins, no duplicate
#
# Both implementations must send exactly one Accept header with the
# caller-supplied value (text/plain), not the default application/json.
start_faultproxy 0 503 /api/v1/ 64 "" "--header-log"
run_capture "gat2" perl \
	"bash -c \"${PERL_EXE} api --host http://127.0.0.1:${FAULTPROXY_PORT} -a 'Accept: text/plain' jobs/${JOB_ID}\""
_GAT2_PERL_EXIT=$_LAST_EXIT
_GAT2_PERL_ACCEPT=$(get_faultproxy_headers "/api/v1/jobs/${JOB_ID}" | grep -c 'accept=text/plain' || true)
reset_faultproxy
run_capture "gat2" zig \
	"bash -c \"${ZIG_EXE} api --host http://127.0.0.1:${FAULTPROXY_PORT} -a 'Accept: text/plain' jobs/${JOB_ID}\""
_GAT2_ZIG_EXIT=$_LAST_EXIT
_GAT2_ZIG_ACCEPT=$(get_faultproxy_headers "/api/v1/jobs/${JOB_ID}" | grep -c 'accept=text/plain' || true)
stop_faultproxy

if [[ "$_GAT2_PERL_EXIT" -eq 0 && "$_GAT2_PERL_ACCEPT" -ge 1 ]]; then
	echo "PASS: GAT-2 Perl sends caller Accept (text/plain), exit 0"
else
	echo "FAIL: GAT-2 Perl exit=$_GAT2_PERL_EXIT accept_lines=$_GAT2_PERL_ACCEPT (expected 0 / >=1)"
	failed_tests=$((failed_tests + 1))
fi
if [[ "$_GAT2_ZIG_EXIT" -eq 0 && "$_GAT2_ZIG_ACCEPT" -ge 1 ]]; then
	echo "PASS: GAT-2 Zig sends caller Accept (text/plain), exit 0"
else
	echo "FAIL: GAT-2 Zig exit=$_GAT2_ZIG_EXIT accept_lines=$_GAT2_ZIG_ACCEPT (expected 0 / >=1)"
	failed_tests=$((failed_tests + 1))
fi

# GAT-3: R2 — challenge page on /api/v1/ does not change API behaviour.
# Test GAT-3: challenge on /api/v1/ — API path unchanged (both exit 0)
#
# The challenge mode returns 200 text/html on the fault path.  For the api
# subcommand the body is simply printed (the API path does not reject HTML),
# so both implementations exit 0.  This documents that R2 applies to asset
# downloads only, not to API routes.
_gat_run_both "gat3" challenge 1 /api/v1/ "" \
	"bash -c \"${PERL_EXE} api --host http://127.0.0.1:${FAULTPROXY_PORT} jobs/${JOB_ID}\"" \
	-- \
	"bash -c \"${ZIG_EXE} api --host http://127.0.0.1:${FAULTPROXY_PORT} jobs/${JOB_ID}\""

if [[ "$_GAT_PERL_EXIT" -eq 0 && "$_GAT_ZIG_EXIT" -eq 0 ]]; then
	echo "PASS: GAT-3 both exit 0 (challenge body printed, API path unchanged)"
else
	echo "FAIL: GAT-3 exits perl=$_GAT_PERL_EXIT zig=$_GAT_ZIG_EXIT (expected 0/0)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi

# GAT-4: R3 — 429 is retried.
# Test GAT-4: 429x2 then success — both retry
#
# With OPENQA_CLI_RETRIES=2 (Zig) / --retries 2 (Perl) and SLEEP=0, both
# must make 3 hits (1 + 2 retries) and exit 0.
_gat_run_both "gat4" 429 2 /api/v1/ "" \
	"bash -c \"OPENQA_CLI_RETRIES=2 OPENQA_CLI_RETRY_SLEEP_TIME_S=0 ${PERL_EXE} api --host http://127.0.0.1:${FAULTPROXY_PORT} jobs/${JOB_ID}\"" \
	-- \
	"bash -c \"OPENQA_CLI_RETRIES=2 OPENQA_CLI_RETRY_SLEEP_TIME_S=0 ${ZIG_EXE} api --host http://127.0.0.1:${FAULTPROXY_PORT} jobs/${JOB_ID}\""

if [[ "$_GAT_PERL_EXIT" -eq 0 && "$_GAT_PERL_HITS" -eq 3 ]]; then
	echo "PASS: GAT-4 Perl exits 0 with 3 hits (retried 429s)"
else
	echo "FAIL: GAT-4 Perl exit=$_GAT_PERL_EXIT hits=$_GAT_PERL_HITS (expected 0 / 3)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi
if [[ "$_GAT_ZIG_EXIT" -eq 0 && "$_GAT_ZIG_HITS" -eq 3 ]]; then
	echo "PASS: GAT-4 Zig exits 0 with 3 hits (retried 429s)"
else
	echo "FAIL: GAT-4 Zig exit=$_GAT_ZIG_EXIT hits=$_GAT_ZIG_HITS (expected 0 / 3)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi

# GAT-5: R3 — 408 / 500 / 504 are retried.
# Test GAT-5: 408/500/504 x1 each — both retry
#
# One faulted attempt per status, then success.  Both must make 2 hits and
# exit 0 for each status.
for _gat5_status in 408 500 504; do
	_gat_run_both "gat5_${_gat5_status}" "${_gat5_status}" 1 /api/v1/ "" \
		"bash -c \"OPENQA_CLI_RETRIES=1 OPENQA_CLI_RETRY_SLEEP_TIME_S=0 ${PERL_EXE} api --host http://127.0.0.1:${FAULTPROXY_PORT} jobs/${JOB_ID}\"" \
		-- \
		"bash -c \"OPENQA_CLI_RETRIES=1 OPENQA_CLI_RETRY_SLEEP_TIME_S=0 ${ZIG_EXE} api --host http://127.0.0.1:${FAULTPROXY_PORT} jobs/${JOB_ID}\""

	if [[ "$_GAT_PERL_EXIT" -eq 0 && "$_GAT_PERL_HITS" -eq 2 ]]; then
		echo "PASS: GAT-5 Perl ${_gat5_status} exits 0 with 2 hits"
	else
		echo "FAIL: GAT-5 Perl ${_gat5_status} exit=$_GAT_PERL_EXIT hits=$_GAT_PERL_HITS (expected 0 / 2)"
		dump_faultproxy_logs
		failed_tests=$((failed_tests + 1))
	fi
	if [[ "$_GAT_ZIG_EXIT" -eq 0 && "$_GAT_ZIG_HITS" -eq 2 ]]; then
		echo "PASS: GAT-5 Zig ${_gat5_status} exits 0 with 2 hits"
	else
		echo "FAIL: GAT-5 Zig ${_gat5_status} exit=$_GAT_ZIG_EXIT hits=$_GAT_ZIG_HITS (expected 0 / 2)"
		dump_faultproxy_logs
		failed_tests=$((failed_tests + 1))
	fi
done

# GAT-6: R3 — persistent 429 exhausts retries.
# Test GAT-6: 429 always — both exhaust retries
#
# With RETRIES=2 both must make 3 hits and exit non-zero.
_gat_run_both "gat6" 429 99 /api/v1/ "" \
	"bash -c \"OPENQA_CLI_RETRIES=2 OPENQA_CLI_RETRY_SLEEP_TIME_S=0 ${PERL_EXE} api --host http://127.0.0.1:${FAULTPROXY_PORT} jobs/${JOB_ID}\"" \
	-- \
	"bash -c \"OPENQA_CLI_RETRIES=2 OPENQA_CLI_RETRY_SLEEP_TIME_S=0 ${ZIG_EXE} api --host http://127.0.0.1:${FAULTPROXY_PORT} jobs/${JOB_ID}\""

if [[ "$_GAT_PERL_EXIT" -ne 0 && "$_GAT_PERL_HITS" -eq 3 ]]; then
	echo "PASS: GAT-6 Perl exits non-zero with 3 hits (retries exhausted)"
else
	echo "FAIL: GAT-6 Perl exit=$_GAT_PERL_EXIT hits=$_GAT_PERL_HITS (expected non-zero / 3)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi
if [[ "$_GAT_ZIG_EXIT" -ne 0 && "$_GAT_ZIG_HITS" -eq 3 ]]; then
	echo "PASS: GAT-6 Zig exits non-zero with 3 hits (retries exhausted)"
else
	echo "FAIL: GAT-6 Zig exit=$_GAT_ZIG_EXIT hits=$_GAT_ZIG_HITS (expected non-zero / 3)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi

# GAT-7: R4 — Retry-After in seconds replaces the computed delay.
# Test GAT-7: 429x2 + Retry-After: 2 — both honour the delay
#
# SLEEP=0 makes the computed delay 0, so any measurable sleep comes from
# Retry-After.  Two retried responses × 2 s = per-leg elapsed >= 4 s.
# The proxy is started before the timestamp so the measured window covers
# only the client run, not proxy startup.
_gat7_perl_cmd="bash -c \"OPENQA_CLI_RETRIES=2 OPENQA_CLI_RETRY_SLEEP_TIME_S=0 ${PERL_EXE} api --host http://127.0.0.1:${FAULTPROXY_PORT} jobs/${JOB_ID}\""
_gat7_zig_cmd="bash -c \"OPENQA_CLI_RETRIES=2 OPENQA_CLI_RETRY_SLEEP_TIME_S=0 ${ZIG_EXE} api --host http://127.0.0.1:${FAULTPROXY_PORT} jobs/${JOB_ID}\""

start_faultproxy 2 429 /api/v1/ 64 2
_gat7_start=$(date +%s%N)
_gat_run_leg "gat7" perl "$_gat7_perl_cmd" /api/v1/
_gat7_perl_elapsed=$(elapsed_since "$_gat7_start")
_GAT7_PERL_EXIT=$_GAT_LEG_EXIT

start_faultproxy 2 429 /api/v1/ 64 2
_gat7_start=$(date +%s%N)
_gat_run_leg "gat7" zig "$_gat7_zig_cmd" /api/v1/
_gat7_zig_elapsed=$(elapsed_since "$_gat7_start")
_GAT7_ZIG_EXIT=$_GAT_LEG_EXIT

if [[ "$_GAT7_PERL_EXIT" -eq 0 ]]; then
	echo "PASS: GAT-7 Perl exits 0"
else
	echo "FAIL: GAT-7 Perl exit=$_GAT7_PERL_EXIT (expected 0)"
	failed_tests=$((failed_tests + 1))
fi
if [[ "$_GAT7_ZIG_EXIT" -eq 0 ]]; then
	echo "PASS: GAT-7 Zig exits 0"
else
	echo "FAIL: GAT-7 Zig exit=$_GAT7_ZIG_EXIT (expected 0)"
	failed_tests=$((failed_tests + 1))
fi
if [[ "$_gat7_perl_elapsed" -ge 4 ]]; then
	echo "PASS: GAT-7 Perl elapsed ${_gat7_perl_elapsed}s >= 4s (Retry-After honoured)"
else
	echo "FAIL: GAT-7 Perl elapsed ${_gat7_perl_elapsed}s < 4s (Retry-After not honoured)"
	failed_tests=$((failed_tests + 1))
fi
if [[ "$_gat7_zig_elapsed" -ge 4 ]]; then
	echo "PASS: GAT-7 Zig elapsed ${_gat7_zig_elapsed}s >= 4s (Retry-After honoured)"
else
	echo "FAIL: GAT-7 Zig elapsed ${_gat7_zig_elapsed}s < 4s (Retry-After not honoured)"
	failed_tests=$((failed_tests + 1))
fi

# GAT-8: R4 — Retry-After as HTTP date (non-integer ignored by Zig).
# Test GAT-8: 429x2 + Retry-After: date:+2 — Perl honours HTTP-date, Zig ignores and falls back
#
# The proxy renders "date:+2" as an HTTP date 2 s in the future.
# Perl parses HTTP-date headers and sleeps >= 2 s.
# Zig ignores non-integer Retry-After headers (per integer-only R4 decision)
# and falls back to computed delay (SLEEP=0 -> elapsed < 2 s).
_gat8_perl_cmd="bash -c \"OPENQA_CLI_RETRIES=2 OPENQA_CLI_RETRY_SLEEP_TIME_S=0 ${PERL_EXE} api --host http://127.0.0.1:${FAULTPROXY_PORT} jobs/${JOB_ID}\""
_gat8_zig_cmd="bash -c \"OPENQA_CLI_RETRIES=2 OPENQA_CLI_RETRY_SLEEP_TIME_S=0 ${ZIG_EXE} api --host http://127.0.0.1:${FAULTPROXY_PORT} jobs/${JOB_ID}\""

start_faultproxy 2 429 /api/v1/ 64 "date:+2"
_gat8_start=$(date +%s%N)
_gat_run_leg "gat8" perl "$_gat8_perl_cmd" /api/v1/
_gat8_perl_elapsed=$(elapsed_since "$_gat8_start")
_GAT8_PERL_EXIT=$_GAT_LEG_EXIT

start_faultproxy 2 429 /api/v1/ 64 "date:+2"
_gat8_start=$(date +%s%N)
_gat_run_leg "gat8" zig "$_gat8_zig_cmd" /api/v1/
_gat8_zig_elapsed=$(elapsed_since "$_gat8_start")
_GAT8_ZIG_EXIT=$_GAT_LEG_EXIT

if [[ "$_GAT8_PERL_EXIT" -eq 0 && "$_GAT8_ZIG_EXIT" -eq 0 ]]; then
	echo "PASS: GAT-8 both exit 0"
else
	echo "FAIL: GAT-8 exits perl=$_GAT8_PERL_EXIT zig=$_GAT8_ZIG_EXIT (expected 0/0)"
	failed_tests=$((failed_tests + 1))
fi
if [[ "$_gat8_perl_elapsed" -ge 2 ]]; then
	echo "PASS: GAT-8 Perl elapsed ${_gat8_perl_elapsed}s >= 2s (HTTP-date Retry-After honoured)"
else
	echo "FAIL: GAT-8 Perl elapsed ${_gat8_perl_elapsed}s < 2s (HTTP-date Retry-After not honoured)"
	failed_tests=$((failed_tests + 1))
fi
if [[ "$_gat8_zig_elapsed" -lt 2 ]]; then
	echo "PASS: GAT-8 Zig elapsed ${_gat8_zig_elapsed}s < 2s (non-integer HTTP-date ignored, fallback to computed delay)"
else
	echo "FAIL: GAT-8 Zig elapsed ${_gat8_zig_elapsed}s >= 2s (non-integer HTTP-date not ignored)"
	failed_tests=$((failed_tests + 1))
fi

# GAT-9: R4 — unparsable Retry-After falls back to the computed delay.
# Test GAT-9: 429x2 + Retry-After: soon — fallback to computed delay
#
# "soon" is not a valid Retry-After value; both fall back to the computed
# delay (SLEEP=1 → 1 s per retry).  Two retries → per-leg elapsed >= 2 s.
# The proxy is started before the timestamp so the measured window covers
# only the client run.
_gat9_perl_cmd="bash -c \"OPENQA_CLI_RETRIES=2 OPENQA_CLI_RETRY_SLEEP_TIME_S=1 ${PERL_EXE} api --host http://127.0.0.1:${FAULTPROXY_PORT} jobs/${JOB_ID}\""
_gat9_zig_cmd="bash -c \"OPENQA_CLI_RETRIES=2 OPENQA_CLI_RETRY_SLEEP_TIME_S=1 ${ZIG_EXE} api --host http://127.0.0.1:${FAULTPROXY_PORT} jobs/${JOB_ID}\""

start_faultproxy 2 429 /api/v1/ 64 "soon"
_gat9_start=$(date +%s%N)
_gat_run_leg "gat9" perl "$_gat9_perl_cmd" /api/v1/
_gat9_perl_elapsed=$(elapsed_since "$_gat9_start")
_GAT9_PERL_EXIT=$_GAT_LEG_EXIT

start_faultproxy 2 429 /api/v1/ 64 "soon"
_gat9_start=$(date +%s%N)
_gat_run_leg "gat9" zig "$_gat9_zig_cmd" /api/v1/
_gat9_zig_elapsed=$(elapsed_since "$_gat9_start")
_GAT9_ZIG_EXIT=$_GAT_LEG_EXIT

if [[ "$_GAT9_PERL_EXIT" -eq 0 && "$_GAT9_ZIG_EXIT" -eq 0 ]]; then
	echo "PASS: GAT-9 both exit 0"
else
	echo "FAIL: GAT-9 exits perl=$_GAT9_PERL_EXIT zig=$_GAT9_ZIG_EXIT (expected 0/0)"
	failed_tests=$((failed_tests + 1))
fi
if [[ "$_gat9_perl_elapsed" -ge 2 ]]; then
	echo "PASS: GAT-9 Perl elapsed ${_gat9_perl_elapsed}s >= 2s (fallback delay used)"
else
	echo "FAIL: GAT-9 Perl elapsed ${_gat9_perl_elapsed}s < 2s (fallback delay not used)"
	failed_tests=$((failed_tests + 1))
fi
if [[ "$_gat9_zig_elapsed" -ge 2 ]]; then
	echo "PASS: GAT-9 Zig elapsed ${_gat9_zig_elapsed}s >= 2s (fallback delay used)"
else
	echo "FAIL: GAT-9 Zig elapsed ${_gat9_zig_elapsed}s < 2s (fallback delay not used)"
	failed_tests=$((failed_tests + 1))
fi

# GAT-10: R4 control — no Retry-After, computed delay only.
# Test GAT-10: 503x2 without Retry-After — computed delay only (control)
#
# SLEEP=0 → computed delay 0 → per-leg elapsed < 5 s.  This is the control
# that proves GAT-7/8/9 measured the Retry-After sleep, not the backoff.
# The proxy is started before the timestamp so the measured window covers
# only the client run (two podman exec round-trips + process startup,
# typically 2-4 s) — not proxy startup.
_gat10_perl_cmd="bash -c \"OPENQA_CLI_RETRIES=2 OPENQA_CLI_RETRY_SLEEP_TIME_S=0 ${PERL_EXE} api --host http://127.0.0.1:${FAULTPROXY_PORT} jobs/${JOB_ID}\""
_gat10_zig_cmd="bash -c \"OPENQA_CLI_RETRIES=2 OPENQA_CLI_RETRY_SLEEP_TIME_S=0 ${ZIG_EXE} api --host http://127.0.0.1:${FAULTPROXY_PORT} jobs/${JOB_ID}\""

start_faultproxy 2 503 /api/v1/ 64 ""
_gat10_start=$(date +%s%N)
_gat_run_leg "gat10" perl "$_gat10_perl_cmd" /api/v1/
_gat10_perl_elapsed=$(elapsed_since "$_gat10_start")
_GAT10_PERL_EXIT=$_GAT_LEG_EXIT

start_faultproxy 2 503 /api/v1/ 64 ""
_gat10_start=$(date +%s%N)
_gat_run_leg "gat10" zig "$_gat10_zig_cmd" /api/v1/
_gat10_zig_elapsed=$(elapsed_since "$_gat10_start")
_GAT10_ZIG_EXIT=$_GAT_LEG_EXIT

if [[ "$_GAT10_PERL_EXIT" -eq 0 && "$_GAT10_ZIG_EXIT" -eq 0 ]]; then
	echo "PASS: GAT-10 both exit 0"
else
	echo "FAIL: GAT-10 exits perl=$_GAT10_PERL_EXIT zig=$_GAT10_ZIG_EXIT (expected 0/0)"
	failed_tests=$((failed_tests + 1))
fi
if [[ "$_gat10_perl_elapsed" -lt 5 ]]; then
	echo "PASS: GAT-10 Perl elapsed ${_gat10_perl_elapsed}s < 5s (no Retry-After, computed delay 0)"
else
	echo "FAIL: GAT-10 Perl elapsed ${_gat10_perl_elapsed}s >= 5s (unexpected delay without Retry-After)"
	failed_tests=$((failed_tests + 1))
fi
if [[ "$_gat10_zig_elapsed" -lt 5 ]]; then
	echo "PASS: GAT-10 Zig elapsed ${_gat10_zig_elapsed}s < 5s (no Retry-After, computed delay 0)"
else
	echo "FAIL: GAT-10 Zig elapsed ${_gat10_zig_elapsed}s >= 5s (unexpected delay without Retry-After)"
	failed_tests=$((failed_tests + 1))
fi

# GAT-11: R4 — Retry-After on a non-retried status (404) is ignored.
# Test GAT-11: 404 + Retry-After: 30 — no retry, delay ignored
#
# 404 is never retried; the Retry-After header must be ignored.  Both make
# exactly 1 hit, exit non-zero, and finish quickly (per-leg elapsed < 5 s).
# The proxy is started before the timestamp so the measured window covers
# only the client run — if the 30 s Retry-After were (wrongly) honoured,
# the leg would take >= 30 s and this would fail.
_gat11_perl_cmd="bash -c \"OPENQA_CLI_RETRIES=2 OPENQA_CLI_RETRY_SLEEP_TIME_S=0 ${PERL_EXE} api --host http://127.0.0.1:${FAULTPROXY_PORT} jobs/${JOB_ID}\""
_gat11_zig_cmd="bash -c \"OPENQA_CLI_RETRIES=2 OPENQA_CLI_RETRY_SLEEP_TIME_S=0 ${ZIG_EXE} api --host http://127.0.0.1:${FAULTPROXY_PORT} jobs/${JOB_ID}\""

start_faultproxy 99 404 /api/v1/ 64 30
_gat11_start=$(date +%s%N)
_gat_run_leg "gat11" perl "$_gat11_perl_cmd" /api/v1/
_gat11_perl_elapsed=$(elapsed_since "$_gat11_start")
_GAT11_PERL_EXIT=$_GAT_LEG_EXIT
_GAT11_PERL_HITS=$_GAT_LEG_HITS

start_faultproxy 99 404 /api/v1/ 64 30
_gat11_start=$(date +%s%N)
_gat_run_leg "gat11" zig "$_gat11_zig_cmd" /api/v1/
_gat11_zig_elapsed=$(elapsed_since "$_gat11_start")
_GAT11_ZIG_EXIT=$_GAT_LEG_EXIT
_GAT11_ZIG_HITS=$_GAT_LEG_HITS

if [[ "$_GAT11_PERL_EXIT" -ne 0 && "$_GAT11_PERL_HITS" -eq 1 ]]; then
	echo "PASS: GAT-11 Perl exits non-zero with 1 hit (404 not retried)"
else
	echo "FAIL: GAT-11 Perl exit=$_GAT11_PERL_EXIT hits=$_GAT11_PERL_HITS (expected non-zero / 1)"
	failed_tests=$((failed_tests + 1))
fi
if [[ "$_GAT11_ZIG_EXIT" -ne 0 && "$_GAT11_ZIG_HITS" -eq 1 ]]; then
	echo "PASS: GAT-11 Zig exits non-zero with 1 hit (404 not retried)"
else
	echo "FAIL: GAT-11 Zig exit=$_GAT11_ZIG_EXIT hits=$_GAT11_ZIG_HITS (expected non-zero / 1)"
	failed_tests=$((failed_tests + 1))
fi
if [[ "$_gat11_perl_elapsed" -lt 5 ]]; then
	echo "PASS: GAT-11 Perl elapsed ${_gat11_perl_elapsed}s < 5s (Retry-After on 404 ignored)"
else
	echo "FAIL: GAT-11 Perl elapsed ${_gat11_perl_elapsed}s >= 5s (Retry-After on 404 was honoured)"
	failed_tests=$((failed_tests + 1))
fi
if [[ "$_gat11_zig_elapsed" -lt 5 ]]; then
	echo "PASS: GAT-11 Zig elapsed ${_gat11_zig_elapsed}s < 5s (Retry-After on 404 ignored)"
else
	echo "FAIL: GAT-11 Zig elapsed ${_gat11_zig_elapsed}s >= 5s (Retry-After on 404 was honoured)"
	failed_tests=$((failed_tests + 1))
fi

# GAT-12: R4 — Retry-After 60s cap divergence (Zig caps at 60s, Perl uncapped).
# Test GAT-12: 429x1 + Retry-After: 70 — Zig caps delay at 60s and finishes within timeout; Perl uncapped.
#
# The server sends Retry-After: 70 on a 429 error.
# Zig clamps the delay to RETRY_AFTER_CAP_S = 60s, retries after 60s, and succeeds (finishing in ~60s).
# Perl does not cap the delay, sleeping the full 70s.
# Using `timeout 65s` (providing a 5s-10s safety margin), Zig completes successfully (exit 0)
# while Perl times out at 65s (exit 124).
_gat12_perl_cmd="timeout 65s bash -c \"OPENQA_CLI_RETRIES=1 OPENQA_CLI_RETRY_SLEEP_TIME_S=0 ${PERL_EXE} api --host http://127.0.0.1:${FAULTPROXY_PORT} jobs/${JOB_ID}\""
_gat12_zig_cmd="timeout 65s bash -c \"OPENQA_CLI_RETRIES=1 OPENQA_CLI_RETRY_SLEEP_TIME_S=0 ${ZIG_EXE} api --host http://127.0.0.1:${FAULTPROXY_PORT} jobs/${JOB_ID}\""

start_faultproxy 1 429 /api/v1/ 64 70
_gat12_start=$(date +%s%N)
_gat_run_leg "gat12" zig "$_gat12_zig_cmd" /api/v1/
_gat12_zig_elapsed=$(elapsed_since "$_gat12_start")
_GAT12_ZIG_EXIT=$_GAT_LEG_EXIT

start_faultproxy 1 429 /api/v1/ 64 70
_gat12_start=$(date +%s%N)
_gat_run_leg "gat12" perl "$_gat12_perl_cmd" /api/v1/
_gat12_perl_elapsed=$(elapsed_since "$_gat12_start")
_GAT12_PERL_EXIT=$_GAT_LEG_EXIT

if [[ "$DRY_RUN" == "true" ]]; then
	echo "PASS: GAT-12 dry run skipped timing checks"
else
	if [[ "$_GAT12_ZIG_EXIT" -eq 0 && "$_gat12_zig_elapsed" -ge 60 && "$_gat12_zig_elapsed" -lt 65 ]]; then
		echo "PASS: GAT-12 Zig capped Retry-After to 60s, exited 0 in ${_gat12_zig_elapsed}s (< 65s timeout)"
	else
		echo "FAIL: GAT-12 Zig exit=$_GAT12_ZIG_EXIT elapsed=${_gat12_zig_elapsed}s (expected 0 / 60-64s)"
		failed_tests=$((failed_tests + 1))
	fi

	if [[ "$_GAT12_PERL_EXIT" -ne 0 ]]; then
		echo "PASS: GAT-12 Perl timed out at 65s as expected (uncapped Retry-After: 70s)"
	else
		echo "FAIL: GAT-12 Perl exit=$_GAT12_PERL_EXIT elapsed=${_gat12_perl_elapsed}s (expected timeout/non-zero)"
		failed_tests=$((failed_tests + 1))
	fi
fi

# =============================================================================
# Part B — zoqa-clone-job ↔ openqa-clone-job (GAT-20 to GAT-28)
# =============================================================================
#
# Part B needs a job with real assets (the rich job: cirros qcow2 + ISO).
# ensure_rich_job is idempotent — if an earlier suite already scheduled the
# rich job, this is a no-op.

ensure_rich_job
GAT_RICH_JOB_ID="$RICH_JOB_ID"

# GAT-20: R1 — Accept on every request including redirect hops.
# Test GAT-20: clone-job with --pass-redirects — Accept on every hop
#
# The proxy does not follow backend redirects, so the 302 + Location from
# the /tests/{id}/asset/... route reaches the client.  Both implementations
# must follow the redirect themselves and send Accept on every hop.  The
# header log must show no "accept=-" line for the asset paths.
start_faultproxy 0 503 "/tests/${GAT_RICH_JOB_ID}/asset/" 64 "" "--header-log --pass-redirects"
ASSET_DIR_GAT_20_ZIG="/tmp/e2e-gat20-zig-$$"
container_exec mkdir -p "$ASSET_DIR_GAT_20_ZIG"
run_capture "gat20" zig \
	"bash -c \"${ZIG_CLONE_EXE} --from http://127.0.0.1:${FAULTPROXY_PORT} \
	 --host http://localhost --skip-deps \
	 ${GAT_RICH_JOB_ID} --dir ${ASSET_DIR_GAT_20_ZIG}\""
_GAT20_ZIG_EXIT=$_LAST_EXIT
assert_all_requests_have_accept "/tests/${GAT_RICH_JOB_ID}/asset/" "GAT-20 Zig sends Accept on every request and redirect hop"
stop_faultproxy

if [[ "$_GAT20_ZIG_EXIT" -eq 0 ]]; then
	echo "PASS: GAT-20 Zig exits 0 with --pass-redirects"
else
	echo "FAIL: GAT-20 Zig exit=$_GAT20_ZIG_EXIT (expected 0)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi
if [[ "$DRY_RUN" != "true" ]]; then
	assert_downloaded_assets_md5 "$ASSET_DIR_GAT_20_ZIG" "GAT-20 Zig"
fi
container_exec rm -rf "$ASSET_DIR_GAT_20_ZIG"

ASSET_DIR_GAT_20_PERL="/tmp/e2e-gat20-perl-$$"
container_exec mkdir -p "$ASSET_DIR_GAT_20_PERL"
start_faultproxy 0 503 "/tests/${GAT_RICH_JOB_ID}/asset/" 64 "" "--header-log --pass-redirects"
run_capture "gat20" perl \
	"bash -c \"${PERL_CLONE_EXE} --from http://127.0.0.1:${FAULTPROXY_PORT} \
	 --host http://localhost --skip-deps \
	 ${GAT_RICH_JOB_ID} --dir ${ASSET_DIR_GAT_20_PERL}\""
_GAT20_PERL_EXIT=$_LAST_EXIT
assert_all_requests_have_accept "/tests/${GAT_RICH_JOB_ID}/asset/" "GAT-20 Perl sends Accept on every request and redirect hop"
stop_faultproxy

if [[ "$_GAT20_PERL_EXIT" -eq 0 ]]; then
	echo "PASS: GAT-20 Perl exits 0 with --pass-redirects"
else
	echo "FAIL: GAT-20 Perl exit=$_GAT20_PERL_EXIT (expected 0)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi
if [[ "$DRY_RUN" != "true" ]]; then
	assert_downloaded_assets_md5 "$ASSET_DIR_GAT_20_PERL" "GAT-20 Perl"
fi
container_exec rm -rf "$ASSET_DIR_GAT_20_PERL"

# GAT-21: R1 — challenge_no_accept: challenged only when Accept is missing.
# Test GAT-21: challenge_no_accept on /tests/ + /assets/ — both download OK
#
# The proxy serves the challenge page only to requests WITHOUT an Accept
# header.  Both implementations send Accept on asset GETs and redirect
# hops, so both download the assets cleanly (exit 0, MD5 OK).
start_faultproxy 99 challenge_no_accept "/tests/${GAT_RICH_JOB_ID}/asset/,/assets/" 64
ASSET_DIR_GAT_21_ZIG="/tmp/e2e-gat21-zig-$$"
container_exec mkdir -p "$ASSET_DIR_GAT_21_ZIG"
run_capture "gat21" zig \
	"bash -c \"${ZIG_CLONE_EXE} --from http://127.0.0.1:${FAULTPROXY_PORT} \
	 --host http://localhost --skip-deps \
	 ${GAT_RICH_JOB_ID} --dir ${ASSET_DIR_GAT_21_ZIG}\""
_GAT21_ZIG_EXIT=$_LAST_EXIT
stop_faultproxy

if [[ "$_GAT21_ZIG_EXIT" -eq 0 ]]; then
	echo "PASS: GAT-21 Zig exits 0 (Accept sent, no challenge)"
else
	echo "FAIL: GAT-21 Zig exit=$_GAT21_ZIG_EXIT (expected 0 — challenged?)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi
if [[ "$DRY_RUN" != "true" ]]; then
	assert_downloaded_assets_md5 "$ASSET_DIR_GAT_21_ZIG" "GAT-21 Zig"
fi
container_exec rm -rf "$ASSET_DIR_GAT_21_ZIG"

ASSET_DIR_GAT_21_PERL="/tmp/e2e-gat21-perl-$$"
container_exec mkdir -p "$ASSET_DIR_GAT_21_PERL"
start_faultproxy 99 challenge_no_accept "/tests/${GAT_RICH_JOB_ID}/asset/,/assets/" 64
run_capture "gat21" perl \
	"bash -c \"${PERL_CLONE_EXE} --from http://127.0.0.1:${FAULTPROXY_PORT} \
	 --host http://localhost --skip-deps \
	 ${GAT_RICH_JOB_ID} --dir ${ASSET_DIR_GAT_21_PERL}\""
_GAT21_PERL_EXIT=$_LAST_EXIT
stop_faultproxy

if [[ "$_GAT21_PERL_EXIT" -eq 0 ]]; then
	echo "PASS: GAT-21 Perl exits 0 (Accept sent, no challenge)"
else
	echo "FAIL: GAT-21 Perl exit=$_GAT21_PERL_EXIT (expected 0 — challenged?)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi
if [[ "$DRY_RUN" != "true" ]]; then
	assert_downloaded_assets_md5 "$ASSET_DIR_GAT_21_PERL" "GAT-21 Perl"
fi
container_exec rm -rf "$ASSET_DIR_GAT_21_PERL"

# GAT-22: R2 — challenge on asset GET.
# Test GAT-22: challenge on asset GET — Zig rejects, Perl saves (divergence)
#
# The proxy serves the challenge page (200 text/html) for every attempt of
# the hdd asset.  Zig must treat this as a permanent error: exit 1, name
# the asset, make exactly 1 attempt (no retry), and keep no file.  Perl
# (oracle) saves the HTML as the asset and exits 0 — a documented
# divergence (docs/PERL_DEVIATIONS.md).
start_faultproxy 99 challenge "/tests/${GAT_RICH_JOB_ID}/asset/hdd/" 64
ASSET_DIR_GAT_22_ZIG="/tmp/e2e-gat22-zig-$$"
container_exec mkdir -p "$ASSET_DIR_GAT_22_ZIG"
run_capture "gat22" zig \
	"bash -c \"${ZIG_CLONE_EXE} --from http://127.0.0.1:${FAULTPROXY_PORT} \
	 --host http://localhost --skip-deps \
	 ${GAT_RICH_JOB_ID} --dir ${ASSET_DIR_GAT_22_ZIG}\""
_GAT22_ZIG_EXIT=$_LAST_EXIT
_GAT22_ZIG_HITS=$(get_faultproxy_hits "/tests/${GAT_RICH_JOB_ID}/asset/hdd/")
stop_faultproxy

if [[ "$_GAT22_ZIG_EXIT" -eq 1 ]]; then
	echo "PASS: GAT-22 Zig exits 1 on HTML challenge"
else
	echo "FAIL: GAT-22 Zig exit=$_GAT22_ZIG_EXIT (expected 1)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi
assert_impl_log_pattern "gat22" zig stderr \
	"asset download failed for '.*qcow2'.*HTML" \
	"GAT-22 Zig stderr names the asset and the HTML challenge"
if [[ "$_GAT22_ZIG_HITS" -eq 1 ]]; then
	echo "PASS: GAT-22 Zig made exactly 1 attempt (no retry on HTML)"
else
	echo "FAIL: GAT-22 Zig made $_GAT22_ZIG_HITS attempt(s) (expected 1)"
	failed_tests=$((failed_tests + 1))
fi
if [[ "$DRY_RUN" != "true" ]]; then
	if container_exec find "$ASSET_DIR_GAT_22_ZIG/hdd" -type f 2>/dev/null | grep -q .; then
		echo "FAIL: GAT-22 Zig kept a file for the challenged asset"
		failed_tests=$((failed_tests + 1))
	else
		echo "PASS: GAT-22 Zig kept no file for the challenged asset"
	fi
fi
container_exec rm -rf "$ASSET_DIR_GAT_22_ZIG"

ASSET_DIR_GAT_22_PERL="/tmp/e2e-gat22-perl-$$"
container_exec mkdir -p "$ASSET_DIR_GAT_22_PERL"
start_faultproxy 99 challenge "/tests/${GAT_RICH_JOB_ID}/asset/hdd/" 64
run_capture "gat22" perl \
	"bash -c \"${PERL_CLONE_EXE} --from http://127.0.0.1:${FAULTPROXY_PORT} \
	 --host http://localhost --skip-deps \
	 ${GAT_RICH_JOB_ID} --dir ${ASSET_DIR_GAT_22_PERL}\""
_GAT22_PERL_EXIT=$_LAST_EXIT
stop_faultproxy
# Perl saves the challenge HTML as the asset and exits 0 (divergence).
if [[ "$_GAT22_PERL_EXIT" -eq 0 ]]; then
	echo "PASS: GAT-22 Perl exits 0 (HTML saved as asset — documented divergence)"
else
	echo "FAIL: GAT-22 Perl exit=$_GAT22_PERL_EXIT (expected 0)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi
container_exec rm -rf "$ASSET_DIR_GAT_22_PERL"

# GAT-23: R3 — BFS GET 429x2.
# Test GAT-23: BFS GET 429x2 — both retry
#
# The proxy faults the BFS GET (/api/v1/jobs/{id}) with 429 twice.  Both
# must retry and exit 0.
_gat_run_both "gat23" 429 2 "/api/v1/jobs/${GAT_RICH_JOB_ID}" "" \
	"bash -c \"${PERL_CLONE_EXE} --from http://127.0.0.1:${FAULTPROXY_PORT} \
	 --host http://localhost --skip-deps \
	 ${GAT_RICH_JOB_ID} --dir /tmp/e2e-gat23-perl-$$ --skip-download\"" \
	-- \
	"bash -c \"${ZIG_CLONE_EXE} --from http://127.0.0.1:${FAULTPROXY_PORT} \
	 --host http://localhost --skip-deps \
	 ${GAT_RICH_JOB_ID} --dir /tmp/e2e-gat23-zig-$$ --skip-download\""

if [[ "$_GAT_PERL_EXIT" -eq 0 ]]; then
	echo "PASS: GAT-23 Perl exits 0 (retried BFS 429s)"
else
	echo "FAIL: GAT-23 Perl exit=$_GAT_PERL_EXIT (expected 0)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi
if [[ "$_GAT_ZIG_EXIT" -eq 0 ]]; then
	echo "PASS: GAT-23 Zig exits 0 (retried BFS 429s)"
else
	echo "FAIL: GAT-23 Zig exit=$_GAT_ZIG_EXIT (expected 0)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi

# GAT-24: R3 — asset 429x2.
# Test GAT-24: asset 429x2 — both retry, MD5 OK
#
# The proxy faults the hdd asset GET with 429 twice, then forwards.  Both
# must retry, exit 0, and download the asset intact (MD5 OK).
start_faultproxy 2 429 "/tests/${GAT_RICH_JOB_ID}/asset/hdd/" 64
ASSET_DIR_GAT_24_ZIG="/tmp/e2e-gat24-zig-$$"
container_exec mkdir -p "$ASSET_DIR_GAT_24_ZIG"
run_capture "gat24" zig \
	"bash -c \"${ZIG_CLONE_EXE} --from http://127.0.0.1:${FAULTPROXY_PORT} \
	 --host http://localhost --skip-deps \
	 ${GAT_RICH_JOB_ID} --dir ${ASSET_DIR_GAT_24_ZIG}\""
_GAT24_ZIG_EXIT=$_LAST_EXIT
_GAT24_ZIG_HITS=$(get_faultproxy_hits "/tests/${GAT_RICH_JOB_ID}/asset/hdd/")
stop_faultproxy

if [[ "$_GAT24_ZIG_EXIT" -eq 0 && "$_GAT24_ZIG_HITS" -ge 3 ]]; then
	echo "PASS: GAT-24 Zig exits 0 with ${_GAT24_ZIG_HITS} hits (retried asset 429s)"
else
	echo "FAIL: GAT-24 Zig exit=$_GAT24_ZIG_EXIT hits=$_GAT24_ZIG_HITS (expected 0 / >=3)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi
if [[ "$DRY_RUN" != "true" ]]; then
	assert_downloaded_assets_md5 "$ASSET_DIR_GAT_24_ZIG" "GAT-24 Zig"
fi
container_exec rm -rf "$ASSET_DIR_GAT_24_ZIG"

ASSET_DIR_GAT_24_PERL="/tmp/e2e-gat24-perl-$$"
container_exec mkdir -p "$ASSET_DIR_GAT_24_PERL"
start_faultproxy 2 429 "/tests/${GAT_RICH_JOB_ID}/asset/hdd/" 64
run_capture "gat24" perl \
	"bash -c \"${PERL_CLONE_EXE} --from http://127.0.0.1:${FAULTPROXY_PORT} \
	 --host http://localhost --skip-deps \
	 ${GAT_RICH_JOB_ID} --dir ${ASSET_DIR_GAT_24_PERL}\""
_GAT24_PERL_EXIT=$_LAST_EXIT
_GAT24_PERL_HITS=$(get_faultproxy_hits "/tests/${GAT_RICH_JOB_ID}/asset/hdd/")
stop_faultproxy

if [[ "$_GAT24_PERL_EXIT" -eq 0 && "$_GAT24_PERL_HITS" -ge 3 ]]; then
	echo "PASS: GAT-24 Perl exits 0 with ${_GAT24_PERL_HITS} hits (retried asset 429s)"
else
	echo "FAIL: GAT-24 Perl exit=$_GAT24_PERL_EXIT hits=$_GAT24_PERL_HITS (expected 0 / >=3)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi
if [[ "$DRY_RUN" != "true" ]]; then
	assert_downloaded_assets_md5 "$ASSET_DIR_GAT_24_PERL" "GAT-24 Perl"
fi
container_exec rm -rf "$ASSET_DIR_GAT_24_PERL"

# GAT-25: R3 — asset 408x2.
# Test GAT-25: asset 408x2 — both retry, MD5 OK
start_faultproxy 2 408 "/tests/${GAT_RICH_JOB_ID}/asset/hdd/" 64
ASSET_DIR_GAT_25_ZIG="/tmp/e2e-gat25-zig-$$"
container_exec mkdir -p "$ASSET_DIR_GAT_25_ZIG"
run_capture "gat25" zig \
	"bash -c \"${ZIG_CLONE_EXE} --from http://127.0.0.1:${FAULTPROXY_PORT} \
	 --host http://localhost --skip-deps \
	 ${GAT_RICH_JOB_ID} --dir ${ASSET_DIR_GAT_25_ZIG}\""
_GAT25_ZIG_EXIT=$_LAST_EXIT
_GAT25_ZIG_HITS=$(get_faultproxy_hits "/tests/${GAT_RICH_JOB_ID}/asset/hdd/")
stop_faultproxy

if [[ "$_GAT25_ZIG_EXIT" -eq 0 && "$_GAT25_ZIG_HITS" -ge 3 ]]; then
	echo "PASS: GAT-25 Zig exits 0 with ${_GAT25_ZIG_HITS} hits (retried asset 408s)"
else
	echo "FAIL: GAT-25 Zig exit=$_GAT25_ZIG_EXIT hits=$_GAT25_ZIG_HITS (expected 0 / >=3)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi
if [[ "$DRY_RUN" != "true" ]]; then
	assert_downloaded_assets_md5 "$ASSET_DIR_GAT_25_ZIG" "GAT-25 Zig"
fi
container_exec rm -rf "$ASSET_DIR_GAT_25_ZIG"

ASSET_DIR_GAT_25_PERL="/tmp/e2e-gat25-perl-$$"
container_exec mkdir -p "$ASSET_DIR_GAT_25_PERL"
start_faultproxy 2 408 "/tests/${GAT_RICH_JOB_ID}/asset/hdd/" 64
run_capture "gat25" perl \
	"bash -c \"${PERL_CLONE_EXE} --from http://127.0.0.1:${FAULTPROXY_PORT} \
	 --host http://localhost --skip-deps \
	 ${GAT_RICH_JOB_ID} --dir ${ASSET_DIR_GAT_25_PERL}\""
_GAT25_PERL_EXIT=$_LAST_EXIT
_GAT25_PERL_HITS=$(get_faultproxy_hits "/tests/${GAT_RICH_JOB_ID}/asset/hdd/")
stop_faultproxy

if [[ "$_GAT25_PERL_EXIT" -eq 0 && "$_GAT25_PERL_HITS" -ge 3 ]]; then
	echo "PASS: GAT-25 Perl exits 0 with ${_GAT25_PERL_HITS} hits (retried asset 408s)"
else
	echo "FAIL: GAT-25 Perl exit=$_GAT25_PERL_EXIT hits=$_GAT25_PERL_HITS (expected 0 / >=3)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi
if [[ "$DRY_RUN" != "true" ]]; then
	assert_downloaded_assets_md5 "$ASSET_DIR_GAT_25_PERL" "GAT-25 Perl"
fi
container_exec rm -rf "$ASSET_DIR_GAT_25_PERL"

# GAT-26: R3 — persistent asset 429 with --retry 0.
# Test GAT-26: asset 429 always, --retry 0 — no retries
#
# With --retry 0 neither implementation retries.  Zig makes 1 request
# (GET) and exits 1 (correct).  Perl makes 2 requests (HEAD + GET —
# the HEAD is curl's redirect-resolution probe, see SPEC §18.18) and
# exits 0 (known curl --fail bug, documented in docs/PERL_DEVIATIONS.md).
start_faultproxy 99 429 "/tests/${GAT_RICH_JOB_ID}/asset/hdd/" 64
ASSET_DIR_GAT_26_ZIG="/tmp/e2e-gat26-zig-$$"
container_exec mkdir -p "$ASSET_DIR_GAT_26_ZIG"
run_capture "gat26" zig \
	"bash -c \"${ZIG_CLONE_EXE} --from http://127.0.0.1:${FAULTPROXY_PORT} \
	 --host http://localhost --skip-deps --retry 0 \
	 ${GAT_RICH_JOB_ID} --dir ${ASSET_DIR_GAT_26_ZIG}\""
_GAT26_ZIG_EXIT=$_LAST_EXIT
_GAT26_ZIG_HITS=$(get_faultproxy_hits "/tests/${GAT_RICH_JOB_ID}/asset/hdd/")
stop_faultproxy

if [[ "$_GAT26_ZIG_EXIT" -eq 1 && "$_GAT26_ZIG_HITS" -eq 1 ]]; then
	echo "PASS: GAT-26 Zig exits 1 with 1 hit (--retry 0)"
else
	echo "FAIL: GAT-26 Zig exit=$_GAT26_ZIG_EXIT hits=$_GAT26_ZIG_HITS (expected 1 / 1)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi
container_exec rm -rf "$ASSET_DIR_GAT_26_ZIG"

ASSET_DIR_GAT_26_PERL="/tmp/e2e-gat26-perl-$$"
container_exec mkdir -p "$ASSET_DIR_GAT_26_PERL"
start_faultproxy 99 429 "/tests/${GAT_RICH_JOB_ID}/asset/hdd/" 64
run_capture "gat26" perl \
	"bash -c \"${PERL_CLONE_EXE} --from http://127.0.0.1:${FAULTPROXY_PORT} \
	 --host http://localhost --skip-deps --retry 0 \
	 ${GAT_RICH_JOB_ID} --dir ${ASSET_DIR_GAT_26_PERL}\""
_GAT26_PERL_EXIT=$_LAST_EXIT
_GAT26_PERL_HITS=$(get_faultproxy_hits "/tests/${GAT_RICH_JOB_ID}/asset/hdd/")
stop_faultproxy

# Perl's openqa-clone-job issues two requests per asset: a HEAD
# (_resolve_redirection, CloneJob.pm:196-198) to resolve the final URL
# after following redirects, and a GET (mirror(), CloneJob.pm:201-204)
# to download the body. Both hit the fault path, so the expected count
# is 2, not 1. Zig follows redirects in-process and issues a single
# GET (1 hit). See SPEC §18.18 step 4 note and PERL_DEVIATIONS.md.
if [[ "$_GAT26_PERL_EXIT" -eq 0 && "$_GAT26_PERL_HITS" -eq 2 ]]; then
	echo "PASS: GAT-26 Perl exits 0 with 2 hits (HEAD + GET, curl --fail bug — documented)"
else
	echo "FAIL: GAT-26 Perl exit=$_GAT26_PERL_EXIT hits=$_GAT26_PERL_HITS (expected 0 / 2)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi
container_exec rm -rf "$ASSET_DIR_GAT_26_PERL"

# GAT-27: R4 — asset 429x2 + Retry-After: 2.
# Test GAT-27: asset 429x2 + Retry-After: 2 — both honour the delay
#
# SLEEP=0 makes the computed delay 0; the 2 s Retry-After on each of the
# two retried responses dominates.  Each leg's elapsed >= 4 s (2 retried
# responses x 2 s).  The legs run sequentially, so each is timed separately.
ASSET_DIR_GAT_27_ZIG="/tmp/e2e-gat27-zig-$$"
container_exec mkdir -p "$ASSET_DIR_GAT_27_ZIG"
start_faultproxy 2 429 "/tests/${GAT_RICH_JOB_ID}/asset/hdd/" 64 2
_gat27_start=$(date +%s%N)
run_capture "gat27" zig \
	"bash -c \"OPENQA_CLI_RETRY_SLEEP_TIME_S=0 ${ZIG_CLONE_EXE} --from http://127.0.0.1:${FAULTPROXY_PORT} \
	 --host http://localhost --skip-deps \
	 ${GAT_RICH_JOB_ID} --dir ${ASSET_DIR_GAT_27_ZIG}\""
_GAT27_ZIG_EXIT=$_LAST_EXIT
stop_faultproxy
_gat27_zig_elapsed=$(elapsed_since "$_gat27_start")

if [[ "$_GAT27_ZIG_EXIT" -eq 0 ]]; then
	echo "PASS: GAT-27 Zig exits 0"
else
	echo "FAIL: GAT-27 Zig exit=$_GAT27_ZIG_EXIT (expected 0)"
	failed_tests=$((failed_tests + 1))
fi
if [[ "$_gat27_zig_elapsed" -ge 4 ]]; then
	echo "PASS: GAT-27 Zig elapsed ${_gat27_zig_elapsed}s >= 4s (Retry-After honoured)"
else
	echo "FAIL: GAT-27 Zig elapsed ${_gat27_zig_elapsed}s < 4s (Retry-After not honoured)"
	failed_tests=$((failed_tests + 1))
fi
if [[ "$DRY_RUN" != "true" ]]; then
	assert_downloaded_assets_md5 "$ASSET_DIR_GAT_27_ZIG" "GAT-27 Zig"
fi
container_exec rm -rf "$ASSET_DIR_GAT_27_ZIG"

ASSET_DIR_GAT_27_PERL="/tmp/e2e-gat27-perl-$$"
container_exec mkdir -p "$ASSET_DIR_GAT_27_PERL"
start_faultproxy 2 429 "/tests/${GAT_RICH_JOB_ID}/asset/hdd/" 64 2
_gat27_start=$(date +%s%N)
run_capture "gat27" perl \
	"bash -c \"OPENQA_CLI_RETRY_SLEEP_TIME_S=0 ${PERL_CLONE_EXE} --from http://127.0.0.1:${FAULTPROXY_PORT} \
	 --host http://localhost --skip-deps \
	 ${GAT_RICH_JOB_ID} --dir ${ASSET_DIR_GAT_27_PERL}\""
_GAT27_PERL_EXIT=$_LAST_EXIT
stop_faultproxy
_gat27_perl_elapsed=$(elapsed_since "$_gat27_start")

if [[ "$_GAT27_PERL_EXIT" -eq 0 ]]; then
	echo "PASS: GAT-27 Perl exits 0"
else
	echo "FAIL: GAT-27 Perl exit=$_GAT27_PERL_EXIT (expected 0)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi
if [[ "$_gat27_perl_elapsed" -ge 4 ]]; then
	echo "PASS: GAT-27 Perl elapsed ${_gat27_perl_elapsed}s >= 4s (Retry-After honoured)"
else
	echo "FAIL: GAT-27 Perl elapsed ${_gat27_perl_elapsed}s < 4s (Retry-After not honoured)"
	failed_tests=$((failed_tests + 1))
fi
if [[ "$DRY_RUN" != "true" ]]; then
	assert_downloaded_assets_md5 "$ASSET_DIR_GAT_27_PERL" "GAT-27 Perl"
fi
container_exec rm -rf "$ASSET_DIR_GAT_27_PERL"

# GAT-28: R3 — POST 429x1 (optional).
# Test GAT-28: POST 429x1 — both retry, job created
#
# The proxy faults the destination POST (/api/v1/jobs) with 429 once.
# Both must retry and create the job (exit 0).
_gat_run_both "gat28" 429 1 "/api/v1/jobs" "" \
	"bash -c \"${PERL_CLONE_EXE} --from http://127.0.0.1:${FAULTPROXY_PORT} \
	 --host http://localhost --skip-deps \
	 ${GAT_RICH_JOB_ID} --dir /tmp/e2e-gat28-perl-$$ --skip-download\"" \
	-- \
	"bash -c \"${ZIG_CLONE_EXE} --from http://127.0.0.1:${FAULTPROXY_PORT} \
	 --host http://localhost --skip-deps \
	 ${GAT_RICH_JOB_ID} --dir /tmp/e2e-gat28-zig-$$ --skip-download\""

if [[ "$_GAT_PERL_EXIT" -eq 0 ]]; then
	echo "PASS: GAT-28 Perl exits 0 (retried POST 429, job created)"
else
	echo "FAIL: GAT-28 Perl exit=$_GAT_PERL_EXIT (expected 0)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi
if [[ "$_GAT_ZIG_EXIT" -eq 0 ]]; then
	echo "PASS: GAT-28 Zig exits 0 (retried POST 429, job created)"
else
	echo "FAIL: GAT-28 Zig exit=$_GAT_ZIG_EXIT (expected 0)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi

# =============================================================================
# Part C — o3 symptom reproduction (GAT-40 to GAT-43)
# =============================================================================
#
# Part C reproduces the openqa.opensuse.org failure mode: the first asset
# downloads fine, then a later asset faults on every attempt.

# GAT-40 (was CLO-129): partial_cl on EVERY attempt of a LATER asset.
# Test GAT-40: persistent truncation on a later asset — Zig retries, Perl does not
#
# Reproduces the failure seen against openqa.opensuse.org: the first asset
# downloads fine, then every attempt of a later, larger asset ends before
# Content-Length bytes arrive, so the retry budget runs out.
#
# Both implementations download seed-nocloud.iso first, then the cirros
# qcow2.  Only the hdd path is faulted (fail_times=99 → never recovers).
# 1 MiB is sent before the RST: more than the 64 KiB file buffer, so the
# real file writer drains mid-stream before the truncation is detected.
#
# Zig (default --retry 5, 3 s sleep):
#   - exit 1, stderr names the qcow2 and HttpTransferTruncated
#   - exactly 6 GETs on the hdd path (1 + 5 retries)
#   - no partial qcow2 left behind (deleted after every attempt)
#   - the ISO, downloaded before the failure, is kept and intact (MD5)
#
# Perl (oracle, same fault): curl sees CURLE_PARTIAL_FILE (18) on the
# length-bearing drop and does not auto-retry (see CLO-98b), so:
#   - exit non-zero (curl 18 → "Cloning aborted during asset download")
#   - >= 1 GET on the hdd path (no retry on error 18; a transient proxy
#     backend-fetch failure can add an extra attempt via curl's error-56
#     retry, so we assert >= 1 rather than exactly 1)
#   - the ISO: Perl's asset download order is non-deterministic; MD5 is
#     asserted only when the ISO is present.
#
# ensure_rich_job is idempotent: if an earlier suite already scheduled the
# rich job, this reuses it.  PARTIAL_JOB_ID is set locally — no cross-suite
# dependency.
ensure_rich_job
PARTIAL_JOB_ID="$RICH_JOB_ID"

echo "--- Test GAT-40: Zig HttpTransferTruncated on every attempt of a later asset ---"
tag="gat-40"
ASSET_DIR_GAT_40="/tmp/e2e-${tag}-zig-$$"
container_exec mkdir -p "$ASSET_DIR_GAT_40"
start_faultproxy 99 partial_cl "/tests/${PARTIAL_JOB_ID}/asset/hdd/" 1048576

run_capture "${tag}" zig \
	"$ZIG_CLONE_EXE --from http://127.0.0.1:${FAULTPROXY_PORT} \
	 --host http://localhost --skip-deps --retry 5 \
	 ${PARTIAL_JOB_ID} --dir ${ASSET_DIR_GAT_40}"
_ZIG_EXIT=$_LAST_EXIT

stop_faultproxy

if [[ "$_ZIG_EXIT" -eq 1 ]]; then
	echo "PASS: GAT-40 Zig exits 1 once retries are exhausted"
else
	echo "FAIL: GAT-40 Zig exited $_ZIG_EXIT (expected 1)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi

assert_impl_log_pattern "${tag}" zig stderr \
	"asset download failed for 'cirros-0\.6\.3-x86_64-disk\.qcow2': HttpTransferTruncated" \
	"GAT-40 Zig stderr names the truncated asset and HttpTransferTruncated"

_GAT40_HITS=$(get_faultproxy_hits "/tests/${PARTIAL_JOB_ID}/asset/hdd/")
if [[ "$_GAT40_HITS" -eq 6 ]]; then
	echo "PASS: GAT-40 Zig made exactly 6 attempts on the truncated asset (1 + 5 retries)"
else
	echo "FAIL: GAT-40 Zig made $_GAT40_HITS attempt(s) on the truncated asset (expected 6)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi

if [[ "$DRY_RUN" != "true" ]]; then
	if container_exec find "$ASSET_DIR_GAT_40/hdd" -type f 2>/dev/null | grep -q .; then
		echo "FAIL: GAT-40 Zig left a partial qcow2 behind"
		container_exec ls -la "$ASSET_DIR_GAT_40/hdd" || true
		failed_tests=$((failed_tests + 1))
	else
		echo "PASS: GAT-40 Zig — no partial qcow2 left after failed download"
	fi

	if container_exec test -s "$ASSET_DIR_GAT_40/iso/seed-nocloud.iso"; then
		echo "PASS: GAT-40 Zig kept the ISO downloaded before the failure"
	else
		echo "FAIL: GAT-40 Zig did not keep the ISO downloaded before the failure"
		failed_tests=$((failed_tests + 1))
	fi
fi

# The kept ISO must be complete, not affected by the later failure.
assert_downloaded_assets_md5 "$ASSET_DIR_GAT_40" "GAT-40 Zig"
container_exec rm -rf "$ASSET_DIR_GAT_40"

# GAT-40 (Perl leg): same persistent partial_cl fault, Perl oracle.
#
# curl sees CURLE_PARTIAL_FILE (18) on the length-bearing drop and does not
# auto-retry (curl's --retry excludes error 18 — see CLO-98b and
# docs/PERL_DEVIATIONS.md "Mid-transfer TCP drop").  Expected:
#   - exit non-zero (curl 18 → "Cloning aborted during asset download")
#   - >= 1 GET on the hdd path (no retry on error 18; a transient backend
#     fetch failure in the proxy can add an extra attempt via curl's
#     error-56 retry, so we assert >= 1 rather than exactly 1 — the
#     faultproxy's backend-fetch retry loop minimises but does not
#     eliminate this)
#   - the partial qcow2 left behind is informational only (no assertion):
#     CLO-98 shows Perl leaves corrupted files in the length-less case, but
#     the length-bearing case is not documented, so we list it without
#     pass/fail.
#   - the ISO: Perl's asset download order is non-deterministic (unlike
#     Zig, which downloads the ISO first).  If Perl downloads the ISO
#     before the faulted qcow2, the ISO is kept and intact (MD5).  If
#     Perl faults the qcow2 first, the ISO is never downloaded.  Both
#     outcomes are valid; we assert MD5 only when the ISO is present.
echo "--- Test GAT-40 (Perl): persistent partial_cl — no retry on length-bearing drop ---"
tag="gat-40-perl"
ASSET_DIR_GAT_40_PERL="/tmp/e2e-${tag}-$$"
container_exec mkdir -p "$ASSET_DIR_GAT_40_PERL"
start_faultproxy 99 partial_cl "/tests/${PARTIAL_JOB_ID}/asset/hdd/" 1048576

run_capture "${tag}" perl \
	"$PERL_CLONE_EXE --from http://127.0.0.1:${FAULTPROXY_PORT} \
	 --host http://localhost --skip-deps \
	 ${PARTIAL_JOB_ID} --dir ${ASSET_DIR_GAT_40_PERL}"
_PERL_EXIT=$_LAST_EXIT

stop_faultproxy

if [[ "$_PERL_EXIT" -ne 0 ]]; then
	echo "PASS: GAT-40 Perl exits non-zero on persistent length-bearing truncation (no retry)"
else
	echo "FAIL: GAT-40 Perl exited 0 (expected non-zero — curl should fail on CURLE_PARTIAL_FILE)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi

_GAT40_PERL_HITS=$(get_faultproxy_hits "/tests/${PARTIAL_JOB_ID}/asset/hdd/")
if [[ "$_GAT40_PERL_HITS" -ge 1 ]]; then
	echo "PASS: GAT-40 Perl made $_GAT40_PERL_HITS attempt(s) on the truncated asset (>= 1; no retry on error 18)"
else
	echo "FAIL: GAT-40 Perl made 0 attempts on the truncated asset (expected >= 1)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi

if [[ "$DRY_RUN" != "true" ]]; then
	# Informational: list any partial qcow2 left behind.  No pass/fail — the
	# length-bearing case is not documented in CLO-98 (which covers the
	# length-less case only).
	if container_exec find "$ASSET_DIR_GAT_40_PERL/hdd" -type f 2>/dev/null | grep -q .; then
		echo "INFO: GAT-40 Perl left a partial qcow2 behind:"
		container_exec ls -la "$ASSET_DIR_GAT_40_PERL/hdd" || true
	else
		echo "INFO: GAT-40 Perl left no partial qcow2 behind"
	fi

	# Perl's asset download order is non-deterministic (unlike Zig, which
	# downloads the ISO first).  If Perl faults the qcow2 before the ISO,
	# the ISO is never downloaded.  Both outcomes are valid; we assert MD5
	# only when the ISO is present.
	if container_exec test -s "$ASSET_DIR_GAT_40_PERL/iso/seed-nocloud.iso"; then
		_ISO_MD5=$(container_exec bash -c \
			"md5sum '${ASSET_DIR_GAT_40_PERL}/iso/seed-nocloud.iso' 2>/dev/null | awk '{print \$1}'" || echo "")
		_SRC_ISO_MD5=$(container_exec bash -c \
			"md5sum '/var/lib/openqa/share/factory/iso/seed-nocloud.iso' 2>/dev/null | awk '{print \$1}'" || echo "")
		if [[ -n "$_ISO_MD5" && "$_ISO_MD5" == "$_SRC_ISO_MD5" ]]; then
			echo "PASS: GAT-40 Perl kept the ISO intact (MD5 OK: ${_ISO_MD5})"
		else
			echo "FAIL: GAT-40 Perl ISO MD5 mismatch — downloaded=${_ISO_MD5} expected=${_SRC_ISO_MD5}"
			failed_tests=$((failed_tests + 1))
		fi
	else
		echo "INFO: GAT-40 Perl did not download the ISO (qcow2 faulted first — non-deterministic order)"
	fi
fi
container_exec rm -rf "$ASSET_DIR_GAT_40_PERL"

# GAT-41: challenge on the hdd asset only — likely o3 cause.
# Test GAT-41: challenge on hdd asset only — Zig rejects, ISO OK
#
# The proxy serves the Anubis challenge page for every attempt of the hdd
# asset only; the ISO downloads cleanly.  This is the most likely shape of
# the o3 failure (ISSUE_HTTP_TRANSFER_TRUNCATED.md §7).  Zig must:
#   - exit 1 with an HTML error naming the qcow2
#   - make exactly 1 attempt on the hdd path (no retry on HTML)
#   - keep no qcow2
#   - keep the ISO intact (MD5)
# Perl (oracle) saves the HTML as the asset and exits 0 (divergence).
start_faultproxy 99 challenge "/tests/${PARTIAL_JOB_ID}/asset/hdd/" 64
ASSET_DIR_GAT_41_ZIG="/tmp/e2e-gat41-zig-$$"
container_exec mkdir -p "$ASSET_DIR_GAT_41_ZIG"
run_capture "gat41" zig \
	"bash -c \"${ZIG_CLONE_EXE} --from http://127.0.0.1:${FAULTPROXY_PORT} \
	 --host http://localhost --skip-deps \
	 ${PARTIAL_JOB_ID} --dir ${ASSET_DIR_GAT_41_ZIG}\""
_GAT41_ZIG_EXIT=$_LAST_EXIT
_GAT41_ZIG_HITS=$(get_faultproxy_hits "/tests/${PARTIAL_JOB_ID}/asset/hdd/")
stop_faultproxy

if [[ "$_GAT41_ZIG_EXIT" -eq 1 ]]; then
	echo "PASS: GAT-41 Zig exits 1 on HTML challenge"
else
	echo "FAIL: GAT-41 Zig exit=$_GAT41_ZIG_EXIT (expected 1)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi
assert_impl_log_pattern "gat41" zig stderr \
	"asset download failed for '.*qcow2'.*HTML" \
	"GAT-41 Zig stderr names the asset and the HTML challenge"
if [[ "$_GAT41_ZIG_HITS" -eq 1 ]]; then
	echo "PASS: GAT-41 Zig made exactly 1 attempt on the challenged asset (no retry)"
else
	echo "FAIL: GAT-41 Zig made $_GAT41_ZIG_HITS attempt(s) (expected 1)"
	failed_tests=$((failed_tests + 1))
fi
if [[ "$DRY_RUN" != "true" ]]; then
	if container_exec find "$ASSET_DIR_GAT_41_ZIG/hdd" -type f 2>/dev/null | grep -q .; then
		echo "FAIL: GAT-41 Zig kept a file for the challenged asset"
		failed_tests=$((failed_tests + 1))
	else
		echo "PASS: GAT-41 Zig kept no file for the challenged asset"
	fi
	# The ISO must have downloaded cleanly before the hdd fault.
	if container_exec test -s "$ASSET_DIR_GAT_41_ZIG/iso/seed-nocloud.iso"; then
		echo "PASS: GAT-41 Zig kept the ISO downloaded before the challenge"
	else
		echo "FAIL: GAT-41 Zig did not keep the ISO (expected before the hdd fault)"
		failed_tests=$((failed_tests + 1))
	fi
fi
container_exec rm -rf "$ASSET_DIR_GAT_41_ZIG"

ASSET_DIR_GAT_41_PERL="/tmp/e2e-gat41-perl-$$"
container_exec mkdir -p "$ASSET_DIR_GAT_41_PERL"
start_faultproxy 99 challenge "/tests/${PARTIAL_JOB_ID}/asset/hdd/" 64
run_capture "gat41" perl \
	"bash -c \"${PERL_CLONE_EXE} --from http://127.0.0.1:${FAULTPROXY_PORT} \
	 --host http://localhost --skip-deps \
	 ${PARTIAL_JOB_ID} --dir ${ASSET_DIR_GAT_41_PERL}\""
_GAT41_PERL_EXIT=$_LAST_EXIT
stop_faultproxy
# Perl saves the challenge HTML as the asset and exits 0 (divergence).
if [[ "$_GAT41_PERL_EXIT" -eq 0 ]]; then
	echo "PASS: GAT-41 Perl exits 0 (HTML saved as asset — documented divergence)"
else
	echo "FAIL: GAT-41 Perl exit=$_GAT41_PERL_EXIT (expected 0)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi
container_exec rm -rf "$ASSET_DIR_GAT_41_PERL"

# GAT-42/43 use a separate job whose only asset is a real HTML file
# (ASSET_1=page.html, type "other").  ensure_html_asset_job is idempotent.
ensure_html_asset_job
_GAT_HTML_PATH="/tests/${GAT_HTML_JOB_ID}/asset/other/"

# GAT-42: R2 exception — a real *.html asset served as text/html is kept.
# Test GAT-42: real page.html asset served as text/html — both download it
#
# No fault: the asset route redirects to /assets/other/page.html, which the
# web server answers with 200 Content-Type: text/html.  R2 rejects text/html
# on asset downloads, except for *.htm/*.html names (Q1), so both
# implementations must save the file (exit 0, MD5 OK).  A precondition check
# makes sure the asset really is served as text/html — without it this test
# would pass trivially and stop covering the exception.
if [[ "$DRY_RUN" != "true" ]]; then
	_gat42_ctype=$(container_exec bash -c \
		"curl -sIL http://localhost${_GAT_HTML_PATH}${GAT_HTML_ASSET} | grep -i '^content-type:' | tail -1" || true)
	if [[ "$_gat42_ctype" == *text/html* ]]; then
		echo "PASS: GAT-42 precondition — ${GAT_HTML_ASSET} is served as text/html"
	else
		echo "FAIL: GAT-42 precondition — ${GAT_HTML_ASSET} served as '${_gat42_ctype}' (expected text/html)"
		failed_tests=$((failed_tests + 1))
	fi
fi

ASSET_DIR_GAT_42_ZIG="/tmp/e2e-gat42-zig-$$"
container_exec mkdir -p "$ASSET_DIR_GAT_42_ZIG"
run_capture "gat42" zig \
	"bash -c \"${ZIG_CLONE_EXE} --from http://localhost \
	 --host http://localhost --skip-deps \
	 ${GAT_HTML_JOB_ID} --dir ${ASSET_DIR_GAT_42_ZIG}\""
_GAT42_ZIG_EXIT=$_LAST_EXIT

if [[ "$_GAT42_ZIG_EXIT" -eq 0 ]]; then
	echo "PASS: GAT-42 Zig exits 0 (HTML asset not rejected)"
else
	echo "FAIL: GAT-42 Zig exit=$_GAT42_ZIG_EXIT (expected 0 — .html exception broken?)"
	failed_tests=$((failed_tests + 1))
fi
if [[ "$DRY_RUN" != "true" ]]; then
	if container_exec test -s "$ASSET_DIR_GAT_42_ZIG/other/${GAT_HTML_ASSET}"; then
		echo "PASS: GAT-42 Zig saved ${GAT_HTML_ASSET}"
	else
		echo "FAIL: GAT-42 Zig did not save ${GAT_HTML_ASSET}"
		failed_tests=$((failed_tests + 1))
	fi
	assert_downloaded_assets_md5 "$ASSET_DIR_GAT_42_ZIG" "GAT-42 Zig"
fi
container_exec rm -rf "$ASSET_DIR_GAT_42_ZIG"

ASSET_DIR_GAT_42_PERL="/tmp/e2e-gat42-perl-$$"
container_exec mkdir -p "$ASSET_DIR_GAT_42_PERL"
run_capture "gat42" perl \
	"bash -c \"${PERL_CLONE_EXE} --from http://localhost \
	 --host http://localhost --skip-deps \
	 ${GAT_HTML_JOB_ID} --dir ${ASSET_DIR_GAT_42_PERL}\""
_GAT42_PERL_EXIT=$_LAST_EXIT

if [[ "$_GAT42_PERL_EXIT" -eq 0 ]]; then
	echo "PASS: GAT-42 Perl exits 0"
else
	echo "FAIL: GAT-42 Perl exit=$_GAT42_PERL_EXIT (expected 0)"
	failed_tests=$((failed_tests + 1))
fi
if [[ "$DRY_RUN" != "true" ]]; then
	if container_exec test -s "$ASSET_DIR_GAT_42_PERL/other/${GAT_HTML_ASSET}"; then
		echo "PASS: GAT-42 Perl saved ${GAT_HTML_ASSET}"
	else
		echo "FAIL: GAT-42 Perl did not save ${GAT_HTML_ASSET}"
		failed_tests=$((failed_tests + 1))
	fi
	assert_downloaded_assets_md5 "$ASSET_DIR_GAT_42_PERL" "GAT-42 Perl"
fi
container_exec rm -rf "$ASSET_DIR_GAT_42_PERL"

# GAT-43: challenge on a *.html asset — KNOWN GAP, pinned.  [KNOWN GAP]
# Test GAT-43: challenge on page.html asset — both save the challenge page
#
# The proxy serves the challenge page for every attempt of the HTML asset.
# Because of the *.htm/*.html exception (Q1), Zig cannot tell the challenge
# from the real page and saves it — exactly like Perl.  This pins TODAY's
# behaviour so the gap stays visible (plan §5a).  It is NOT a [TDD] test:
# when the gap is fixed, flip the Zig assertions to "rejects".
#
# Both: exit 0 and the saved page.html is the challenge page (marker
# "Verifying your browser"), not the real asset.  Zig makes exactly 1 GET
# (a 200 is never retried).  Perl's hit count is not asserted (HEAD + GET).
start_faultproxy 99 challenge "$_GAT_HTML_PATH" 64
ASSET_DIR_GAT_43_ZIG="/tmp/e2e-gat43-zig-$$"
container_exec mkdir -p "$ASSET_DIR_GAT_43_ZIG"
run_capture "gat43" zig \
	"bash -c \"${ZIG_CLONE_EXE} --from http://127.0.0.1:${FAULTPROXY_PORT} \
	 --host http://localhost --skip-deps \
	 ${GAT_HTML_JOB_ID} --dir ${ASSET_DIR_GAT_43_ZIG}\""
_GAT43_ZIG_EXIT=$_LAST_EXIT
_GAT43_ZIG_HITS=$(get_faultproxy_hits "$_GAT_HTML_PATH")
stop_faultproxy

if [[ "$_GAT43_ZIG_EXIT" -eq 0 && "$_GAT43_ZIG_HITS" -eq 1 ]]; then
	echo "PASS: GAT-43 Zig exits 0 with 1 hit (challenge on .html asset not detected) [KNOWN GAP]"
else
	echo "FAIL: GAT-43 Zig exit=$_GAT43_ZIG_EXIT hits=$_GAT43_ZIG_HITS (expected 0 / 1) [KNOWN GAP — gap fixed? flip this test]"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi
if [[ "$DRY_RUN" != "true" ]]; then
	if container_exec grep -q "Verifying your browser" "$ASSET_DIR_GAT_43_ZIG/other/${GAT_HTML_ASSET}" 2>/dev/null; then
		echo "PASS: GAT-43 Zig saved the challenge page as ${GAT_HTML_ASSET} [KNOWN GAP]"
	else
		echo "FAIL: GAT-43 Zig did not save the challenge page as ${GAT_HTML_ASSET} [KNOWN GAP — gap fixed? flip this test]"
		failed_tests=$((failed_tests + 1))
	fi
fi
container_exec rm -rf "$ASSET_DIR_GAT_43_ZIG"

ASSET_DIR_GAT_43_PERL="/tmp/e2e-gat43-perl-$$"
container_exec mkdir -p "$ASSET_DIR_GAT_43_PERL"
start_faultproxy 99 challenge "$_GAT_HTML_PATH" 64
run_capture "gat43" perl \
	"bash -c \"${PERL_CLONE_EXE} --from http://127.0.0.1:${FAULTPROXY_PORT} \
	 --host http://localhost --skip-deps \
	 ${GAT_HTML_JOB_ID} --dir ${ASSET_DIR_GAT_43_PERL}\""
_GAT43_PERL_EXIT=$_LAST_EXIT
stop_faultproxy

if [[ "$_GAT43_PERL_EXIT" -eq 0 ]]; then
	echo "PASS: GAT-43 Perl exits 0 (challenge saved as asset)"
else
	echo "FAIL: GAT-43 Perl exit=$_GAT43_PERL_EXIT (expected 0)"
	dump_faultproxy_logs
	failed_tests=$((failed_tests + 1))
fi
if [[ "$DRY_RUN" != "true" ]]; then
	if container_exec grep -q "Verifying your browser" "$ASSET_DIR_GAT_43_PERL/other/${GAT_HTML_ASSET}" 2>/dev/null; then
		echo "PASS: GAT-43 Perl saved the challenge page as ${GAT_HTML_ASSET}"
	else
		echo "FAIL: GAT-43 Perl did not save the challenge page as ${GAT_HTML_ASSET}"
		failed_tests=$((failed_tests + 1))
	fi
fi
container_exec rm -rf "$ASSET_DIR_GAT_43_PERL"

echo "==> [gatekeeper] Done."
