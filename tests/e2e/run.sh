#!/usr/bin/env bash
# run.sh — Near End-to-End tests for zoqa.
#
# Starts the openQA container (via setup.sh), runs comparison tests between
# openqa-cli (Perl reference) and zoqa (Zig), then tears down.
#
# Usage:
#   bash tests/e2e/run.sh [OPTIONS]
#
# Run with --help for the full option reference.

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
  --suites NAMES      Comma-separated list of suite names to run (no .sh
                      extension). Valid names: core, auth, data, output,
                      robustness, retry_knobs, archive, monitor, schedule,
                      help, stress, perf. Omit or use 'all' to run all suites.
                      Pass an empty string to skip all tests (e.g. --suites "").

ENVIRONMENT VARIABLES:
  E2E_STORAGE_KEEP_FREE_RATIO   isotovideo disk-space check threshold.
                      Unset (default) = isotovideo built-in 20% keep-free.
                      Set to 0 to disable the check entirely, useful on CI
                      hosts with low free disk space:
                        make e2e E2E_STORAGE_KEEP_FREE_RATIO=0

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
# (COLLECT_LOGS defaults to false via lib.sh; --collect-logs sets it to true)
E2E_SUITES="all"

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
	--suites)
		E2E_SUITES=$2
		shift 2
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

# Print MD5 and last-modified date of the zoqa binary if the required tools
# are available.  Both checks are optional — missing tools are silently skipped.
if [[ -f "zig-out/bin/zoqa" ]]; then
	_zoqa_bin="zig-out/bin/zoqa"
	echo "    zoqa path  : $(realpath "$_zoqa_bin")"
	if command -v md5sum >/dev/null 2>&1; then
		echo "    zoqa md5   : $(md5sum "$_zoqa_bin" | awk '{print $1}')"
	elif command -v md5 >/dev/null 2>&1; then
		echo "    zoqa md5   : $(md5 -q "$_zoqa_bin")"
	fi
	if command -v stat >/dev/null 2>&1; then
		# GNU stat (Linux) and BSD stat (macOS) use different -f/-c flags.
		if stat --version >/dev/null 2>&1; then
			echo "    zoqa mtime : $(stat -c '%y' "$_zoqa_bin")"
		else
			echo "    zoqa mtime : $(stat -f '%Sm' "$_zoqa_bin")"
		fi
	fi
	if command -v readelf >/dev/null 2>&1; then
		if readelf -S "$_zoqa_bin" 2>/dev/null | grep -q "debug_aranges"; then
			echo "    zoqa build : Debug"
		else
			echo "    zoqa build : Release"
		fi
	fi
	if command -v stat >/dev/null 2>&1; then
		if stat --version >/dev/null 2>&1; then
			echo "    zoqa size  : $(stat -c '%s' "$_zoqa_bin") bytes"
		else
			echo "    zoqa size  : $(stat -f '%z' "$_zoqa_bin") bytes"
		fi
	fi
	unset _zoqa_bin
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
# ENV_FILE is set to /tmp/openqa_e2e_env.sh by lib.sh
if [[ -f "$ENV_FILE" ]]; then
	# shellcheck source=/dev/null
	source "$ENV_FILE"
else
	if [[ "$DRY_RUN" == "false" ]]; then
		echo "Error: $ENV_FILE not found — setup.sh did not complete successfully." >&2
		exit 1
	fi
	# Dry-run defaults
	export OPENQA_API_KEY="MOCK_KEY"
	export OPENQA_API_SECRET="MOCK_SECRET"
	export GROUP_ID="1"
fi

echo "==> Environment:"
echo "    GROUP_ID=$GROUP_ID"
[[ -n "$E2E_SUITES" ]] && echo "==> Suites filter: $E2E_SUITES"

# -----------------------------------------------------------------------------
# Test Infrastructure
# -----------------------------------------------------------------------------
ZIG_EXE="/app/zig-out/bin/zoqa"
PERL_EXE="openqa-cli"

failed_tests=0
warned_tests=0

# Create a timestamped directory in /tmp for all log files produced during
# this run.  Printed here so it's easy to find after the run finishes.
LOG_DIR="/tmp/zoqa_e2e_$(date +%Y%m%dT%H%M%S)"
mkdir -p "$LOG_DIR"
echo "==> Log directory: $LOG_DIR"

if [[ "$DRY_RUN" == "true" ]]; then
	echo "==> [DRY-RUN] Running E2E tests (simulated)..."
else
	echo "==> Running E2E tests..."
fi

# shellcheck source=SCRIPTDIR/tests.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tests.sh"

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
