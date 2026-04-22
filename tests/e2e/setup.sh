#!/usr/bin/env bash
# setup.sh — Generic openQA single-instance container setup.
#
# Starts the container, waits for bootstrap, seeds test fixtures, and writes
# an env file that run.sh can source.
#
# Usage:
#   source tests/e2e/setup.sh [OPTIONS]
#   - or -
#   bash tests/e2e/setup.sh [OPTIONS] && source /tmp/openqa_e2e_env.sh
#
# OPTIONS:
#   --dryrun          Print commands without executing them.
#   --keep-container  Accepted for caller compatibility; setup.sh itself does
#                     not stop the container — that is run.sh's responsibility.
#   --expose-ports    [INTERNAL] Publish container ports 80->8080 and 443->8443.
#                     Forwarded automatically by run.sh when --keep-container is
#                     used. Not intended for direct invocation by users.
#   -h, --help        Show this help message and exit.
#
# Exports (written to /tmp/openqa_e2e_env.sh):
#   CONTAINER_NAME    — name of the running container
#   OPENQA_API_KEY    — API key extracted from /etc/openqa/client.conf
#   OPENQA_API_SECRET — API secret
#   JOB_ID            — scheduled job ID from seeding
#   ASSET_ID          — registered asset ID for Perl DELETE test
#   ZIG_ASSET_ID      — registered asset ID for Zig DELETE test
#   GROUP_ID          — job group ID from seeding

set -eo pipefail

# -----------------------------------------------------------------------------
# Source shared library
# -----------------------------------------------------------------------------
LOG_PREFIX="setup"
# shellcheck source=SCRIPTDIR/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
cd_to_project_root "${BASH_SOURCE[0]}"

# -----------------------------------------------------------------------------
# Argument Parsing
# -----------------------------------------------------------------------------
EXPOSE_PORTS=false

show_help() {
	cat <<'EOF'
# Starts the container, waits for bootstrap, seeds test fixtures, and writes
# an env file that run.sh can source.
#
# Usage:
#   source tests/e2e/setup.sh [OPTIONS]
#   - or -
#   bash tests/e2e/setup.sh [OPTIONS] && source /tmp/openqa_e2e_env.sh
#
# OPTIONS:
#   --dryrun          Print commands without executing them.
#   --keep-container  Accepted for caller compatibility; setup.sh itself does
#                     not stop the container — that is run.sh's responsibility.
#   --expose-ports    [INTERNAL] Publish container ports 80->8080 and 443->8443.
#                     Forwarded automatically by run.sh when --keep-container is
#                     used. Not intended for direct invocation by users.
#   -h, --help        Show this help message and exit.
#
# Exports (written to /tmp/openqa_e2e_env.sh):
#   CONTAINER_NAME    — name of the running container
#   OPENQA_API_KEY    — API key extracted from /etc/openqa/client.conf
#   OPENQA_API_SECRET — API secret
#   JOB_ID            — scheduled job ID from seeding
#   ASSET_ID          — registered asset ID for Perl DELETE test
#   ZIG_ASSET_ID      — registered asset ID for Zig DELETE test
#   GROUP_ID          — job group ID from seeding
EOF
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
	--keep-container)
		# No-op in setup.sh; accepted so run.sh can forward its own flags here.
		shift
		;;
	--expose-ports)
		EXPOSE_PORTS=true
		shift
		;;
	*)
		echo "Unknown parameter: $1" >&2
		exit 1
		;;
	esac
done

# (log() and ENV_FILE are provided by lib.sh)

# -----------------------------------------------------------------------------
# Entrypoint Wrapper
# Patches openqa-bootstrap to skip unnecessary steps and avoid zypper errors.
# -----------------------------------------------------------------------------
WRAPPER_TMP="/tmp/openqa-entrypoint-wrapper.sh"
log "Preparing entrypoint wrapper..."
if [[ "$DRY_RUN" == "true" ]]; then
	echo "[DRY-RUN] cat > $WRAPPER_TMP << 'WRAPPER_EOF' ... WRAPPER_EOF"
	echo "[DRY-RUN] chmod +x $WRAPPER_TMP"
else
	cat >"$WRAPPER_TMP" <<'WRAPPER_EOF'
#!/bin/bash
set -xeuo pipefail
zypper -n --gpg-auto-import-keys ref
zypper -n --gpg-auto-import-keys dup -y
# Install GNU time so /usr/bin/time -v is available for peak-RSS measurement
# in tests_perf.sh.  The base image does not include it. Also install gawk for metrics.
zypper -n --gpg-auto-import-keys install -y time gawk
BOOTSTRAP="/usr/share/openqa/script/openqa-bootstrap"
sed -i 's/zypper -n/zypper -n --gpg-auto-import-keys/g' "$BOOTSTRAP"
sed -i 's/ os-autoinst-distri-opensuse-deps//' "$BOOTSTRAP"
sed -i 's/pkgs+=(openQA-single-instance)/true/' "$BOOTSTRAP"
SPLIT_INSTALL="echo 1 | zypper -n --gpg-auto-import-keys install --no-recommends --force-resolution os-autoinst-distri-opensuse-deps openQA-single-instance"
sed -i "/install.*pkgs/a $SPLIT_INSTALL" "$BOOTSTRAP"
exec "$BOOTSTRAP" "$@"
WRAPPER_EOF
	chmod +x "$WRAPPER_TMP"
fi

