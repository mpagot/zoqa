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
#
# Job management (host-side only — use container_exec internally):
#   schedule_job()  — POST /api/v1/isos, prints job ID
#   wait_for_job()  — poll until terminal state, prints state
#   cancel_job()    — POST cancel for a job
#   get_job_state() — query and print a job's state
#   ensure_basic_job()  — lazy-init JOB_ID (create once, reuse after)
#   ensure_rich_job()   — lazy-init RICH_JOB_ID (create + wait for terminal)
#   ensure_stress_job() — lazy-init STRESS_JOB_ID (takes steps & text_size args)
#   dump_job_logs()     — fetch and print per-job diagnostics on failure
#   register_deletable_asset() — create a file-backed asset, prints asset ID

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

# ===========================================================================
# Job Management Functions (host-side — use container_exec internally)
#
# These functions call openqa-cli inside the container via container_exec.
# They are intended for use by test suites (tests_*.sh), NOT by scripts
# that already run inside the container (e.g. seed_fixtures.sh).
# ===========================================================================

# Path to the cached scenario YAML inside the container.
# Written by seed_fixtures.sh during infrastructure setup.
_SCENARIO_YAML_PATH="/tmp/scenario.yaml"

# ---------------------------------------------------------------------------
# schedule_job KEY=VALUE... — schedule an openQA job via POST /api/v1/isos
#
# Automatically includes SCENARIO_DEFINITIONS_YAML from the cached file.
# Prints the new job ID to stdout.
#
# Usage:
#   job_id=$(schedule_job DISTRI=example VERSION=0 FLAVOR=DVD ARCH=x86_64 \
#                         BUILD=my-build HDD_1=cirros.qcow2 "_GROUP_ID=1")
# ---------------------------------------------------------------------------
schedule_job() {
	if [[ "$DRY_RUN" == "true" ]]; then
		echo "1"
		return 0
	fi
	local response
	# Run everything inside a single bash -c to avoid shell escaping issues
	# with the multi-line SCENARIO_YAML value. The caller's KEY=VALUE args
	# are passed as positional parameters via the trailing "$@".
	#
	# When E2E_STORAGE_KEEP_FREE_RATIO is set, inject it as the
	# STORAGE_KEEP_FREE_RATIO job variable to tune (or disable, with 0)
	# isotovideo's disk-space check.  When unset, the parameter is omitted
	# entirely and isotovideo uses its built-in default (20% keep-free).
	local storage_args=()
	if [[ -n "${E2E_STORAGE_KEEP_FREE_RATIO+set}" ]]; then
		storage_args+=("STORAGE_KEEP_FREE_RATIO=${E2E_STORAGE_KEEP_FREE_RATIO}")
	fi
	# shellcheck disable=SC2016
	response=$(container_exec bash -c '
		SCENARIO_YAML=$(cat "$1")
		shift
		openqa-cli api --host http://localhost -X POST isos \
			"SCENARIO_DEFINITIONS_YAML=$SCENARIO_YAML" \
			"$@" 2>/dev/null
	' _ "$_SCENARIO_YAML_PATH" "${storage_args[@]}" "$@") || die "schedule_job: POST /api/v1/isos failed"

	local job_id
	job_id=$(echo "$response" | jq -r '.ids[0] // empty')
	[[ -n "$job_id" ]] || die "schedule_job: no job ID in response: $response"
	echo "$job_id"
}

# ---------------------------------------------------------------------------
# wait_for_job JOB_ID [TIMEOUT_SECONDS] — poll until the job reaches a
# terminal state (done, cancelled, failed).
#
# Prints the terminal state to stdout. Returns 0 on success, 1 on timeout.
#
# Usage:
#   state=$(wait_for_job "$JOB_ID" 300)
# ---------------------------------------------------------------------------
wait_for_job() {
	local job_id="$1"
	local timeout="${2:-300}"

	if [[ "$DRY_RUN" == "true" ]]; then
		echo "done"
		return 0
	fi

	local elapsed=0
	while [[ "$elapsed" -lt "$timeout" ]]; do
		local state
		state=$(container_exec openqa-cli api --host http://localhost \
			"jobs/$job_id" 2>/dev/null | jq -r '.job.state // empty')
		echo "  [wait] Job $job_id: state=$state (${elapsed}s/${timeout}s)" >&2
		if [[ "$state" == "done" || "$state" == "cancelled" || "$state" == "failed" ]]; then
			echo "$state"
			return 0
		fi
		sleep 2
		elapsed=$((elapsed + 2))
	done
	echo "timeout"
	return 1
}

# ---------------------------------------------------------------------------
# cancel_job JOB_ID — cancel a running job
# ---------------------------------------------------------------------------
cancel_job() {
	local job_id="$1"
	if [[ "$DRY_RUN" == "true" ]]; then
		echo "[DRY-RUN] cancel_job $job_id"
		return 0
	fi
	container_exec openqa-cli api --host http://localhost \
		-X POST "jobs/$job_id/cancel" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# get_job_state JOB_ID — query and print the current state of a job
# ---------------------------------------------------------------------------
get_job_state() {
	local job_id="$1"
	if [[ "$DRY_RUN" == "true" ]]; then
		echo "done"
		return 0
	fi
	container_exec openqa-cli api --host http://localhost \
		"jobs/$job_id" 2>/dev/null | jq -r '.job.state // empty'
}

# ---------------------------------------------------------------------------
# dump_job_logs JOB_ID [LABEL] — fetch and print per-job diagnostics.
#
# Queries the openQA API for the job's result/reason and fetches the tail
# of autoinst-log.txt (the isotovideo log that explains *why* a job died).
# All output goes to stderr, prefixed with [diag].
#
# Call this before die() when a job's result is unexpected — it makes the
# failure reason visible in CI output without manual container inspection.
# ---------------------------------------------------------------------------
dump_job_logs() {
	local job_id="$1"
	local label="${2:-Job $job_id}"
	[[ "$DRY_RUN" == "true" ]] && return 0

	# 1. Fetch job result/reason from the API
	local job_json result reason
	job_json=$(container_exec openqa-cli api --host http://localhost \
		"jobs/$job_id" 2>/dev/null) || true
	result=$(echo "$job_json" | jq -r '.job.result // "unknown"')
	reason=$(echo "$job_json" | jq -r '.job.reason // "none"')
	echo "  [diag] $label (job $job_id): result=$result reason=$reason" >&2

	# 2. Fetch tail of autoinst-log.txt (isotovideo log — shows why the job died)
	local autoinst_log
	autoinst_log=$(container_exec bash -c \
		"curl -sSf http://localhost/tests/$job_id/file/autoinst-log.txt 2>/dev/null | tail -30" \
	) || true
	if [[ -n "$autoinst_log" ]]; then
		echo "  [diag] autoinst-log.txt (last 30 lines):" >&2
		while IFS= read -r _line; do
			printf '  [diag]   %s\n' "$_line" >&2
		done <<<"$autoinst_log"
	else
		echo "  [diag] autoinst-log.txt: not available" >&2
	fi
}

# ---------------------------------------------------------------------------
# ensure_basic_job — lazy-init a basic job (JOB_ID).
#
# If JOB_ID is already set in the caller's scope, this is a no-op.
# Otherwise, schedules a simple job (no SLEEPTEST) and waits for it to
# reach a terminal state so its results are available for archive/GET tests.
#
# Sets JOB_ID in the caller's scope.
# ---------------------------------------------------------------------------
ensure_basic_job() {
	if [[ -n "${JOB_ID:-}" ]]; then
		return 0
	fi

	echo "  [ensure] Scheduling basic job..." >&2
	JOB_ID=$(schedule_job \
		DISTRI=example \
		VERSION=0 \
		FLAVOR=DVD \
		ARCH=x86_64 \
		BUILD=e2e-test \
		HDD_1="cirros-0.6.3-x86_64-disk.qcow2" \
		ISO_1="seed-nocloud.iso" \
		CASEDIR="/var/lib/openqa/share/tests/cirros" \
		NEEDLES_DIR="%CASEDIR%/needles" \
		"_GROUP_ID=${GROUP_ID:-1}")
	echo "  [ensure] JOB_ID=$JOB_ID — waiting for completion..." >&2
	wait_for_job "$JOB_ID" 300 >/dev/null || die "ensure_basic_job: timeout waiting for JOB_ID=$JOB_ID"
	# Verify the job actually passed — fail early with diagnostics
	if [[ "$DRY_RUN" != "true" ]]; then
		local _result
		_result=$(container_exec openqa-cli api --host http://localhost \
			"jobs/$JOB_ID" 2>/dev/null | jq -r '.job.result // empty')
		if [[ "$_result" != "passed" ]]; then
			dump_job_logs "$JOB_ID" "basic job"
			die "ensure_basic_job: job $JOB_ID result=$_result (expected passed)"
		fi
		echo "  [ensure] JOB_ID=$JOB_ID ready (result=$_result)." >&2
	else
		echo "  [ensure] JOB_ID=$JOB_ID ready." >&2
	fi
	export JOB_ID
}

# ---------------------------------------------------------------------------
# ensure_rich_job — lazy-init a rich CirrOS job (RICH_JOB_ID).
#
# If RICH_JOB_ID is already set, this is a no-op.
# Otherwise, ensures the basic job is done first (frees the single worker),
# then schedules the rich job and waits for it to complete.
#
# Sets RICH_JOB_ID in the caller's scope.
# ---------------------------------------------------------------------------
ensure_rich_job() {
	if [[ -n "${RICH_JOB_ID:-}" ]]; then
		return 0
	fi

	# The single worker must be free before we schedule another job.
	ensure_basic_job

	echo "  [ensure] Scheduling rich job..." >&2
	RICH_JOB_ID=$(schedule_job \
		DISTRI=example \
		VERSION=0 \
		FLAVOR=DVD \
		ARCH=x86_64 \
		BUILD=e2e-test-rich \
		HDD_1="cirros-0.6.3-x86_64-disk.qcow2" \
		ISO_1="seed-nocloud.iso" \
		CASEDIR="/var/lib/openqa/share/tests/cirros" \
		NEEDLES_DIR="%CASEDIR%/needles" \
		"_GROUP_ID=${GROUP_ID:-1}")
	echo "  [ensure] RICH_JOB_ID=$RICH_JOB_ID — waiting for completion..." >&2
	wait_for_job "$RICH_JOB_ID" 300 >/dev/null || die "ensure_rich_job: timeout waiting for RICH_JOB_ID=$RICH_JOB_ID"
	# Verify the job actually passed — fail early with diagnostics
	if [[ "$DRY_RUN" != "true" ]]; then
		local _result
		_result=$(container_exec openqa-cli api --host http://localhost \
			"jobs/$RICH_JOB_ID" 2>/dev/null | jq -r '.job.result // empty')
		if [[ "$_result" != "passed" ]]; then
			dump_job_logs "$RICH_JOB_ID" "rich job"
			die "ensure_rich_job: job $RICH_JOB_ID result=$_result (expected passed)"
		fi
		echo "  [ensure] RICH_JOB_ID=$RICH_JOB_ID ready (result=$_result)." >&2
	else
		echo "  [ensure] RICH_JOB_ID=$RICH_JOB_ID ready." >&2
	fi
	export RICH_JOB_ID
}

# ---------------------------------------------------------------------------
# ensure_stress_job STRESS_STEPS STRESS_TEXT_SIZE — lazy-init a stress job
# (STRESS_JOB_ID).
#
# Schedules a job that runs tests/stress.pm (record_info loop) to inflate
# the jobs/ID/details API response to a configurable size.
#
# Arguments (both required):
#   $1  STRESS_STEPS     — number of record_info calls
#   $2  STRESS_TEXT_SIZE  — bytes per call
#
# Sets STRESS_JOB_ID in the caller's scope.
# ---------------------------------------------------------------------------
ensure_stress_job() {
	[[ $# -ge 2 ]] || die "ensure_stress_job: requires 2 arguments (STRESS_STEPS STRESS_TEXT_SIZE), got $#"
	local stress_steps="$1"
	local stress_text_size="$2"

	if [[ -n "${STRESS_JOB_ID:-}" ]]; then
		return 0
	fi

	# The single worker must be free before we schedule another job.
	ensure_basic_job

	echo "  [ensure] Scheduling stress job..." >&2
	# stress.pm only calls record_info() — it never interacts with a VM.
	# Use BACKEND=null to skip QEMU entirely, avoiding the isotovideo
	# HDDSIZEGB storage check that fails on hosts with low free space.
	STRESS_JOB_ID=$(schedule_job \
		DISTRI=example \
		VERSION=0 \
		FLAVOR=DVD \
		ARCH=x86_64 \
		BUILD=e2e-stress \
		BACKEND=null \
		CASEDIR="/var/lib/openqa/share/tests/cirros" \
		NEEDLES_DIR="%CASEDIR%/needles" \
		STRESSTEST=1 \
		STRESS_STEPS="$stress_steps" \
		STRESS_TEXT_SIZE="$stress_text_size" \
		"_GROUP_ID=${GROUP_ID:-1}")
	echo "  [ensure] STRESS_JOB_ID=$STRESS_JOB_ID — waiting for completion..." >&2
	wait_for_job "$STRESS_JOB_ID" 300 >/dev/null ||
		die "ensure_stress_job: timeout waiting for STRESS_JOB_ID=$STRESS_JOB_ID"
	# Verify the job actually passed — fail early with diagnostics
	if [[ "$DRY_RUN" != "true" ]]; then
		local _result
		_result=$(container_exec openqa-cli api --host http://localhost \
			"jobs/$STRESS_JOB_ID" 2>/dev/null | jq -r '.job.result // empty')
		if [[ "$_result" != "passed" ]]; then
			dump_job_logs "$STRESS_JOB_ID" "stress job"
			die "ensure_stress_job: job $STRESS_JOB_ID result=$_result (expected passed)"
		fi
		echo "  [ensure] STRESS_JOB_ID=$STRESS_JOB_ID ready (result=$_result)." >&2
	else
		echo "  [ensure] STRESS_JOB_ID=$STRESS_JOB_ID ready." >&2
	fi
	export STRESS_JOB_ID
}

# ---------------------------------------------------------------------------
# register_deletable_asset NAME — create a file-backed asset for DELETE tests.
#
# Creates a dummy file in the container's factory/other directory, triggers
# openQA asset registration, and prints the asset ID to stdout.
#
# Usage:
#   ASSET_ID=$(register_deletable_asset "delete-me-perl.tar.gz")
# ---------------------------------------------------------------------------
register_deletable_asset() {
	local name="$1"

	if [[ "$DRY_RUN" == "true" ]]; then
		echo "1"
		return 0
	fi

	local other_dir="/var/lib/openqa/share/factory/other"
	container_exec bash -c "mkdir -p $other_dir && touch $other_dir/$name"
	# Trigger asset registration
	container_exec openqa-cli api --host http://localhost \
		-X POST assets type=other name="$name" >/dev/null 2>&1 || true
	sleep 2

	local asset_id
	asset_id=$(container_exec openqa-cli api --host http://localhost \
		assets 2>/dev/null | jq --arg name "$name" \
		'.assets[] | select(.name == $name) | .id // empty' | head -1)

	if [[ -z "$asset_id" ]]; then
		echo "SKIP"
	else
		echo "$asset_id"
	fi
}
