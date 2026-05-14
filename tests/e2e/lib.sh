#!/usr/bin/env bash
# lib.sh — Shared library for openQA E2E test scripts.
#
# Source this file near the top of each script (after set -eo pipefail):
#
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
#
# Provides:
#   CONTAINER_NAME  — default container name (overridable before sourcing)
#   COLLECT_LOGS    — default false (overridable before sourcing)
#   DRY_RUN         — default false (set before sourcing or via --dryrun parsing)
#   ENV_FILE        — path to the shell env file written by setup.sh
#   LOG_PREFIX      — prefix used by die() and log(); set before sourcing, e.g. "setup"
#   log()           — echo "[LOG_PREFIX] $*" to stdout
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
#   _ensure_job()       — generic lazy-init for any named job variable
#   _E2E_JOB_COMMON_ARGS — shared schedule_job args (DISTRI/FLAVOR/ARCH/…)
#   dump_job_logs()     — fetch and print per-job diagnostics on failure
#   register_deletable_asset() — create a file-backed asset, prints asset ID
#
# Performance helpers (moved here from tests_perf.sh):
#   _perf_wall_time_s()  — measure wall-clock time of a container command
#   _perf_peak_rss_kb()  — measure peak RSS via /usr/bin/time -v
#   _perf_timev_field()  — read a field from the saved /usr/bin/time -v output
#
# Test-side capture helpers:
#   run_capture()        — run one command, capture stdout/stderr/exit
#   run_perl_and_zig()   — run the same args against PERL_EXE and ZIG_EXE
#   run_capture_both()   — like run_perl_and_zig but with explicit full commands
#   run_sigpipe_test()   — run CMD | head -c 1, capture CMD's exit via PIPESTATUS
#   assert_capture_exits() — check _PERL_EXIT/_ZIG_EXIT, PASS/FAIL
#   assert_stdout_pattern() — check both impl stdout logs for a pattern, PASS/FAIL
#
# Test runner functions (the canonical home of these; tests.sh sources lib.sh):
#   run_test()           — run one command, check exit + optional grep, PASS/FAIL
#   run_comparison()     — run the same api args against PERL_EXE and ZIG_EXE
#   run_diff_test()      — diff stdout of both impls, PASS/FAIL

# Guard against double-sourcing
[[ -n "${_OPENQA_E2E_LIB_LOADED:-}" ]] && return 0
_OPENQA_E2E_LIB_LOADED=1

# ---------------------------------------------------------------------------
# Defaults (callers may override before sourcing)
# ---------------------------------------------------------------------------
: "${CONTAINER_NAME:=openqa-e2e}"
: "${COLLECT_LOGS:=false}"
: "${DRY_RUN:=false}"
: "${ENV_FILE:=/tmp/openqa_e2e_env.sh}"
: "${LOG_PREFIX:=e2e}"

