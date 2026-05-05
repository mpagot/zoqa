# Usage

zoqa mirrors the four `openqa-cli` subcommands. Run `zoqa <subcommand> --help`
for the full flag list of each.

- [`api`](#api--make-a-raw-api-request) — make a raw API request
- [`archive`](#archive--download-a-jobs-assets-and-test-results) — download a job's assets and test results
- [`monitor`](#monitor--wait-until-jobs-reach-a-final-state) — wait until jobs reach a final state
- [`schedule`](#schedule--create-new-jobs-via-post-apiv1isos) — create new jobs via `POST /api/v1/isos`
- [Authentication](#authentication)
- [Host aliases](#host-aliases)


## `api` — make a raw API request

```sh
# List recent jobs
zoqa api --host openqa.opensuse.org /api/v1/jobs

# GET with query parameters
zoqa api --o3 /api/v1/jobs groupid=1 limit=5

# POST with form data
zoqa api --host localhost -X POST /api/v1/jobs DISTRI=opensuse VERSION=Tumbleweed

# PUT with JSON body
zoqa api --host localhost -X PUT -j -d '{"priority":50}' /api/v1/jobs/12345

# Pretty-print the JSON response
zoqa api --o3 -p /api/v1/jobs/1

# Verbose output (shows status line and response headers)
zoqa api --o3 -v /api/v1/jobs/1

# Retry on transient errors (502/503)
zoqa api --osd -r 3 /api/v1/jobs
```


## `archive` — download a job's assets and test results

Downloads everything attached to a finished job (logs, screenshots, uploaded
assets) into a local directory, streaming straight to disk.

```sh
# Archive a job to ./job-12345
zoqa archive --o3 12345 ./job-12345

# Include thumbnails for every screenshot
zoqa archive --o3 -t 12345 ./job-12345

# Skip individual assets larger than 50 MiB (default is 200 MiB)
zoqa archive --o3 -l 50 12345 ./job-12345
```


## `monitor` — wait until jobs reach a final state

Polls the server until each given job is done. Exit code summarises the
outcome: `0` if every job passed/softfailed, `1` if any job is missing or
failed, `2` if any job was cancelled.

```sh
# Block until a single job finishes
zoqa monitor --o3 12345

# Wait on several jobs at once
zoqa monitor --o3 12345 12346 12347

# Tighten the polling interval (default: 10s)
zoqa monitor --o3 --poll-interval 5 12345

# Track the newest clone of each job (useful when jobs get restarted)
zoqa monitor --o3 --follow 12345
```


## `schedule` — create new jobs via `POST /api/v1/isos`

Each positional argument is a `KEY=VALUE` ISO-post parameter. Use
`--param-file KEY=PATH` to load a value from a file (handy for inline
`SCENARIO_DEFINITIONS_YAML`).

```sh
# Synchronous schedule — server returns the created job IDs immediately
zoqa schedule --osd \
    DISTRI=opensuse VERSION=Tumbleweed FLAVOR=DVD ARCH=x86_64 \
    BUILD=my-build

# Pull a large parameter value from a file
zoqa schedule --osd \
    --param-file SCENARIO_DEFINITIONS_YAML=./scenarios.yaml \
    DISTRI=example VERSION=0 FLAVOR=DVD ARCH=x86_64 BUILD=my-build

# Async scheduling — returns a scheduled_product_id, jobs are created in the background
zoqa schedule --osd async=1 DISTRI=opensuse VERSION=Tumbleweed FLAVOR=DVD ARCH=x86_64

# Schedule and then block until every resulting job finishes
zoqa schedule --osd --monitor \
    DISTRI=opensuse VERSION=Tumbleweed FLAVOR=DVD ARCH=x86_64 BUILD=my-build
```


## Authentication

zoqa reads API credentials from `~/.config/openqa/client.conf` — the same INI file
used by `openqa-cli`:

```ini
[openqa.opensuse.org]
key = YOUR_API_KEY
secret = YOUR_API_SECRET
```

You can also pass credentials directly:

```sh
zoqa api --host openqa.opensuse.org --apikey KEY --apisecret SECRET /api/v1/jobs
```

Priority order: CLI flags > environment variables > config file.


## Host aliases

| Flag | Resolves to |
|---|---|
| `--o3` | `https://openqa.opensuse.org` |
| `--osd` | `http://openqa.suse.de` |
| `--odn` | `https://openqa.debian.net` |
