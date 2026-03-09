# openQAclient

A Zig reimplementation of the `openqa-cli api` subcommand, distributed as
both a CLI executable and a static library.

---

## Prerequisites

- Zig 0.15.2
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

### Near End-to-End Testing (openQA Container)

Validates CLI behavior, HMAC authentication, and API parity with the Perl reference
using a live official openQA single-instance container.

Requires: Podman, `/dev/kvm` access recommended.

```sh
# Ensure the binary is built first
zig build

# Run the full E2E suite (starts container, seeds data, runs 20 tests, tears down)
bash tests/e2e/run.sh
```

See [tests/e2e/README.md](tests/e2e/README.md) for the full script reference,
debugging tips, flag documentation (e.g., `--keep-container`), and test coverage table.

---

### Fuzz Testing

Coverage-guided fuzz testing using AFL++ is supported for the INI parser, CLI argument parser, and HTTP response handling.

Refer to [tests/fuzz/README.md](tests/fuzz/README.md) for setup and workflow instructions.

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
PLAN.md           — implementation plan
```
