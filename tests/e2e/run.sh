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

WHAT IT DOES:
  1. Starts an official openQA single-instance container.
  2. Extracts dynamically generated API credentials.
  3. Executes comparison tests between 'openqa-cli' (Perl) and 'openQAclient' (Zig).
  4. Validates that credentials are correctly read from /etc/openqa/client.conf.
  5. Validates that CLI flags override the config file.

OPTIONS:
  -h, --help    Show this help message and exit.
  --dryrun      Print commands without executing them.
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

pe() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] podman exec openqa-e2e $*"
    else
        podman exec openqa-e2e "$@"
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
zypper -n --gpg-auto-import-keys ref
zypper -n --gpg-auto-import-keys dup -y
BOOTSTRAP="/usr/share/openqa/script/openqa-bootstrap"
sed -i 's/zypper -n/zypper -n --gpg-auto-import-keys/g' "$BOOTSTRAP"
sed -i 's/ os-autoinst-distri-opensuse-deps//' "$BOOTSTRAP"
sed -i 's/pkgs+=(openQA-single-instance)/true/' "$BOOTSTRAP"
SPLIT_INSTALL="echo 1 | zypper -n --gpg-auto-import-keys install --no-recommends --force-resolution os-autoinst-distri-opensuse-deps openQA-single-instance"
sed -i "/install.*pkgs/a $SPLIT_INSTALL" "$BOOTSTRAP"
exec "$BOOTSTRAP" "$@"
EOF
chmod +x "$WRAPPER_TMP"

# -----------------------------------------------------------------------------
# Container Execution
# -----------------------------------------------------------------------------
echo "==> Starting openQA container..."
it "podman rm -f openqa-e2e >/dev/null 2>&1 || true"
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

    echo "==> Waiting for openQA bootstrap to finish..."
    for i in {1..450}; do
        ! podman inspect -f '{{.State.Running}}' openqa-e2e >/dev/null 2>&1 && { echo "Error: Container stopped!" >&2; exit 1; }
        if pe grep -q "\[localhost\]" /etc/openqa/client.conf 2>/dev/null; then
            echo "openQA is ready!"
            break
        fi
        [[ "$i" -eq 450 ]] && { echo "Error: Timeout waiting for openQA" >&2; exit 1; }
        [[ $((i % 30)) -eq 0 ]] && echo "... still bootstrapping ($((i * 2))s elapsed) ..."
        sleep 2
    done
fi

# -----------------------------------------------------------------------------
# Credential Extraction (for manual verification and CLI override test)
# -----------------------------------------------------------------------------
echo "==> Extracting credentials..."
if [[ "$DRY_RUN" == "true" ]]; then
    API_KEY="MOCK_KEY"; API_SECRET="MOCK_SECRET"
else
    pe cat /etc/openqa/client.conf > client.conf.e2e || true
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
echo "==> Running E2E tests (using /etc/openqa/client.conf)..."

failed_tests=0

run_test() {
    local label=$1
    local cmd=$2
    local expected_exit=${3:-0}
    local grep_pattern=$4

    echo "--- Test: $label ---"
    echo "Command: $cmd"
    
    set +e
    eval pe "$cmd" > test_output.log 2>&1
    local exit_code=$?
    set -e

    echo "Exit code: $exit_code"
    if [[ "$exit_code" -ne "$expected_exit" ]]; then
        echo "FAIL: Expected exit code $expected_exit, got $exit_code"
        cat test_output.log
        failed_tests=$((failed_tests + 1))
        return
    fi

    if [[ -n "$grep_pattern" ]]; then
        if ! grep -q "$grep_pattern" test_output.log; then
            echo "FAIL: Output did not match pattern '$grep_pattern'"
            cat test_output.log
            failed_tests=$((failed_tests + 1))
            return
        fi
    fi

    echo "PASS"
}

# Define base binary commands (without api subcommand yet, to allow flags injection)
ZIG_EXE="/app/zig-out/bin/openQAclient"
PERL_EXE="openqa-cli"

run_comparison() {
    local label=$1
    local env_vars=$2
    local api_args=$3
    local expected_exit=${4:-0}
    local grep_pattern=$5

    run_test "PERL: $label" "bash -c \"$env_vars $PERL_EXE api --host http://localhost $api_args\"" "$expected_exit" "$grep_pattern"
    run_test "ZIG : $label" "bash -c \"$env_vars $ZIG_EXE --host http://localhost api $api_args\"" "$expected_exit" "$grep_pattern"
}

# Test 1: Basic GET jobs/overview
run_comparison "GET jobs/overview" "" "jobs/overview" 0 "\[\]"

# Test 2: GET workers
run_comparison "GET workers" "" "workers" 0

# Test 3: GET with query params
run_comparison "GET jobs with filter" "" "jobs distri=opensuse" 0 "\[\]"

# Test 4: GET 404
run_comparison "GET non-existent (404)" "" "jobs/999999" 1 "404 Not Found"

# Test 5: DELETE 404 (Tests HMAC on DELETE)
run_comparison "DELETE non-existent (404)" "" "-X DELETE assets/999999" 1 "404 Not Found"

# Test 6: POST isos (HMAC validation)
run_comparison "POST isos (HMAC validation)" "" "-X POST isos DISTRI=test VERSION=1 FLAVOR=test ARCH=x86_64" 0

# Test 7: --param-file support
pe bash -c "printf 'opensuse' > /tmp/distri.txt"
run_comparison "--param-file" "" "--param-file distri=/tmp/distri.txt jobs" 0 "\[\]"

# Test 8: CLI Flags Override (Correct credentials on CLI override wrong ones in config)
pe bash -c "printf '[localhost]\nkey=WRONG\nsecret=WRONG\n' > /tmp/wrong.conf"
run_comparison "CLI Override" "OPENQA_CONFIG=/tmp" "--apikey '$API_KEY' --apisecret '$API_SECRET' jobs/overview" 0 "\[\]"

# Test 9: Authentication Failure (Wrong Secret)
# We use POST /jobs because it's an authenticated route (unlike jobs/overview which is public)
run_comparison "Wrong Secret (403)" "" "--apisecret WRONG_SECRET -X POST jobs" 1 "403 Forbidden"

# Test 10: Missing PATH positional
run_test "PERL: Missing PATH" "$PERL_EXE api --host http://localhost" 255
run_test "ZIG : Missing PATH" "$ZIG_EXE --host http://localhost api" 1 "MissingPath"

# Test 11: Invalid Host (Connection Refused)
# Note: we don't use binary base here to avoid injecting --host http://localhost
run_test "PERL: Invalid Host" "$PERL_EXE api --host http://localhost:12345 jobs/overview" 1
run_test "ZIG : Invalid Host" "$ZIG_EXE --host http://localhost:12345 api jobs/overview" 1 "Connection error"

# Test 12: Zig specific: --pretty (Perl doesn't have it)
run_test "ZIG : Pretty print" "$ZIG_EXE --host http://localhost api --pretty jobs/overview" 0 "\[\]"

if [[ "$DRY_RUN" == "true" ]]; then
    echo "==> [DRY-RUN] E2E tests simulated successfully!"
else
    if [[ "$failed_tests" -eq 0 ]]; then
        echo "==> All E2E tests successful!"
    else
        echo "==> $failed_tests E2E tests failed!"
        exit 1
    fi
fi
