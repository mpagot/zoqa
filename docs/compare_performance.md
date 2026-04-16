# Performance Comparison: zoqa vs openqa-cli

This document provides a detailed, eventually fair analysis of the performance differences
between zoqa (Zig) and openqa-cli (Perl).

**Production-server measurements are the primary reference in this document.**
They reflect what users actually experience:
 * real network latency,
 * real server-side processing,
 * and real disk I/O.
The containerised E2E suite is valuable for isolating client-side overhead and understanding
*why* zoqa is faster, but its near-zero network latency inflates wall-clock speedup ratios
beyond what any user would see in practice.

Production `api` and `archive` numbers come from the [manual test suites](../tests/manual/)
running against a production openQA server over the network.
E2E numbers come from the automated [performance test suite](../tests/e2e/tests_perf.sh)
running inside a containerised openQA instance.


## Summary table

Production-server measurements (†) are listed first — these best reflect what users
will experience in practice. Container-based E2E measurements follow for reference.

| | `openqa-cli` (Perl) | `zoqa` (Zig) |
|---|---|---|
| **Wall-time per `api` call (production) †** | ~0.6–1.3 s | ~0.13–0.35 s (4–5× faster) |
| **Peak memory (`api`, production) †** | ~61 MB | ~5.3 MB (91% less) |
| **Wall-time `archive` (~3.4 GB, production) †** | ~18m 42s | ~14m 23s (~23% faster) |
| **CPU user time `archive` (~3.4 GB) †** | ~151 s | ~2.9 s (52× less) |
| **Peak memory (`archive`, ~3.4 GB) †** | ~70 MB | ~11 MB (6.3× less) |
| | | |
| **Wall-time per `api` call (E2E, container)** | ~0.5–1.1 s | ~0.02–0.08 s (12–37× faster) |
| **Peak memory (`api`, E2E)** | ~57 MB | ~3.7 MB (93% less) |
| **Wall-time `archive` (~21 MB, E2E)** | ~1.0 s | ~0.4 s (~3× faster) |
| **Peak memory (`archive`, ~21 MB, E2E)** | ~60 MB | ~4 MB (93% less) |

<sup>† Measured against a production openQA server over the network. API numbers:
3 runs each via `tests/manual/test_api.sh` (T4 excluded — server-side table scan dominates).
Archive numbers: single run via `tests/manual/test_archive.sh`;
raw-curl baseline for the same data: ~10m 40s.</sup>


## Where the time goes: decomposing the `api` speedup

The 12–37× speedup measured in the E2E suite is real, but it reflects a
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
| `zoqa api …` (full request) | ~20–80 ms | ~3.7 MB | ~200 |

These are measured values from PERF-B1 and PERF-B2 in the E2E suite (5 runs each).

### Reading the numbers

1. **Bare Perl startup** (`perl -e '1'`) costs ~5 ms and ~4.7 MB — only 215
   minor page faults. Perl's core interpreter is lean and fast. This is
   *not* where the overhead lives.

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
   `OpenQA::Client`, etc.) loading on top of the framework. The actual HTTP
   round-trip to a local server adds negligible time — it is lost in the noise.

4. **zoqa full request** does all of the above in ~20–80 ms total, with ~3.7 MB
   RSS and ~200 minor faults. There is no framework to load; the binary maps
   into memory in one shot at startup.


The "speedup" is honest but should be understood correctly: zoqa is not doing
the HTTP work 13–37× faster. The network round-trip is roughly the same for
both.
The difference is that openqa-cli pays a ~730 ms average tax on every
invocation to load Mojolicious — highly variable, and unavoidable, because
it is the nature of a CPAN-based runtime.
zoqa, as a compiled static binary, simply does not have this cost.

The high variability in the Mojo load time also explains why openqa-cli timings
fluctuate significantly between runs: on a cold cache it may take 1.1 s, on a
warm one 0.4 s — a 2.7× swing with no change in workload.

For a single interactive invocation, both tools respond in under a second — the
difference is noticeable but not critical. For a CI pipeline making hundreds of
`api` calls in a loop, the ~730 ms average overhead compounds to minutes.


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

