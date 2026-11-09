# Usage

zoqa provides two standalone binaries:
- `zoqa`: drop-in replacement for the four `openqa-cli` subcommands (`api`, `archive`, `monitor`, `schedule`).
- `zoqa-clone-job`: drop-in replacement for the standalone `openqa-clone-job` script.

Run `zoqa <subcommand> --help` or `zoqa-clone-job --help` for the full flag list.

- [`api`](#api-make-a-raw-api-request) - make a raw API request
- [`archive`](#archive-download-a-jobs-assets-and-test-results) - download a job's assets and test results
- [`monitor`](#monitor-wait-until-jobs-reach-a-final-state) - wait until jobs reach a final state
- [`schedule`](#schedule-create-new-jobs-via-post-apiv1isos) - create new jobs via `POST /api/v1/isos`
- [`zoqa-clone-job`](#zoqa-clone-job-clone-and-re-trigger-jobs) - clone and re-trigger jobs across or within instances
- [Authentication](#authentication)
- [Host aliases](#host-aliases)


## `api`: make a raw API request

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


## `archive`: download a job's assets and test results

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


## `monitor`: wait until jobs reach a final state

Polls the server until each given job is done. Exit code summarizes the
outcome: `0` if every job passed/softfailed, `1` if any job is missing or
failed, `2` if any job was canceled.

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


## `schedule`: create new jobs via `POST /api/v1/isos`

Each positional argument is a `KEY=VALUE` ISO-post parameter. Use
`--param-file KEY=PATH` to load a value from a file (handy for inline
`SCENARIO_DEFINITIONS_YAML`).

```sh
# Synchronous schedule: server returns the created job IDs immediately
zoqa schedule --osd \
    DISTRI=opensuse VERSION=Tumbleweed FLAVOR=DVD ARCH=x86_64 \
    BUILD=my-build

# Pull a large parameter value from a file
zoqa schedule --osd \
    --param-file SCENARIO_DEFINITIONS_YAML=./scenarios.yaml \
    DISTRI=example VERSION=0 FLAVOR=DVD ARCH=x86_64 BUILD=my-build

# Async scheduling: returns a scheduled_product_id, jobs are created in the background
zoqa schedule --osd async=1 DISTRI=opensuse VERSION=Tumbleweed FLAVOR=DVD ARCH=x86_64

# Schedule and then block until every resulting job finishes
zoqa schedule --osd --monitor \
    DISTRI=opensuse VERSION=Tumbleweed FLAVOR=DVD ARCH=x86_64 BUILD=my-build
```


## `zoqa-clone-job`: clone and re-trigger jobs

`zoqa-clone-job` clones an existing job (and optionally its dependency graph)
from a source openQA instance and creates equivalent new jobs on a destination
instance. It runs as a standalone executable.

```sh
zoqa-clone-job [OPTIONS] JOBREF [KEY=VALUE ...]
```

`JOBREF` can be a bare job ID (when `--from` or `--within-instance` is specified)
or a full URL such as `https://openqa.opensuse.org/tests/12345`.

### Basic cloning workflows

```sh
# Clone within the same instance (no asset downloads needed)
zoqa-clone-job --within-instance openqa.opensuse.org 12345

# Clone from a remote server to a local openQA instance (downloads assets)
zoqa-clone-job --from https://openqa.opensuse.org 12345

# Display a live progress meter while downloading assets
zoqa-clone-job --from https://openqa.opensuse.org --show-progress 12345

# Specify explicit source and destination instances
zoqa-clone-job --from https://openqa.opensuse.org --host http://localhost 12345
```

### Setting overrides

Append `KEY=VALUE` pairs to override settings on the cloned jobs:

```sh
# Override BUILD and WORKER_CLASS
zoqa-clone-job --within-instance openqa.opensuse.org 12345 \
    BUILD=test-01 WORKER_CLASS=qemu_x86_64

# Scope an override to a specific test module (KEY:TEST=VALUE)
zoqa-clone-job --within-instance openqa.opensuse.org 12345 \
    DESKTOP:boot_to_desktop=gnome

# Append a value to an existing setting (KEY+=VALUE)
zoqa-clone-job --within-instance openqa.opensuse.org 12345 \
    CASEDIR+=#my-feature-branch

# Delete a setting from the clone by passing an empty value
zoqa-clone-job --within-instance openqa.opensuse.org 12345 \
    MAINTENANCE_INCIDENT=
```

### Dependency graph filtering

By default, `zoqa-clone-job` traverses parent jobs (chained and parallel) and
direct child jobs (`--max-depth 1`).

```sh
# Clone only the target job, ignoring all parents and children
zoqa-clone-job --within-instance openqa.opensuse.org --skip-deps 12345

# Skip chained and directly chained parents, but keep parallel parents
zoqa-clone-job --within-instance openqa.opensuse.org --skip-chained-deps 12345

# Also clone chained child jobs
zoqa-clone-job --within-instance openqa.opensuse.org --clone-children 12345

# Set the maximum child recursion depth (0 for unlimited)
zoqa-clone-job --within-instance openqa.opensuse.org --max-depth 2 12345

# Apply setting overrides to parent jobs as well (depth >= 2)
zoqa-clone-job --within-instance openqa.opensuse.org --parental-inheritance 12345 \
    BUILD=test-01
```

### Output and execution modes

```sh
# Print the equivalent zoqa api command without creating jobs
zoqa-clone-job --within-instance openqa.opensuse.org --export-command 12345

# Inject original git repository and needle settings from vars.json
zoqa-clone-job --within-instance openqa.opensuse.org --reproduce 12345

# Run 3 consecutive clone iterations with -01, -02, -03 test suffixes
zoqa-clone-job --within-instance openqa.opensuse.org --repeat 3 12345

# Output markdown badges for git pull request comments
zoqa-clone-job --within-instance openqa.opensuse.org --badge 12345

# Output machine-readable JSON mapping original IDs to new IDs
zoqa-clone-job --within-instance openqa.opensuse.org --json-output 12345
```


## Authentication

Both `zoqa` and `zoqa-clone-job` read API credentials from `~/.config/openqa/client.conf`,
the same INI file used by `openqa-cli` and `openqa-clone-job`:

```ini
[openqa.opensuse.org]
key = YOUR_API_KEY
secret = YOUR_API_SECRET
```

You can also pass credentials directly via CLI flags:

```sh
zoqa api --host openqa.opensuse.org --apikey KEY --apisecret SECRET /api/v1/jobs
zoqa-clone-job --from openqa.opensuse.org --apikey KEY --apisecret SECRET 12345
```

Priority order: CLI flags > environment variables (`OPENQA_API_KEY`/`OPENQA_API_SECRET`) > config file.


## Host aliases

On `zoqa` subcommands (`api`, `archive`, `monitor`, `schedule`), host aliases provide quick access to known instances:

| Flag | Resolves to |
|---|---|
| `--o3` | `https://openqa.opensuse.org` |
| `--osd` | `http://openqa.suse.de` |
| `--odn` | `https://openqa.debian.net` |

For `zoqa-clone-job`, specify instances via `--host`, `--from`, or `--within-instance`.
