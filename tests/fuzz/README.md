# Fuzz Testing `openQAclient`

Coverage-guided fuzz testing uses [AFL++](https://github.com/AFLplusplus/AFLplusplus)
in Persistent Mode with LLVM instrumentation.

## Fuzz Targets

There are three separate fuzz targets, one per domain:

| Binary | Harness | Corpus | Dict | What it tests |
|---|---|---|---|---|
| `openQAclient-fuzz-ini` | `fuzz_ini.zig` | `corpus/` | `ini.dict` | INI config parser (`src/config.zig`) |
| `openQAclient-fuzz-cli` | `fuzz_cli.zig` | `corpus_cli/` | `cli.dict` | CLI arg parser + `buildRequest` pipeline (`src/main.zig`) |
| `openQAclient-fuzz-http` | `fuzz_http.zig` | `corpus_http/` | `http.dict` | Link header parser + JSON parse/stringify (`src/http_client.zig`) |
| `openQAclient-fuzz-auth` | `fuzz_auth.zig` | `corpus_auth/` | `auth.dict` | HMAC-SHA1 signing + URL normalization (`src/auth.zig`) |
| `openQAclient-fuzz-gzip` | `fuzz_gzip.zig` | `corpus_gzip/` | — | Gzip decompression + JSON parse/stringify |

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
    -- ./zig-out/openQAclient-fuzz-ini

# CLI argument parser
rm -rf tests/fuzz/corpus_cli_min
PATH="$PWD/vendor/aflplusplus:$PATH" \
  vendor/aflplusplus/afl-cmin \
    -i tests/fuzz/corpus_cli \
    -o tests/fuzz/corpus_cli_min \
    -- ./zig-out/openQAclient-fuzz-cli

# HTTP response parser
rm -rf tests/fuzz/corpus_http_min
PATH="$PWD/vendor/aflplusplus:$PATH" \
  vendor/aflplusplus/afl-cmin \
    -i tests/fuzz/corpus_http \
    -o tests/fuzz/corpus_http_min \
    -- ./zig-out/openQAclient-fuzz-http

# Auth / HMAC-SHA1 signing
rm -rf tests/fuzz/corpus_auth_min
PATH="$PWD/vendor/aflplusplus:$PATH" \
  vendor/aflplusplus/afl-cmin \
    -i tests/fuzz/corpus_auth \
    -o tests/fuzz/corpus_auth_min \
    -- ./zig-out/openQAclient-fuzz-auth

# Gzip decompression
rm -rf tests/fuzz/corpus_gzip_min
PATH="$PWD/vendor/aflplusplus:$PATH" \
  vendor/aflplusplus/afl-cmin \
    -i tests/fuzz/corpus_gzip \
    -o tests/fuzz/corpus_gzip_min \
    -- ./zig-out/openQAclient-fuzz-gzip
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
    -- ./zig-out/openQAclient-fuzz-http
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
    -- ./zig-out/openQAclient-fuzz-http
```

### 4. Corpus Distillation & Seed Promotion

As the fuzzer runs, it discovers new interesting inputs in `tests/fuzz/out_*/main-node/queue/`. 

1.  **Distillation:** Periodically minimize the machine-generated queue back into a temporary directory:
    ```sh
    rm -rf tests/fuzz/corpus_distilled
    PATH="$PWD/vendor/aflplusplus:$PATH" \
      vendor/aflplusplus/afl-cmin \
        -i tests/fuzz/out_http/main-node/queue \
        -o tests/fuzz/corpus_distilled \
        -- ./zig-out/openQAclient-fuzz-http
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
