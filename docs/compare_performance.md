# Performance Comparison: zoqa vs openqa-cli

This document provides a detailed, balanced analysis of the performance differences
between zoqa (Zig) and openqa-cli (Perl).

**Production-server measurements are the primary reference in this document.**
They reflect what users experience in production:
 * real network latency,
 * real server-side processing,
 * and real disk I/O.
The containerized E2E suite is valuable for isolating client-side overhead and understanding
*why* zoqa is faster, but its near-zero network latency inflates wall-clock speedup ratios
beyond what any user would see in practice.

Production `api`, `archive`, and `clone-job` numbers come from the [manual test suites](../tests/manual/)
running against a production openQA server over the network.
E2E numbers come from the automated [performance test suite](../tests/e2e/tests_perf.sh)
running inside a containerized openQA instance.


## Summary table

Production-server measurements (†, ‡) are listed first: these best reflect what users
will experience in practice. Container-based E2E measurements follow for reference.

| | `openqa-cli` (Perl) | `zoqa` (Zig) |
|---|---|---|
| **Runtime dependencies** | Perl 5, ~15 CPAN modules, `curl` (clone-job) | None (static binary) |
| **Wall-time per `api` call (production) †** | ~0.6–1.3 s | ~0.13–0.35 s (4–5× faster) |
| **Peak memory (`api`, production) †** | ~61 MB | ~5.3 MB (91% less) |
| **Wall-time `archive` (~3.4 GB, production) †** | ~18m 42s | ~14m 23s (~23% faster) |
| **CPU user time `archive` (~3.4 GB) †** | ~151 s | ~2.9 s (52× less) |
| **Peak memory (`archive`, ~3.4 GB) †** | ~70 MB | ~11 MB (6.3× less) |
| **Wall-time `clone-job` (~2.36 GB, production) ‡** | ~125.0 s | ~116.3 s (~1.1× faster) |
| **CPU user time `clone-job` (~2.36 GB) ‡** | ~8.5 s | ~3.6 s (57% less) |
| **Peak memory (`clone-job`, ~2.36 GB) ‡** | ~53.3 MB | ~4.2 MB (12.7× less) |
| **Minor page faults `clone-job` (~2.36 GB) ‡** | ~26,900 | ~500 (53× fewer) |
| | | |
| **Wall-time per `api` call (E2E, container)** | ~0.5–1.3 s | ~0.01–0.09 s (12–62× faster) |
| **Peak memory (`api`, E2E)** | ~57 MB | ~0.9 MB (98% less) |
| **Wall-time `archive` (~21 MB, E2E)** | ~1.2 s | ~0.25 s (~5× faster) |
| **Peak memory (`archive`, ~21 MB, E2E)** | ~61 MB | ~1.1 MB (98% less) |

<sup>† Measured against a production openQA server over the network. API numbers:
3 runs each via `tests/manual/test_api.sh` (T4 excluded: server-side table scan dominates).
Archive numbers: single run via `tests/manual/test_archive.sh`;
raw-curl baseline for the same data: ~10m 40s.</sup>  
<sup>‡ Measured against `openqa.opensuse.org` downloading 2.36 GB across 5 assets (job 6272684)
via `tests/manual/test_perf_clone.sh`. Curl baseline for the single 1.45 GB asset: 76.8 s.</sup>


## Where the time goes: decomposing the `api` speedup

The 12–62× speedup measured in the E2E suite is real, but it reflects a
near-zero-latency environment where client-side overhead dominates. Against a
production server, the ratio compresses to 4–5×. Both numbers trace to the same
root cause: **Perl + Mojolicious startup overhead**, not HTTP performance.

The E2E suite includes interpreter baseline measurements (PERF-B1, PERF-B2)
that quantify this directly:

| What runs | Wall time | Peak RSS | Minor faults |
|---|---|---|---|
| `perl -e '1'` (bare interpreter) | ~3–7 ms (avg 5 ms) | ~4.7 MB | 215 |
| `perl -MMojo::UserAgent -e '1'` (framework load) | ~400–1,100 ms (avg 730 ms) | ~41 MB | ~7,900 |
| `openqa-cli api …` (full request) | ~500–1,100 ms | ~57 MB | ~12,000 |
| `zoqa api …` (full request) | ~15–90 ms | ~0.9 MB | ~80 |