T4 (`jobs?id=:id`) is excluded — the server performs a full table scan
(~20 s) that dominates both tools equally, making client-side differences
unmeasurable.

### Peak RSS

| Test | Zig | Perl | Reduction |
|---|---|---|---|
| T1–T3, T5–T7 (normal) | ~5.3–5.4 MB | ~61–69 MB | 91–92% |
| T4 (large response) | 76 MB | 145 MB | 47% |

The 91% reduction is consistent across all normal API workloads — Perl loads
the full Mojolicious stack regardless of response size. For T4, both tools
buffer a multi-megabyte response body; Zig still uses 47% less memory.

### Why 4× here vs 12–37× in E2E

The E2E suite runs against a local containerised server with sub-millisecond
network latency. There, the ~730 ms Mojolicious startup tax is nearly the
entire wall time of a Perl request, yielding 12–37× ratios. Over a real
network, the ~100–200 ms of round-trip time is a fixed floor for both tools,
compressing the ratio. The typical speedup against a production server is
**4–5× on wall-clock**, with the startup tax still visible but diluted by I/O
wait.

### Perl timing variance

Perl's run-to-run variance is notably higher than Zig's. T2 shows
807/921/1,431 ms across 3 runs; Zig shows 143/142/146 ms. The 1,431 ms
outlier inflates T2's 7.3× figure — the steady-state ratio is closer to 4×.
The variance likely reflects Mojolicious module loading interacting with OS
page-cache state and GC pauses.


## The `archive` story: startup overhead vs architectural difference

The `archive` subcommand tells a more nuanced story than `api`, because there
are *two* distinct effects at play.

### Small jobs (~21 MB, E2E suite)

| Metric | openqa-cli | zoqa | Ratio |
|---|---|---|---|
| Wall time | ~1.0 s | ~0.4 s | ~3× faster |
| Peak RSS | ~60 MB | ~4 MB | 93% less |

On small downloads, most of the gap is still startup overhead. The actual I/O
completes in a fraction of a second for both tools.

### Large jobs (~3.4 GB, production server)

The [manual archive test](../tests/manual/test_archive.sh) downloads the full
archive of a production job — including a multi-GB HDD
asset, test results, logs, and uploaded logs. A raw-curl baseline (same two
largest files, no API logic) establishes the network floor.

| Metric | openqa-cli | zoqa | curl baseline | Ratio (Perl/Zig) |
|---|---|---|---|---|
| Wall time | 18m 42s | 14m 23s | 10m 40s | ~1.3× faster |
| User CPU | 151 s | 2.9 s | 13 s | 52× less |
| System CPU | 66 s | 52 s | 52 s | ~same |
| Peak RSS | 70 MB | 11 MB | 15 MB | 6.3× less |
| Exit status | 0 | 0 | 0 | — |

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
  - The Perl process holds ~70 MB RSS throughout (Mojolicious runtime + buffers)
  - CPU user time is 52× higher due to Perl-level data copying

The curl baseline puts the wall-time result in context: the network floor is
10m 40s. zoqa adds 3m 43s of client overhead (API calls, directory creation,
dozens of small file downloads); openqa-cli adds 8m 2s. The ~23% wall-time
advantage is real but modest because network throughput is the bottleneck. **CPU
and memory** are where the architectural difference shows its full effect: zoqa
uses 52× less user CPU and 6.3× less memory than openqa-cli, while doing
strictly more work than curl.


## RSS deep-dive: what the ~57–61 MB actually is

Both the E2E suite and the manual API tests collect detailed process metrics via
`/usr/bin/time -v`. A typical `api` call shows:

```
                      E2E (local)           Manual (remote)
PERL peak RSS:        57,880 kB             61,580 kB
ZIG  peak RSS:         3,756 kB              5,344 kB
Minor faults:  PERL:  11,943       PERL:    12,179
               ZIG:      202       ZIG:        266
User time (s): PERL:    0.79       PERL:      0.57
               ZIG:     0.00       ZIG:       0.00
```

