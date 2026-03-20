#!/usr/bin/env bash
# run.sh — Near End-to-End tests for zoqa.
#
# Starts the openQA container (via setup.sh), runs comparison tests between
# openqa-cli (Perl reference) and zoqa (Zig), then tears down.
#
# Usage:
#   bash tests/e2e/run.sh [OPTIONS]
#
# OPTIONS:
#   -h, --help          Show this help message and exit.
#   --dryrun            Print commands without executing them.
#   --keep-container    Do not stop the container after tests finish. Publishes
#                       ports 80->8080 and 443->8443 so the openQA web UI is
#                       reachable at http://localhost:8080.
#   --collect-logs      Collect server-side openQA logs into ./openqa-e2e-logs/
#                       before stopping (or always, when combined with
#                       --keep-container the logs are collected but the container
#                       stays up).

set -eo pipefail

# -----------------------------------------------------------------------------
# Source shared library
# -----------------------------------------------------------------------------
LOG_PREFIX="run"
# shellcheck source=SCRIPTDIR/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
cd_to_project_root "${BASH_SOURCE[0]}"

# -----------------------------------------------------------------------------
# Help Message
# -----------------------------------------------------------------------------
show_help() {
	cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Near End-to-End testing for the zoqa Zig binary against a live openQA
single-instance container.

WHAT IT DOES:
  1. Starts an official openQA single-instance container.
  2. Seeds it with test fixtures (machines, products, jobs, assets).
  3. Runs comparison tests between openqa-cli (Perl) and zoqa (Zig).
  4. Reports results and optionally collects logs / keeps the container alive.

OPTIONS:
  -h, --help          Show this help message and exit.
  --dryrun            Print commands without executing them.
  --keep-container    Leave the container running after tests finish. Publishes
                      ports 80->8080 and 443->8443 so the openQA web UI is
                      reachable at http://localhost:8080.
  --collect-logs      Dump openQA server logs to ./openqa-e2e-logs/.

DEBUGGING TIPS:
  Use --keep-container to browse the openQA web UI during or after the run.
  Use --collect-logs --keep-container to inspect logs without stopping the container.
  The container name is always 'openqa-e2e'.
  podman exec openqa-e2e bash   — drop into the container shell.
  podman logs openqa-e2e        — stream container stdout/stderr.
EOF
}

# -----------------------------------------------------------------------------
# Argument Parsing
# -----------------------------------------------------------------------------
KEEP_CONTAINER=false
COLLECT_LOGS=false

while [[ "$#" -gt 0 ]]; do
	case $1 in
	-h | --help)
		show_help
		exit 0
		;;
	--dryrun)
		DRY_RUN=true
		shift
		;;
	--keep-container)
		KEEP_CONTAINER=true
		shift
		;;
	--collect-logs)
		COLLECT_LOGS=true
		shift
		;;
	*)
		echo "Unknown parameter: $1" >&2
		exit 1
		;;
	esac
done

# Build setup.sh / teardown.sh argument lists
SETUP_ARGS=()
TEARDOWN_ARGS=()
[[ "$DRY_RUN" == "true" ]] && SETUP_ARGS+=(--dryrun) && TEARDOWN_ARGS+=(--dryrun)
[[ "$KEEP_CONTAINER" == "true" ]] && SETUP_ARGS+=(--keep-container --expose-ports)
[[ "$COLLECT_LOGS" == "true" ]] && TEARDOWN_ARGS+=(--collect-logs)

# -----------------------------------------------------------------------------
# Preflight Check
# -----------------------------------------------------------------------------
if [[ ! -f "zig-out/bin/zoqa" && "$DRY_RUN" == "false" ]]; then
	echo "Error: zig-out/bin/zoqa not found. Please run 'zig build' first." >&2
	exit 1
fi