These are measured values from PERF-B1 and PERF-B2 in the E2E suite (5 runs each).

### Reading the numbers

1. **Bare Perl startup** (`perl -e '1'`) costs ~5 ms and ~4.7 MB, with only 215
   minor page faults. Perl's core interpreter is lean and fast. This is
   *not* where the overhead originates.

2. **Mojolicious framework load** (`perl -MMojo::UserAgent -e '1'`) costs
   ~400–1,100 ms (avg ~730 ms) and ~41 MB, generating ~7,900 minor page faults.
   Perl must locate, read, and compile the full Mojolicious dependency tree
   (UserAgent, JSON, IOLoop, Transaction, etc.) before a single line of
   application code runs. The wide range (400–1,100 ms across 5 runs on the
   same machine) reflects OS page-cache state: cold loads hit disk; warm loads
   find the `.pm` files already cached.

3. **openqa-cli full request** runs at roughly the same wall time as the bare
   Mojo load (0.5–1.1 s). The additional ~11 MB RSS and ~4,000 extra minor
   faults over PERF-B2 are the openqa-cli application modules (`OpenQA::CLI`,
   `OpenQA::Client`, etc.) loading on top of the framework. The HTTP round-trip
   itself to a local server adds negligible time and is lost in the noise.

4. **zoqa full request** does all of the above in ~15–90 ms total, with ~0.9 MB
   RSS and ~80 minor faults. There is no framework to load; the binary maps
   into memory in one shot at startup.


The "speedup" is honest but should be understood correctly: zoqa is not doing
the HTTP work 12–62× faster. The network round-trip is roughly the same for
both.
The difference is that openqa-cli pays a ~730 ms average tax on every
invocation to load Mojolicious. This cost is highly variable and unavoidable, because
it is the nature of a CPAN-based runtime.
zoqa, as a compiled static binary, simply does not have this cost.

The high variability in the Mojo load time also explains why openqa-cli timings
fluctuate significantly between runs: on a cold cache it may take 1.1 s, on a
warm one 0.4 s, a 2.7× swing with no change in workload.

For a single interactive invocation, both tools respond in under a second; the
difference is noticeable but not critical. For a CI pipeline making hundreds of
`api` calls in a loop, the ~730 ms average overhead accumulates to minutes.


## Manual API tests: production server over the network

The [manual API test suite](../tests/manual/test_api.sh) complements the E2E
numbers by exercising zoqa and openqa-cli against a real production openQA
server over the network.
This introduces real network latency, a constant cost paid equally by both tools,
which reduces the observed speedup from the 12–37× seen in E2E (near-zero latency)
to a more representative 3.4–7.3× range.

### Per-scenario results (3 runs each)

| Test | Endpoint | Zig avg | Perl avg | Speedup |
|---|---|---|---|---|
| T1 | `jobs/overview` | 139 ms | 584 ms | 4.2× |
| T2 | `jobs/:id` | 144 ms | 1,053 ms | 7.3× |
| T3 | `jobs/:id/details` (large body) | 352 ms | 1,310 ms | 3.7× |
| T5 | `jobs limit=5` | 202 ms | 690 ms | 3.4× |
| T6 | `--pretty jobs/:id` | 139 ms | 729 ms | 5.2× |
| T7 | `--verbose jobs/:id` | 134 ms | 632 ms | 4.7× |

T4 (`jobs?id=:id`) is excluded: the server performs a full table scan
(~20 s) that dominates both tools equally, making client-side differences
unmeasurable.

### Peak RSS

| Test | Zig | Perl | Reduction |
|---|---|---|---|
| T1–T3, T5–T7 (normal) | ~5.3–5.4 MB | ~61–69 MB | 91–92% |
| T4 (large response) | 76 MB | 145 MB | 47% |

The 91% reduction is consistent across all normal API workloads, because Perl loads
the full Mojolicious stack regardless of response size. For T4, both tools
buffer a multi-megabyte response body; Zig still uses 47% less memory.

### Why 4× here vs 12–62× in E2E

The E2E suite runs against a local containerized server with sub-millisecond
network latency. There, the ~730 ms Mojolicious startup tax accounts for nearly
the full wall time of a Perl request, yielding 12–62× ratios. Over a real
network, the ~100–200 ms of round-trip time is a fixed floor for both tools,
compressing the ratio. The typical speedup against a production server is
**4–5× on wall-clock**, with the startup tax still visible but diluted by I/O
wait.

