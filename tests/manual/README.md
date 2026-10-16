# tests/manual

Manual test scripts that run against a **real production openQA server**.
They are not part of CI and require network access; some require write-access
credentials.

---

## Prerequisites

### Environment variables

Validated by `lib.sh` at startup — the scripts exit immediately if a required
variable is unset.

| Variable | Required | Default | Description |
|---|---|---|---|
| `OPENQA_HOST` | yes | — | Base URL, e.g. `https://openqa.opensuse.org` |
| `OPENQA_JOB_ID` | yes | — | A known-good completed job ID |
| `ZOQA` | no | `./zig-out/bin/zoqa` | Path to the zoqa binary |
| `ZOQA_CLONE` | no | `./zig-out/bin/zoqa-clone-job` | Path to the zoqa-clone-job binary (`test_perf_clone.sh`) |
| `RUNS` | no | `3` | Number of timing repetitions per scenario |
| `SLEEP` | no | `0` | Seconds to sleep between individual runs (`test_perf_details.sh`, `test_perf_clone.sh`) |
| `ASSET_DIR` | no | `/tmp/zoqa-clone-perf-$$` | Base directory for downloads (`test_perf_clone.sh`) |

### Host tools

| Tool | Required | Notes |
|---|---|---|
| `bash 4+` | yes | |
| `openqa-cli` | by script | `test_api.sh`, `test_schedule_monitor.sh` — install with `zypper install openQA-client` |
| `openqa-clone-job` | by script | `test_perf_clone.sh` — install with `zypper install openQA-client` |
| `curl` | by script | `test_perf_details.sh`, `test_perf_clone.sh` — raw I/O baseline |
| `python3` | by script | `test_api.sh`, `test_schedule_monitor.sh`, `test_perf_clone.sh` — JSON validation and extraction |
| `/usr/bin/time` | no | GNU time; if absent, RSS measurement is silently skipped |

---

## Scripts

| Script | Description |
|---|---|
| `lib.sh` | Shared helpers (env-var validation, timing, RSS, correctness checks). Sourced by the other scripts; not run directly. |
| `test_api.sh` | Read-only `api` subcommand: 7 correctness + wall-clock timing scenarios comparing zoqa vs `openqa-cli`. |
| `test_archive.sh` | Archive download comparison: runs zoqa, `openqa-cli`, and `curl` in sequence, verifies MD5 checksums. Needs ~3.5 GB free disk space. |
| `test_perf_details.sh` | Three-way (zoqa / `openqa-cli` / `curl`) benchmark of the `jobs/ID/details` endpoint: wall-clock timing + peak RSS. |
| `test_perf_clone.sh` | Three-way (zoqa-clone-job / `openqa-clone-job` / `curl`) benchmark of clone-job asset downloads with `--show-progress` and `--skip-deps`: wall-clock timing + peak RSS. Needs ~4 GB free disk space. |
| `test_schedule_monitor.sh` | `schedule` + `monitor` correctness + timing vs `openqa-cli`. **Creates real jobs on the server** (write access required). Supports `--dry-run` to skip all mutating calls. |

---

## Running

Build first, then run any script directly with `bash`:

```sh
zig build

OPENQA_HOST=https://openqa.opensuse.org OPENQA_JOB_ID=12345 \
    bash tests/manual/test_api.sh

OPENQA_HOST=https://openqa.opensuse.org OPENQA_JOB_ID=12345 \
    bash tests/manual/test_archive.sh

OPENQA_HOST=https://openqa.opensuse.org OPENQA_JOB_ID=12345 \
    bash tests/manual/test_perf_details.sh

# Benchmark clone-job asset downloads (use a job with large assets)
OPENQA_HOST=https://openqa.opensuse.org OPENQA_JOB_ID=6262303 \
    bash tests/manual/test_perf_clone.sh

# Live run — creates jobs on the server
OPENQA_HOST=https://openqa.opensuse.org OPENQA_JOB_ID=12345 \
    bash tests/manual/test_schedule_monitor.sh

# Dry run — prints commands, makes no mutating requests
OPENQA_HOST=https://openqa.opensuse.org OPENQA_JOB_ID=12345 \
    bash tests/manual/test_schedule_monitor.sh --dry-run
```

API credentials for `test_schedule_monitor.sh` are read from
`~/.config/openqa/client.conf` or the `OPENQA_API_KEY` / `OPENQA_API_SECRET`
environment variables.

---

## Linting

```sh
make manual-lint
```

Runs `bash -n` (syntax check) and `shellcheck` on all scripts in this
directory.
