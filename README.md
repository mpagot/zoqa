# openQAclient

A Zig reimplementation of the `openqa-cli api` subcommand, distributed as
both a CLI executable and a static library.

---

## Prerequisites

- Zig 0.15.2

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

Shortcuts: `make build` and `make release` (ReleaseFast).

---

## Make Targets

```sh
make help  # print this table
```

| Target | Description |
|---|---|
| `build` | Build the zoqa executable and static library. |
| `release` | Build with release optimizations (`ReleaseFast`). |
| `test` | Run all Zig unit tests. |
| `e2e` | Build, then run the full E2E suite (starts + tears down container). |
| `e2e-keep` | Build, then run E2E keeping the container alive (`--keep-container`). |
| `lint` | Bash `-n` syntax check and shellcheck on all E2E scripts. |
| `fuzz-build` | Build the instrumented AFL++ fuzz binaries. |

---

## Test

### Unit Testing (Native Zig)

```sh
# Run all unit tests
zig build test --summary all

# Run tests in a single file
zig test src/config.zig
zig test src/main.zig

# Run a single named test (substring match)
zig test src/config.zig --test-filter "parseIni"
```

Shortcut: `make test`.

### Near End-to-End Testing (openQA Container)

Validates CLI behavior, HMAC authentication, and API parity with the Perl reference
using a live official openQA single-instance container managed by Podman.

See [tests/e2e/README.md](tests/e2e/README.md) for prerequisites, script reference,
flags (`--keep-container`, `--collect-logs`, `--dryrun`), debugging tips, and full
test coverage table.

Shortcuts: `make e2e` and `make e2e-keep`.

### Fuzz Testing

Coverage-guided fuzz testing using AFL++ in Persistent Mode with LLVM instrumentation.

See [tests/fuzz/README.md](tests/fuzz/README.md) for setup, workflow, crash triage,
corpus distillation, and coverage reporting.

Shortcut: `make fuzz-build`.

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
  e2e/      — Near End-to-End test harness (see [tests/e2e/README.md](tests/e2e/README.md))
  fuzz/     — AFL++ fuzzing infrastructure (see [tests/fuzz/README.md](tests/fuzz/README.md))
vendor/
  aflplusplus/    — local AFL++ build (git-ignored; run `make source-only` once)
build.zig
build.zig.zon
SPEC.md           — functional specification
```
