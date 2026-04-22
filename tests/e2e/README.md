# Near End-to-End (E2E) Test Harness

This directory contains the near end-to-end test harness for `openQAclient`. It
validates the HTTP client, HMAC handshake, CLI flags, and API interaction against a
live official openQA single-instance container managed by Podman.

Two test flows are provided:

- **Linux / macOS** — `run.sh` runs the full test suite (Zig + Perl comparisons)
  inside the container using Bash.
- **Windows** — `run_windows.ps1` runs a zoqa-only subset (~30 tests) using
  PowerShell.  The container still runs in WSL; `zoqa.exe` is called natively.

---

## Prerequisites

### Linux / macOS
- [Podman](https://podman.io/) installed and rootless-ready
- `/dev/kvm` access recommended (container stability)
- `zig build` already run — the test harness mounts `zig-out/bin/zoqa` into
  the container as `/app/zig-out/bin/zoqa`

### Windows
- WSL2 with a Linux distro that has Podman available
- `zoqa.exe` built natively on Windows: `zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe`
- PowerShell 5.1+ or `pwsh` 7+

---

## Quick Start

### Linux / macOS

```sh
# Build the binary first
zig build

# Run the full suite (starts container, seeds data, runs tests, tears down)
bash tests/e2e/run.sh
```

### Windows

```powershell
# Build the binary first (native Windows Zig toolchain)
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe

# From the repository root in PowerShell:
pwsh tests\e2e\run_windows.ps1
```

`run_windows.ps1` will:
1. Verify `zig-out\bin\zoqa.exe` exists
2. Start the openQA container in WSL (exposes port 8080 to Windows)
3. Wait for bootstrap and fixture seeding
4. Run `run_tests.ps1` natively on Windows against the WSL-hosted container
5. Signal teardown and wait for cleanup

By default the script uses the **WSL default distro** (whatever `wsl --set-default`
points to).  If Podman is only installed in a specific distro, pass it explicitly:

```powershell
# List available distros
wsl --list --verbose

# Use a specific distro
pwsh tests\e2e\run_windows.ps1 -WslDistro "openSUSE-Tumbleweed"
```

---

## Script Overview

### Linux / macOS scripts

| Script | Purpose |
|---|---|
| `run.sh` | Main entry point. Delegates setup/teardown, then runs all tests. |
| `setup.sh` | Starts the openQA container, waits for bootstrap, seeds fixtures, writes `/tmp/openqa_e2e_env.sh`. |
| `teardown.sh` | Stops the container, collects optional logs, removes temp files. |
| `seed_fixtures.sh` | Runs **inside** the container. Loads templates, schedules jobs, registers assets, writes `/tmp/seeded_ids.env`. |
| `lib.sh` | Shared library sourced by all scripts above. Provides `run_cmd()`, `container_exec()`, `die()`, and common defaults (`CONTAINER_NAME`, `DRY_RUN`, `LOG_PREFIX`). |
| `tests.sh` | Sources all `tests_*.sh` domain files. |
| `tests_core.sh` | Section A — core protocol and CLI flag tests (tests 1–10). |
| `tests_auth.sh` | Section B — authentication tests (tests 11–17). |
| `tests_data.sh` | Section C — seeded data, pagination, parity tests (tests 18–24). |
| `tests_output.sh` | Section D — `--verbose`, `--pretty`, `--name` (tests 25–28). |
| `tests_robustness.sh` | Section E — broken pipe, non-2xx stderr, `--quiet` (tests 29–31). |
| `tests_retry_knobs.sh` | Section F — retry/timeout env var smoke tests (tests 32–35). |
| `tests_archive.sh` | Section H — archive subcommand tests (ARC-1–ARC-63). |
| `tests_monitor.sh` | Section I — monitor subcommand tests (MON-1–MON-51). |
| `tests_schedule.sh` | Section J — schedule subcommand tests (SCH-1–SCH-50). |
| `tests_help.sh` | Help output structure tests (global, api, archive, monitor, schedule). |
| `tests_perf.sh` | Section G — wall-clock timing and peak RSS comparisons (PERF-B1–B2, T1–T8, R1–R9). |
| `tests_stress.sh` | Section L — large response stress and gzip negotiation tests. |

`run.sh` is the only script you need to call directly in normal use. The others are
invoked automatically.

### Windows scripts

| Script | Purpose |
|---|---|
| `run_windows.ps1` | Orchestrator. Verifies `zoqa.exe` exists, starts WSL container, runs tests, tears down. |
| `run_container.sh` | WSL-side container lifecycle. Exposes port 8080, writes `/tmp/openqa_e2e_env.ps1`, waits for sentinel. |
| `run_tests.ps1` | PowerShell test runner. Calls `zoqa.exe` natively; 30 tests across all 6 domains. No Perl comparisons. |

`run_windows.ps1` is the only script you need to call directly. The others are
invoked automatically.

---

## `run.sh` Options (Linux / macOS)

```
--dryrun            Print commands without executing them (no container started).
--keep-container    Leave the container running after tests finish. Publishes
                    ports 80->8080 and 443->8443 so the web UI is reachable
                    at http://localhost:8080.
--collect-logs      Dump openQA server-side logs to ./openqa-e2e-logs/ before stopping.
--suites NAMES      Comma-separated list of suite names to run. Valid names:
                    core, auth, data, output, robustness, retry_knobs, archive,
                    monitor, schedule, help, stress, perf. When omitted, all
                    suites are run (default behaviour).
-h, --help          Show help.
```

Examples:

```sh
# Run the full suite (default)
bash tests/e2e/run.sh

# Run only the core suite
bash tests/e2e/run.sh --suites core

# Via make
make e2e SUITES=core
make e2e SUITES=core,auth

# Deployment check (starts container, seeds data, runs NO tests, then stops)
make e2e SUITES=

# Deployment for manual inspection (starts container, seeds, keeps it alive)
# All tests are skipped; web UI is reachable at http://localhost:8080 (HTTP)
# and https://localhost:8443 (HTTPS).
make e2e-keep SUITES=

# Simulation (runs the full logic without starting Podman)
make e2e-dryrun
```

---

## `setup.sh` Options

```
--dryrun            Print commands without executing them.
--keep-container    Accepted for caller compatibility; no-op in setup.sh.
--expose-ports      [INTERNAL] Publish container ports 80->8080 and 443->8443.
                    Forwarded automatically by run.sh when --keep-container is
                    used. Not intended for direct invocation.
-h, --help          Show help.
```

`setup.sh` writes `/tmp/openqa_e2e_env.sh` with the following exports:

```sh
export CONTAINER_NAME="openqa-e2e"
export OPENQA_API_KEY="..."
export OPENQA_API_SECRET="..."
export JOB_ID="..."
export ASSET_ID="..."
export GROUP_ID="..."
```

You can source this file manually after a `--keep-container` run to reuse the seeded
IDs in ad-hoc commands.

---

## `teardown.sh` Options

```
--dryrun            Print commands without executing them.
--collect-logs      Collect server-side logs before stopping.
-h, --help          Show help.
```

When `--collect-logs` is used, logs are written to `./openqa-e2e-logs/`:

| File | Contents |
|---|---|
| `openqa.log` | openQA application log |
| `apache-access.log` | Apache access log |
| `apache-error.log` | Apache error log |
| `journal.log` | Full `journalctl` output |
| `gru.log` | Gru / Minion worker logs |
| `container-stdout-stderr.log` | `podman logs` output |

---

## Generated Files

The following files are created at runtime and never committed to the repository.

### Linux / macOS flow

| File | Created by | Purpose |
|---|---|---|
| `/tmp/openqa-entrypoint-wrapper.sh` | `setup.sh` | Patched container entrypoint that skips unnecessary bootstrap steps. Mounted into the container as a read-only volume. |
| `/tmp/openqa_e2e_env.sh` | `setup.sh` | Bash env file exported after seeding. Sourced by `run.sh` to obtain `CONTAINER_NAME`, `OPENQA_API_KEY`, `OPENQA_API_SECRET`, `JOB_ID`, `ASSET_ID`, `ZIG_ASSET_ID`, `GROUP_ID`. |
| `/tmp/seeded_ids.env` | `seed_fixtures.sh` (inside container) | Plain `KEY=VALUE` file written inside the container. Read back by `setup.sh` to populate `/tmp/openqa_e2e_env.sh`. |

### Windows + WSL flow

All files from the Linux flow are also created (inside WSL), plus:

| File | Created by | Purpose |
|---|---|---|
| `$env:TEMP\openqa_e2e_env.ps1` | `run_container.sh` | PowerShell env file derived from `/tmp/openqa_e2e_env.sh`. Dot-sourced by `run_windows.ps1` to pass credentials and seeded IDs to `run_tests.ps1`. Written to the Windows `TEMP` directory (a real NTFS path) so PowerShell's execution policy does not block dot-sourcing. |
| `/tmp/openqa_e2e_done` | `run_windows.ps1` | Sentinel file touched by `run_windows.ps1` after tests complete to signal `run_container.sh` to begin teardown. Removed by `run_container.sh` on exit. |

---

## Linting

All E2E shell scripts are checked by `bash -n` (syntax) and
[shellcheck](https://www.shellcheck.net/). A `.shellcheckrc` in this directory
configures source resolution so no extra flags are needed.

Additionally, `check_suite_registry.sh` verifies that every `tests_*.sh` file on
disk is properly registered in all three required locations:

1. `tests/e2e/tests.sh` — `_e2e_all_suites` array
2. `Makefile` — `E2E_SCRIPTS` list
3. `tests/e2e/README.md` — File Layout section

It also detects stale entries (registrations pointing to files that no longer exist).

Run from the repository root:

```sh
make e2e-lint
```

---

## Debugging Tips

```sh
# Keep the container alive and expose the web UI
bash tests/e2e/run.sh --keep-container
# Then open http://localhost:8080 in a browser.

# Collect logs without stopping the container
bash tests/e2e/run.sh --keep-container --collect-logs

# Drop into the container shell
podman exec -it openqa-e2e bash

# Stream container stdout/stderr
podman logs openqa-e2e

# Run a one-off API call inside the container using the Zig binary
podman exec openqa-e2e /app/zig-out/bin/zoqa api --host http://localhost jobs/overview

# Stop the container manually
podman rm -f openqa-e2e
```

---

## Interactive Development with `e2e-keep`

When iterating on a test suite or investigating performance, the full
`make e2e` cycle (bootstrap openQA, seed fixtures, run
all suites, tear down) takes several minutes.  The `e2e-keep` target
short-circuits this by keeping the container alive after the automated
run finishes.  You can then re-run individual test scripts or ad-hoc
commands against the same seeded container as many times as you like.

### Step 1 — Start the container and run a specific suite

```sh
# Build zoqa, start the container, run only the "stress" suite, keep alive.
# E2E_STORAGE_KEEP_FREE_RATIO=0 disables isotovideo's disk-space check.
make e2e-keep SUITES=stress E2E_STORAGE_KEEP_FREE_RATIO=0

# Or start the container with NO tests at all (just seed fixtures):
make e2e-keep SUITES=
```

After the run finishes, the output shows:

```
==> Container 'openqa-e2e' is still running (--keep-container).
    openQA web UI: http://localhost:8080  /  https://localhost:8443
    To stop it:  podman rm -f openqa-e2e
```

### Step 2 — Re-run a test script manually

The automated test scripts (`tests_*.sh`) are designed to be sourced by
`tests.sh` inside `run.sh`, which sets up shared variables (`ZIG_EXE`,
`PERL_EXE`, `LOG_DIR`, `failed_tests`, etc.).  To re-run a script against
the kept container, replicate that environment in a shell:

```sh
# Source credentials and seeded IDs written by setup.sh
source /tmp/openqa_e2e_env.sh

# Set the variables that run.sh normally provides
export ZIG_EXE="/app/zig-out/bin/zoqa"
export PERL_EXE="openqa-cli"
export LOG_DIR="/tmp/zoqa_e2e_manual"
mkdir -p "$LOG_DIR"
export failed_tests=0
export warned_tests=0
export E2E_SUITES="all"          # enable all suites in the _e2e_suite_enabled check

# Source the shared library and test helpers
source tests/e2e/lib.sh
source tests/e2e/tests.sh        # defines run_test(), run_diff_test(), etc.
```

Or source only the library and helpers, then source one specific suite:

```sh
source /tmp/openqa_e2e_env.sh
ZIG_EXE="/app/zig-out/bin/zoqa"
PERL_EXE="openqa-cli"
LOG_DIR="/tmp/zoqa_e2e_manual"; mkdir -p "$LOG_DIR"
failed_tests=0; warned_tests=0; E2E_SUITES="all"

source tests/e2e/lib.sh

# Source just the helpers from tests.sh without running all suites.
# The helper functions (run_test, run_diff_test, run_comparison) are
# defined before the suite-sourcing loop, so we can extract them with:
_E2E_DIR="tests/e2e"
source <(sed -n '1,/^# Source domain test files/p' tests/e2e/tests.sh)

# Now run one suite:
source tests/e2e/tests_stress.sh
echo "Failed: $failed_tests"
```

### Step 3 — Run ad-hoc commands against the container

With the container alive, you can run any command directly via
`podman exec`.  This is useful for manual benchmarking, debugging job
output, or verifying fixes before committing:

```sh
# Check a job's status
podman exec openqa-e2e openqa-cli api --host http://localhost jobs/2 \
  2>/dev/null | jq '{state: .job.state, result: .job.result}'

# Measure response size
podman exec openqa-e2e bash -c \
  'openqa-cli api --host http://localhost jobs/2/details 2>/dev/null | wc -c'

# Wall-clock timing (Perl then Zig, sequentially)
podman exec openqa-e2e bash -c "
  TIMEFORMAT='%R'
  { time openqa-cli api --host http://localhost jobs/2/details \
      >/dev/null 2>&1; } 2>&1"

podman exec openqa-e2e bash -c "
  TIMEFORMAT='%R'
  { time /app/zig-out/bin/zoqa api --host http://localhost jobs/2/details \
      >/dev/null 2>&1; } 2>&1"

# Detailed resource usage via /usr/bin/time -v
podman exec openqa-e2e bash -c \
  '/usr/bin/time -v /app/zig-out/bin/zoqa api --host http://localhost \
     jobs/2/details >/dev/null' </dev/null 2>&1

# Output parity — compare md5 checksums
podman exec openqa-e2e bash -c \
  'openqa-cli api --host http://localhost jobs/2/details 2>/dev/null | md5sum'
podman exec openqa-e2e bash -c \
  '/app/zig-out/bin/zoqa api --host http://localhost jobs/2/details 2>/dev/null | md5sum'
```

### Step 4 — Rebuild zoqa and re-test without restarting the container

The zoqa binary is bind-mounted from `zig-out/bin/zoqa` into the
container at `/app/zig-out/bin/zoqa`.  A plain `zig build` on the host
updates the binary in place, and the next `podman exec` picks up the
new version immediately — no container restart needed:

```sh
# Edit src/http_client.zig, then:
zig build
# The container already sees the new binary:
podman exec openqa-e2e /app/zig-out/bin/zoqa api --host http://localhost jobs/2/details \
  >/dev/null 2>&1
```

### Step 5 — Tear down

```sh
podman rm -f openqa-e2e
```

---

## Testing Methodology

The harness employs three primary testing patterns to validate the Zig executable:

1.  **Functional Testing:** Validates that `zoqa` correctly handles internal logic, such as CLI argument validation and connection error reporting.
2.  **Comparison Testing:** Runs the same command against both the Perl reference (`openqa-cli`) and the Zig binary, ensuring both return the same exit codes and match specific output patterns.
3.  **Parity Testing (Diff):** Captures the full JSON output of both binaries for a complex nested resource and performs a `diff` to detect structural or data mismatches.

---

## Test Coverage

See [TEST_CATALOG.md](TEST_CATALOG.md) for the full per-test reference covering
all suites: API & Protocol, Authentication (HMAC-SHA1), CLI Flags &
Configuration, Error Handling & Edge Cases, Verbose Headers, Archive, Monitor,
Schedule, and Stress.

## Expected Failures

All existing tests (api, auth, data, output, robustness, retry, archive, monitor,
help, perf) pass. The **schedule** suite tests are expected to **FAIL on the Zig
side** until the `schedule` subcommand is implemented (TDD approach — tests are
written first). Perl-side assertions in the schedule suite should pass.

---

## Fixture Files

| File | Purpose |
|---|---|
| `fixtures/templates.json` | Loaded by `openqa-load-templates`: 3 machines, 2 test suites, 1 product, 1 job group (`example`). |
| `fixtures/scenario-definitions.yaml` | Passed inline as `SCENARIO_DEFINITIONS_YAML` to `POST /api/v1/isos`. Schedules `simple_boot` on 64bit. |

These files are committed and must not be modified without updating the corresponding
test expectations in `run.sh`.

---

## File Layout

```
tests/e2e/
  .shellcheckrc               — shellcheck configuration (source-path, external-sources)
  lib.sh                      — shared functions and defaults
  run.sh                      — main entry point
  setup.sh                    — container lifecycle + bootstrap + seeding
  teardown.sh                 — container stop + log collection + cleanup
  seed_fixtures.sh            — fixture seeding (runs inside container)
  tests.sh                    — sources all tests_*.sh domain files
  tests_core.sh               — Section A: core protocol and CLI flag tests
  tests_auth.sh               — Section B: authentication tests
  tests_data.sh               — Section C: seeded data, pagination, parity
  tests_output.sh             — Section D: verbose, pretty, name
  tests_robustness.sh         — Section E: broken pipe, non-2xx stderr, quiet
  tests_retry_knobs.sh        — Section F: retry/timeout env var smoke tests
  tests_archive.sh            — Section H: archive subcommand
  tests_monitor.sh            — Section I: monitor subcommand
  tests_schedule.sh           — Section J: schedule subcommand
  tests_help.sh               — help output structure tests
  tests_perf.sh               — Section G: wall-clock timing and peak RSS
  tests_stress.sh             — Section L: large response stress tests
  check_suite_registry.sh     — lint: verify suite files are registered everywhere
  fixtures/
    templates.json            — machine/suite/product/group definitions
    scenario-definitions.yaml — job scheduling YAML
```

