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
# shellcheck source=tests/e2e/lib.sh
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

log() { echo "[seed] $*" >&2; }

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
# 5. Schedule jobs via POST /api/v1/isos with inline SCENARIO_DEFINITIONS_YAML
# ---------------------------------------------------------------------------
log "Reading scenario-definitions.yaml..."
if [[ "$DRY_RUN" == "false" ]]; then
	[[ -f "$FIXTURE_DIR/scenario-definitions.yaml" ]] ||
		die "scenario-definitions.yaml not found at $FIXTURE_DIR"
	SCENARIO_YAML=$(cat "$FIXTURE_DIR/scenario-definitions.yaml")
else
	SCENARIO_YAML="[DRY-RUN placeholder]"
fi

log "Scheduling jobs via POST /api/v1/isos..."
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

# ---------------------------------------------------------------------------
# 6. Register two dummy assets for the DELETE tests (one for Perl, one for Zig)
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
# 7. Write seeded IDs to env file
# ---------------------------------------------------------------------------
log "Writing $IDS_FILE..."
if [[ "$DRY_RUN" == "true" ]]; then
	echo "[DRY-RUN] cat > $IDS_FILE << EOF ... EOF"
else
	cat >"$IDS_FILE" <<EOF
JOB_ID=$JOB_ID
ASSET_ID=$ASSET_ID
ZIG_ASSET_ID=$ZIG_ASSET_ID
GROUP_ID=$GROUP_ID
EOF
	log "Seeding complete."
	cat "$IDS_FILE" >&2
fi
