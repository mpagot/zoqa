# Architecture

## Overview

zoqa is structured as **one library and multiple executables**. The
library provides the core openQA protocol logic; executables handle
CLI-specific concerns (argument parsing, environment variables, process
lifecycle).

---

## Layers

### Library layer (`src/root.zig`)

The `zoqa` library is the sole public API for interacting with openQA. It is
designed to be consumed by CLI tools, GUI applications, web frontends, or test
harnesses without modification.

**Rules:**

- No `std.process` dependencies (no env vars, no `exit`, no argv).
- No stdout/stderr output except via the `quiet` flag on diagnostics.
- No CLI-specific concepts (help text, exit codes, argument parsing).
- All I/O is injected via `client: anytype` (dependency injection for testability).
- All allocations are explicit (pass `std.mem.Allocator`, no globals).

**Services exposed:**

- `openQAReq(host, path, opts, client)` — authenticated HTTP request to openQA.
- Workflow orchestrators: `runArchive`, `runMonitor`, `runSchedule`.
- Pure utilities: credential lookup (`config.findCredentials`), host resolution
  (`config.resolveHost`), credential merge (`config.mergeCredentials`), auth
  headers (`auth.buildAuthHeaders`), URL encoding (`url.formEncodeAppend`),
  Link header parsing (`parseLinkHeader`).

### Executable layer (`*_main.zig`)

Each executable owns:

- Its `Args` struct and `parseArgs` function.
- Help text and exit-code policy.
- Subcommand dispatch and error formatting.
- The process lifecycle (`main()`, `std.process.exit`).

**Rules:**

- Business logic lives in the library; executables are thin orchestration shells.
- Each executable may define its own named helper functions for multi-phase

---

## Design Principles

1. **Library purity.** A GUI or web frontend can call `zoqa.openQAReq(...)` and
   `zoqa.runSchedule(...)` without pulling in any CLI machinery.


---

## Build Modules

```
build.zig:
  lib_mod (zoqa)        -> src/root.zig              [library: UX-agnostic]
  exe (zoqa)            -> src/main.zig              [imports: zoqa, arg_match, cli_credentials]
```

---
