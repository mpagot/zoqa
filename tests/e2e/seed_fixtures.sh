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

log() { echo "[seed] $*"; }

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
# 5. Download CirrOS image for Rich Job
# ---------------------------------------------------------------------------
HDD_DIR="/var/lib/openqa/share/factory/hdd"
CIRROS_ORIG="cirros-0.6.3-x86_64-disk.img"
CIRROS_IMG="cirros-0.6.3-x86_64-disk.qcow2"
CIRROS_URL="https://download.cirros-cloud.net/0.6.3/${CIRROS_ORIG}"

log "Downloading CirrOS image to $HDD_DIR/$CIRROS_IMG..."
run_cmd "mkdir -p $HDD_DIR"
if [[ "$DRY_RUN" == "false" ]]; then
	if [[ ! -f "$HDD_DIR/$CIRROS_IMG" ]]; then
		run_cmd "curl -sS -L -o $HDD_DIR/$CIRROS_ORIG $CIRROS_URL"
		# Rename to .qcow2 so os-autoinst's deduce_driver detects the
		# backing format correctly (it keys on file extension, not content).
		run_cmd "mv $HDD_DIR/$CIRROS_ORIG $HDD_DIR/$CIRROS_IMG"
	else
		log "CirrOS image already exists, skipping download."
	fi
else
	echo "[DRY-RUN] curl -sS -L -o $HDD_DIR/$CIRROS_ORIG $CIRROS_URL"
	echo "[DRY-RUN] mv $HDD_DIR/$CIRROS_ORIG $HDD_DIR/$CIRROS_IMG"
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
	run_cmd "mkdir -p /var/lib/openqa/share/tests/cirros"
	run_cmd "cp -a $FIXTURE_DIR/cirros-distri/* /var/lib/openqa/share/tests/cirros/"
	run_cmd "chown -R geekotest:geekotest /var/lib/openqa/share/tests/cirros"
else
	echo "[DRY-RUN] cp -a $FIXTURE_DIR/cirros-distri/* /var/lib/openqa/share/tests/cirros/"
fi

# ---------------------------------------------------------------------------
# 6. Cache scenario-definitions.yaml for use by lib.sh schedule_job()
# ---------------------------------------------------------------------------
log "Caching scenario-definitions.yaml to /tmp/scenario.yaml..."
if [[ "$DRY_RUN" == "false" ]]; then
	[[ -f "$FIXTURE_DIR/scenario-definitions.yaml" ]] ||
		die "scenario-definitions.yaml not found at $FIXTURE_DIR"
	cp "$FIXTURE_DIR/scenario-definitions.yaml" /tmp/scenario.yaml
else
	echo "[DRY-RUN] cp $FIXTURE_DIR/scenario-definitions.yaml /tmp/scenario.yaml"
fi

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
	log "Seeding complete."
	cat "$IDS_FILE"
fi