# ---------------------------------------------------------------------------
# log() — print a prefixed informational message to stdout
#
# Uses $LOG_PREFIX (default: "e2e").
# Usage: log "Container is ready"
# ---------------------------------------------------------------------------
log() { echo "[$LOG_PREFIX] $*"; }

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
# e2e_sleep SECONDS — sleep unless in dry-run mode
#
# Wrapper around `sleep` that skips the actual delay when DRY_RUN is true.
# Use this instead of bare `sleep` in test scripts so that dry-run completes
# instantly.
# ---------------------------------------------------------------------------
e2e_sleep() {
	if [[ "$DRY_RUN" == "true" ]]; then
		echo "[DRY-RUN] sleep $1 (skipped)"
		return 0
	fi
	sleep "$1"
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
#   this_job_id=$(schedule_job DISTRI=example VERSION=0 FLAVOR=DVD ARCH=x86_64 \
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
	# shellcheck disable=SC2016
	response=$(container_exec bash -c '
		SCENARIO_YAML=$(cat "$1")
		shift
		openqa-cli api --host http://localhost -X POST isos \
			"SCENARIO_DEFINITIONS_YAML=$SCENARIO_YAML" \
			"$@" 2>/dev/null
	' _ "$_SCENARIO_YAML_PATH" "${storage_args[@]}" "$@") || die "schedule_job: POST /api/v1/isos failed"

	local this_job_id
	this_job_id=$(echo "$response" | jq -r '.ids[0] // empty')
	[[ -n "$this_job_id" ]] || die "schedule_job: no job ID in response: $response"
	echo "$this_job_id"
}

# ---------------------------------------------------------------------------
# schedule_chained_jobs BUILD — schedule chained jobs via POST /api/v1/isos
#
# Uses the cached chained-scenario-definitions.yaml.
# Returns space-separated list of all created job IDs.
# ---------------------------------------------------------------------------
schedule_chained_jobs() {
	schedule_topology_jobs "chained" "$1" "${@:2}"
}

# ---------------------------------------------------------------------------
# schedule_topology_jobs TOPOLOGY BUILD — generic topology scheduler
# ---------------------------------------------------------------------------
schedule_topology_jobs() {
	local topology="$1"
	local build="$2"
	shift 2
	if [[ "$DRY_RUN" == "true" ]]; then
		echo "1 2"
		return 0
	fi
	local response
	# shellcheck disable=SC2016
	response=$(container_exec bash -c '
		SCENARIO_YAML=$(cat "$1")
		shift
		openqa-cli api --host http://localhost -X POST isos \
			"SCENARIO_DEFINITIONS_YAML=$SCENARIO_YAML" \
			"$@" 2>/dev/null
	' _ "/tmp/${topology}-scenario.yaml" \
		"${_E2E_JOB_COMMON_ARGS[@]}" \
		"BUILD=$build" "_GROUP_ID=${GROUP_ID:-1}" "$@") || die "schedule_topology_jobs: POST /api/v1/isos failed"

	echo "$response" | jq -r '.ids[]'
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
	local this_job_id="$1"
	local timeout="${2:-300}"

	if [[ "$DRY_RUN" == "true" ]]; then
		echo "done"
		return 0
	fi

	local elapsed=0
	while [[ "$elapsed" -lt "$timeout" ]]; do
		local state
		state=$(container_exec openqa-cli api --host http://localhost \
			"jobs/$this_job_id" 2>/dev/null | jq -r '.job.state // empty')
		echo "  [wait] Job $this_job_id: state=$state (${elapsed}s/${timeout}s)" >&2
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
	local this_job_id="$1"
	if [[ "$DRY_RUN" == "true" ]]; then
		echo "[DRY-RUN] cancel_job $this_job_id"
		return 0
	fi
	container_exec openqa-cli api --host http://localhost \
		-X POST "jobs/$this_job_id/cancel" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# get_job_state JOB_ID — query and print the current state of a job
# ---------------------------------------------------------------------------
get_job_state() {
	local this_job_id="$1"
	if [[ "$DRY_RUN" == "true" ]]; then
		echo "done"
		return 0
	fi
	container_exec openqa-cli api --host http://localhost \
		"jobs/$this_job_id" 2>/dev/null | jq -r '.job.state // empty'
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
	local this_job_id="$1"
	local label="${2:-Job $this_job_id}"
	[[ "$DRY_RUN" == "true" ]] && return 0

	# 1. Fetch job result/reason from the API
	local job_json result reason
	job_json=$(container_exec openqa-cli api --host http://localhost \
		"jobs/$this_job_id" 2>/dev/null) || true
	result=$(echo "$job_json" | jq -r '.job.result // "unknown"')
	reason=$(echo "$job_json" | jq -r '.job.reason // "none"')
	echo "  [diag] $label (job $this_job_id): result=$result reason=$reason" >&2

	# 2. Fetch tail of autoinst-log.txt (isotovideo log — shows why the job died)
	local autoinst_log
	autoinst_log=$(container_exec bash -c \
		"curl -sSf http://localhost/tests/$this_job_id/file/autoinst-log.txt 2>/dev/null | tail -30" \
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
# _E2E_JOB_COMMON_ARGS — shared schedule_job args for all standard jobs.
#
# These are the DISTRI/VERSION/FLAVOR/ARCH/HDD_1/ISO_1/CASEDIR/NEEDLES_DIR
# values used by every ensure_* call.  BUILD and _GROUP_ID are job-specific
# and must be supplied at each call site.
# ---------------------------------------------------------------------------
_E2E_JOB_COMMON_ARGS=(
	DISTRI=example
	VERSION=0
	FLAVOR=DVD
	ARCH=x86_64
	HDD_1="cirros-0.6.3-x86_64-disk.qcow2"
	ISO_1="seed-nocloud.iso"
	CASEDIR="/var/lib/openqa/share/tests/cirros"
	NEEDLES_DIR="%CASEDIR%/needles"
)

# ---------------------------------------------------------------------------
# _ensure_job VAR_NAME LABEL SCHEDULE_ARGS...
#
# Generic lazy-init for any named job variable.
#
# If VAR_NAME is already set (non-empty) in the environment, this is a no-op.
# Otherwise, schedules a job using the provided SCHEDULE_ARGS (passed directly
# to schedule_job), waits for it to complete, verifies it passed, and exports
# the variable.
#
# Arguments:
#   $1  VAR_NAME       — name of the variable to set (e.g. "JOB_ID")
#   $2  LABEL          — human-readable label for log messages (e.g. "basic job")
#   $3… SCHEDULE_ARGS  — key=value pairs forwarded to schedule_job()
#
# Sets and exports VAR_NAME in the caller's scope.
# ---------------------------------------------------------------------------
_ensure_job() {
	local var_name="$1"
	local label="$2"
	shift 2

	# No-op if already set.
	if [[ -n "${!var_name:-}" ]]; then
		return 0
	fi

	echo "  [ensure] Scheduling $label..." >&2
	local this_job_id
	this_job_id=$(schedule_job "$@")
	echo "  [ensure] ${var_name}=${this_job_id} — waiting for completion..." >&2
	wait_for_job "$this_job_id" 300 >/dev/null ||
		die "_ensure_job: timeout waiting for ${var_name}=${this_job_id} ($label)"

	if [[ "$DRY_RUN" != "true" ]]; then
		local _result
		_result=$(container_exec openqa-cli api --host http://localhost \
			"jobs/$this_job_id" 2>/dev/null | jq -r '.job.result // empty')
		if [[ "$_result" != "passed" ]]; then
			dump_job_logs "$this_job_id" "$label"
			die "_ensure_job: job $this_job_id result=$_result (expected passed) ($label)"
		fi
		echo "  [ensure] ${var_name}=${this_job_id} ready (result=$_result)." >&2
	else
		echo "  [ensure] ${var_name}=${this_job_id} ready." >&2
	fi

	printf -v "$var_name" '%s' "$this_job_id"
	export "${var_name?}"
}

# ---------------------------------------------------------------------------
# ensure_basic_job — lazy-init JOB_ID (basic CirrOS job).
# ensure_rich_job  — lazy-init RICH_JOB_ID (waits for basic first).
# ensure_stress_job STRESS_STEPS STRESS_TEXT_SIZE — lazy-init STRESS_JOB_ID.
#
# Thin wrappers around _ensure_job kept for call-site compatibility.
# ---------------------------------------------------------------------------
ensure_basic_job() {
	_ensure_job JOB_ID "basic job" \
		"${_E2E_JOB_COMMON_ARGS[@]}" \
		BUILD=e2e-test \
		"_GROUP_ID=${GROUP_ID:-1}"
}

ensure_rich_job() {
	# The single worker must be free before we schedule another job.
	ensure_basic_job
	_ensure_job RICH_JOB_ID "rich job" \
		"${_E2E_JOB_COMMON_ARGS[@]}" \
		BUILD=e2e-test-rich \
		"_GROUP_ID=${GROUP_ID:-1}"
}

ensure_stress_job() {
	[[ $# -ge 2 ]] || die "ensure_stress_job: requires 2 arguments (STRESS_STEPS STRESS_TEXT_SIZE), got $#"
	local stress_steps="$1"
	local stress_text_size="$2"
	# The single worker must be free before we schedule another job.
	ensure_basic_job
	# stress.pm only calls record_info() — it never interacts with a VM.
	# Use BACKEND=null to skip QEMU entirely, avoiding the isotovideo
	# HDDSIZEGB storage check that fails on hosts with low free space.
	_ensure_job STRESS_JOB_ID "stress job" \
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
		"_GROUP_ID=${GROUP_ID:-1}"
}

# ---------------------------------------------------------------------------
# ensure_chained_jobs — lazy-init CHAIN_PARENT_ID and CHAIN_CHILD_ID.
# ---------------------------------------------------------------------------
ensure_chained_jobs() {
	if [[ -n "${CHAIN_PARENT_ID:-}" && -n "${CHAIN_CHILD_ID:-}" ]]; then
		return 0
	fi

	if [[ "$DRY_RUN" == "true" ]]; then
		CHAIN_PARENT_ID="1"
		CHAIN_CHILD_ID="2"
		echo "  [ensure] [DRY-RUN] CHAIN_PARENT_ID=$CHAIN_PARENT_ID, CHAIN_CHILD_ID=$CHAIN_CHILD_ID" >&2
		export CHAIN_PARENT_ID CHAIN_CHILD_ID
		return 0
	fi

	echo "  [ensure] Scheduling chained job pair..." >&2
	local ids
	ids=$(schedule_topology_jobs "chained" "chain-seed")

	# Identify parent vs child by querying TEST setting
	for id in $ids; do
		local test_name
		test_name=$(container_exec openqa-cli api --host http://localhost \
			"jobs/$id" 2>/dev/null | jq -r '.job.settings.TEST')
		case "$test_name" in
			chain_parent) CHAIN_PARENT_ID="$id" ;;
			chain_child)  CHAIN_CHILD_ID="$id" ;;
		esac
	done

	[[ -n "${CHAIN_PARENT_ID:-}" ]] || die "ensure_chained_jobs: parent ID not found"
	[[ -n "${CHAIN_CHILD_ID:-}" ]] || die "ensure_chained_jobs: child ID not found"

	# Wait for child (dependency means parent completes first)
	echo "  [ensure] CHAIN_PARENT_ID=$CHAIN_PARENT_ID, CHAIN_CHILD_ID=$CHAIN_CHILD_ID — waiting..." >&2
	wait_for_job "$CHAIN_CHILD_ID" 600 >/dev/null ||
		die "ensure_chained_jobs: timeout waiting for chain_child"

	export CHAIN_PARENT_ID CHAIN_CHILD_ID
}

# ---------------------------------------------------------------------------
# ensure_fanout_jobs — lazy-init FANOUT_*_ID variables
# ---------------------------------------------------------------------------
ensure_fanout_jobs() {
	if [[ -n "${FANOUT_PARENT_ID:-}" && -n "${FANOUT_CHILD_A_ID:-}" ]]; then
		return 0
	fi

	if [[ "$DRY_RUN" == "true" ]]; then
		FANOUT_PARENT_ID="1"
		FANOUT_CHILD_A_ID="2"
		FANOUT_CHILD_B_ID="3"
		FANOUT_CHILD_C_ID="4"
		echo "  [ensure] [DRY-RUN] FANOUT_PARENT_ID=$FANOUT_PARENT_ID, children=$FANOUT_CHILD_A_ID/$FANOUT_CHILD_B_ID/$FANOUT_CHILD_C_ID" >&2
		export FANOUT_PARENT_ID FANOUT_CHILD_A_ID FANOUT_CHILD_B_ID FANOUT_CHILD_C_ID
		return 0
	fi

	echo "  [ensure] Scheduling fanout jobs..." >&2
	local ids
	ids=$(schedule_topology_jobs "fanout" "fanout-seed")

	for id in $ids; do
		local test_name
		test_name=$(container_exec openqa-cli api --host http://localhost \
			"jobs/$id" 2>/dev/null | jq -r '.job.settings.TEST')
		case "$test_name" in
			fanout_parent)  FANOUT_PARENT_ID="$id" ;;
			fanout_child_a) FANOUT_CHILD_A_ID="$id" ;;
			fanout_child_b) FANOUT_CHILD_B_ID="$id" ;;
			fanout_child_c) FANOUT_CHILD_C_ID="$id" ;;
		esac
	done

	[[ -n "${FANOUT_PARENT_ID:-}" ]] || die "ensure_fanout_jobs: parent ID not found"
	
	echo "  [ensure] Fanout parent: $FANOUT_PARENT_ID — waiting for children..." >&2
	# Wait for all children
	for id in "$FANOUT_CHILD_A_ID" "$FANOUT_CHILD_B_ID" "$FANOUT_CHILD_C_ID"; do
		wait_for_job "$id" 600 >/dev/null || die "ensure_fanout_jobs: timeout waiting for child $id"
	done

	export FANOUT_PARENT_ID FANOUT_CHILD_A_ID FANOUT_CHILD_B_ID FANOUT_CHILD_C_ID
}

# ---------------------------------------------------------------------------
# ensure_multilayer_jobs — lazy-init LAYER_*_ID variables
# ---------------------------------------------------------------------------
ensure_multilayer_jobs() {
	if [[ -n "${LAYER_GRANDPARENT_ID:-}" && -n "${LAYER_CHILD_ID:-}" ]]; then
		return 0
	fi

	if [[ "$DRY_RUN" == "true" ]]; then
		LAYER_GRANDPARENT_ID="1"
		LAYER_PARENT_ID="2"
		LAYER_CHILD_ID="3"
		echo "  [ensure] [DRY-RUN] LAYER_GRANDPARENT_ID=$LAYER_GRANDPARENT_ID, LAYER_PARENT_ID=$LAYER_PARENT_ID, LAYER_CHILD_ID=$LAYER_CHILD_ID" >&2
		export LAYER_GRANDPARENT_ID LAYER_PARENT_ID LAYER_CHILD_ID
		return 0
	fi

	echo "  [ensure] Scheduling multilayer jobs..." >&2
	local ids
	ids=$(schedule_topology_jobs "multilayer" "layer-seed")

	for id in $ids; do
		local test_name
		test_name=$(container_exec openqa-cli api --host http://localhost \
			"jobs/$id" 2>/dev/null | jq -r '.job.settings.TEST')
		case "$test_name" in
			layer_grandparent) LAYER_GRANDPARENT_ID="$id" ;;
			layer_parent)      LAYER_PARENT_ID="$id" ;;
			layer_child)       LAYER_CHILD_ID="$id" ;;
		esac
	done

	[[ -n "${LAYER_CHILD_ID:-}" ]] || die "ensure_multilayer_jobs: child ID not found"
	
	echo "  [ensure] Multilayer child: $LAYER_CHILD_ID — waiting..." >&2
	wait_for_job "$LAYER_CHILD_ID" 600 >/dev/null || die "ensure_multilayer_jobs: timeout waiting for child"

	export LAYER_GRANDPARENT_ID LAYER_PARENT_ID LAYER_CHILD_ID
}