### Perl timing variance

Perl's run-to-run variance is notably higher than Zig's. T2 shows
807/921/1,431 ms across 3 runs; Zig shows 143/142/146 ms. The 1,431 ms
outlier inflates T2's 7.3× figure; the steady-state ratio is closer to 4×.
The variance likely reflects Mojolicious module loading interacting with OS
page-cache state and GC pauses.


## The `archive` story: startup overhead vs architectural difference

The `archive` subcommand tells a more nuanced story than `api`, because there
are *two* distinct effects at play.

### Small jobs (~21 MB, E2E suite)

| Metric | openqa-cli | zoqa | Ratio |
|---|---|---|---|
| Wall time | ~1.2 s | ~0.25 s | ~5× faster |
| Peak RSS | ~61 MB | ~1.1 MB | 98% less |

On small downloads, most of the gap is still startup overhead. The I/O transfer
itself completes in a fraction of a second for both tools.

### Large jobs (~3.4 GB, production server)

The [manual archive test](../tests/manual/test_archive.sh) downloads the full
archive of a production job, including a multi-GB HDD
asset, test results, logs, and uploaded logs. A raw-curl baseline (same two
largest files, no API logic) establishes the network floor.

| Metric | openqa-cli | zoqa | curl baseline | Ratio (Perl/Zig) |
|---|---|---|---|---|
| Wall time | 18m 42s | 14m 23s | 10m 40s | ~1.3× faster |
| User CPU | 151 s | 2.9 s | 13 s | 52× less |
| System CPU | 66 s | 52 s | 52 s | ~same |
| Peak RSS | 70 MB | 11 MB | 15 MB | 6.3× less |
| Exit status | 0 | 0 | 0 | - |

Checksums (MD5) match across all three tools for both the large HDD asset and a
smaller tarball, confirming identical downloads.

On large downloads, a genuine **architectural difference** dominates:

- **zoqa** streams each HTTP response directly to disk using ~192 KB of
  stack-allocated buffers. Memory usage is constant regardless of file size.

- **openqa-cli** routes each response through Mojolicious's transaction layer,
  which buffers the body into a `/tmp` temporary file before moving it to the
  final destination. This means:
  - Every byte is written to disk twice (temp file → final path)
  - Peak disk usage is approximately double the download size
  - The Perl process retains ~70 MB RSS throughout (Mojolicious runtime + buffers)
  - CPU user time is 52× higher due to Perl-level data copying

The curl baseline puts the wall-time result in context: the network floor is
10m 40s. zoqa adds 3m 43s of client overhead (API calls, directory creation,
dozens of small file downloads); openqa-cli adds 8m 2s. The ~23% wall-time
advantage is real but modest because network throughput is the bottleneck. **CPU
and memory** are where the architectural difference shows its full effect: zoqa
uses 52× less user CPU and 6.3× less memory than openqa-cli, while doing
strictly more work than curl.


## The `clone-job` benchmark: wire-speed saturation, CPU, and memory efficiency

The `clone-job` subcommand (`zoqa-clone-job`) provides a direct comparison against the
standalone `openqa-clone-job` Perl script. While `openqa-cli archive` downloads assets
and results for a completed job, `clone-job` queries job settings and dependency trees,
clones or links parent jobs, and downloads required asset files (such as ISOs and HDD images)
before posting new job definitions.

The [manual clone-job benchmark](../tests/manual/test_perf_clone.sh) evaluates both tools
on a production server (`https://openqa.opensuse.org`) downloading 5 assets totalling
**2,358,025,009 bytes (~2.36 GB)** for job 6272684. The largest asset is a 1.45 GB HDD
image. A baseline run using `curl -sfL` on the largest asset provides the reference network
floor.

### Timing comparison (average of 2 runs)

| Tool | Scope | Run 1 | Run 2 | Average | Effective Throughput |
|---|---|:---:|:---:|:---:|:---:|
| `zoqa-clone-job` (with progress) | All 5 assets (2.36 GB) | 117.12 s | 115.39 s | **116.26 s** | **20.28 MB/s** |
| `zoqa-clone-job` (no progress) | All 5 assets (2.36 GB) | 119.14 s | 116.81 s | **117.98 s** | **19.99 MB/s** |
| `openqa-clone-job` (Perl reference) | All 5 assets (2.36 GB) | 118.84 s | 131.18 s | **125.01 s** | **18.86 MB/s** |
| `curl -sfL` baseline | Largest asset only (1.45 GB) | 76.91 s | 76.67 s | **76.79 s** | **18.85 MB/s** |