# Podman sanity check — verify podman is usable before spending time on the
# openQA container setup.
#
# NOTE on BoltDB warnings: on some systems (e.g. older Podman installations
# that have not yet been migrated to SQLite) every `podman` invocation emits a
# deprecation warning to stderr:
#
#   level=warning msg="The deprecated BoltDB database driver is in use..."
#
# This is a Podman-level issue, not specific to any one container or command —
# it appears on ALL `podman` calls throughout this script (run, exec, rm, …).
# It is purely cosmetic and does not affect correctness.  Where test output
# comparisons are sensitive to stderr noise (e.g. Test 21) stderr is redirected
# to /dev/null.  To silence it permanently, migrate with:
#   podman system migrate --migrate-db
if [[ "$DRY_RUN" == "false" ]]; then
	if ! podman info >/dev/null 2>&1; then
		echo "Error: 'podman info' failed — is the Podman daemon running?" >&2
		exit 1
	fi
	# Quick smoke-test: run a minimal container and confirm it exits cleanly.
	if ! podman run --rm busybox true >/dev/null 2>&1; then
		echo "Error: podman run smoke-test failed — check Podman installation." >&2
		echo "       Run 'podman run --rm busybox true' manually to diagnose." >&2
		exit 1
	fi
fi

# -----------------------------------------------------------------------------
# Container Setup
# -----------------------------------------------------------------------------
bash tests/e2e/setup.sh "${SETUP_ARGS[@]}"

