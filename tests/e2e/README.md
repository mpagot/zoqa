# Near End-to-End (E2E) Test Harness

This directory contains the near end-to-end test harness for `openQAclient`. It
validates the HTTP client, HMAC handshake, CLI flags, and API interaction against a
live official openQA single-instance container managed by Podman.

---

## Prerequisites

- [Podman](https://podman.io/) installed and rootless-ready
- `/dev/kvm` access recommended (container stability)
- `zig build` already run — the test harness mounts `zig-out/bin/openQAclient` into
  the container as `/app/zig-out/bin/openQAclient`

---

## Quick Start

```sh
# Build the binary first
zig build

# Run the full suite (starts container, seeds data, runs tests, tears down)
bash tests/e2e/run.sh
```

---

## Script Overview

| Script | Purpose |
|---|---|
| `run.sh` | Main entry point. Delegates setup/teardown, then runs all 20 tests. |
| `setup.sh` | Starts the openQA container, waits for bootstrap, seeds fixtures, writes `/tmp/openqa_e2e_env.sh`. |
| `teardown.sh` | Stops the container, collects optional logs, removes temp files. |
| `seed_fixtures.sh` | Runs **inside** the container. Loads templates, schedules jobs, registers assets, writes `/tmp/seeded_ids.env`. |
| `lib.sh` | Shared library sourced by all scripts above. Provides `it()`, `pe()`, `die()`, and common defaults. |

`run.sh` is the only script you need to call directly in normal use. The others are
invoked automatically.

---

## `run.sh` Options

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
podman exec openqa-e2e /app/zig-out/bin/openQAclient --host http://localhost api jobs/overview

# Stop the container manually
podman rm -f openqa-e2e
```

---

## Testing Methodology

The harness employs three primary testing patterns to validate the Zig executable:

1.  **Functional Testing:** Validates that `openQAclient` correctly handles internal logic, such as CLI argument validation and connection error reporting.
2.  **Comparison Testing:** Runs the same command against both the Perl reference (`openqa-cli`) and the Zig binary, ensuring both return the same exit codes and match specific output patterns.
3.  **Parity Testing (Diff):** Captures the full JSON output of both binaries for a complex nested resource and performs a `diff` to detect structural or data mismatches.

---

## Test Coverage (20 test cases)

### API & Protocol
| # | Test | Verification |
|---|---|---|
| 1 | GET `jobs/overview` | Basic endpoint connectivity and JSON array response. |
| 2 | GET `workers` | Basic endpoint connectivity. |
| 3 | Query Parameters | Appending filters (e.g., `distri=opensuse`) to the URL. |
| 14 | Nested JSON Parsing | Correctly parsing and returning complex nested objects (e.g., `settings`). |
| 19 | Resource Discovery | Retrieving seeded groups and verifying data persistence. |

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
| 16 | `--verbose` Flag | Capturing and displaying raw HTTP response headers. |
| 12, 17 | `--pretty` Flag | JSON indentation logic for both empty and populated responses. |

### Error Handling & Edge Cases
| # | Test | Verification |
|---|---|---|
| 4 | 404 Not Found | Standard API error propagation. |
| 10 | Missing Arguments | Internal validation when the required `PATH` is omitted. |
| 11 | Connection Refused | Graceful exit when the host is unreachable. |
| 20 | Output Parity | Soft-warning `diff` comparison between Perl and Zig output. |

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
  lib.sh                      — shared functions and defaults
  run.sh                      — main entry point (20 tests)
  setup.sh                    — container lifecycle + bootstrap + seeding
  teardown.sh                 — container stop + log collection + cleanup
  seed_fixtures.sh            — fixture seeding (runs inside container)
  fixtures/
    templates.json            — machine/suite/product/group definitions
    scenario-definitions.yaml — job scheduling YAML
```
