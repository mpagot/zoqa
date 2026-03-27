#!/usr/bin/env bash
# run_container.sh — Container lifecycle manager for the Windows E2E flow.
#
# Starts the openQA container (via setup.sh), writes a PowerShell-compatible
# env file so that run_windows.ps1 can source the seeded credentials and IDs,
# then waits until run_windows.ps1 signals completion (by creating the sentinel
# file /tmp/openqa_e2e_done) before tearing down.
#
# This script is the WSL/Linux counterpart to run_windows.ps1.  It is NOT a
# replacement for run.sh — the Linux/macOS full suite still uses run.sh.
#
# Usage (from WSL, invoked by run_windows.ps1):
#   bash tests/e2e/run_container.sh [OPTIONS]
#
# OPTIONS:
#   -h, --help          Show this help message and exit.
#   --dryrun            Print commands without executing them.
#   --collect-logs      Collect server-side openQA logs into ./openqa-e2e-logs/
#                       before stopping.
#   --env-file <path>   WSL path where the PowerShell env file is written.
#                       Defaults to /tmp/openqa_e2e_env.ps1.
#                       run_windows.ps1 passes the WSL equivalent of $env:TEMP
#                       so the file lands on a real NTFS path and can be
#                       dot-sourced without execution policy issues.
#
# Lifecycle:
#   1. Runs setup.sh (--expose-ports always set so Windows can reach port 8080).
#   2. Writes the PowerShell env file (PowerShell $env:VAR = "..." syntax).
#   3. Polls /tmp/openqa_e2e_done (created by run_windows.ps1 when tests finish).
#   4. Runs teardown.sh.
#
# The sentinel file /tmp/openqa_e2e_done is removed by teardown.sh's standard
# cleanup via the rm -f /tmp/openqa_e2e_env.sh block; run_container.sh removes
# the done sentinel itself after detecting it.

set -eo pipefail

# -----------------------------------------------------------------------------
# Source shared library
# -----------------------------------------------------------------------------
LOG_PREFIX="run_container"
# shellcheck source=SCRIPTDIR/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
cd_to_project_root "${BASH_SOURCE[0]}"

# -----------------------------------------------------------------------------
# Help Message
# -----------------------------------------------------------------------------
show_help() {
	cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Container lifecycle manager for the Windows E2E flow.

Starts the openQA container, seeds fixtures, writes a PowerShell env file,
waits for run_windows.ps1 to finish, then tears down.

OPTIONS:
  -h, --help          Show this help message and exit.
  --dryrun            Print commands without executing them.
  --collect-logs      Dump openQA server logs to ./openqa-e2e-logs/ on teardown.
  --env-file <path>   WSL path for the PowerShell env file (default: /tmp/openqa_e2e_env.ps1).

TYPICAL INVOCATION:
  This script is normally called by run_windows.ps1, not directly.
  To invoke manually from WSL for debugging:

    bash tests/e2e/run_container.sh
    # (blocks until /tmp/openqa_e2e_done appears)

SENTINEL FILE:
  /tmp/openqa_e2e_done  — Create this file from Windows to signal completion.
  Example (PowerShell):
    wsl -- touch /tmp/openqa_e2e_done
EOF
}

# -----------------------------------------------------------------------------
# Argument Parsing
# -----------------------------------------------------------------------------
DRY_RUN=false
COLLECT_LOGS=false
PS_ENV_FILE="/tmp/openqa_e2e_env.ps1"

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
	--collect-logs)
		COLLECT_LOGS=true
		shift
		;;
	--env-file)
		PS_ENV_FILE="$2"
		shift 2
		;;
	*)
		echo "Unknown parameter: $1" >&2
		exit 1
		;;
	esac
done

TEARDOWN_ARGS=(--expose-ports)
[[ "$DRY_RUN" == "true" ]] && TEARDOWN_ARGS+=(--dryrun)
[[ "$COLLECT_LOGS" == "true" ]] && TEARDOWN_ARGS+=(--collect-logs)

# -----------------------------------------------------------------------------
# Preflight Check
# -----------------------------------------------------------------------------
# The zoqa binary is built for Windows and run natively on the Windows side;
# the container only needs the Zig binary if you want to run in-container tests.
# We do NOT require zig-out/bin/zoqa here.

