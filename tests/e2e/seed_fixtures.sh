#!/usr/bin/env bash
# seed_fixtures.sh — Seeds the running openQA container with test data.
#
# Designed to be called from setup.sh via:
#   podman exec openqa-e2e bash /app/tests/e2e/seed_fixtures.sh
#
# Writes /tmp/seeded_ids.env inside the container with:
#   JOB_ID=<id>
#   ASSET_ID=<id>
#   GROUP_ID=<id>
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
	sed -n '4,17p' "${BASH_SOURCE[0]}"
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
# 6. Schedule jobs via POST /api/v1/isos with inline SCENARIO_DEFINITIONS_YAML
# ---------------------------------------------------------------------------
log "Reading scenario-definitions.yaml..."
if [[ "$DRY_RUN" == "false" ]]; then
	[[ -f "$FIXTURE_DIR/scenario-definitions.yaml" ]] ||
		die "scenario-definitions.yaml not found at $FIXTURE_DIR"
	SCENARIO_YAML=$(cat "$FIXTURE_DIR/scenario-definitions.yaml")
else
	SCENARIO_YAML="[DRY-RUN placeholder]"
fi

log "Scheduling basic dummy job via POST /api/v1/isos..."
if [[ "$DRY_RUN" == "true" ]]; then
	echo "[DRY-RUN] $CLI -X POST isos DISTRI=example VERSION=0 FLAVOR=DVD ARCH=x86_64 BUILD=e2e-test ISO=$ISO_NAME ..."
	JOB_ID=1
else
	ISO_RESPONSE=$(
		$CLI -X POST isos \
			DISTRI=example \
			VERSION=0 \
			FLAVOR=DVD \
			ARCH=x86_64 \
			BUILD=e2e-test \
			ISO="$ISO_NAME" \
			CASEDIR="https://github.com/os-autoinst/os-autoinst-distri-example.git#main" \
			NEEDLES_DIR="%%CASEDIR%%/needles" \
			"_GROUP_ID=$GROUP_ID" \
			"SCENARIO_DEFINITIONS_YAML=$SCENARIO_YAML" \
			2>/dev/null
	) || die "POST /api/v1/isos failed"

	log "POST /api/v1/isos response: $ISO_RESPONSE"

	JOB_ID=$(echo "$ISO_RESPONSE" | jq '.ids[0] // empty')
	[[ -n "$JOB_ID" ]] || {
		log "WARNING: No job IDs in response. Trying to find any existing job..."
		JOB_ID=$($CLI jobs 2>/dev/null | jq '.jobs[0].id // empty')
	}
	[[ -n "$JOB_ID" ]] || die "Could not obtain any JOB_ID"
fi
log "JOB_ID=$JOB_ID"

log "Scheduling RICH job via POST /api/v1/isos..."
if [[ "$DRY_RUN" == "true" ]]; then
	echo "[DRY-RUN] $CLI -X POST isos ... HDD_1=$CIRROS_IMG ISO_1=$SEED_ISO BUILD=e2e-test-rich ..."
	RICH_JOB_ID=2
else
	RICH_RESPONSE=$(
		$CLI -X POST isos \
			DISTRI=example \
			VERSION=0 \
			FLAVOR=DVD \
			ARCH=x86_64 \
			BUILD=e2e-test-rich \
			HDD_1="$CIRROS_IMG" \
			ISO_1="$SEED_ISO" \
			CASEDIR="/var/lib/openqa/share/tests/cirros" \
			NEEDLES_DIR="%CASEDIR%/needles" \
			"_GROUP_ID=$GROUP_ID" \
			"SCENARIO_DEFINITIONS_YAML=$SCENARIO_YAML" \
			2>/dev/null
	) || die "POST /api/v1/isos (rich) failed"

	log "POST /api/v1/isos (rich) response: $RICH_RESPONSE"
	RICH_JOB_ID=$(echo "$RICH_RESPONSE" | jq '.ids[0] // empty')
	[[ -n "$RICH_JOB_ID" ]] || die "Could not obtain RICH_JOB_ID"
fi
log "RICH_JOB_ID=$RICH_JOB_ID"

