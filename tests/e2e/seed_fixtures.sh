#!/usr/bin/env bash
# seed_fixtures.sh — Seeds the running openQA container with infrastructure.
#
# Sets up templates, images, and the test distribution so that test suites
# can schedule jobs on demand via lib.sh helper functions (ensure_basic_job,
# ensure_rich_job, schedule_job, etc.).  This script does NOT schedule any
# openQA jobs — that responsibility belongs to the individual test suites.
#
# Designed to be called from setup.sh via:
#   podman exec openqa-e2e bash /app/tests/e2e/seed_fixtures.sh
#
# Writes /tmp/seeded_ids.env inside the container with:
#   GROUP_ID=<id>
#
# Writes /tmp/scenario.yaml inside the container (cached for schedule_job).
#
# OPTIONS:
#   --dryrun    Print commands without executing them.
#   -h, --help  Show this help message and exit.
#
# Requires: jq, openqa-cli, /etc/openqa/client.conf already populated.

set -eo pipefail

# -----------------------------------------------------------------------------
# Source shared library (container path)
# -----------------------------------------------------------------------------
LOG_PREFIX="seed"
# shellcheck source=SCRIPTDIR/lib.sh
# shellcheck disable=SC1091  # lib.sh is only reachable at the container path /app/...
source /app/tests/e2e/lib.sh

# -----------------------------------------------------------------------------
# Argument Parsing
# -----------------------------------------------------------------------------
show_help() {
	sed -n '4,22p' "${BASH_SOURCE[0]}"
}

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
	*)
		echo "Unknown parameter: $1" >&2
		exit 1
		;;
	esac
done

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------
CLI="openqa-cli api --host http://localhost"
FIXTURE_DIR="/app/tests/e2e/fixtures"
IDS_FILE="/tmp/seeded_ids.env"
# (log() is provided by lib.sh; LOG_PREFIX is set to "seed" above)

# ---------------------------------------------------------------------------
# 1. Load templates (Machines, TestSuites, Products, JobGroups) from JSON
# ---------------------------------------------------------------------------
log "Loading templates from fixtures/templates.json..."
if [[ "$DRY_RUN" == "true" ]]; then
	echo "[DRY-RUN] openqa-load-templates --host http://localhost $FIXTURE_DIR/templates.json"
	LOAD_OUT="[DRY-RUN skipped]"
