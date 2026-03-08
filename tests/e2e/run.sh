#!/usr/bin/env bash
# run.sh — Near End-to-End tests for openQAclient.
#
# Starts the openQA container (via setup.sh), runs comparison tests between
# openqa-cli (Perl reference) and openQAclient (Zig), then tears down.
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
# shellcheck source=tests/e2e/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
cd_to_project_root "${BASH_SOURCE[0]}"

# -----------------------------------------------------------------------------
# Help Message
# -----------------------------------------------------------------------------
show_help() {
	cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Near End-to-End testing for the openQAclient Zig binary against a live openQA
single-instance container.

WHAT IT DOES:
  1. Starts an official openQA single-instance container.
  2. Seeds it with test fixtures (machines, products, jobs, assets).
  3. Runs comparison tests between openqa-cli (Perl) and openQAclient (Zig).
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
if [[ ! -f "zig-out/bin/openQAclient" && "$DRY_RUN" == "false" ]]; then
	echo "Error: zig-out/bin/openQAclient not found. Please run 'zig build' first." >&2
	exit 1
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
ZIG_EXE="/app/zig-out/bin/openQAclient"
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
		"bash -c \"$env_vars $ZIG_EXE --host http://localhost api $api_args\"" \
		"$expected_exit" "$grep_pattern"
}

# Diff test: same output expected, failure is a soft WARN (not a hard FAIL).
run_diff_test() {
	local label=$1
	local api_args=$2

	echo "--- Test: DIFF $label ---"

	set +e
	container_exec bash -c "$PERL_EXE api --host http://localhost $api_args" \
		>test_output_perl.log 2>/dev/null
	container_exec bash -c "$ZIG_EXE  --host http://localhost api $api_args" \
		>test_output_zig.log 2>/dev/null
	set -e

	if diff -u test_output_perl.log test_output_zig.log >test_output_diff.log 2>&1; then
		echo "PASS (outputs identical)"
	else
		echo "WARN: Perl and Zig outputs differ (soft failure — not counted as FAIL):"
		cat test_output_diff.log
		warned_tests=$((warned_tests + 1))
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
run_test "PERL: Missing PATH" "$PERL_EXE api --host http://localhost" 255
run_test "ZIG : Missing PATH" "$ZIG_EXE --host http://localhost api" 1 "MissingPath"

# Test 11: Invalid host (connection refused)
run_test "PERL: Invalid Host" "$PERL_EXE api --host http://localhost:12345 jobs/overview" 1
run_test "ZIG : Invalid Host" "$ZIG_EXE --host http://localhost:12345 api jobs/overview" 1 "Connection error"

# Test 12: --pretty on a real response produces valid JSON output
run_test "ZIG : --pretty" "$ZIG_EXE --host http://localhost api --pretty jobs/overview" 0

# =============================================================================
# Tests 13–20: New coverage using seeded data
# =============================================================================

# Test 13: GET jobs/overview returns non-empty list after seeding
run_comparison "GET jobs/overview (non-empty after seeding)" "" "jobs/overview" 0 "simple_boot"

# Test 14: GET jobs/:id returns a real nested job object
run_comparison "GET jobs/$JOB_ID (nested object)" "" \
	"jobs/$JOB_ID" 0 '"settings"'

# Test 15: GET machines?limit=2 with --links triggers the Link pagination header
# We seeded 3 machines; requesting limit=2 should yield a Link: rel="next" header.
# parseLinkHeader formats output as "next: <url>" per link.
run_test "ZIG : --links pagination header" \
	"$ZIG_EXE --host http://localhost api --links 'machines?limit=2'" \
	0 'next:'

# Test 16: --verbose on a real endpoint shows HTTP response headers
run_test "ZIG : --verbose shows HTTP headers" \
	"$ZIG_EXE --host http://localhost api --verbose jobs/overview" \
	0 "HTTP/"

# Test 17: --pretty on a non-empty response produces indented JSON
run_test "ZIG : --pretty (non-empty)" \
	"$ZIG_EXE --host http://localhost api --pretty jobs/overview" \
	0 "simple_boot"

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
		"$ZIG_EXE --host http://localhost api -X DELETE assets/$ZIG_ASSET_ID" 0
fi

# Test 19: GET job_groups returns the seeded group
run_comparison "GET job_groups (seeded group present)" "" "job_groups" 0 '"example"'

# Test 20: Perl vs Zig output diff on a real nested object (soft WARN on mismatch)
run_diff_test "GET jobs/$JOB_ID output parity" "jobs/$JOB_ID"

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
