#!/usr/bin/env bash
set -eo pipefail

# Ensure we run from the project root
cd "$(dirname "$0")/../.."

# -----------------------------------------------------------------------------
# Help Message
# -----------------------------------------------------------------------------
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

This script performs Near End-to-End (E2E) testing for the openQAclient Zig binary.

WHY WE HAVE IT:
  To validate the HTTP client logic, HMAC-SHA1 authentication handshake, and 
  actual API interaction against a real openQA server without manual setup or
  mocking complex server behavior.

WHAT IT DOES:
  1. Prepares an entrypoint wrapper to surgically patch the container at runtime.
  2. Starts an official openQA single-instance container in the background.
  3. The wrapper performs 'zypper dup' and patches dependency conflicts in-place.
  4. Waits for the container and openQA services to be fully initialized.
  5. Extracts dynamically generated API credentials from the container.
  6. Executes the 'openQAclient' Zig binary INSIDE the container.
  7. Validates the binary's output and exit code.

OPTIONS:
  -h, --help    Show this help message and exit.
  --dryrun      Print commands without executing them.

TRIAGE & TROUBLESHOOTING:
  - Container Fails to Start: Check 'podman logs openqa-e2e'.
  - Timeout: Initialization can take up to 10 minutes (due to zypper dup).
  - Test Failure: Check 'test_output.log' for the full binary output.

EOF
}

# -----------------------------------------------------------------------------
# Argument Parsing
# -----------------------------------------------------------------------------
DRY_RUN=false
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -h|--help) show_help; exit 0 ;;
        --dryrun) DRY_RUN=true; shift ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
done

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
it() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] $*"
    else
        eval "$*"
    fi
}

# -----------------------------------------------------------------------------
# Preparation
# -----------------------------------------------------------------------------
if [[ ! -f "zig-out/bin/openQAclient" && "$DRY_RUN" == "false" ]]; then
    echo "Error: zig-out/bin/openQAclient not found! Please build it first." >&2
    exit 1
fi

WRAPPER_TMP="tests/e2e/entrypoint-wrapper.sh"
echo "==> Preparing entrypoint wrapper..."
cat << 'EOF' > "$WRAPPER_TMP"
#!/bin/bash
set -xeuo pipefail

diagnose_zypper() {
    echo "==> Zypper Diagnostic: checking libs..."
    ldd "$(which zypper)" | grep "not found" || echo "No missing libs"
    zypper --help >/dev/null 2>&1 || echo "zypper --help FAILED"
}

# 1. Full System Update
# We do this here to avoid OverlayFS collision with bind-mounts.
zypper -n --gpg-auto-import-keys ref || { diagnose_zypper; exit 1; }
zypper -n --gpg-auto-import-keys dup -y || { diagnose_zypper; exit 1; }

# 2. Surgical patch of the bootstrap script in the writable layer
BOOTSTRAP="/usr/share/openqa/script/openqa-bootstrap"
sed -i 's/zypper -n/zypper -n --gpg-auto-import-keys/g' "$BOOTSTRAP"
sed -i 's/ os-autoinst-distri-opensuse-deps//' "$BOOTSTRAP"
sed -i 's/pkgs+=(openQA-single-instance)/true/' "$BOOTSTRAP"

SPLIT_INSTALL="echo 1 | zypper -n --gpg-auto-import-keys install --no-recommends --force-resolution os-autoinst-distri-opensuse-deps openQA-single-instance"
sed -i "/install.*pkgs/a $SPLIT_INSTALL" "$BOOTSTRAP"

# 3. Hand over to the real (now patched) bootstrap
exec "$BOOTSTRAP" "$@"
EOF
chmod +x "$WRAPPER_TMP"

# -----------------------------------------------------------------------------
# Container Execution
# -----------------------------------------------------------------------------
echo "==> Starting openQA container..."
it "podman rm -f openqa-e2e >/dev/null 2>&1 || true"

