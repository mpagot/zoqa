# Near End-to-End (E2E) Test Harness

This directory contains the near end-to-end test harness for `openQAclient`. It
validates the HTTP client, HMAC handshake, CLI flags, and API interaction against a
live official openQA single-instance container managed by Podman.

Two test flows are provided:

- **Linux / macOS** — `run.sh` runs the full 35-test suite (Zig + Perl comparisons)
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
| `run.sh` | Main entry point. Delegates setup/teardown, then runs all 35 tests. |
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
-h, --help          Show help.
```

---

## `setup.sh` Options

```
--dryrun            Print commands without executing them.
--keep-container    Accepted for caller compatibility; no-op in setup.sh.
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

## Testing Methodology

The harness employs three primary testing patterns to validate the Zig executable:

1.  **Functional Testing:** Validates that `zoqa` correctly handles internal logic, such as CLI argument validation and connection error reporting.
2.  **Comparison Testing:** Runs the same command against both the Perl reference (`openqa-cli`) and the Zig binary, ensuring both return the same exit codes and match specific output patterns.
3.  **Parity Testing (Diff):** Captures the full JSON output of both binaries for a complex nested resource and performs a `diff` to detect structural or data mismatches.

---

## Test Coverage (30 test cases)

### API & Protocol
| # | Test | Verification |
|---|---|---|
| 1 | GET `jobs/overview` | Basic endpoint connectivity and JSON array response. |
| 2 | GET `workers` | Basic endpoint connectivity. |
| 3 | Query Parameters | Appending filters (e.g., `distri=opensuse`) to the URL. |
| 14 | Nested JSON Parsing | Correctly parsing and returning complex nested objects (e.g., `settings`). |
| 19 | Resource Discovery | Retrieving seeded groups and verifying data persistence. |
| 21 | Relative vs Absolute Path | `zoqa api jobs/1` and `zoqa api http://localhost/api/v1/jobs/1` produce identical output. |

### Authentication (HMAC-SHA1)
| # | Test | Verification |
|---|---|---|
| 5 | DELETE HMAC | Correct signature generation for `DELETE` requests (verified via 404). |
| 6 | POST HMAC | Correct signature generation for `POST` requests. |
| 18 | Authenticated DELETE | Successful deletion of a real asset using full HMAC handshake. |
| 9 | Auth Failure (403) | Graceful handling of invalid secrets/signatures. |

### CLI Flags & Configuration
| # | Test | Verification |
|---|---|---|
| 7 | `--param-file` | Reading key/value pairs from external files. |
| 8 | CLI Overrides | Explicit flags (`--apikey`) take precedence over `client.conf`. |
| 15 | `--links` Flag | Parsing and displaying `Link` pagination headers. |
| 16 | `--verbose` Flag | HTTP status line and `Content-Type` header present in output. |
| 12, 17 | `--pretty` Flag | JSON indentation logic for both empty and populated responses. |
| 22 | `--name` Flag | Accepted by both Perl and Zig (Zig: **FAIL** until §1.2 implemented). |

### Error Handling & Edge Cases
| # | Test | Verification |
|---|---|---|
| 4 | 404 Not Found | Standard API error propagation. |
| 10 | Missing Arguments | Both Perl and Zig exit when PATH is omitted (**FAIL** for Zig until §1.7). |
| 11 | Connection Refused | Graceful exit when the host is unreachable. |
| 11b | Arg-order Divergence | Perl rejects `--host` before subcommand (exit 255); Zig accepts it (exit 0). Intentional, permanent divergence. |
| 20 | Output Parity | Hard `diff` comparison between Perl and Zig output for a nested object. |
| 23 | Broken Pipe | `zoqa … \| head -c 1` exits cleanly without crashing on SIGPIPE. |
| 25, 26 | Non-2xx stderr | `404` reported on stderr without `--quiet`; suppressed with `--quiet`. |

### Verbose Headers (Phase 1.3)
| # | Test | Verification |
|---|---|---|
| 24 | Verbose Header Count | Perl vs Zig header line count comparison (**FAIL** until §1.3 implemented). |

---

## Expected Failures

Four tests are intentional pre-implementation failures. All others must pass:

| Test | Reason | Tracked by |
|---|---|---|
| 10 (ZIG sub-test) | Zig exits 1 + raw error name; Perl exits 255 + usage text | §1.7 |
| 22 (ZIG sub-test) | `--name` flag not yet parsed | §1.2 |
| 24 | Zig prints 1 verbose header; Perl prints 5 | §1.3 |
| 26 | Same root cause as test 24 | §1.3 |

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
  run.sh                      — main entry point (35 tests)
  setup.sh                    — container lifecycle + bootstrap + seeding
  teardown.sh                 — container stop + log collection + cleanup
  seed_fixtures.sh            — fixture seeding (runs inside container)
  fixtures/
    templates.json            — machine/suite/product/group definitions
    scenario-definitions.yaml — job scheduling YAML
```

