#!/usr/bin/env bash
# lib_topology.sh — Topology job fixture helpers (chained, fanout, diamond, etc.)
#
# Extracted from lib.sh.  These functions are used exclusively by
# tests_clone_job.sh to set up multi-job dependency graphs for clone testing.
#
# Source this file explicitly in suites that need topology fixtures:
#
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_topology.sh"
#
# Provides:
#   schedule_topology_jobs()     — generic topology scheduler (POST /api/v1/isos)
#   schedule_chained_jobs()      — convenience wrapper for "chained" topology
#   ensure_chained_jobs()        — lazy-init CHAIN_PARENT_ID / CHAIN_CHILD_ID
#   ensure_fanout_jobs()         — lazy-init FANOUT_*_ID variables
#   ensure_multilayer_jobs()     — lazy-init LAYER_*_ID variables
#   ensure_deeplayer_jobs()      — lazy-init DEEPLAY_LAYER_*_ID variables
#   ensure_diamond_jobs()        — lazy-init DIAMOND_*_ID variables
#   ensure_parallel_jobs()       — lazy-init PARALLEL_*_ID variables
#   assert_job_has_chained_parent() — verify chained dependency assertion
#
# Dependencies: lib.sh and lib_fixtures.sh must be sourced first (provides
# container_exec, die, wait_for_job, _E2E_JOB_COMMON_ARGS, DRY_RUN, GROUP_ID).

# Guard against double-sourcing
[[ -n "${_OPENQA_E2E_LIB_TOPOLOGY_LOADED:-}" ]] && return 0
_OPENQA_E2E_LIB_TOPOLOGY_LOADED=1

# Ensure dependencies are loaded
if [[ -z "${_OPENQA_E2E_LIB_LOADED:-}" ]]; then
	source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
fi

# ---------------------------------------------------------------------------
# schedule_topology_jobs TOPOLOGY BUILD [EXTRA_ARGS...] — generic topology scheduler
#
# Posts to /api/v1/isos using /tmp/${TOPOLOGY}-scenario.yaml as the scenario
# definitions file.  Returns space-separated list of all created job IDs.
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
# schedule_chained_jobs BUILD — schedule chained jobs via POST /api/v1/isos
#
# Uses the cached chained-scenario-definitions.yaml.
# Returns space-separated list of all created job IDs.
# ---------------------------------------------------------------------------
schedule_chained_jobs() {
	schedule_topology_jobs "chained" "$1" "${@:2}"
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
# ensure_deeplayer_jobs — lazy-init DEEPLAY_LAYER_*_ID variables
#
# Schedules the 17-layer linear chain (layer_a → layer_b → … → layer_s;
# letters j and k are absent from the fixture YAML).
# Sets and exports DEEPLAY_LAYER_A_ID … DEEPLAY_LAYER_S_ID.
# Waits for the terminal node (layer_s) to reach a completed state so that
# --max-depth clone tests can immediately use all 17 jobs as source jobs.
# ---------------------------------------------------------------------------
ensure_deeplayer_jobs() {
	if [[ -n "${DEEPLAY_LAYER_A_ID:-}" && -n "${DEEPLAY_LAYER_S_ID:-}" ]]; then
		return 0
	fi

	local suffix suffix_upper
	if [[ "$DRY_RUN" == "true" ]]; then
		for suffix in a b c d e f g h i l m n o p q r s; do
			suffix_upper="${suffix^^}"
			eval "DEEPLAY_LAYER_${suffix_upper}_ID=1"
			export "DEEPLAY_LAYER_${suffix_upper}_ID"
		done
		echo "  [ensure] [DRY-RUN] DEEPLAY_LAYER_A_ID to DEEPLAY_LAYER_S_ID initialized" >&2
		return 0
	fi

	echo "  [ensure] Scheduling deeplayer jobs..." >&2
	local ids
	ids=$(schedule_topology_jobs "deeplayer" "deeplayer-seed")

	for id in $ids; do
		local test_name
		test_name=$(container_exec openqa-cli api --host http://localhost \
			"jobs/$id" 2>/dev/null | jq -r '.job.settings.TEST')
		if [[ "$test_name" =~ ^layer_([a-s])$ ]]; then
			suffix="${BASH_REMATCH[1]}"
			suffix_upper="${suffix^^}"
			eval "DEEPLAY_LAYER_${suffix_upper}_ID=\$id"
		fi
	done

	[[ -n "${DEEPLAY_LAYER_S_ID:-}" ]] || die "ensure_deeplayer_jobs: terminal child (layer_s) ID not found"

	echo "  [ensure] Deeplayer terminal child: $DEEPLAY_LAYER_S_ID — waiting..." >&2
	wait_for_job "$DEEPLAY_LAYER_S_ID" 600 >/dev/null || die "ensure_deeplayer_jobs: timeout waiting for terminal child"

	for suffix in a b c d e f g h i l m n o p q r s; do
		suffix_upper="${suffix^^}"
		export "DEEPLAY_LAYER_${suffix_upper}_ID"
	done
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
# start_worker2 — start worker instance 2 for parallel-topology tests
# stop_worker2  — gracefully stop worker instance 2
#
# Parallel jobs require two simultaneous workers. The standard test environment
# runs only worker instance 1. Call start_worker2 before ensure_parallel_jobs
# and stop_worker2 after the last parallel test to keep the extra worker
# scoped to the minimum necessary window.
# ---------------------------------------------------------------------------
start_worker2() {
	if [[ "$DRY_RUN" == "true" ]]; then
		echo "  [worker2] [DRY-RUN] start worker instance 2" >&2
		return 0
	fi
	echo "  [worker2] Starting worker instance 2..." >&2
	# Kill any stale worker 2 from a previous run. Run pkill directly (not inside
	# bash -c) so "worker --instance 2" doesn't appear in the bash process argv
	# and cause pkill to self-match via the parent's cmdline. pkill excludes its
	# own PID via getpid(), so direct invocation is safe.
	container_exec pkill -f 'worker --instance 2' 2>/dev/null || true
	sleep 1  # host-side: let the OS release the pool/2 flock before re-locking
	# Pre-create pool/2 with correct ownership; bootstrap only provisions pool/1
	# and _openqa-worker can't mkdir under the root-owned pool/ directory.
	container_exec mkdir -p /var/lib/openqa/pool/2
	container_exec chown _openqa-worker:_openqa-worker /var/lib/openqa/pool/2
	podman exec -d "$CONTAINER_NAME" \
		su _openqa-worker -c '/usr/share/openqa/script/worker --instance 2'
	local i count
	for i in {1..15}; do
		count=$(container_exec curl -sf http://localhost/admin/workers.json 2>/dev/null \
			| jq '[.workers[] | select(.alive == 1)] | length' 2>/dev/null || echo 0)
		if [[ "${count:-0}" -ge 2 ]]; then
			echo "  [worker2] Worker 2 registered after ${i}s." >&2
			return 0
		fi
		sleep 1
	done
	echo "  [worker2] WARNING: Worker 2 did not register within 15s — parallel tests may hang" >&2
}

stop_worker2() {
	if [[ "$DRY_RUN" == "true" ]]; then
		echo "  [worker2] [DRY-RUN] stop worker instance 2" >&2
		return 0
	fi
	echo "  [worker2] Stopping worker instance 2..." >&2
	container_exec pkill -f 'worker --instance 2' 2>/dev/null || true
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