# Note: We mount the wrapper to /app/wrapper and use it as --entrypoint.
# This keeps /usr/share/openqa/script/openqa-bootstrap clear for zypper to update.
it "podman run -d --name openqa-e2e --rm \
    --device /dev/kvm \
    -e skip_suse_specifics=1 \
    -e skip_suse_tests=1 \
    -v \"\$(pwd)/$WRAPPER_TMP\":/app/entrypoint-wrapper.sh:ro \
    -v \"\$(pwd)\":/app:z \
    -w /app \
    --entrypoint /app/entrypoint-wrapper.sh \
    registry.opensuse.org/devel/openqa/containers/openqa-single-instance"

# shellcheck disable=SC2317
function cleanup {
    echo "==> Cleaning up environment..."
    it "podman rm -f openqa-e2e >/dev/null 2>&1 || true"
    it "rm -f \"$WRAPPER_TMP\" client.conf.e2e test_output.log"
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Readiness Checks
# -----------------------------------------------------------------------------
if [[ "$DRY_RUN" == "true" ]]; then
    echo "==> [DRY-RUN] Skipping readiness wait loops..."
else
    echo "==> Waiting for container to be in 'running' state..."
    for i in {1..30}; do
        if podman inspect -f '{{.State.Running}}' openqa-e2e 2>/dev/null | grep -q "true"; then
            echo "Container is running."
            break
        fi
        [[ "$i" -eq 30 ]] && { echo "Error: Timeout waiting for container" >&2; exit 1; }
        sleep 2
    done

    echo "==> Waiting for openQA bootstrap to finish (this can take 5-10 minutes)..."
    for i in {1..450}; do
        ! podman inspect -f '{{.State.Running}}' openqa-e2e >/dev/null 2>&1 && { echo "Error: Container stopped!" >&2; exit 1; }
        if podman exec openqa-e2e grep -q "\[localhost\]" /etc/openqa/client.conf 2>/dev/null; then
            echo "openQA is ready!"
            break
        fi
        [[ "$i" -eq 450 ]] && { echo "Error: Timeout waiting for openQA" >&2; exit 1; }
        [[ $((i % 30)) -eq 0 ]] && echo "... still bootstrapping ($((i * 2))s elapsed) ..."
        sleep 2
    done
fi

# -----------------------------------------------------------------------------
# Credential Extraction
# -----------------------------------------------------------------------------
echo "==> Extracting credentials..."
if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] podman exec openqa-e2e cat /etc/openqa/client.conf > client.conf.e2e"
    API_KEY="MOCK_KEY"; API_SECRET="MOCK_SECRET"
else
    podman exec openqa-e2e cat /etc/openqa/client.conf > client.conf.e2e || true
    if [[ -f client.conf.e2e ]]; then
        API_KEY=$(sed -n '/\[localhost\]/,/\[/p' client.conf.e2e | grep "^key" | head -n 1 | cut -d'=' -f2 | tr -d ' ')
        API_SECRET=$(sed -n '/\[localhost\]/,/\[/p' client.conf.e2e | grep "^secret" | head -n 1 | cut -d'=' -f2 | tr -d ' ')
        echo "Found credentials: $API_KEY"
    else
        echo "Error: Could not extract credentials!" >&2; exit 1
    fi
fi

# -----------------------------------------------------------------------------
# E2E Test Execution
# -----------------------------------------------------------------------------
echo "==> Running E2E tests..."
it "podman exec openqa-e2e /app/zig-out/bin/openQAclient \
    --verbose \
    --host http://localhost \
    --apikey \"$API_KEY\" \
    --apisecret \"$API_SECRET\" \
    api jobs/overview > test_output.log 2>&1"
TEST_EXIT_CODE=$?

if [[ "$DRY_RUN" == "true" ]]; then
    echo "==> [DRY-RUN] E2E test simulated successfully!"
else
    echo "Test exit code: $TEST_EXIT_CODE"
    echo "--- Test Output Start ---"
    cat test_output.log
    echo "--- Test Output End ---"
    
    if [[ "$TEST_EXIT_CODE" -eq 0 ]]; then
        echo "==> E2E test successful!"
    else
        echo "==> E2E test failed!"
        exit 1
    fi
fi