The ~12,000 minor page faults on the Perl side are the Mojolicious module pages
being demand-paged into RSS. zoqa's ~200–270 minor faults are the ELF loader
mapping the static binary — its entire working set fits in ~3.7–5.4 MB.

Perl's RSS is dominated by the framework regardless of what the application
does. Whether it's a plain GET, a config-file read, a pretty-print, or an
authenticated request, the peak RSS stays at ~57–62 MB. zoqa stays at
~3.7–5.4 MB across all scenarios.

For the `archive` subcommand, the pattern holds at larger scale. On a ~3.4 GB
download against a production server, openqa-cli peaks at 70 MB RSS while zoqa
peaks at 11 MB — 6.3× less. Notably, zoqa uses *less* memory than raw curl
(15 MB) for the same data, because zoqa's streaming buffers are stack-allocated
and smaller than curl's heap allocations.


## When does this matter in practice?

| Use case | Impact |
|---|---|
| **Interactive one-off query** | Imperceptible — both respond in under a second |
| **CI pipeline with hundreds of `api` calls** | Startup compounds: ~500 ms × 200 calls = ~100 s of pure framework loading |
| **Containers / minimal images** | zoqa is a single static binary (zero deps); openqa-cli needs Perl + ~15 CPAN packages |
| **Large `archive` downloads (GB-scale)** | Streaming vs. buffering: 52× less CPU, 6× less memory, no temp-file doubling |
| **Memory-constrained environments** | ~4 MB vs ~57 MB baseline — matters on small VMs or when running many parallel clients |


## About openqa-cli

`openqa-cli` is part of the [openQA project](https://github.com/os-autoinst/openQA),
actively maintained by the SUSE and openSUSE teams. The client library
(`OpenQA::Client`) dates to **2015** — over 10 years of production use — with
the CLI layer (`OpenQA::CLI`) added in **2020**.

### Code size in context

The Perl implementation is ~750 lines of application code across 9 files.
It is compact *because* Mojolicious handles HTTP, TLS, JSON, async I/O,
temporary-file management, and content negotiation on its behalf. The framework
is battle-tested and provides capabilities (WebSocket, non-blocking I/O, upload
handling) that openqa-cli uses with minimal code.

zoqa reimplements all of the HTTP, JSON, auth, config parsing, and I/O logic
against the Zig standard library in ~5,500 lines:

| Module | Lines | Purpose |
|---|---|---|
| `main.zig` | ~2,652 | CLI entry point, arg parsing, dispatch |
| `root.zig` | ~736 | Library root, C-ABI exports |
| `http_client.zig` | ~733 | HTTP client with retry logic |
| `archive.zig` | ~448 | Archive download (streaming) |
| `schedule.zig` | ~344 | Schedule subcommand |
| `monitor.zig` | ~234 | Monitor subcommand |
| `config.zig` | ~231 | INI config parser |
| `auth.zig` | ~129 | HMAC-SHA1 authentication |

The 7× difference in line count is a direct consequence of having zero
external dependencies — every feature that Mojolicious provides for free must
be written explicitly.


## Methodology

### E2E performance tests

The [E2E performance suite](../tests/e2e/tests_perf.sh) runs inside a Podman
container with a real openQA instance. It measures:

- **Wall-clock time** — via bash `TIMEFORMAT="%R"` (3–5 runs per scenario)
- **Peak RSS** — via `/usr/bin/time -v` (`getrusage(2)` high-water mark)
- **Interpreter baselines** — `perl -e '1'` and `perl -MMojo::UserAgent -e '1'`
  to isolate framework startup cost from application work

All results are informational — no pass/fail thresholds are enforced. Timing
in a containerised environment is inherently noisy; the numbers show relative
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
server-independent metric is Phase 2b — monitoring already-terminal jobs —
which isolates pure client overhead: a single GET to
`experimental/jobs/{id}/status`, JSON parse, and exit. The results (188 ms
vs 1,270 ms, 6.8× speedup; 5.3 MB vs 61.7 MB RSS, 91% less) confirm the
same Mojolicious startup-tax pattern documented in the `api` section above
and add no new insight.
