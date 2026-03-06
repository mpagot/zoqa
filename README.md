# openQAclient

A Zig 0.15.2 reimplementation of the `openqa-cli api` subcommand, distributed as
both a CLI executable and a static library.

---

## Prerequisites

- [asdf](https://asdf-vm.com/) with the Zig plugin, or Zig 0.15.2 installed manually
- The `.tool-versions` file pins `zig 0.15.2`; run `asdf install` to activate it
- [Podman](https://podman.io/) (for Near-E2E testing)
- `/dev/kvm` access (recommended for E2E container stability)

---

## Build

```sh
# Build library + executable
zig build

# Run the executable
zig build run -- api jobs/overview

# Build with step summary
zig build --summary all
```

---

## Test

### 1. Unit Testing (Native Zig)

```sh
# Run all unit tests
zig build test --summary all

# Run tests in a single file
zig test src/config.zig
zig test src/main.zig

# Run a single named test (substring match)
zig test src/config.zig --test-filter "parseIni"
```

### 2. Near End-to-End Testing (openQA Container)

This validates the HTTP client, HMAC handshake, and API interaction against a live
official openQA single-instance container.

```sh
# Ensure the binary is built first
zig build

# Run the E2E suite (starts/stops container automatically)
./tests/e2e/run.sh
```

---

## Fuzz Testing

Coverage-guided fuzz testing targets the INI parser in `src/config.zig` using
[AFL++](https://github.com/AFLplusplus/AFLplusplus) in Persistent Mode with LLVM
instrumentation.

AFL++ is vendored at `vendor/aflplusplus/` (git-ignored). Build it once after
cloning the repo.

### 1. Install LLVM

AFL++'s LLVM mode requires `llvm-config` and `clang` from the same LLVM version.

```sh
# openSUSE / Tumbleweed
sudo zypper install llvm21-devel
```

### 2. Build the vendored AFL++

```sh
make source-only -j$(nproc) -C vendor/aflplusplus
# Produces: vendor/aflplusplus/afl-fuzz, vendor/aflplusplus/afl-cc, ...
```

### 3. Build the instrumented binary

`afl-cc` must be on `PATH`. Prefix the build command with the vendor directory:

```sh
PATH="$PWD/vendor/aflplusplus:$PATH" zig build -Dfuzz
# Produces: zig-out/openQAclient-afl
```

### 4. Minimise the seed corpus

```sh
rm -rf tests/fuzz/corpus_min
PATH="$PWD/vendor/aflplusplus:$PATH" \
  vendor/aflplusplus/afl-cmin -i tests/fuzz/corpus -o tests/fuzz/corpus_min \
  -- ./zig-out/openQAclient-afl
```

### 5. Run the fuzzer

```sh
# Single main node
PATH="$PWD/vendor/aflplusplus:$PATH" \
  vendor/aflplusplus/afl-fuzz \
    -M main-node \
    -i tests/fuzz/corpus_min \
    -o tests/fuzz/out \
    -x tests/fuzz/ini.dict \
    -- ./zig-out/openQAclient-afl
```

---

## Project Layout

```
src/
  main.zig        — CLI entry point
  root.zig        — library root (re-exports config + auth)
  config.zig      — INI parser, credential and host resolution
  auth.zig        — HMAC-SHA1 auth header generation
  http_client.zig — std.http.Client wrapper (retry, response handling)
tests/
  e2e/
    run.sh        — Near End-to-End test harness
  fuzz/
    fuzz.zig      — AFL++ persistent-mode fuzz harness
    corpus/       — seed inputs for the INI parser fuzzer
    ini.dict      — AFL++ token dictionary for INI syntax
vendor/
  aflplusplus/    — local AFL++ build (git-ignored; run `make source-only` once)
build.zig
build.zig.zon
SPEC.md           — functional specification
PLAN.md           — implementation plan
```
