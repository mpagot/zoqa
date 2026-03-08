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

## Test Coverage (20 tests)

| # | Description |
|---|---|
| 1 | GET `jobs/overview` — blank slate returns `[]` |
| 2 | GET `workers` |
| 3 | GET `jobs` with query parameters |
| 4 | GET non-existent resource (404) |
| 5 | DELETE non-existent resource — validates HMAC on DELETE (404) |
| 6 | POST `isos` — validates HMAC on POST |
| 7 | `--param-file` flag support |
| 8 | CLI flags override wrong config-file credentials |
| 9 | Wrong secret returns 403 Forbidden |
| 10 | Missing PATH positional argument handled gracefully |
| 11 | Invalid host (connection refused) |
| 12 | `--pretty` on empty response |
| 13 | GET `jobs/overview` returns seeded job names |
| 14 | GET `jobs/:id` returns nested job object with `settings` |
| 15 | `--links` flag surfaces `Link: rel="next"` pagination header |
| 16 | `--verbose` flag shows HTTP response headers |
| 17 | `--pretty` on non-empty response produces indented JSON |
| 18 | DELETE a real asset (successful authenticated DELETE) |
| 19 | GET `job_groups` returns the seeded group name |
| 20 | Perl vs Zig output parity on a nested object (soft WARN, not hard FAIL) |

Tests 1–12 use the blank-slate container. Tests 13–20 require seeded fixture data
(provided automatically by `seed_fixtures.sh`).

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