# ---------------------------------------------------------------------------
# ensure_diamond_jobs — lazy-init DIAMOND_*_ID variables
# ---------------------------------------------------------------------------
ensure_diamond_jobs() {
	if [[ -n "${DIAMOND_ROOT_ID:-}" && -n "${DIAMOND_MERGE_ID:-}" ]]; then
		return 0
	fi

	if [[ "$DRY_RUN" == "true" ]]; then
		DIAMOND_ROOT_ID="1"
		DIAMOND_LEFT_ID="2"
		DIAMOND_RIGHT_ID="3"
		DIAMOND_MERGE_ID="4"
		echo "  [ensure] [DRY-RUN] DIAMOND_ROOT=$DIAMOND_ROOT_ID, LEFT=$DIAMOND_LEFT_ID, RIGHT=$DIAMOND_RIGHT_ID, MERGE=$DIAMOND_MERGE_ID" >&2
		export DIAMOND_ROOT_ID DIAMOND_LEFT_ID DIAMOND_RIGHT_ID DIAMOND_MERGE_ID
		return 0
	fi

	echo "  [ensure] Scheduling diamond jobs..." >&2
	local ids
	ids=$(schedule_topology_jobs "diamond" "diamond-seed")

	for id in $ids; do
		local test_name
		test_name=$(container_exec openqa-cli api --host http://localhost \
			"jobs/$id" 2>/dev/null | jq -r '.job.settings.TEST')
		case "$test_name" in
			diamond_root)  DIAMOND_ROOT_ID="$id" ;;
			diamond_left)  DIAMOND_LEFT_ID="$id" ;;
			diamond_right) DIAMOND_RIGHT_ID="$id" ;;
			diamond_merge) DIAMOND_MERGE_ID="$id" ;;
		esac
	done

	[[ -n "${DIAMOND_MERGE_ID:-}" ]] || die "ensure_diamond_jobs: merge ID not found"
	
	echo "  [ensure] Diamond merge: $DIAMOND_MERGE_ID — waiting..." >&2
	wait_for_job "$DIAMOND_MERGE_ID" 600 >/dev/null || die "ensure_diamond_jobs: timeout waiting for merge"

	export DIAMOND_ROOT_ID DIAMOND_LEFT_ID DIAMOND_RIGHT_ID DIAMOND_MERGE_ID
}