### Resource metrics (`/usr/bin/time -v`, single run)

| Tool | Peak RSS | User CPU | Sys CPU | Minor Faults | Major Faults |
|---|:---:|:---:|:---:|:---:|:---:|
| `zoqa-clone-job` (no progress) | **4.1 MB** (4,124 kB) | **3.14 s** | 8.42 s | **492** | **0** |
| `zoqa-clone-job` (--show-progress) | **4.2 MB** (4,192 kB) | **3.62 s** | 8.52 s | **503** | **0** |
| `openqa-clone-job` | 53.3 MB (53,268 kB) | 8.47 s | 9.97 s | 26,928 | 57 |
| `curl` (1.45 GB asset) | 14.5 MB (14,480 kB) | 4.08 s | 6.30 s | 1,273 | 11 |

### Analyzing the clone-job results

1. **Zero dependency on `curl` and in-process execution:**
   The reference `openqa-clone-job` does not download assets with its own HTTP client;
   it delegates asset transfers to the external `curl` command-line utility (`mirror()` in
   `lib/OpenQA/Script/CloneJob.pm`). For every asset, Perl spawns two distinct `curl` processes:
   - A `HEAD` request (`curl --head --location -w %{url_effective}`) to resolve HTTP redirects and discover the final target URL.
   - A `GET` request (`curl --continue-at - --output ...`) to resume or complete the transfer.
   This design imposes an external runtime dependency on `curl` (and system TLS/OpenSSL libraries),
   adds process fork and exec overhead twice per asset, and requires `curl` to be installed on any
   host or container running the tool.
   In contrast, `zoqa-clone-job` has zero runtime dependency on `curl`. It performs HTTP/1.1
   requests, TLS handshakes, redirect following, and ranged streaming downloads entirely
   in-process using Zig's standard library (`std.http.Client`). Each asset is downloaded
   through a single ranged `GET` that follows redirects in-memory, avoiding external processes
   and redundant handshakes.

2. **Wire-speed saturation and dispatch latency:**
   All tools are bounded by WAN bandwidth to `openqa.opensuse.org` (~19–20 MB/s).
   Extrapolating curl's 18.85 MB/s transfer rate across the full 2.36 GB payload yields
   ~125.1 s. `openqa-clone-job` completed in 125.01 s because it shells out to curl
   sequentially for each asset. `zoqa-clone-job` completed the identical 5 downloads in
   116.26 s (8.75 s faster) because it avoids repeated process spawns and handshake
   setup per asset.

3. **Native TLS and CPU efficiency:**
   In optimized builds (`ReleaseSafe` / `ReleaseFast`), Zig's native TLS and streaming
   I/O consumed only 3.62 s of user CPU across 2.36 GB of data. By comparison,
   `openqa-clone-job` required 8.47 s (57% more user CPU), and curl used 4.08 s on just
   the single 1.45 GB asset (projected to ~6.6 s across all assets).

4. **Memory footprint and paging stability:**
   `zoqa-clone-job` operated within ~4.2 MB of resident memory (12.7× lower than Perl's
   53.3 MB) and generated zero major page faults and only 503 minor page faults.
   `openqa-clone-job` incurred 26,928 minor faults and 57 major faults from interpreter
   startup, symbol resolution, and subprocess management.

5. **Self-healing retries and error handling:**
   Shelling out to `curl` introduces error-handling limitations. In upstream openQA,
   `openqa-clone-job` executes `curl` without `--fail`, meaning HTTP 404 or 503
   responses exit 0 from `curl`, which can allow failed downloads to pass undetected.
   Additionally, `curl`'s `--retry` option does not retry `CURLE_PARTIAL_FILE` (error 18)
   when a TCP connection drops mid-transfer, causing Perl to fail the clone immediately.
   `zoqa-clone-job` detects truncated transfers in-process (`error.HttpTransferTruncated`)
   and performs self-healing retries with exponential backoff.

6. **Progress meter overhead:**
   Comparing `zoqa-clone-job` with and without `--show-progress` demonstrates that the
   terminal progress meter adds negligible overhead (+0.48 s user CPU across 2.36 GB,
   with wall times within normal network variation).