else
	LOAD_OUT=$(openqa-load-templates --host http://localhost "$FIXTURE_DIR/templates.json" 2>&1) || true
fi
log "openqa-load-templates output: $LOAD_OUT"

# ---------------------------------------------------------------------------
# 2. Verify we have at least 3 machines (needed for pagination test)
# ---------------------------------------------------------------------------
log "Verifying machines were loaded..."
if [[ "$DRY_RUN" == "true" ]]; then
	echo "[DRY-RUN] $CLI machines | jq '.Machines | length'"
	MACHINE_COUNT=3
else
	MACHINES_JSON=$($CLI machines 2>/dev/null) || die "Could not GET machines"
	MACHINE_COUNT=$(echo "$MACHINES_JSON" | jq '.Machines | length')
fi
log "Machine count: $MACHINE_COUNT"
[[ "$DRY_RUN" == "true" || "$MACHINE_COUNT" -ge 3 ]] ||
	die "Expected >=3 machines, got $MACHINE_COUNT — check templates.json"

# ---------------------------------------------------------------------------
# 3. Capture the job group ID
# ---------------------------------------------------------------------------
log "Fetching job group ID..."
if [[ "$DRY_RUN" == "true" ]]; then
	echo "[DRY-RUN] $CLI job_groups | jq '...' "
	GROUP_ID=1
else
	GROUPS_JSON=$($CLI job_groups 2>/dev/null) || die "Could not GET job_groups"
	GROUP_ID=$(echo "$GROUPS_JSON" | jq '[.[] | select(.name == "example")] | .[0].id // empty')
	[[ -n "$GROUP_ID" ]] || die "Job group 'example' not found after template load"
fi
log "GROUP_ID=$GROUP_ID"

# ---------------------------------------------------------------------------
# 4. Create a dummy ISO asset file
# ---------------------------------------------------------------------------
ISO_DIR="/var/lib/openqa/share/factory/iso"
ISO_NAME="dummy.iso"
log "Creating dummy ISO at $ISO_DIR/$ISO_NAME..."
run_cmd "mkdir -p $ISO_DIR"
run_cmd "touch $ISO_DIR/$ISO_NAME"

# ---------------------------------------------------------------------------
# 5. Verify CirrOS image for Rich Job
#
# The actual download happens on the host (in setup.sh) and is injected via
# podman cp before this script runs.  We just verify it arrived.
# ---------------------------------------------------------------------------
HDD_DIR="/var/lib/openqa/share/factory/hdd"

if [[ "$DRY_RUN" == "false" ]]; then
	if [[ ! -f "$HDD_DIR/$CIRROS_IMG" ]]; then
		die "CirrOS image not found at $HDD_DIR/$CIRROS_IMG — setup.sh should have injected it"
	fi
	log "CirrOS image present at $HDD_DIR/$CIRROS_IMG"
else
	echo "[DRY-RUN] test -f $HDD_DIR/$CIRROS_IMG"
fi

# ---------------------------------------------------------------------------
# 5b. Create NoCloud seed ISO to skip CirrOS metadata service timeout
# ---------------------------------------------------------------------------
SEED_ISO="seed-nocloud.iso"
log "Creating NoCloud seed ISO at $ISO_DIR/$SEED_ISO..."
if [[ "$DRY_RUN" == "false" ]]; then
	if [[ ! -f "$ISO_DIR/$SEED_ISO" ]]; then
		CIDATA_TMP=$(mktemp -d)
		echo '{ "instance-id": "nocloud" }' >"$CIDATA_TMP/meta-data"
		printf '#!/bin/sh\n' >"$CIDATA_TMP/user-data"
		run_cmd "mkisofs -output $ISO_DIR/$SEED_ISO -volid cidata -joliet -rock -input-charset utf-8 $CIDATA_TMP/meta-data $CIDATA_TMP/user-data >/dev/null 2>&1"
		rm -rf "$CIDATA_TMP"
	else
		log "NoCloud seed ISO already exists, skipping."
	fi
else
	echo "[DRY-RUN] mkisofs -output $ISO_DIR/$SEED_ISO -volid cidata ..."
fi

# ---------------------------------------------------------------------------
# 5c. Install custom CirrOS test distribution
# ---------------------------------------------------------------------------
log "Installing custom CirrOS test distribution..."
if [[ "$DRY_RUN" == "false" ]]; then
	run_cmd "mkdir -p $CIRROS_TESTDIR"
	run_cmd "cp -a $FIXTURE_DIR/cirros-distri/* $CIRROS_TESTDIR/"
	run_cmd "chown -R geekotest:geekotest $CIRROS_TESTDIR"
else
	echo "[DRY-RUN] cp -a $FIXTURE_DIR/cirros-distri/* $CIRROS_TESTDIR/"
fi

# ---------------------------------------------------------------------------
# 6. Cache scenario-definitions.yaml for use by lib.sh schedule_job()
#
# In openQA, scheduling a set of tests isn't just about scheduling single standalone jobs;
# it involves orchestrating complex multi-job   dependencies (topologies) such as:
#   * Chained Jobs: Job B starts only after Job A finishes successfully (_START_AFTER).
#   * Fan-out: A parent job triggers multiple parallel sibling child jobs.
#   * Multi-layer (Ancestral): Multi-depth dependency chains (Grandparent → Parent → Child).
#   * Diamond / Merge Topologies: Two independent branch jobs (Left and Right)
#     merging back into a single terminal synchronization point (Merge).
#   * Parallel clusters: Simultaneous multi-worker execution.
#
#  To schedule these configurations via openQA’s ISO-triggering endpoint (POST /api/v1/isos),
#  you must feed the API a YAML payload containing the
#  Scenario Definitions (representing your test templates and structures).
#
#  Copied scenarios will be used to trigger groups of jobs by schedule_topology_jobs
# ---------------------------------------------------------------------------
log "Caching scenario-definitions to container storage..."
[[ "$DRY_RUN" == "true" ]] || [[ -f "$FIXTURE_DIR/scenario-definitions.yaml" ]] || \
	die "scenario-definitions.yaml not found at $FIXTURE_DIR"

for src_path in "$FIXTURE_DIR"/*scenario-definitions.yaml; do
	[[ -f "$src_path" ]] || continue
	filename=$(basename "$src_path")

	# Determine destination path
	if [[ "$filename" == "scenario-definitions.yaml" ]]; then
		dest_path="$_SCENARIO_YAML_PATH"
	else
		# Map e.g. chained-scenario-definitions.yaml -> /tmp/chained-scenario.yaml
		base_name="${filename%-definitions.yaml}"
		dest_path="/tmp/${base_name}.yaml"
	fi

	if [[ "$DRY_RUN" == "true" ]]; then
		echo "[DRY-RUN] cp $src_path $dest_path"
	else
		cp "$src_path" "$dest_path"
	fi
done

# ---------------------------------------------------------------------------
# 7. Write seeded IDs to env file
# ---------------------------------------------------------------------------
log "Writing $IDS_FILE..."
if [[ "$DRY_RUN" == "true" ]]; then
	echo "[DRY-RUN] cat > $IDS_FILE << EOF ... EOF"
else
	cat >"$IDS_FILE" <<EOF
GROUP_ID=$GROUP_ID
EOF
fi

# ---------------------------------------------------------------------------
# 8. Setup Additional Workers
# ---------------------------------------------------------------------------
log "Setting up additional openQA worker (instance 2)..."
if [[ "$DRY_RUN" == "false" ]]; then
	cat <<EOF >> /etc/openqa/workers.ini

[2]
WORKER_CLASS = qemu_x86_64,qemu_i686,qemu_i586
EOF
	install -d -m 0755 -o _openqa-worker /var/lib/openqa/pool/2
	su _openqa-worker -c "/usr/share/openqa/script/worker --instance 2 &"
else
	echo "[DRY-RUN] Setting up worker instance 2..."
fi

if [[ "$DRY_RUN" == "false" ]]; then
	log "Seeding complete."
	cat "$IDS_FILE"
fi