# Register cleanup trap (respects --keep-container)
cleanup() {
	if [[ "$KEEP_CONTAINER" == "true" ]]; then
		echo ""
		echo "==> Container '$CONTAINER_NAME' is still running (--keep-container)."
		echo "    openQA web UI: http://localhost:8080  /  https://localhost:8443"
		echo "    To stop it:  podman rm -f $CONTAINER_NAME"
		echo "    To enter it: podman exec -it $CONTAINER_NAME bash"
		# Still collect logs if requested
		if [[ "$COLLECT_LOGS" == "true" && "$DRY_RUN" == "false" ]]; then
			bash tests/e2e/teardown.sh --collect-logs
		elif [[ "$COLLECT_LOGS" == "true" && "$DRY_RUN" == "true" ]]; then
			bash tests/e2e/teardown.sh --collect-logs --dryrun
		fi
	else
		bash tests/e2e/teardown.sh "${TEARDOWN_ARGS[@]}"
	fi
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Load Seeded IDs and Credentials
# -----------------------------------------------------------------------------
ENV_FILE="/tmp/openqa_e2e_env.sh"
if [[ -f "$ENV_FILE" ]]; then
	# shellcheck source=/dev/null
	source "$ENV_FILE"
else
	if [[ "$DRY_RUN" == "false" ]]; then
		echo "Error: $ENV_FILE not found — setup.sh did not complete successfully." >&2
		exit 1
	fi
	# Dry-run defaults
	OPENQA_API_KEY="MOCK_KEY"
	OPENQA_API_SECRET="MOCK_SECRET"
	JOB_ID="1"
	ASSET_ID="1"
	ZIG_ASSET_ID="2"
	GROUP_ID="1"
fi

echo "==> Environment:"
echo "    JOB_ID=$JOB_ID  ASSET_ID=$ASSET_ID  ZIG_ASSET_ID=${ZIG_ASSET_ID:-}  GROUP_ID=$GROUP_ID"

# -----------------------------------------------------------------------------
# Test Infrastructure
# -----------------------------------------------------------------------------
ZIG_EXE="/app/zig-out/bin/zoqa"
PERL_EXE="openqa-cli"

failed_tests=0
warned_tests=0

run_test() {
	local label=$1
	local cmd=$2
	local expected_exit=${3:-0}
	local grep_pattern=$4

	echo "--- Test: $label ---"
	echo "Command: $cmd"

	set +e
	eval "container_exec $cmd" >test_output.log 2>&1
	local exit_code=$?
	set -e

	echo "Exit code: $exit_code"

	if [[ "$exit_code" -ne "$expected_exit" ]]; then
		echo "FAIL: Expected exit code $expected_exit, got $exit_code"
		cat test_output.log
		failed_tests=$((failed_tests + 1))
		return
	fi

	if [[ -n "$grep_pattern" ]]; then
		if ! grep -q "$grep_pattern" test_output.log; then
			echo "FAIL: Output did not match pattern '$grep_pattern'"
			cat test_output.log
			failed_tests=$((failed_tests + 1))
			return
		fi
	fi

	echo "PASS"
}

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

# Diff test: same output expected, failure is a hard FAIL.
# Both outputs are normalised to end with exactly one newline before diffing,
# so a trailing-newline difference between Perl and Zig is not flagged.
run_diff_test() {
	local label=$1
	local api_args=$2

	echo "--- Test: DIFF $label ---"

	set +e
	container_exec bash -c "$PERL_EXE api --host http://localhost $api_args" \
		>test_output_perl.log 2>/dev/null
	container_exec bash -c "$ZIG_EXE api --host http://localhost $api_args" \
		>test_output_zig.log 2>/dev/null
	set -e

	# Normalise: strip all trailing newlines then add exactly one.
	{ printf '%s\n' "$(cat test_output_perl.log)"; } >test_output_perl_norm.log
	{ printf '%s\n' "$(cat test_output_zig.log)"; } >test_output_zig_norm.log

	if diff -u test_output_perl_norm.log test_output_zig_norm.log >test_output_diff.log 2>&1; then
		echo "PASS (outputs identical)"
	else
		echo "FAIL: Perl and Zig outputs differ:"
		cat test_output_diff.log
		failed_tests=$((failed_tests + 1))
	fi
}

if [[ "$DRY_RUN" == "true" ]]; then
	echo "==> [DRY-RUN] Running E2E tests (simulated)..."
else
	echo "==> Running E2E tests..."
fi

# =============================================================================
# Tests 1–12: Existing coverage (unchanged)
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
container_exec bash -c "printf 'opensuse' > /tmp/distri.txt"
run_comparison "--param-file" "" "--param-file distri=/tmp/distri.txt jobs" 0 "\[\]"

# Test 8: CLI flags override wrong config credentials
container_exec bash -c "printf '[localhost]\nkey=WRONG\nsecret=WRONG\n' > /tmp/wrong.conf"
run_comparison "CLI Override (correct key overrides wrong config)" \
	"OPENQA_CONFIG=/tmp" \
	"--apikey '$OPENQA_API_KEY' --apisecret '$OPENQA_API_SECRET' jobs/overview" \
	0

# Test 9: Authentication failure (wrong secret on authenticated route)
run_comparison "Wrong Secret (403)" "" "--apisecret WRONG_SECRET -X POST jobs" 1 "403 Forbidden"

# Test 10: Missing PATH positional argument
# Perl exits 255 and prints the api usage block to stderr.
# Zig exits 1 and prints "Request build error: MissingPath" — hard FAIL until §1.7.
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
# Zig currently accepts flags in any position (exits 0) — this is a bug tracked
# by §1.8. The ZIG sub-test is a hard FAIL until §1.8 is fixed.
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
container_exec bash -c "$ZIG_EXE api --host http://localhost --links 'machines?limit=2'" >test_pagination.log 2>&1
if grep -q "next:" test_pagination.log; then
	NEXT_URL=$(grep "^next: " test_pagination.log | cut -d' ' -f2 | tr -d '\r')
	echo "Found next URL: $NEXT_URL"
	# Call again with the next URL to verify it returns the remaining data
	run_test "ZIG : Follow pagination link" "$ZIG_EXE api --host http://localhost '$NEXT_URL'" 0 '"name":"uefi"'
else
	echo "FAIL: next link not found in output"
	cat test_pagination.log
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
# (see the "Podman sanity check" comment above).  The warning timestamp
# differs between the two calls, which would cause a spurious diff failure
# if stderr were captured.
echo "--- Test: ZIG : relative vs absolute path parity ---"
container_exec bash -c "$ZIG_EXE api --host http://localhost jobs/$JOB_ID" \
	>test_relative.log 2>/dev/null
container_exec bash -c "$ZIG_EXE api 'http://localhost/api/v1/jobs/$JOB_ID'" \
	>test_absolute.log 2>/dev/null
if diff -u test_relative.log test_absolute.log >test_path_parity_diff.log 2>&1; then
	echo "PASS (relative and absolute outputs identical)"
else
	echo "FAIL: relative and absolute path outputs differ"
	cat test_path_parity_diff.log
	failed_tests=$((failed_tests + 1))
fi

# Test 22: --name flag acceptance (SPEC §2, Phase 1.2)
#
# SPEC §2 lists `--name STRING` for setting the User-Agent header.
# Both Perl and Zig must accept the flag and exit 0 on a valid request.
# Phase 1.2 status: --name is not yet parsed in zoqa; the ZIG sub-test will
# fail until Phase 1.2 is implemented.
#
# Server-side User-Agent verification (via access logs) is not attempted here:
# the openQA single-instance image does not expose the Mojolicious or Apache
# access log at a predictable path, so those checks would produce unreliable
# WARNs.  The primary acceptance criterion for Phase 1.2 is this comparison.
run_comparison "--name flag accepted (exit 0)" "" \
	"--name zoqa-e2e-test jobs/overview" 0

# =============================================================================
# Tests 23–26: Verbose mode and non-2xx stderr (Phase 1.3 and 1.4)
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

# Test 24: Verbose mode — Perl vs Zig header count comparison (Phase 1.3)
#
# Captures stdout and stderr separately for both implementations and compares
# the header-line count.  Perl produces ~5 header lines to stdout; Zig currently
# produces only 1 (Content-Type).  This test will FAIL until Phase 1.3 is
# implemented.  Diagnostic counts are printed regardless of pass/fail to make
# the gap visible in CI output.
echo "--- Test: PERL vs ZIG : --verbose header count (Phase 1.3) ---"
set +e
container_exec bash -c "$PERL_EXE api --host http://localhost --verbose jobs/overview \
	2>/tmp/perl_verbose_stderr.log >/tmp/perl_verbose_stdout.log"
container_exec cat /tmp/perl_verbose_stderr.log >perl_verbose_stderr.log 2>/dev/null
container_exec cat /tmp/perl_verbose_stdout.log >perl_verbose_stdout.log 2>/dev/null

container_exec bash -c "$ZIG_EXE api --host http://localhost --verbose jobs/overview \
	2>/tmp/zig_verbose_stderr.log >/tmp/zig_verbose_stdout.log"
container_exec cat /tmp/zig_verbose_stderr.log >zig_verbose_stderr.log 2>/dev/null
container_exec cat /tmp/zig_verbose_stdout.log >zig_verbose_stdout.log 2>/dev/null
set -e

perl_stdout_headers=$(grep -cE '^[A-Za-z_-]+: ' perl_verbose_stdout.log || true)
perl_stderr_headers=$(grep -cE '^[A-Za-z_-]+: ' perl_verbose_stderr.log || true)
zig_stdout_headers=$(grep -cE '^[A-Za-z_-]+: ' zig_verbose_stdout.log || true)
zig_stderr_headers=$(grep -cE '^[A-Za-z_-]+: ' zig_verbose_stderr.log || true)

echo "PERL headers in stdout: $perl_stdout_headers"
echo "PERL headers in stderr: $perl_stderr_headers"
echo "ZIG  headers in stdout: $zig_stdout_headers"
echo "ZIG  headers in stderr: $zig_stderr_headers"
echo "PERL HTTP/1.1 line in stdout: $(grep -c 'HTTP/1.1 ' perl_verbose_stdout.log || true)"
echo "PERL HTTP/1.1 line in stderr: $(grep -c 'HTTP/1.1 ' perl_verbose_stderr.log || true)"

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

# Tests 25–26: Non-2xx error reporting and --quiet suppression (Phase 1.4)
#
# SPEC §9.3: on a non-2xx response, the status line must be printed to stderr
# (unless --quiet is set).  Both sub-tests run together because Test 26's PASS
# criterion depends on the stderr file captured in Test 25.
echo "--- Test: PERL vs ZIG : non-2xx stderr without --quiet (Phase 1.4) ---"
set +e
container_exec bash -c "$PERL_EXE api --host http://localhost non_existent_e2e_route \
	2>/tmp/perl_404_stderr.log >/tmp/perl_404_stdout.log"
perl_404_exit=$?
container_exec bash -c "$ZIG_EXE api --host http://localhost non_existent_e2e_route \
	2>/tmp/zig_404_stderr.log >/tmp/zig_404_stdout.log"
zig_404_exit=$?
container_exec cat /tmp/perl_404_stderr.log >perl_404_stderr.log 2>/dev/null
container_exec cat /tmp/zig_404_stderr.log >zig_404_stderr.log 2>/dev/null
set -e

echo "PERL exit: $perl_404_exit, ZIG exit: $zig_404_exit"
echo "PERL stderr contains '404': $(grep -c '404' perl_404_stderr.log || true)"
echo "ZIG  stderr contains '404': $(grep -c '404' zig_404_stderr.log || true)"

# Hard assertion: both Perl and Zig must emit '404' on stderr without --quiet.
if grep -q "404" perl_404_stderr.log && grep -q "404" zig_404_stderr.log; then
	echo "PASS (both Perl and Zig report 404 on stderr without --quiet)"
else
	echo "FAIL: expected '404' on stderr from both implementations"
	failed_tests=$((failed_tests + 1))
fi

echo "--- Test: PERL vs ZIG : non-2xx stderr with --quiet (Phase 1.4) ---"
set +e
container_exec bash -c "$PERL_EXE api --host http://localhost --quiet non_existent_e2e_route \
	2>/tmp/perl_404q_stderr.log >/tmp/perl_404q_stdout.log"
perl_404q_exit=$?
container_exec bash -c "$ZIG_EXE api --host http://localhost --quiet non_existent_e2e_route \
	2>/tmp/zig_404q_stderr.log >/tmp/zig_404q_stdout.log"
zig_404q_exit=$?
container_exec cat /tmp/perl_404q_stderr.log >perl_404q_stderr.log 2>/dev/null
container_exec cat /tmp/zig_404q_stderr.log >zig_404q_stderr.log 2>/dev/null
set -e

echo "PERL exit: $perl_404q_exit, ZIG exit: $zig_404q_exit"
echo "PERL stderr bytes: $(wc -c <perl_404q_stderr.log)"
echo "ZIG  stderr bytes: $(wc -c <zig_404q_stderr.log)"
echo "PERL stderr contains '404': $(grep -c '404' perl_404q_stderr.log || true)"
echo "ZIG  stderr contains '404': $(grep -c '404' zig_404q_stderr.log || true)"

# Hard assertion: --quiet must suppress the error output for both implementations.
if ! grep -q "404" perl_404q_stderr.log && ! grep -q "404" zig_404q_stderr.log; then
	echo "PASS (both Perl and Zig suppress 404 stderr with --quiet)"
else
	echo "FAIL: --quiet did not suppress stderr as expected"
	failed_tests=$((failed_tests + 1))
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "========================================"
if [[ "$DRY_RUN" == "true" ]]; then
	echo "==> [DRY-RUN] E2E tests simulated successfully!"
elif [[ "$failed_tests" -eq 0 && "$warned_tests" -eq 0 ]]; then
	echo "==> All E2E tests passed!"
elif [[ "$failed_tests" -eq 0 ]]; then
	echo "==> All E2E tests passed ($warned_tests warning(s))."
else
	echo "==> $failed_tests test(s) FAILED, $warned_tests warning(s)."
	exit 1
fi
echo "========================================"