## RSS deep-dive: what the ~57–61 MB represents

Both the E2E suite and the manual API tests collect detailed process metrics via
`/usr/bin/time -v`. A typical `api` call shows:

```
                      E2E (local)           Manual (remote)
PERL peak RSS:        58,064 kB             61,580 kB
ZIG  peak RSS:           868 kB              5,344 kB
Minor faults:  PERL:  11,907       PERL:    12,179
               ZIG:       77       ZIG:        266
User time (s): PERL:    0.50       PERL:      0.57
               ZIG:     0.00       ZIG:       0.00
```

The ~12,000 minor page faults on the Perl side are the Mojolicious module pages
being demand-paged into RSS. zoqa's ~80–270 minor faults are the ELF loader
mapping the static binary; its entire working set fits in ~0.9–5.4 MB.

Perl's RSS is dominated by the framework regardless of what the application
does. Whether it's a plain GET, a config-file read, a pretty-print, or an
authenticated request, the peak RSS stays at ~57–62 MB. zoqa stays at
~0.9–5.4 MB across all scenarios (the lower end in E2E with local loopback;
the higher end against production servers where TLS adds overhead).

For the `archive` subcommand, the pattern remains consistent at larger scale. On a ~3.4 GB
download against a production server, openqa-cli peaks at 70 MB RSS while zoqa
peaks at 11 MB, 6.3× less. Notably, zoqa uses *less* memory than raw curl
(15 MB) for the same data, because zoqa's streaming buffers are stack-allocated
and smaller than curl's heap allocations.


## When is this difference relevant?

| Use case | Impact |
|---|---|
| **Interactive one-off query** | Negligible difference: both respond in under a second |
| **CI pipeline with hundreds of `api` calls** | Startup overhead accumulates: ~500 ms × 200 calls = ~100 s of pure framework loading |
| **Containers / minimal images** | zoqa is a single static binary (zero deps, no curl or Perl needed); openqa-cli needs Perl + ~15 CPAN packages, and openqa-clone-job additionally requires curl |
| **Large `archive` downloads (GB-scale)** | Streaming vs. buffering: 52× less CPU, 6× less memory, no temp-file doubling |
| **Large `clone-job` asset downloads (GB-scale)** | In-process streaming: 57% less CPU, 12.7× less memory, no per-asset curl fork overhead |
| **Memory-constrained environments** | ~1–5 MB vs ~53–61 MB baseline, relevant on small VMs or when running many parallel clients |


## About openqa-cli