# ---------------------------------------------------------------------------
# ensure_parallel_jobs — lazy-init PARALLEL_*_ID variables
# ---------------------------------------------------------------------------
ensure_parallel_jobs() {
	if [[ -n "${PARALLEL_PARENT_ID:-}" && -n "${PARALLEL_CHILD_ID:-}" ]]; then
		return 0
	fi

	if [[ "$DRY_RUN" == "true" ]]; then
		PARALLEL_PARENT_ID="1"
		PARALLEL_CHILD_ID="2"
		echo "  [ensure] [DRY-RUN] PARALLEL_PARENT_ID=$PARALLEL_PARENT_ID, PARALLEL_CHILD_ID=$PARALLEL_CHILD_ID" >&2
		export PARALLEL_PARENT_ID PARALLEL_CHILD_ID
		return 0
	fi

	echo "  [ensure] Scheduling parallel jobs..." >&2
	local ids
	ids=$(schedule_topology_jobs "parallel" "parallel-seed")

	for id in $ids; do
		local test_name
		test_name=$(container_exec openqa-cli api --host http://localhost \
			"jobs/$id" 2>/dev/null | jq -r '.job.settings.TEST')
		case "$test_name" in
			parallel_parent) PARALLEL_PARENT_ID="$id" ;;
			parallel_child)  PARALLEL_CHILD_ID="$id" ;;
		esac
	done

	[[ -n "${PARALLEL_PARENT_ID:-}" ]] || die "ensure_parallel_jobs: parent ID not found"
	
	echo "  [ensure] Parallel parent: $PARALLEL_PARENT_ID — waiting..." >&2
	# Since they run in parallel, we wait for both to complete
	wait_for_job "$PARALLEL_PARENT_ID" 600 >/dev/null || die "ensure_parallel_jobs: timeout waiting for parent"
	wait_for_job "$PARALLEL_CHILD_ID" 600 >/dev/null || die "ensure_parallel_jobs: timeout waiting for child"

	export PARALLEL_PARENT_ID PARALLEL_CHILD_ID
}

