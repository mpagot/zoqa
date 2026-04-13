# Performance Comparison: zoqa vs openqa-cli

This document provides a detailed, eventually fair analysis of the performance differences
between zoqa (Zig) and openqa-cli (Perl).

All E2E numbers below come from the automated [performance test suite](../tests/e2e/tests_perf.sh)
running inside a containerised openQA instance. The 2.6 GB archive benchmark was measured
separately against a real openQA instance.

---

## Summary table

| | `openqa-cli` (Perl) | `zoqa` (Zig) |
|---|---|---|
| **Wall-time per `api` call** | ~0.5–1.1 s | ~0.02–0.08 s (12–37× faster) |
| **Peak memory (`api`)** | ~57 MB | ~3.7 MB (93% less) |
| **Wall-time `archive` (~21 MB job)** | ~1.0 s | ~0.4 s (~3× faster) |
| **Peak memory (`archive`, ~21 MB)** | ~60 MB | ~4 MB (93% less) |
| **Wall-time `archive` (2.6 GB job) ‡** | ~15m 28s | ~10m 20s (~50% faster) |
| **CPU user time `archive` (2.6 GB) ‡** | ~112 s | ~8 s (14× less) |
| **Peak memory (`archive`, 2.6 GB) ‡** | ~69 MB | ~14 MB (4.8× less) |

<sup>‡ Measured manually on a dedicated host, not in the containerised E2E suite.</sup>

---

## Where the time goes: decomposing the `api` speedup

The 12–37× speedup on `api` calls is real, but the cause is almost entirely
**Perl + Mojolicious startup overhead**, not a difference in HTTP performance.

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

### What this means

The "speedup" is honest but should be understood correctly: zoqa is not doing
the HTTP work 13–37× faster. The network round-trip is roughly the same for
both. The difference is that openqa-cli pays a ~730 ms average tax on every
invocation to load Mojolicious — highly variable, and unavoidable, because
it is the nature of a CPAN-based runtime. zoqa, as a compiled static binary,
simply does not have this cost.

The high variability in the Mojo load time also explains why openqa-cli timings
fluctuate significantly between runs: on a cold cache it may take 1.1 s, on a
warm one 0.4 s — a 2.7× swing with no change in workload.

For a single interactive invocation, both tools respond in under a second — the
difference is noticeable but not critical. For a CI pipeline making hundreds of
`api` calls in a loop, the ~730 ms average overhead compounds to minutes.

---

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

### Large jobs (2.6 GB, manual benchmark)

| Metric | openqa-cli | zoqa | Ratio |
|---|---|---|---|
| Wall time | ~15m 28s | ~10m 20s | ~50% faster |
| Peak RSS | ~69 MB | ~14 MB | 4.8× less |
| CPU user time | ~112 s | ~8 s | 14× less |

On large downloads, a genuine **architectural difference** dominates:

- **zoqa** streams each HTTP response directly to disk using ~192 KB of
  stack-allocated buffers. Memory usage is constant regardless of file size.

- **openqa-cli** routes each response through Mojolicious's transaction layer,
  which buffers the body into a `/tmp` temporary file before moving it to the
  final destination. This means:
  - Every byte is written to disk twice (temp file → final path)
  - Peak disk usage is approximately double the download size
  - The Perl process holds ~69 MB RSS throughout (Mojolicious runtime + buffers)
  - CPU user time is 14× higher due to Perl-level data copying

The 50% wall-time improvement on 2.6 GB is modest because the bottleneck is
network throughput, not client-side processing. The CPU and memory differences
are where the architectural choice shows its full effect.

---

## RSS deep-dive: what the ~57 MB actually is

The E2E suite collects detailed process metrics via `/usr/bin/time -v`. A
typical `api` call shows:

```
PERL peak RSS: 57,880 kB    ZIG peak RSS: 3,756 kB
Minor page faults:  PERL: 11,943    ZIG: 202
User time (s):      PERL: 0.79      ZIG: 0.00
System time (s):    PERL: 0.08      ZIG: 0.00
```

