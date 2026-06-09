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
zypper -n --gpg-auto-import-keys install -y time
BOOTSTRAP="/usr/share/openqa/script/openqa-bootstrap"
sed -i 's/zypper -n/zypper -n --gpg-auto-import-keys/g' "$BOOTSTRAP"
sed -i 's/ os-autoinst-distri-opensuse-deps//' "$BOOTSTRAP"
sed -i 's/pkgs+=(openQA-single-instance)/true/' "$BOOTSTRAP"
SPLIT_INSTALL="echo 1 | zypper -n --gpg-auto-import-keys install --no-recommends --force-resolution os-autoinst-distri-opensuse-deps openQA-single-instance"
sed -i "/install.*pkgs/a $SPLIT_INSTALL" "$BOOTSTRAP"

# ---------------------------------------------------------------------------
# Force Fake authentication (HMAC-SHA1 enforcement).
#
# WHY: The primary goal of these E2E tests is to validate that zoqa correctly
# constructs HMAC-SHA1 signatures, passes credentials from config/flags/env,
# and handles authentication errors (401/403).  For these tests to be
# meaningful, the openQA server MUST enforce credential validation — it must
# reject requests with missing or invalid signatures and accept only properly
# signed ones.  Without real enforcement, auth tests would always pass
# regardless of whether zoqa actually sends correct credentials.
#
# WHAT CHANGED: upstream commit e49241b (2026-05-18, os-autoinst/openQA#7297)
# changed openqa-bootstrap to use "method = None" instead of "method = Fake".
# With None auth the server accepts ANY request without validating HMAC
# signatures — the server does not check credentials at all.  This was done
# to simplify the default developer experience, but it breaks our E2E
# authentication test suite (tests_auth.sh) which relies on the server
# actually verifying HMAC signatures against real keys stored in the database.
#
# HOW WE FIX IT: Since `zypper dup` above pulls the latest packages (which
# include this change), the bootstrap will write 01-enable-none-auth.ini with
# method=None.  We counteract by pre-writing a higher-priority INI file (99-*)
# that sets method=Fake.  openQA reads .ini.d/ files in alphabetical order;
# the last [auth] section wins, so 99-force-fake-auth.ini overrides any
# 01-enable-*.ini written by the bootstrap.
#
# HOW FAKE AUTH WORKS: With Fake auth, hitting /login triggers Auth::Fake to
# create a "Demo" user (admin + operator) and inserts an API key into the
# database.  The key/secret default to 1234567890ABCDEF (overridable via
# OPENQA_FAKE_AUTH_KEY and OPENQA_FAKE_AUTH_SECRET env vars).  The HMAC
# signature is then validated on every subsequent API request — exactly what
# we need for E2E testing of zoqa's credential handling.
# ---------------------------------------------------------------------------
mkdir -p /etc/openqa/openqa.ini.d
echo -e "[auth]\nmethod = Fake" > /etc/openqa/openqa.ini.d/99-force-fake-auth.ini

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

	log "Waiting for openQA web UI to respond (up to 15 minutes)..."
	for i in {1..450}; do
		! podman inspect -f '{{.State.Running}}' "$CONTAINER_NAME" >/dev/null 2>&1 &&
			die "Container stopped unexpectedly during bootstrap"
		if container_exec curl -sf -o /dev/null http://localhost/ 2>/dev/null; then
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
# Credential Setup (Fake auth)
#
# With method=Fake, hitting /login creates the "Demo" user (admin+operator) and
# inserts an API key into the database.  The key/secret default to the constant
# 1234567890ABCDEF (see lib/OpenQA/WebAPI/Auth/Fake.pm).  We then write
# client.conf ourselves so that openqa-cli and other in-container tools can
# authenticate.  The HMAC signature is validated server-side on every request.
# -----------------------------------------------------------------------------
log "Triggering Fake auth login to create Demo user and API key in DB..."
if [[ "$DRY_RUN" == "true" ]]; then
	API_KEY="MOCK_KEY"
	API_SECRET="MOCK_SECRET"