if [[ "$DRY_RUN" == "false" ]]; then
	if ! podman info >/dev/null 2>&1; then
		echo "Error: 'podman info' failed — is the Podman daemon running?" >&2
		exit 1
	fi
	if ! podman run --rm busybox true >/dev/null 2>&1; then
		echo "Error: podman run smoke-test failed — check Podman installation." >&2
		exit 1
	fi
fi

# -----------------------------------------------------------------------------
# Container Setup
# -----------------------------------------------------------------------------
# Always expose ports so the Windows host can reach the openQA API on port 8080.
bash tests/e2e/setup.sh --expose-ports \
	$([[ "$DRY_RUN" == "true" ]] && echo "--dryrun") 2>&1

# Register cleanup trap
cleanup() {
	local teardown_collect_flag=""
	[[ "$COLLECT_LOGS" == "true" ]] && teardown_collect_flag="--collect-logs"
	local teardown_dryrun_flag=""
	[[ "$DRY_RUN" == "true" ]] && teardown_dryrun_flag="--dryrun"
	# shellcheck disable=SC2086
	bash tests/e2e/teardown.sh $teardown_collect_flag $teardown_dryrun_flag
	# Clean up the done sentinel so a subsequent run starts clean
	rm -f /tmp/openqa_e2e_done
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
# Write PowerShell-compatible env file
# -----------------------------------------------------------------------------
# PS_ENV_FILE is either the default /tmp/openqa_e2e_env.ps1 or the path passed
# via --env-file by run_windows.ps1 (the WSL equivalent of $env:TEMP so the
# file lands on a real NTFS path and can be dot-sourced without execution
# policy issues).
if [[ "$DRY_RUN" == "true" ]]; then
	echo "[DRY-RUN] Writing $PS_ENV_FILE (PowerShell env syntax)"
else
	cat >"$PS_ENV_FILE" <<EOF
# Auto-generated by tests/e2e/run_container.sh — do not edit manually.
\$env:OPENQA_API_KEY    = "$OPENQA_API_KEY"
\$env:OPENQA_API_SECRET = "$OPENQA_API_SECRET"
\$env:JOB_ID            = "$JOB_ID"
\$env:ASSET_ID          = "$ASSET_ID"
\$env:ZIG_ASSET_ID      = "${ZIG_ASSET_ID:-}"
\$env:GROUP_ID          = "$GROUP_ID"
EOF
	echo "==> PowerShell env file written to $PS_ENV_FILE"
fi

# Print the WSL IP so run_windows.ps1 can contact the container
if [[ "$DRY_RUN" == "false" ]]; then
	WSL_IP=$(hostname -I | awk '{print $1}')
	echo "==> Container exposed on WSL IP: $WSL_IP"
	echo "    openQA API reachable at: http://$WSL_IP:8080"
	# Append the WSL IP to the PS env file so run_windows.ps1 can read it
	echo "\$env:OPENQA_E2E_HOST  = \"http://$WSL_IP:8080\"" >>"$PS_ENV_FILE"
else
	echo "[DRY-RUN] Skipping WSL IP detection"
fi

# -----------------------------------------------------------------------------
# Wait for completion sentinel
# -----------------------------------------------------------------------------
SENTINEL="/tmp/openqa_e2e_done"
echo ""
echo "==> Container is ready.  Waiting for run_windows.ps1 to finish..."
echo "    (Create $SENTINEL from Windows to signal completion)"
echo "    PowerShell:  wsl -- touch $SENTINEL"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
	echo "[DRY-RUN] Sentinel wait skipped."
else
	# Poll every 5 seconds; timeout after 30 minutes (360 iterations)
	for i in $(seq 1 360); do
		if [[ -f "$SENTINEL" ]]; then
			echo "==> Sentinel detected after $((i * 5))s. Proceeding to teardown."
			break
		fi
		if [[ "$i" -eq 360 ]]; then
			echo "Error: Timed out after 30 minutes waiting for sentinel $SENTINEL" >&2
			exit 1
		fi
		sleep 5
	done
fi