The ~12,000 minor page faults on the Perl side are the Mojolicious module pages
being demand-paged into RSS. zoqa's ~200 minor faults are the ELF loader
mapping the static binary — its entire working set fits in ~3.7 MB.

Perl's RSS is dominated by the framework regardless of what the application
does. Whether it's a plain GET, a config-file read, a pretty-print, or an
authenticated request, the peak RSS stays at ~57–58 MB. zoqa stays at
~3.7–3.9 MB across all scenarios.

---

## When does this matter in practice?

| Use case | Impact |
|---|---|
| **Interactive one-off query** | Imperceptible — both respond in under a second |
| **CI pipeline with hundreds of `api` calls** | Startup compounds: ~500 ms × 200 calls = ~100 s of pure framework loading |
| **Containers / minimal images** | zoqa is a single static binary (zero deps); openqa-cli needs Perl + ~15 CPAN packages |
| **Large `archive` downloads (GB-scale)** | Streaming vs. buffering: 14× less CPU, 5× less memory, no temp-file doubling |
| **Memory-constrained environments** | ~4 MB vs ~57 MB baseline — matters on small VMs or when running many parallel clients |

---

## About openqa-cli

`openqa-cli` is part of the [openQA project](https://github.com/os-autoinst/openQA),
actively maintained by the SUSE and openSUSE teams. The client library
(`OpenQA::Client`) dates to **2015** — over 10 years of production use — with
the CLI layer (`OpenQA::CLI`) added in **2020**.

### Code size in context

The Perl implementation is ~750 lines of application code across 9 files:

| Module | Lines | Purpose |
|---|---|---|
| `OpenQA::CLI` | ~93 | CLI dispatcher and base class |
| `OpenQA::CLI::api` | ~39 | `api` subcommand |
| `OpenQA::CLI::archive` | ~29 | `archive` subcommand |
| `OpenQA::CLI::monitor` | ~55 | `monitor` subcommand |
| `OpenQA::CLI::schedule` | ~78 | `schedule` subcommand |
| `OpenQA::Client` | ~103 | HTTP client with HMAC auth |
| `OpenQA::Client::Archive` | ~203 | Archive download logic |
| `OpenQA::Client::Handler` | ~31 | Response handler |
| `OpenQA::Client::Upload` | ~97 | Asset upload |
| `script/openqa-cli` | ~17 | Entry point |

It is compact *because* Mojolicious handles HTTP, TLS, JSON, async I/O,
temporary-file management, and content negotiation on its behalf. The framework
is battle-tested and provides capabilities (WebSocket, non-blocking I/O, upload
handling) that openqa-cli uses with minimal code.

zoqa reimplements all of the HTTP, JSON, auth, config parsing, and I/O logic
against the Zig standard library in ~4,900 lines:

| Module | Lines | Purpose |
|---|---|---|
| `main.zig` | ~2,512 | CLI entry point, arg parsing, dispatch |
| `root.zig` | ~730 | Library root, C-ABI exports |
| `http_client.zig` | ~733 | HTTP client with retry logic |
| `archive.zig` | ~448 | Archive download (streaming) |
| `config.zig` | ~231 | INI config parser |
| `auth.zig` | ~129 | HMAC-SHA1 authentication |
| `monitor.zig` | ~140 | Monitor subcommand |

The 6.5× difference in line count is a direct consequence of having zero
external dependencies — every feature that Mojolicious provides for free must
be written explicitly.

### Feature coverage

`openqa-cli` covers ground zoqa has not yet reached:

- The `schedule` subcommand
- Companion scripts: `openqa-clone-job`, `openqa-clone-custom-git-refspec`
- Asset upload (`OpenQA::Client::Upload`)

The authentication scheme, configuration format, host aliases, and entire CLI
design that zoqa implements are derived from `openqa-cli`.

---

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

### 2.6 GB benchmark

The large-archive numbers were measured on a dedicated host (not in CI) with a
real openQA server and a job containing a 2.6 GB disk image. These numbers are
not part of the automated suite because the download takes ~10–15 minutes per
run and requires significant disk space.