# ---------------------------------------------------------------------------
# assert_job_has_chained_parent JOB_ID EXPECTED_PARENT_ID
# ---------------------------------------------------------------------------
assert_job_has_chained_parent() {
	local job_id="$1" expected_parent="$2"
	local parents
	parents=$(container_exec openqa-cli api --host http://localhost \
		"jobs/$job_id" 2>/dev/null | jq -r '.job.parents.Chained[]')
	if ! echo "$parents" | grep -qw "$expected_parent"; then
		echo "  FAIL: Job $job_id does not have $expected_parent in parents.Chained. Actual: $parents"
		return 1
	fi
	return 0
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
	e2e_sleep 2

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

# ===========================================================================
# Performance Helpers
#
# Shared between tests_perf.sh and tests_stress.sh.
# All helpers run commands inside the container via container_exec.
# ===========================================================================

# ---------------------------------------------------------------------------
# _perf_wall_time_s ENV_VARS CMD
#
# Measures the wall-clock execution time of CMD running inside the container.
# ENV_VARS is a string of assignments to prepend (e.g. "VAR=val"), or "".
# Prints the elapsed time in decimal seconds to stdout.
# ---------------------------------------------------------------------------
_perf_wall_time_s() {
	local env_vars=$1
	local cmd=$2
	container_exec bash -c "
TIMEFORMAT='%R'
{ time $env_vars $cmd >/dev/null 2>&1; } 2>/tmp/_perf_wall.out
cat /tmp/_perf_wall.out
" 2>/dev/null
}

# ---------------------------------------------------------------------------
# _perf_peak_rss_kb ENV_VARS CMD [TAG]
#
# Measures peak RSS (kB) of CMD running inside the container via
# /usr/bin/time -v (GNU time, installed in setup.sh).
#
# TAG (optional) overrides the temp-file name used for the saved output.
# When absent, the tag is derived from the first token of CMD.  Use an
# explicit TAG when the same binary is invoked with different roles (e.g.
# "stress_perl" / "stress_zig") so the output files don't collide.
#
# Prints the "Maximum resident set size (kbytes)" value, or "" on failure.
# Also writes the full /usr/bin/time -v output to /tmp/_perf_timev_<tag>.txt
# inside the container so callers can retrieve additional fields.
# ---------------------------------------------------------------------------
_perf_peak_rss_kb() {
	local env_vars=$1
	local cmd=$2
	local tag="${3:-}"

	if [[ "${DRY_RUN:-false}" == "true" ]]; then
		echo "0"
		return
	fi

	# Derive a safe tag from the first token of cmd when not explicitly given.
	if [[ -z "$tag" ]]; then
		tag=$(echo "$cmd" | cut -d' ' -f1 | tr -cs 'a-zA-Z0-9_-' '_')
	fi

	container_exec bash -c \
		"$env_vars /usr/bin/time -v $cmd >/dev/null 2>/tmp/_perf_timev_${tag}.txt" \
		</dev/null 2>/dev/null || true

	container_exec bash -c \
		"grep 'Maximum resident set size' /tmp/_perf_timev_${tag}.txt | cut -d: -f2 | tr -d ' \t'" \
		</dev/null 2>/dev/null
}

# ---------------------------------------------------------------------------
# _perf_timev_field TAG FIELD_PATTERN
#
# Reads a numeric value from the /usr/bin/time -v output file written by a
# previous _perf_peak_rss_kb call.  TAG must match the tag used in that call.
# Returns "" if the file or field is absent.
# ---------------------------------------------------------------------------
_perf_timev_field() {
	local tag=$1
	local field=$2
	container_exec bash -c \
		"grep '$field' /tmp/_perf_timev_${tag}.txt 2>/dev/null | cut -d: -f2 | tr -d ' \t'" \
		</dev/null 2>/dev/null
}

# ===========================================================================
# Test-side capture helpers
#
# Eliminate the boilerplate:
#     set +e
#     container_exec bash -c "<cmd>" >stdout 2>stderr
#     exit_code=$?
#     set -e
#
# Use run_capture for a single command, or run_perl_and_zig when both
# implementations are exercised with the same arguments.
# ===========================================================================

# ---------------------------------------------------------------------------
# run_capture TAG IMPL CMD
#
# Runs CMD inside the container without aborting on non-zero exit.  Captures
# stdout to $LOG_DIR/${TAG}_${IMPL}_stdout.log and stderr to
# $LOG_DIR/${TAG}_${IMPL}_stderr.log.  The command's exit code is left in the
# global _LAST_EXIT for the caller to inspect.
#
# TAG  — short identifier shared across one logical test (e.g. "mon_cancel")
# IMPL — "perl" or "zig" (used in the log filenames; any string is accepted)
# CMD  — the full command line passed to `container_exec bash -c`
#
# Usage:
#   run_capture "mon_cancel" perl "timeout 60 $PERL_EXE monitor $JOB_ID"
#   echo "Perl exit: $_LAST_EXIT"
# ---------------------------------------------------------------------------
run_capture() {
	local tag=$1
	local impl=$2
	local cmd=$3
	set +e
	container_exec bash -c "$cmd" \
		>"$LOG_DIR/${tag}_${impl}_stdout.log" \
		2>"$LOG_DIR/${tag}_${impl}_stderr.log"
	_LAST_EXIT=$?
	set -e
}

# ---------------------------------------------------------------------------
# run_perl_and_zig TAG ARGS [TIMEOUT_S]
#
# Runs the same command tail against both PERL_EXE and ZIG_EXE inside the
# container.  Stores their exit codes in _PERL_EXIT and _ZIG_EXIT, and writes
# the four log files:
#     $LOG_DIR/${TAG}_perl_stdout.log  / _perl_stderr.log
#     $LOG_DIR/${TAG}_zig_stdout.log   / _zig_stderr.log
#
# TAG       — short identifier shared by the perl and zig invocations
# ARGS      — everything that follows the binary name
#             (e.g. "monitor $JOB_ID" or "schedule --host http://localhost …")
# TIMEOUT_S — optional; wraps each invocation in `timeout N`. Omit for none.
#
# Usage:
#   run_perl_and_zig "mon_cancel" "monitor $MONITOR_JOB_ID" 60
#   if [[ "$_PERL_EXIT" -eq 2 && "$_ZIG_EXIT" -eq 2 ]]; then
#       echo "PASS"
#   fi
#
# Note: ARGS is interpolated into a single bash -c command string, so any
# special characters must already be quoted by the caller (same constraint as
# container_exec bash -c "...").
# ---------------------------------------------------------------------------
run_perl_and_zig() {
	local tag=$1
	local args=$2
	local timeout_s=${3:-}
	local prefix=""
	[[ -n "$timeout_s" ]] && prefix="timeout $timeout_s "

	run_capture "$tag" perl "${prefix}${PERL_EXE} ${args}"
	_PERL_EXIT=$_LAST_EXIT
	run_capture "$tag" zig  "${prefix}${ZIG_EXE} ${args}"
	_ZIG_EXIT=$_LAST_EXIT
}

# ---------------------------------------------------------------------------
# run_sigpipe_test TAG IMPL CMD
#
# Tests that CMD survives a broken pipe (SIGPIPE / EPIPE) without crashing.
#
# Runs  CMD | head -c 1  inside the container and captures CMD's own exit
# code — not head's — via bash PIPESTATUS[0].  This is critical: without
# PIPESTATUS the pipeline would always return head's exit code (0),
# silently masking a SIGPIPE crash in CMD (exit 141) or an unhandled EPIPE
# propagation (exit 1).
#
# Stdout/stderr are captured to $LOG_DIR/${TAG}_${IMPL}_{stdout,stderr}.log.
# The exit code is left in _LAST_EXIT.
#
# Usage:
#   run_sigpipe_test "bp" perl "$PERL_EXE api --host http://localhost jobs/overview"
#   _PERL_EXIT=$_LAST_EXIT
#   run_sigpipe_test "bp" zig  "$ZIG_EXE api --host http://localhost jobs/overview"
#   _ZIG_EXIT=$_LAST_EXIT
# ---------------------------------------------------------------------------
run_sigpipe_test() {
	local tag=$1
	local impl=$2
	local cmd=$3
	set +e
	container_exec bash -c \
		"$cmd | head -c 1; exit \${PIPESTATUS[0]}" \
		>"$LOG_DIR/${tag}_${impl}_stdout.log" \
		2>"$LOG_DIR/${tag}_${impl}_stderr.log"
	_LAST_EXIT=$?
	set -e
}

# ---------------------------------------------------------------------------
# run_capture_both TAG PERL_CMD ZIG_CMD
#
# Runs PERL_CMD and ZIG_CMD via run_capture (IMPL=perl, then IMPL=zig).
# Stores exit codes in _PERL_EXIT and _ZIG_EXIT respectively.
#
# Analogous to run_perl_and_zig but accepts explicit full command strings
# instead of building them from the global PERL_EXE/ZIG_EXE with shared args.
# Use this when the two implementations differ in binary path or flag spelling.
#
# Usage:
#   run_capture_both "clone12" \
#       "$PERL_CLONE_EXE --within-instance http://localhost $JOB_ID" \
#       "$ZIG_CLONE_EXE --within-instance http://localhost $JOB_ID"
#   # exits now in _PERL_EXIT and _ZIG_EXIT
# ---------------------------------------------------------------------------
run_capture_both() {
	local tag=$1
	local perl_cmd=$2
	local zig_cmd=$3
	run_capture "$tag" perl "$perl_cmd"
	_PERL_EXIT=$_LAST_EXIT
	run_capture "$tag" zig "$zig_cmd"
	_ZIG_EXIT=$_LAST_EXIT
}

# ---------------------------------------------------------------------------
# assert_capture_exits TAG [EXPECTED_EXIT]
#
# Asserts that _PERL_EXIT and _ZIG_EXIT (set by run_capture_both, or set
# manually after individual run_capture calls) both equal EXPECTED_EXIT
# (default: 0).
#
# On failure: prints the failing impl's stderr log and increments failed_tests.
# On success: prints "PASS".
#
# When the two captures are interleaved with waits (e.g. single-worker jobs),
# set _PERL_EXIT and _ZIG_EXIT directly after each run_capture call and then
# call this function once at the end.
#
# Usage:
#   run_capture_both "clone12" "$PERL_CMD" "$ZIG_CMD"
#   assert_capture_exits "clone12" 0
# ---------------------------------------------------------------------------
assert_capture_exits() {
	local tag=$1
	local expected_exit=${2:-0}
	local pass=true
	if [[ "$_PERL_EXIT" -ne "$expected_exit" ]]; then
		echo "  FAIL: Perl exited $_PERL_EXIT (expected $expected_exit)"
		cat "$LOG_DIR/${tag}_perl_stderr.log"
		pass=false
	fi
	if [[ "$_ZIG_EXIT" -ne "$expected_exit" ]]; then
		echo "  FAIL: Zig exited $_ZIG_EXIT (expected $expected_exit)"
		cat "$LOG_DIR/${tag}_zig_stderr.log"
		pass=false
	fi
	if [[ "$pass" == "true" ]]; then
		echo "PASS"
	else
		failed_tests=$((failed_tests + 1))
	fi
}

# ---------------------------------------------------------------------------
# assert_stdout_pattern TAG PATTERN
#
# Checks that the stdout log for both perl and zig (written by a prior
# run_capture or run_capture_both call with the same TAG) match PATTERN via
# grep -qE.  Prints "PASS" if both match; on failure, prints the failing
# impl's stdout log and increments failed_tests.
#
# Usage:
#   assert_stdout_pattern "clone12" "has been created"
#   assert_stdout_pattern "clone12" 'http://localhost/tests/[0-9]+'
# ---------------------------------------------------------------------------
assert_stdout_pattern() {
	local tag=$1
	local pattern=$2
	local pass=true
	local _impl
	for _impl in perl zig; do
		if ! grep -qE "$pattern" "$LOG_DIR/${tag}_${_impl}_stdout.log" 2>/dev/null; then
			echo "  FAIL: $_impl stdout missing pattern '$pattern'"
			cat "$LOG_DIR/${tag}_${_impl}_stdout.log"
			pass=false
		fi
	done
	if [[ "$pass" == "true" ]]; then
		echo "PASS"
	else
		failed_tests=$((failed_tests + 1))
	fi
}

# ===========================================================================
# Test Runner Functions
#
# These were previously defined inline in tests.sh.  They live here so that
# lib.sh is the single, authoritative home for all shared test helpers.
# tests.sh sources lib.sh and then sources the per-domain suite files.
# ===========================================================================

# ---------------------------------------------------------------------------
# run_test LABEL CMD [EXPECTED_EXIT [GREP_PATTERN]]
#
# Runs CMD inside the container, checks the exit code, and optionally greps
# the combined stdout+stderr output for GREP_PATTERN.
#
# Parameters:
#   LABEL         — human-readable test name printed in the --- Test: --- line
#   CMD           — command string passed to container_exec (eval'd)
#   EXPECTED_EXIT — expected exit code (default: 0)
#   GREP_PATTERN  — optional grep pattern; FAIL if not found in output
#
# Side effects: increments failed_tests on failure.
# ---------------------------------------------------------------------------
run_test() {
	local label=$1
	local cmd=$2
	local expected_exit=${3:-0}
	local grep_pattern=$4

	echo "--- Test: $label ---"
	echo "Command: $cmd"

	set +e
	eval "container_exec $cmd" >"$LOG_DIR/test_output.log" 2>&1
	local exit_code=$?
	set -e

	echo "Exit code: $exit_code"

	if [[ "$exit_code" -ne "$expected_exit" ]]; then
		echo "FAIL: Expected exit code $expected_exit, got $exit_code"
		cat "$LOG_DIR/test_output.log"
		failed_tests=$((failed_tests + 1))
		return
	fi

	if [[ -n "$grep_pattern" ]]; then
		if ! grep -q "$grep_pattern" "$LOG_DIR/test_output.log"; then
			echo "FAIL: Output did not match pattern '$grep_pattern'"
			cat "$LOG_DIR/test_output.log"
			failed_tests=$((failed_tests + 1))
			return
		fi
	fi

	echo "PASS"
}

# ---------------------------------------------------------------------------
# run_comparison LABEL ENV_VARS API_ARGS [EXPECTED_EXIT [GREP_PATTERN]]
#
# Runs the same API call against both the Perl reference implementation and
# the Zig implementation, checking each one independently.  A test PASSES
# when both implementations satisfy the exit-code and grep-pattern criteria;
# each can fail independently, producing a separate FAIL line.
#
# This is the right helper when you care about whether each implementation
# behaves correctly in isolation (correct exit code, correct output pattern),
# but do NOT require the two outputs to be identical.  Use run_diff_test when
# you want to assert byte-for-byte output parity (modulo trailing newlines).
#
# Parameters:
#   LABEL         — human-readable test name (prefixed with PERL:/ZIG: automatically)
#   ENV_VARS      — space-separated env-var assignments prepended to the command
#                   (e.g. "OPENQA_CONFIG=/tmp"); pass "" for none
#   API_ARGS      — arguments passed after `api --host http://localhost`
#   EXPECTED_EXIT — expected exit code for both impls (default: 0)
#   GREP_PATTERN  — optional grep pattern checked against combined stdout+stderr
#
# Side effects: increments failed_tests once per implementation that fails.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# run_diff_test LABEL API_ARGS
#
# Runs the same API call against both implementations and asserts that their
# stdout output is identical (after trailing-newline normalisation).  stderr is
# discarded from both sides to avoid noise from ANSI colour codes, Mojo
# warnings, and the BoltDB deprecation warning emitted by podman on some hosts.
#
# Use this helper when you want to detect regressions in the Zig output format
# relative to the Perl reference — i.e., "both must produce the same body".
# For exit-code or pattern checks use run_comparison instead.
#
# Parameters:
#   LABEL    — human-readable test name printed in the --- Test: DIFF --- line
#   API_ARGS — arguments passed after `api --host http://localhost`
#
# Side effects: increments failed_tests on mismatch.
# ---------------------------------------------------------------------------
run_diff_test() {
	local label=$1
	local api_args=$2

	echo "--- Test: DIFF $label ---"

	set +e
	container_exec bash -c "$PERL_EXE api --host http://localhost $api_args" \
		>"$LOG_DIR/test_output_perl.log" 2>/dev/null
	container_exec bash -c "$ZIG_EXE api --host http://localhost $api_args" \
		>"$LOG_DIR/test_output_zig.log" 2>/dev/null
	set -e

	# Normalise: strip all trailing newlines then add exactly one.
	{ printf '%s\n' "$(cat "$LOG_DIR/test_output_perl.log")"; } >"$LOG_DIR/test_output_perl_norm.log"
	{ printf '%s\n' "$(cat "$LOG_DIR/test_output_zig.log")"; } >"$LOG_DIR/test_output_zig_norm.log"

	if diff -u "$LOG_DIR/test_output_perl_norm.log" "$LOG_DIR/test_output_zig_norm.log" \
		>"$LOG_DIR/test_output_diff.log" 2>&1; then
		echo "PASS (outputs identical)"
	else
		echo "FAIL: Perl and Zig outputs differ:"
		cat "$LOG_DIR/test_output_diff.log"
		failed_tests=$((failed_tests + 1))
	fi
}
