# Fuzz Testing `openQAclient`

Coverage-guided fuzz testing uses [AFL++](https://github.com/AFLplusplus/AFLplusplus)
in Persistent Mode with LLVM instrumentation.

## Fuzz Targets

There are two generations of harnesses. Gen-2 is the active set; gen-1 is kept
for performance comparison until gen-2 campaigns are established, then will be
removed.

### Gen-2 (current)

| Binary | Harness | Corpus | Dict | What it tests |
|---|---|---|---|---|
| `zoqa-fuzz-config` | `fuzz_config.zig` | `corpus_config/` | `ini.dict` | INI parser + `resolveHost` all 7 branches (`src/config.zig`) |
| `zoqa-fuzz-request` | `fuzz_request.zig` | `corpus_request/` | `cli.dict` | CLI args + `buildRequest` + `parseLinkHeader` + JSON (`src/main.zig`, `src/http_client.zig`) |
| `zoqa-fuzz-execute` | `fuzz_execute.zig` | `corpus_execute/` | — | Full pipeline: auth + retry + gzip + `openQAReq` (`src/http_client.zig`, `src/auth.zig`) |

### Gen-1 (deprecated — pending removal)

| Binary | Harness | Corpus | Dict | Superseded by |
|---|---|---|---|---|
| `zoqa-fuzz-ini` | `fuzz_ini.zig` | `corpus_ini/` | `ini.dict` | `zoqa-fuzz-config` |
| `zoqa-fuzz-cli` | `fuzz_cli.zig` | `corpus_cli/` | `cli.dict` | `zoqa-fuzz-request` |
| `zoqa-fuzz-http` | `fuzz_http.zig` | `corpus_http/` | `http.dict` | `zoqa-fuzz-request` |
| `zoqa-fuzz-auth` | `fuzz_auth.zig` | `corpus_auth/` | `auth.dict` | `zoqa-fuzz-execute` |
| `zoqa-fuzz-gzip` | `fuzz_gzip.zig` | `corpus_gzip/` | — | `zoqa-fuzz-execute` |

## Setup

AFL++ is vendored at `vendor/aflplusplus/` (git-ignored).

### 1. Install LLVM

AFL++'s LLVM mode requires `llvm-config` and `clang` from the same LLVM version (recommended: 18 or newer).

```sh
# openSUSE / Tumbleweed
sudo zypper install llvm21-devel clang21
```

### 2. Build the vendored AFL++

```sh
make source-only -j$(nproc) -C vendor/aflplusplus
# Produces: vendor/aflplusplus/afl-fuzz, vendor/aflplusplus/afl-cc, ...
```

### 3. Build the instrumented binaries

`afl-cc` must be on `PATH`. Pass `-Dfuzz` to activate the fuzz build step:

```sh
# From the project root
./tests/fuzz/build.sh
# Produces all the test binaries in zig-out/
```

## Workflow

### Minimise the seed corpora

Use `cmin.sh` to run `afl-cmin` for all targets or a named subset:

```sh
# Minimise all corpora
./tests/fuzz/cmin.sh

# Minimise a single target
./tests/fuzz/cmin.sh config
```

### Run a fuzzer

Use `run.sh` to launch exactly one target:

```sh
# Fresh run (requires corpus_<target>_min/ to be non-empty)
./tests/fuzz/run.sh config

# Resume a prior campaign
./tests/fuzz/run.sh config --continue
```

The script sets `AFL_SKIP_CPUFREQ=1` and `AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1`
by default; override by exporting those variables before calling `run.sh`.

For maximum performance, point AFL++ to a RAM disk (tmpfs) to avoid disk I/O
bottlenecks:

```sh
export AFL_TMPDIR=/tmp/afl_fuzz
./tests/fuzz/run.sh request
```

### Distill and promote the queue

After a fuzzing campaign, use `distill.sh` to distill the machine-generated
queue into an optimised seed corpus and promote it into the tracked
`corpus_<target>/` directory. This replaces the old seeds with the smallest
set of files that covers every execution path discovered by the fuzzer, with
each file individually minimised by `afl-tmin`.

```sh
# Distill all targets that have queue output
./tests/fuzz/distill.sh

# Distill a single target
./tests/fuzz/distill.sh config

# Skip creating a backup of the old corpus
./tests/fuzz/distill.sh --no-backup config
```

The script performs five steps per target: corpus distillation (`afl-cmin`),
individual file minimisation (`afl-tmin`), backup of the old corpus, promotion
of the distilled corpus, and regeneration of `corpus_<target>_min/` via
`cmin.sh`. See [Helper Scripts](#distillsh--distill-and-promote-the-queue)
for full details.

### Crash Triage

After a fuzzing session, any inputs that triggered a crash or hang are saved
under `tests/fuzz/out_<target>/main-node/crashes/` and
`tests/fuzz/out_<target>/main-node/hangs/`.

The crash filename encodes the signal number (`sig:`), source queue entry
(`src:`), elapsed time, and mutation operator, for example:

```
id:000000,sig:06,src:000091,time:5018,execs:76791,op:havoc,rep:53
```

`sig:06` is `SIGABRT` — in Zig this means a safety-checked panic
(integer overflow, out-of-bounds slice, unreachable, etc.).

#### Step 1 — Reproduce outside AFL++

Run the crash input directly against the fuzz binary. Because the binary
links the AFL forkserver, set `AFL_IGNORE_PROBLEMS=1` to prevent the
forkserver from aborting before the panic is reached:

```sh
AFL_IGNORE_PROBLEMS=1 ./zig-out/zoqa-fuzz-config \
  < tests/fuzz/out_config/main-node/crashes/id:000000,...
```

The Zig panic handler prints a stack trace with the exact source location
and panic message to stderr. Note the file and line number.

#### Step 2 — Minimise the crash input with `afl-tmin`

Raw AFL crash files are often large and contain irrelevant bytes.
`afl-tmin` reduces the input to the smallest byte sequence that still
triggers the same crash, making root-cause analysis easier:

```sh
mkdir -p /tmp/tmin_work
AFL_IGNORE_PROBLEMS=1 vendor/aflplusplus/afl-tmin \
  -i "tests/fuzz/out_config/main-node/crashes/id:000000,..." \
  -o /tmp/tmin_work/crash_min.bin \
  -- ./zig-out/zoqa-fuzz-config
```

Inspect the minimised input to understand the triggering condition:

```sh
xxd /tmp/tmin_work/crash_min.bin
# or, for text-like inputs:
cat /tmp/tmin_work/crash_min.bin
```

#### Step 3 — Read the panic and locate the root cause

The Zig panic output names the source file, line, and column. Common
panics to watch for:

| Panic message | Likely cause |
|---|---|
| `integer overflow` | Arithmetic on a too-small inferred integer type; use `@as(usize, ...)` or explicit casts |
| `index out of bounds` | Slice or array access past end; add a bounds check |
| `attempt to unwrap null` | Unconditional `.?` on an optional; handle `null` explicitly |
| `unreachable` | Control flow reached a branch marked `unreachable`; add a missing case |

For `integer overflow` in particular, watch out for Zig's peer-type
resolution: `@min(runtime_val, comptime_int_N)` infers the result type
as the smallest integer that fits `N`, not as `usize`. Arithmetic on that
result (e.g. `result + 1`) overflows when `result == N`. Fix by casting
the comptime operand: `@min(runtime_val, @as(usize, N))`.

#### Step 4 — Write a regression test

Before patching, add a unit test (inline in the relevant source file) that
reproduces the crash deterministically. This prevents silent regressions
if the same code path is touched again:

```zig
test "regression: <short description>" {
    // paste the minimised crash input content here
    // call the function that panicked
    // assert the expected safe behaviour
}
```

#### Step 5 — Fix the code and verify

Apply the fix, then:

1. Confirm the crash no longer triggers:
   ```sh
   AFL_IGNORE_PROBLEMS=1 ./zig-out/zoqa-fuzz-<target> \
     < tests/fuzz/out_<target>/main-node/crashes/id:000000,...
   ```
2. Run unit tests: `zig build test`
3. Optionally, resume the fuzzing campaign with `--continue` to confirm the
   fuzzer no longer re-discovers the same crash.

#### Step 6 — Promote minimised inputs to the seed corpus

If the minimised crash input (after the fix makes it a valid non-crashing
input) exercises a previously uncovered code path, add it to the tracked
seed corpus for the target (`tests/fuzz/corpus_<target>/`). This
permanently encodes the new coverage into future fuzzing campaigns.

---

### 5. Corpus Distillation & Seed Promotion

As the fuzzer runs, it discovers new interesting inputs in `out_<target>/main-node/queue/`.
The `distill.sh` script automates the full post-fuzzing promotion cycle:

```sh
# Distill and promote a single target
./tests/fuzz/distill.sh config

# Distill all targets that have queue output, skip backup
./tests/fuzz/distill.sh --no-backup
```

For each target, `distill.sh` performs five steps:

1. **Distillation (`afl-cmin`):** Extract the smallest subset of queue
   entries that triggers 100% of the accumulated edge coverage.
2. **File minimisation (`afl-tmin`):** Shrink every distilled file to the
   smallest byte sequence that still triggers the same execution path.
   This dramatically improves fuzzing speed in future campaigns.
3. **Backup:** Move `corpus_<target>/` → `corpus_<target>_backup/`
   (pass `--no-backup` to skip this and delete the old corpus instead).
4. **Promotion:** Move the distilled corpus into `corpus_<target>/`.
   The distilled queue is a strict superset of the original corpus in
   terms of code coverage, so there is no need to merge — it replaces
   the old seeds entirely.
5. **Regeneration:** Re-run `cmin.sh <target>` to produce a fresh
   `corpus_<target>_min/` for the next fuzzing campaign.

After promotion, the updated `corpus_<target>/` should be committed to
Git so that other developers and CI benefit from the machine-discovered
seeds.

---

## Coverage

Source-level coverage uses [kcov](https://github.com/SimonKagstrom/kcov) with
the Zig self-hosted backend. The LLVM backend must **not** be used for coverage
binaries — kcov reports 0% on x86_64-linux when Zig compiles via LLVM due to
missing DWARF line information (see [ziglang/zig#25368](https://github.com/ziglang/zig/issues/25368)).
`cov_build.zig` leaves `use_llvm` unset (null) so Zig automatically selects the
self-hosted backend for native Debug builds.

### Install kcov

```sh
# openSUSE
sudo zypper install kcov
```

### Run coverage

```sh
# Coverage for a single gen-2 target (seeds from corpus_config/)
zig build -p . --build-file tests/fuzz/cov_build.zig coverage-config

# Coverage for all three gen-2 targets
zig build -p . --build-file tests/fuzz/cov_build.zig coverage

# Open the report
xdg-open coverage/config/index.html
```

Reports are written to `zig-out/coverage/{config,request,execute}/`.

### How it works

`cov_build.zig` enumerates every seed file in `corpus_<name>/` at build-graph
construction time and generates one `kcov` invocation per seed. The first
invocation passes `--clean` to reset any stale report; subsequent invocations
merge into the same output directory. All invocations are chained serially so
kcov never runs concurrently (concurrent kcov runs corrupt the merged output).

---

## Helper Scripts

Three convenience scripts in `tests/fuzz/` wrap the most common operations. All
can be run from the project root or from `tests/fuzz/`; they locate the project
root automatically.

A fourth script, `distill.sh`, handles the post-fuzzing promotion workflow.

### `build.sh` — build all instrumented binaries

Equivalent to `PATH="$PWD/vendor/aflplusplus:$PATH" zig build -Dfuzz`, with
upfront validation that AFL++ has been built.

```sh
# Build with defaults
./tests/fuzz/build.sh

# Pass extra zig build flags
./tests/fuzz/build.sh -Doptimize=ReleaseSafe
```

### `cmin.sh` — minimise seed corpora

Runs `afl-cmin` for all targets or a named subset, writing results to the
corresponding `corpus_<name>_min/` directories.

```sh
# Minimise all corpora
./tests/fuzz/cmin.sh

# Minimise a single target
./tests/fuzz/cmin.sh config

# Minimise multiple specific targets
./tests/fuzz/cmin.sh config request execute
```

Valid target names: `config`, `request`, `execute`, `ini`, `cli`, `http`, `auth`, `gzip`.

### `run.sh` — run a single fuzzer

Launches `afl-fuzz` for exactly one named target.

```sh
# Fresh run
./tests/fuzz/run.sh config

# Resume a prior campaign
./tests/fuzz/run.sh config --continue
```

Valid target names: same as `cmin.sh`.

### `distill.sh` — distill and promote the queue

After a fuzzing campaign, distills the machine-generated queue into an
optimised seed corpus and promotes it into the tracked `corpus_<target>/`
directory. Runs `afl-cmin` (corpus distillation), then `afl-tmin` (individual
file minimisation), then backs up and replaces the old corpus, and finally
regenerates the `_min/` directory via `cmin.sh`.

```sh
# Distill all targets that have queue output
./tests/fuzz/distill.sh

# Distill a single target
./tests/fuzz/distill.sh config

# Distill multiple specific targets
./tests/fuzz/distill.sh config request

# Skip creating a backup of the old corpus
./tests/fuzz/distill.sh --no-backup config
```

Valid target names: same as `cmin.sh`. When no targets are specified, all
targets with a non-empty `out_<target>/main-node/queue/` are processed.
