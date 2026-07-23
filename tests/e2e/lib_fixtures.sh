#!/usr/bin/env bash
# lib_fixtures.sh — Job scheduling, waiting, and fixture management helpers.
#
# Extracted from lib.sh to separate job-orchestration concerns from universal
# primitives.  Sourced automatically by lib.sh — do NOT source directly.
#
# Provides:
#   schedule_job()          — POST /api/v1/isos, prints job ID
#   wait_for_job()          — poll until terminal state, prints state
#   cancel_job()            — POST cancel for a job
#   get_job_state()         — query and print a job's state
#   _ensure_job()           — generic lazy-init for any named job variable
#   _E2E_JOB_COMMON_ARGS   — shared schedule_job args (DISTRI/FLAVOR/ARCH/…)
#   dump_job_logs()         — fetch and print per-job diagnostics on failure
#   register_deletable_asset() — create a file-backed asset, prints asset ID
#   ensure_basic_job()      — lazy-init JOB_ID
#   ensure_rich_job()       — lazy-init RICH_JOB_ID
#   ensure_stress_job()     — lazy-init STRESS_JOB_ID
#
# Dependencies: lib.sh must be sourced first (provides container_exec, die,
# e2e_sleep, DRY_RUN, CIRROS_IMG, CIRROS_TESTDIR, LOG_PREFIX).

# Guard against double-sourcing
[[ -n "${_OPENQA_E2E_LIB_FIXTURES_LOADED:-}" ]] && return 0
_OPENQA_E2E_LIB_FIXTURES_LOADED=1

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
	HDD_1="$CIRROS_IMG"
	ISO_1="seed-nocloud.iso"
	CASEDIR="$CIRROS_TESTDIR"
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
		echo "_ensure_job var_name:${var_name} already defined ${!var_name}"
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
		CASEDIR="$CIRROS_TESTDIR" \
		NEEDLES_DIR="%CASEDIR%/needles" \
		STRESSTEST=1 \
		STRESS_STEPS="$stress_steps" \
		STRESS_TEXT_SIZE="$stress_text_size" \
		"_GROUP_ID=${GROUP_ID:-1}"
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
# Fault Proxy Helpers (Stateful Reverse Proxy for testing retry logic)
# ===========================================================================
FAULTPROXY_PORT="9797"
FAULTPROXY_COUNT_FILE="/tmp/faultproxy_counts.txt"
FAULTPROXY_LOG="/tmp/faultproxy_proxy.log"
FAULTPROXY_SCRIPT="/app/tests/e2e/fixtures/faultproxy.py"

# Usage: start_faultproxy [FAIL_TIMES] [FAULT_MODE] [FAULT_PATH] [PARTIAL_BYTES]
# Defaults: FAIL_TIMES=2, FAULT_MODE=503, FAULT_PATH=/tests/, PARTIAL_BYTES=64
start_faultproxy() {
	local fail_times="${1:-2}"
	local mode="${2:-503}"
	local fault_path="${3:-/tests/}"
	local partial_bytes="${4:-64}"

	if [[ "$DRY_RUN" == "true" ]]; then
		echo "[DRY-RUN] start_faultproxy $fail_times $mode $fault_path $partial_bytes"
		return 0
	fi

	# Kill any leftover proxy from a previous sub-test.
	# Pattern anchored to ^python3 so pkill never matches the bash -c process
	# that runs this very pkill command (which would otherwise exit 137).
	container_exec bash -c 'pkill -9 -f "^python3 .*faultproxy" 2>/dev/null || true'
	container_exec bash -c "truncate -s 0 ${FAULTPROXY_COUNT_FILE} 2>/dev/null || true"

	# Use podman exec -d (detached) so this call returns immediately.
	# container_exec blocks until all descendants exit on cgroup-v2 systems.
	podman exec -d "$CONTAINER_NAME" bash -c \
		"python3 ${FAULTPROXY_SCRIPT} \
		 --port ${FAULTPROXY_PORT} \
		 --backend http://127.0.0.1:80 \
		 --fault-path ${fault_path} \
		 --fault-mode ${mode} \
		 --fail-times ${fail_times} \
		 --partial-bytes ${partial_bytes} \
		 --count-file ${FAULTPROXY_COUNT_FILE} \
		 >${FAULTPROXY_LOG} 2>&1"
	sleep 1 # wait for the proxy socket to be ready
}

# Stop the proxy process.
stop_faultproxy() {
	if [[ "$DRY_RUN" == "true" ]]; then
		echo "[DRY-RUN] stop_faultproxy"
		return 0
	fi
	container_exec bash -c 'pkill -9 -f "^python3 .*faultproxy" 2>/dev/null || true'
}

# Get proxy hit count for the given path pattern.
get_faultproxy_hits() {
	local pattern=$1
	if [[ "$DRY_RUN" == "true" ]]; then
		echo "0"
		return 0
	fi
	container_exec bash -c \
		"grep -c '${pattern}' ${FAULTPROXY_COUNT_FILE} 2>/dev/null || echo 0"
}

# Dump the fault proxy log file for troubleshooting in case of test failures.
dump_faultproxy_logs() {
	echo "=== FAULT PROXY LOGS (${FAULTPROXY_LOG}) ===" >&2
	container_exec cat "${FAULTPROXY_LOG}" 2>/dev/null || echo "(no proxy log found)" >&2
	echo "============================================" >&2
}

# Reset the proxy in-memory hit counts by truncating its log file.
# Works via the self-resetting file check, avoiding slow and flaky process restarts.
reset_faultproxy() {
	if [[ "$DRY_RUN" == "true" ]]; then
		echo "[DRY-RUN] reset_faultproxy"
		return 0
	fi
	container_exec bash -c "truncate -s 0 ${FAULTPROXY_COUNT_FILE} 2>/dev/null || true"
}
