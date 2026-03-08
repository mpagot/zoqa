#!/usr/bin/env bash
# lib.sh — Shared library for openQA E2E test scripts.
#
# Source this file near the top of each script (after set -eo pipefail):
#
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
#
# Provides:
#   CONTAINER_NAME  — default container name (overridable before sourcing)
#   DRY_RUN         — default false (set before sourcing or via --dryrun parsing)
#   LOG_PREFIX      — prefix used by die(); set this before sourcing, e.g. "setup"
#   run_cmd()       — eval a command string, or print it in dry-run mode
#   container_exec()— run a command inside the container, or print it in dry-run mode
#   die()           — print a prefixed error to stderr and exit 1
#   cd_to_project_root() — cd to the project root; pass "${BASH_SOURCE[0]}" of the caller

# Guard against double-sourcing
[[ -n "${_OPENQA_E2E_LIB_LOADED:-}" ]] && return 0
_OPENQA_E2E_LIB_LOADED=1

# ---------------------------------------------------------------------------
# Defaults (callers may override before sourcing)
# ---------------------------------------------------------------------------
: "${CONTAINER_NAME:=openqa-e2e}"
: "${DRY_RUN:=false}"
: "${LOG_PREFIX:=e2e}"

# ---------------------------------------------------------------------------
# run_cmd() — eval a command string, or print it (dry-run)
#
# Usage: run_cmd "podman rm -f $CONTAINER_NAME"
# ---------------------------------------------------------------------------
run_cmd() {
	if [[ "$DRY_RUN" == "true" ]]; then
		echo "[DRY-RUN] $*"
	else
		eval "$*"
	fi
}

# ---------------------------------------------------------------------------
# container_exec() — run a command inside the container, or print it (dry-run)
#
# Usage: container_exec cat /etc/openqa/client.conf
# ---------------------------------------------------------------------------
container_exec() {
	if [[ "$DRY_RUN" == "true" ]]; then
		echo "[DRY-RUN] podman exec $CONTAINER_NAME $*"
	else
		podman exec "$CONTAINER_NAME" "$@"
	fi
}

# ---------------------------------------------------------------------------
# die() — print a prefixed error message to stderr and exit 1
#
# Uses $LOG_PREFIX (default: "e2e").
# Usage: die "Could not read client.conf"
# ---------------------------------------------------------------------------
die() {
	echo "[$LOG_PREFIX] ERROR: $*" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# cd_to_project_root() — cd to the repository root from a caller's location
#
# Must be called with the caller's BASH_SOURCE[0]:
#   cd_to_project_root "${BASH_SOURCE[0]}"
#
# Assumes scripts live two levels deep under the project root
# (e.g. tests/e2e/setup.sh → project root is ../../).
# ---------------------------------------------------------------------------
cd_to_project_root() {
	local caller_script="$1"
	local caller_dir
	caller_dir="$(cd "$(dirname "$caller_script")" && pwd)"
	cd "$caller_dir/../.." || exit 1
}
