# Fuzz Testing `openQAclient`

Coverage-guided fuzz testing uses [AFL++](https://github.com/AFLplusplus/AFLplusplus)
in Persistent Mode with LLVM instrumentation.

## Fuzz Targets

There are three separate fuzz targets, one per domain:

| Binary | Harness | Corpus | Dict | What it tests |
|---|---|---|---|---|
| `zoqa-fuzz-ini` | `fuzz_ini.zig` | `corpus/` | `ini.dict` | INI config parser (`src/config.zig`) |
| `zoqa-fuzz-cli` | `fuzz_cli.zig` | `corpus_cli/` | `cli.dict` | CLI arg parser + `buildRequest` pipeline (`src/main.zig`) |
| `zoqa-fuzz-http` | `fuzz_http.zig` | `corpus_http/` | `http.dict` | Link header parser + JSON parse/stringify (`src/http_client.zig`) |
| `zoqa-fuzz-auth` | `fuzz_auth.zig` | `corpus_auth/` | `auth.dict` | HMAC-SHA1 signing + URL normalization (`src/auth.zig`) |
| `zoqa-fuzz-gzip` | `fuzz_gzip.zig` | `corpus_gzip/` | — | Gzip decompression + JSON parse/stringify |

## Setup

AFL++ is vendored at `vendor/aflplusplus/` (git-ignored).

### 1. Install LLVM

AFL++'s LLVM mode requires `llvm-config` and `clang` from the same LLVM version (recommended: 18 or newer).

```sh
# openSUSE / Tumbleweed
sudo zypper install llvm21-devel clang21

# Fedora
sudo dnf install llvm-devel clang

# Ubuntu / Debian
sudo apt-get install llvm-dev clang
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
PATH="$PWD/vendor/aflplusplus:$PATH" zig build -Dfuzz
# Produces binaries in zig-out/
```

## Workflow

### 1. Minimise the seed corpora

Run `afl-cmin` separately for each target to remove redundant seeds. AFL++ prioritizes "favored" seeds—those that are smaller and faster while covering unique edges.

```sh
# From the project root

# INI parser
rm -rf tests/fuzz/corpus_ini_min
PATH="$PWD/vendor/aflplusplus:$PATH" \
  vendor/aflplusplus/afl-cmin \
    -i tests/fuzz/corpus_ini \
    -o tests/fuzz/corpus_ini_min \
    -- ./zig-out/zoqa-fuzz-ini

# CLI argument parser
rm -rf tests/fuzz/corpus_cli_min
PATH="$PWD/vendor/aflplusplus:$PATH" \
  vendor/aflplusplus/afl-cmin \
    -i tests/fuzz/corpus_cli \
    -o tests/fuzz/corpus_cli_min \
    -- ./zig-out/zoqa-fuzz-cli

# HTTP response parser
rm -rf tests/fuzz/corpus_http_min
PATH="$PWD/vendor/aflplusplus:$PATH" \
  vendor/aflplusplus/afl-cmin \
    -i tests/fuzz/corpus_http \
    -o tests/fuzz/corpus_http_min \
    -- ./zig-out/zoqa-fuzz-http

# Auth / HMAC-SHA1 signing
rm -rf tests/fuzz/corpus_auth_min
PATH="$PWD/vendor/aflplusplus:$PATH" \
  vendor/aflplusplus/afl-cmin \
    -i tests/fuzz/corpus_auth \
    -o tests/fuzz/corpus_auth_min \
    -- ./zig-out/zoqa-fuzz-auth

# Gzip decompression
rm -rf tests/fuzz/corpus_gzip_min
PATH="$PWD/vendor/aflplusplus:$PATH" \
  vendor/aflplusplus/afl-cmin \
    -i tests/fuzz/corpus_gzip \
    -o tests/fuzz/corpus_gzip_min \
    -- ./zig-out/zoqa-fuzz-gzip
```

### 2. Run a fuzzer

For maximum performance, point AFL++ to a RAM disk (tmpfs) to avoid disk I/O bottlenecks:

```sh
export AFL_TMPDIR=/tmp/afl_fuzz

# HTTP response parser
PATH="$PWD/vendor/aflplusplus:$PATH" \
  vendor/aflplusplus/afl-fuzz \
    -M main-node \
    -i tests/fuzz/corpus_http_min \
    -o tests/fuzz/out_http \
    -x tests/fuzz/http.dict \
    -- ./zig-out/zoqa-fuzz-http
```

### 3. Resuming a Campaign

To leverage the knowledge gained in previous runs, point the fuzzer to its own output directory using `-i -`:

```sh
PATH="$PWD/vendor/aflplusplus:$PATH" \
  vendor/aflplusplus/afl-fuzz \
    -M main-node \
    -i - \
    -o tests/fuzz/out_http \
    -x tests/fuzz/http.dict \
    -- ./zig-out/zoqa-fuzz-http
```

### 4. Crash Triage

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
AFL_IGNORE_PROBLEMS=1 ./zig-out/zoqa-fuzz-auth \
  < tests/fuzz/out_auth/main-node/crashes/id:000000,...
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
  -i "tests/fuzz/out_auth/main-node/crashes/id:000000,..." \
  -o /tmp/tmin_work/crash_min.bin \
  -- ./zig-out/zoqa-fuzz-auth
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
3. Optionally, resume the fuzzing campaign with `-i -` to confirm the
   fuzzer no longer re-discovers the same crash.

#### Step 6 — Promote minimised inputs to the seed corpus

If the minimised crash input (after the fix makes it a valid non-crashing
input) exercises a previously uncovered code path, add it to the tracked
seed corpus for the target (`tests/fuzz/corpus_<target>/`). This
permanently encodes the new coverage into future fuzzing campaigns.

---

### 5. Corpus Distillation & Seed Promotion

As the fuzzer runs, it discovers new interesting inputs in `tests/fuzz/out_*/main-node/queue/`. 

1.  **Distillation:** Periodically minimize the machine-generated queue back into a temporary directory:
    ```sh
    rm -rf tests/fuzz/corpus_distilled
    PATH="$PWD/vendor/aflplusplus:$PATH" \
      vendor/aflplusplus/afl-cmin \
        -i tests/fuzz/out_http/main-node/queue \
        -o tests/fuzz/corpus_distilled \
        -- ./zig-out/zoqa-fuzz-http
    ```
2.  **Promotion:** If the fuzzer finds an input that covers a significantly new area of code, copy it from `corpus_distilled` into your tracked `tests/fuzz/corpus_http/` directory. This preserves the "machine-learned" knowledge permanently in source control.

---

## Helper Scripts

Two convenience scripts in `tests/fuzz/` wrap the most common operations. Both
can be run from the project root or from `tests/fuzz/`; they locate the project
root automatically.

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
# Minimise all five corpora
./tests/fuzz/cmin.sh

# Minimise a single target
./tests/fuzz/cmin.sh ini

# Minimise multiple specific targets
./tests/fuzz/cmin.sh cli http auth
```

Valid target names: `ini`, `cli`, `http`, `auth`, `gzip`.