# -----------------------------------------------------------------------------
# Container Start
# -----------------------------------------------------------------------------
log "Removing any stale container..."
run_cmd "podman rm -f $CONTAINER_NAME >/dev/null 2>&1 || true"

PORT_FLAGS=""
if [[ "$EXPOSE_PORTS" == "true" ]]; then
	PORT_FLAGS="-p 8080:80 -p 8443:443"
	log "Port forwarding enabled: http://localhost:8080 and https://localhost:8443"
fi

log "Starting openQA container ($CONTAINER_NAME)..."
KVM_FLAG=""
if [[ -e /dev/kvm ]]; then
	KVM_FLAG="--device /dev/kvm"
	log "KVM device found — enabling hardware virtualisation."
else
	log "WARNING: /dev/kvm not found — starting container without KVM (tests may be slower)."
fi
run_cmd "podman run -d --name $CONTAINER_NAME \
    $KVM_FLAG \
    -e skip_suse_specifics=1 \
    -e skip_suse_tests=1 \
    -v \"$WRAPPER_TMP\":/app/entrypoint-wrapper.sh:ro \
    -v \"\$(pwd)\":/app:z \
    -w /app \
    $PORT_FLAGS \
    --entrypoint /app/entrypoint-wrapper.sh \
    registry.opensuse.org/devel/openqa/containers/openqa-single-instance"

# -----------------------------------------------------------------------------
# Readiness Checks
# -----------------------------------------------------------------------------
if [[ "$DRY_RUN" == "true" ]]; then
	log "[DRY-RUN] Skipping readiness wait loops..."
	API_KEY="MOCK_KEY"
	API_SECRET="MOCK_SECRET"
else
	log "Waiting for container to reach 'running' state..."
	for i in {1..30}; do
		if podman inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -q "true"; then
			log "Container is running."
			break
		fi
		[[ "$i" -eq 30 ]] && die "Timeout waiting for container to start"
		sleep 2
	done

	log "Waiting for openQA bootstrap to finish (up to 15 minutes)..."
	for i in {1..450}; do
		! podman inspect -f '{{.State.Running}}' "$CONTAINER_NAME" >/dev/null 2>&1 &&
			die "Container stopped unexpectedly during bootstrap"
		if container_exec grep -q "\[localhost\]" /etc/openqa/client.conf 2>/dev/null; then
			log "openQA is ready! (after $((i * 2))s)"
			break
		fi
		[[ "$i" -eq 450 ]] && die "Timeout waiting for openQA bootstrap"
		[[ $((i % 30)) -eq 0 ]] && log "... still bootstrapping ($((i * 2))s elapsed) ..."
		sleep 2
	done

	# Extra grace period for the web server and Gru workers to be fully up
	log "Waiting 5s for web server and Gru workers to stabilise..."
	sleep 5
fi

# -----------------------------------------------------------------------------
# Credential Extraction
# -----------------------------------------------------------------------------
log "Extracting API credentials..."
if [[ "$DRY_RUN" == "true" ]]; then
	API_KEY="MOCK_KEY"
	API_SECRET="MOCK_SECRET"
else
	CONF_CONTENT=$(container_exec cat /etc/openqa/client.conf) || die "Could not read client.conf"
	API_KEY=$(echo "$CONF_CONTENT" | sed -n '/\[localhost\]/,/\[/p' | grep "^key" | head -n1 | cut -d'=' -f2 | tr -d ' ')
	API_SECRET=$(echo "$CONF_CONTENT" | sed -n '/\[localhost\]/,/\[/p' | grep "^secret" | head -n1 | cut -d'=' -f2 | tr -d ' ')
	[[ -n "$API_KEY" && -n "$API_SECRET" ]] || die "Could not extract credentials from client.conf"
	log "Credentials extracted: key=${API_KEY}"
fi

# -----------------------------------------------------------------------------
# Fixture Seeding
# -----------------------------------------------------------------------------
if [[ "$DRY_RUN" == "true" ]]; then
	log "[DRY-RUN] Skipping fixture seeding..."
	GROUP_ID="1"
else
	log "Running fixture seeding inside container..."
	container_exec bash /app/tests/e2e/seed_fixtures.sh ||
		die "seed_fixtures.sh failed — check container logs for details"

	log "Reading seeded IDs from container..."
	SEEDED=$(container_exec cat /tmp/seeded_ids.env) || die "Could not read /tmp/seeded_ids.env"
	GROUP_ID=$(echo "$SEEDED" | grep "^GROUP_ID=" | cut -d'=' -f2)
	log "Seeded: GROUP_ID=$GROUP_ID"
fi

# -----------------------------------------------------------------------------
# Write Environment File
# -----------------------------------------------------------------------------
if [[ "$DRY_RUN" == "true" ]]; then
	echo "[DRY-RUN] cat > $ENV_FILE << EOF ... EOF"
else
	cat >"$ENV_FILE" <<EOF
# Auto-generated by tests/e2e/setup.sh — do not edit manually.
export CONTAINER_NAME="$CONTAINER_NAME"
export OPENQA_API_KEY="$API_KEY"
export OPENQA_API_SECRET="$API_SECRET"
export GROUP_ID="$GROUP_ID"
EOF
fi
log "Environment written to $ENV_FILE"

if [[ "$EXPOSE_PORTS" == "true" ]]; then
	log ""
	log "  openQA web UI is available at:"
	log "    http://localhost:8080"
	log "    https://localhost:8443"
	log ""
	log "  To stop the container manually:"
	log "    podman rm -f $CONTAINER_NAME"
fi