# ---------------------------------------------------------------------------
# 7. Wait for RICH job to reach terminal state
# ---------------------------------------------------------------------------
log "Waiting for rich job $RICH_JOB_ID to complete (up to 5 minutes)..."
if [[ "$DRY_RUN" == "false" ]]; then
	for i in {1..150}; do
		JOB_STATE=$($CLI jobs/"$RICH_JOB_ID" 2>/dev/null | jq -r '.job.state // empty')
		log "Job $RICH_JOB_ID state: $JOB_STATE ($((i * 2))s elapsed)"
		if [[ "$JOB_STATE" == "done" || "$JOB_STATE" == "cancelled" || "$JOB_STATE" == "failed" ]]; then
			log "Rich job $RICH_JOB_ID reached terminal state: $JOB_STATE"
			break
		fi
		[[ "$i" -eq 150 ]] && die "Timeout waiting for rich job $RICH_JOB_ID to complete"
		sleep 2
	done
else
	log "[DRY-RUN] Skipping job completion wait."
fi

# ---------------------------------------------------------------------------
# 8. Register two dummy assets for the DELETE tests (one for Perl, one for Zig)
# ---------------------------------------------------------------------------
log "Fetching asset ID for $ISO_NAME..."
if [[ "$DRY_RUN" == "true" ]]; then
	echo "[DRY-RUN] sleep 3 && $CLI assets | jq '...'"
	ASSET_ID=1
	ZIG_ASSET_ID=2
else
	# Give openQA a moment to register the ISO asset after scheduling
	sleep 3
	ASSETS_JSON=$($CLI assets 2>/dev/null) || die "Could not GET assets"
	ASSET_ID=$(echo "$ASSETS_JSON" | jq --arg name "$ISO_NAME" \
		'.assets[] | select(.name == $name) | .id // empty' | head -1)

	if [[ -z "$ASSET_ID" ]]; then
		log "ISO asset not yet registered, creating a separate 'other' asset for Perl DELETE test..."
		OTHER_DIR="/var/lib/openqa/share/factory/other"
		mkdir -p "$OTHER_DIR"
		touch "$OTHER_DIR/delete-me.tar.gz"
		# Trigger asset registration via the admin cleanup endpoint
		$CLI -X POST assets/cleanup >/dev/null 2>&1 || true
		sleep 2
		ASSETS_JSON=$($CLI assets 2>/dev/null) || die "Could not GET assets (retry)"
		ASSET_ID=$(echo "$ASSETS_JSON" | jq \
			'.assets[] | select(.name == "delete-me.tar.gz") | .id // empty' | head -1)
	fi

	[[ -n "$ASSET_ID" ]] || {
		log "WARNING: Could not obtain ASSET_ID for Perl DELETE test. DELETE test will be skipped."
		ASSET_ID="SKIP"
	}

	# Create a second ISO asset exclusively for the Zig DELETE test by scheduling
	# a second job that references a distinct ISO file.
	log "Creating second ISO asset for Zig DELETE test..."
	ISO2_NAME="dummy2.iso"
	touch "$ISO_DIR/$ISO2_NAME"
	$CLI -X POST isos \
		DISTRI=example \
		VERSION=0 \
		FLAVOR=DVD \
		ARCH=x86_64 \
		BUILD=e2e-test-zig \
		ISO="$ISO2_NAME" \
		"_GROUP_ID=$GROUP_ID" \
		>/dev/null 2>&1 || true
	sleep 3
	ASSETS_JSON=$($CLI assets 2>/dev/null) || die "Could not GET assets (zig asset)"
	ZIG_ASSET_ID=$(echo "$ASSETS_JSON" | jq --arg name "$ISO2_NAME" \
		'.assets[] | select(.name == $name) | .id // empty' | head -1)
	[[ -n "$ZIG_ASSET_ID" ]] || {
		log "WARNING: Could not obtain ZIG_ASSET_ID. Zig DELETE test will be skipped."
		ZIG_ASSET_ID="SKIP"
	}
fi
log "ASSET_ID=$ASSET_ID"
log "ZIG_ASSET_ID=$ZIG_ASSET_ID"

# ---------------------------------------------------------------------------
# 9. Write seeded IDs to env file
# ---------------------------------------------------------------------------
log "Writing $IDS_FILE..."
if [[ "$DRY_RUN" == "true" ]]; then
	echo "[DRY-RUN] cat > $IDS_FILE << EOF ... EOF"
else
	cat >"$IDS_FILE" <<EOF
JOB_ID=$JOB_ID
RICH_JOB_ID=$RICH_JOB_ID
ASSET_ID=$ASSET_ID
ZIG_ASSET_ID=$ZIG_ASSET_ID
GROUP_ID=$GROUP_ID
EOF
	log "Seeding complete."
	cat "$IDS_FILE"
fi