else
	# Trigger /login — Auth::Fake creates Demo user + inserts API key into DB
	container_exec curl -sf http://localhost/login >/dev/null ||
		die "Could not trigger /login for Fake auth credential creation"
	API_KEY="1234567890ABCDEF"
	API_SECRET="1234567890ABCDEF"

	# Write client.conf so that openqa-cli (Perl reference) can authenticate
	# inside the container.  This file is also used by openqa-clone-job.
	container_exec bash -c "cat > /etc/openqa/client.conf <<'CCONF'
[localhost]
key = ${API_KEY}
secret = ${API_SECRET}
CCONF"
	log "Credentials configured: key=${API_KEY} (Fake auth, HMAC enforced)"
fi

# -----------------------------------------------------------------------------
# Restart openqa-worker
#
# WHY: openqa-bootstrap starts `worker --instance 1` immediately after the web
# stack is up. With our Fake-auth override (99-force-fake-auth.ini, written by
# the entrypoint wrapper *before* bootstrap), the web UI enforces HMAC from
# the first request — but at that point /etc/openqa/client.conf does not yet
# exist and the API key has not been inserted into the DB (that happens when
# /login is hit, which we only did just above). The bootstrap-launched worker
# therefore gets a 403 "no api key" on its first registration attempt and
# exits permanently. Without this restart, /admin/workers is empty and every
# scheduled job sits in 'scheduled' forever.
# -----------------------------------------------------------------------------
if [[ "$DRY_RUN" == "true" ]]; then
	log "[DRY-RUN] Skipping openqa-worker restart..."
else
	log "Starting openqa-worker (bootstrap's initial worker died before credentials existed)..."
	# Detached exec so the worker keeps running after this command returns
	podman exec -d "$CONTAINER_NAME" \
		su _openqa-worker -c '/usr/share/openqa/script/worker --instance 1'
	for i in {1..15}; do
		if container_exec curl -sf http://localhost/admin/workers.json 2>/dev/null | grep -q '"alive":1'; then
			log "Worker registered after ${i}s."
			break
		fi
		[[ "$i" -eq 15 ]] && die "Worker failed to register within 15s — check podman logs $CONTAINER_NAME"
		sleep 1
	done
fi

# -----------------------------------------------------------------------------
# Pre-download CirrOS image on the host and inject into the container
#
# Downloading inside the container often fails (DNS, proxy, or network
# namespace issues).  By fetching on the host — where connectivity is proven
# — and copying into the container, seed_fixtures.sh will find the file
# already in place and skip its own download.
# -----------------------------------------------------------------------------
HDD_DIR="/var/lib/openqa/share/factory/hdd"
_CIRROS_CACHE="/tmp/$CIRROS_IMG"

if [[ "$DRY_RUN" == "true" ]]; then
	echo "[DRY-RUN] curl -sSf -L -o $_CIRROS_CACHE $CIRROS_URL"
	echo "[DRY-RUN] podman cp $_CIRROS_CACHE $CONTAINER_NAME:$HDD_DIR/$CIRROS_IMG"
else
	if [[ ! -f "$_CIRROS_CACHE" ]]; then
		log "Downloading CirrOS image on host..."
		if ! curl -sSf -L -o "$_CIRROS_CACHE" "$CIRROS_URL"; then
			die "curl failed on host: curl -sSf -L -o $_CIRROS_CACHE $CIRROS_URL"
		fi
	else
		log "CirrOS image cached at $_CIRROS_CACHE, reusing."
	fi
	container_exec mkdir -p "$HDD_DIR"
	podman cp "$_CIRROS_CACHE" "$CONTAINER_NAME:$HDD_DIR/$CIRROS_IMG"
	log "CirrOS image injected into container at $HDD_DIR/$CIRROS_IMG"
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
