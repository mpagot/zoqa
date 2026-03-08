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

## Authentication
The tool supports HMAC-SHA1 authentication using API keys. Credentials are resolved with **field-level priority**, meaning each field (Key and Secret) is determined independently:
1. CLI Flags (`--apikey`, `--apisecret`)
2. Environment Variables (`OPENQA_API_KEY`, `OPENQA_API_SECRET`)
3. Configuration file (`client.conf`)

For example, if only `--apisecret` is provided on the command line, it will override the secret from the config file while still using the key defined in that file.

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
  e2e/
    run.sh          — Near End-to-End test harness
  fuzz/
    fuzz_ini.zig    — AFL++ harness: INI config parser
    fuzz_cli.zig    — AFL++ harness: CLI arg parser + jsonToFormEncoded
    fuzz_http.zig   — AFL++ harness: Link header + JSON body parser
    corpus/         — seed inputs for the INI parser fuzzer
    corpus_cli/     — seed inputs for the CLI fuzzer
    corpus_http/    — seed inputs for the HTTP response fuzzer
    ini.dict        — AFL++ token dictionary for INI syntax
    cli.dict        — AFL++ token dictionary for CLI flags/keywords
    http.dict       — AFL++ token dictionary for HTTP Link header syntax
vendor/
  aflplusplus/    — local AFL++ build (git-ignored; run `make source-only` once)
build.zig
build.zig.zon
SPEC.md           — functional specification
PLAN.md           — implementation plan
```