`openqa-cli` is part of the [openQA project](https://github.com/os-autoinst/openQA),
actively maintained by the SUSE and openSUSE teams. The client library
(`OpenQA::Client`) dates to **2015** (over 10 years of production use), with
the CLI layer (`OpenQA::CLI`) added in **2020**.

### Code size in context

The Perl implementation is ~750 lines of application code across 9 files.
It is compact *because* Mojolicious handles HTTP, TLS, JSON, async I/O,
temporary-file management, and content negotiation on its behalf. The framework
is battle-tested and provides capabilities (WebSocket, non-blocking I/O, upload
handling) that openqa-cli uses with minimal code.

zoqa reimplements all of the HTTP, JSON, auth, config parsing, graph traversal, and I/O logic
against the Zig standard library in ~15,500 lines across 14 modules:

| Module | Lines | Purpose |
|---|---|---|
| `http_client.zig` | ~3,784 | HTTP client with retry logic, redirect handling, and streaming downloads |
| `main.zig` | ~2,954 | `zoqa` CLI entry point, argument parsing, dispatch |
| `clone_job.zig` | ~2,604 | `clone-job` dependency graph walker, BFS resolution, post body assembly |
| `clone_job_main.zig` | ~2,452 | `zoqa-clone-job` CLI entry point, asset downloader, progress meter |
| `schedule.zig` | ~762 | Schedule subcommand |
| `config.zig` | ~551 | INI config parser, credential and host resolution |
| `archive.zig` | ~516 | Archive download (streaming) |
| `cli_env.zig` | ~442 | CLI environment and argument resolution |
| `fs_utils.zig` | ~369 | Filesystem abstraction layer (live and memory-backed filesystems) |
| `arg_match.zig` | ~307 | Positional argument matcher |
| `monitor.zig` | ~270 | Monitor subcommand |
| `root.zig` | ~257 | Library root, re-exports core modules and C-ABI exports |
| `auth.zig` | ~141 | HMAC-SHA1 authentication |
| `url.zig` | ~115 | URL parser and query parameter formatting |

The difference in line count reflects zero external runtime dependencies:
every protocol feature, graph traversal algorithm, terminal progress meter,
and configuration parser is implemented directly in standard Zig, without depending
on Mojolicious, CPAN modules, or external tools such as `curl`.


## Methodology

### E2E performance tests

The [E2E performance suite](../tests/e2e/tests_perf.sh) runs inside a Podman
container with a real openQA instance. It measures:

- **Wall-clock time**: via bash `TIMEFORMAT="%R"` (3–5 runs per scenario)
- **Peak RSS**: via `/usr/bin/time -v` (`getrusage(2)` high-water mark)
- **Interpreter baselines**: `perl -e '1'` and `perl -MMojo::UserAgent -e '1'`
  to isolate framework startup cost from application work

All results are informational: no pass/fail thresholds are enforced. Timing
in a containerized environment is inherently noisy; the numbers show relative
magnitudes, not absolute benchmarks.

### Scenarios tested

| Scenario | What it exercises |
|---|---|
| Plain `api` request | Minimal path: arg parsing → HTTP GET → JSON decode → stdout |
| Config-file credentials | Adds disk read + INI parse |
| CLI-flag credentials | Exercises the argument-parser credential path |
| Pretty-print (`--pretty`) | Adds JSON re-formatting |
| Archive baseline (dummy job) | Fixed overhead: parsing, initial API call, dir creation |
| Archive with asset-size-limit | Isolates overhead by skipping large assets |
| Archive rich job (~21 MB) | Real I/O throughput and memory pressure |
| Monitor (5 completed jobs) | Per-job API polling overhead |

### Large archive benchmark

The [manual archive test](../tests/manual/test_archive.sh) downloads the full
archive of a production job (~3.4 GB including a large HDD asset) from
a production openQA server. It runs zoqa, openqa-cli, and a raw-curl
baseline sequentially, collecting `/usr/bin/time -v` metrics and MD5 checksums
for each. These numbers are not part of the automated E2E suite because the
download takes ~10–19 minutes per tool and requires significant disk space.

### Large clone-job asset benchmark

The [manual clone-job test](../tests/manual/test_perf_clone.sh) downloads the
assets required for a production job (~2.36 GB across 5 assets, including a
1.45 GB disk image) from `https://openqa.opensuse.org` with `--skip-deps`. It runs
`zoqa-clone-job` (with and without `--show-progress`), `openqa-clone-job`, and a
`curl` baseline sequentially, recording wall-clock time, process resource metrics
via `/usr/bin/time -v`, and file integrity checksums.

### Manual API tests

The [manual API test suite](../tests/manual/test_api.sh) runs 7 `api`
scenarios against a production openQA server over the network, with 3 timing
runs each and per-scenario RSS measurement. It verifies:

- Exit codes (both tools exit 0)
- JSON validity of both outputs
- Semantic field checks on zoqa output (e.g. `.job.id` matches expected value)
- Wall-clock timing via bash `TIMEFORMAT="%R"` (3 runs)
- Peak RSS and process metrics via `/usr/bin/time -v`

All requests are read-only GETs. The test requires `openqa-cli`, `python3`,
and network access to the target server. See [`tests/manual/lib.sh`](../tests/manual/lib.sh)
for shared helpers and configuration.

### Manual schedule/monitor tests

The [manual schedule/monitor test](../tests/manual/test_schedule_monitor.sh)
exercises both subcommands against a production server, verifying correctness
(exit codes, stdout format, job URLs) and collecting timing and RSS metrics.

The schedule and monitor wall-clock timings are **not reported in this
document** because server-side job execution time (~90 s per job) dominates
the measurement, making client-side differences unmeasurable. The only
server-independent metric is Phase 2b (monitoring already-terminal jobs),
which isolates pure client overhead: a single GET to
`experimental/jobs/{id}/status`, JSON parse, and exit. The results (188 ms
vs 1,270 ms, 6.8× speedup; 5.3 MB vs 61.7 MB RSS, 91% less) confirm the
same Mojolicious startup-tax pattern documented in the `api` section above
and add no new insight.
