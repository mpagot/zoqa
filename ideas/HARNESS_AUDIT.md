# Fuzz Harness Coverage Audit

> **Research Date**: 2026-04-28
> **Scope**: Static analysis of all 8 fuzz harnesses (gen-1 + gen-2) against production source code
> **Status**: Complete
>
> **Update 2026-04-29 — Gen-1 cleanup DONE.** The five gen-1 harnesses
> (`fuzz_ini`, `fuzz_cli`, `fuzz_http`, `fuzz_auth`, `fuzz_gzip`) along with
> their corpora (`corpus_{ini,cli,http,auth,gzip}{,_min,_backup}/`),
> output dirs (`out_{ini,cli,http,auth,gzip}/`), dictionaries
> (`ini.dict`, `http.dict`, `auth.dict`), `cov_harness_ini.zig`, and the
> `build.zig` / shell-script entries have all been removed (commit on
> branch `fuzz_refresh`). Recommendation #6 below is complete; the gen-1
> sections in this audit are kept for historical reference.

## Executive Summary

**Gen-1 pruning verdict**: ✅ **DONE** — all 5 gen-1 harnesses (`fuzz_ini`, `fuzz_cli`, `fuzz_http`, `fuzz_auth`, `fuzz_gzip`) have been deleted. Coverage was strictly subsumed by gen-2 harnesses, so no real coverage was lost.

**Gen-2 coverage gaps** (now the active set): The three harnesses (`fuzz_config`, `fuzz_request`, `fuzz_execute`) provide excellent coverage of `config.zig`, `auth.zig`, and `http_client.zig` (87-100%), but completely miss three major src files: `schedule.zig` (500 LoC), `archive.zig` (448 LoC), and `monitor.zig` (234 LoC) — a combined **1182 LoC (20.7% of codebase) is unreachable** by any harness.

**Highest-impact action**: Create a new `fuzz_schedule` harness that exercises `runSchedule` → `runMonitor` through the library API (`zoqa.runSchedule`). This single harness would cover all three missing files.

---

## Table of Contents

1. [Per-harness analysis](#per-harness-analysis)
2. [Coverage matrix](#coverage-matrix)
3. [Gen-1 pruning verdict](#gen-1-pruning-verdict)
4. [Gen-2 improvement opportunities](#gen-2-improvement-opportunities)
5. [Completely uncovered src/ areas](#completely-uncovered-src-areas)
6. [Concrete recommendations](#concrete-recommendations)

---

## Per-harness analysis

### Gen-2: fuzz_config.zig

**Input format**: Two-section format separated by `\n---\n`:
- Section 1: `<flags_byte><hostname>` — first byte is bitmask (bit 0=flag_osd, bit 1=flag_o3, bit 2=flag_odn), rest is hostname string
- Section 2: INI content

**Entry points called**:
- Direct: `config.resolveHost` (line 69), `config.parseIni` (line 81)
- Transitive: None (both are leaf functions)

**Source coverage potential**:
- `src/config.zig`: **100%** — exercises all 7 branches of `resolveHost` plus full INI parser (sections, key/value, comments, hostname matching)
- Other files: none reachable

**Mock vs real**: No mocks — pure parser harness

**Quality assessment**: **Excellent**. Clean design, comprehensive branch coverage. The two-section format elegantly allows fuzzing both the INI parser and the hostname resolver with correlated inputs (hostname in section 1 can match/mismatch sections in INI content).

---

### Gen-2: fuzz_request.zig

**Input format**: One argument per line, plus four optional content blocks:
- `---FILECONTENT---` / `---FILECONTENTEND---`: inline param-file content
- `---DATAFILECONTENT---` / `---DATAFILECONTENTEND---`: inline --data-file content  
- `---LINKHEADER---` / `---LINKHEADEREND---`: Link header value
- `---JSON---` / `---JSONEND---`: JSON response body

**Entry points called**:
- Direct: `main_mod.parseArgs` (line 287), `main_mod.buildRequest` (line 293), `zoqa.parseLinkHeader` (line 302), `std.json.parseFromSlice` + `Stringify.value` (lines 311-315)
- Transitive (via buildRequest): `isAbsoluteUrl`, `resolveHost`, `buildFormParams`, `jsonToFormEncoded` (if `--form` flag present), URI parsing, method normalization

**Source coverage potential**:
- `src/main.zig`: **87.42%** current (Gap 1-6 documented in `FUZZER_CORPUS_GAP.md`):
  - Unreached: absolute URL path (lines 790-823), `isAbsoluteUrl` true-branch (lines 23-26), lowercase method normalization (lines 764-770), several CLI option flags, `jsonToFormEncoded` complex token types
- `src/root.zig`: **100%** (`parseLinkHeader` + `LinkIterator`)
- `src/config.zig`: **90%** (missing one `parseIni` branch, but that's covered by fuzz_config)

**Mock vs real**: No HTTP mocks — this harness stops at the request-building stage and never calls `openQAReq`. Exercises CLI parsing + request construction only.

**Quality assessment**: **Good, with known gaps**. The four content blocks enable rich testing of param-file, data-file, Link headers, and JSON without filesystem I/O. Main weakness: **architectural limitation** — the harness cannot reach subcommand-specific code paths (`schedule`, `archive`, `monitor`) because `buildRequest` only handles the `api` subcommand. The harness calls `parseArgs` which *parses* subcommand tokens, but then unconditionally calls `buildRequest` which assumes `.api` subcommand context.

**Specific issues**:
- Corpus lacks absolute URL seeds (Gap 1 + 5)
- Corpus lacks varied JSON structures for `jsonToFormEncoded` (Gap 6)
- No way to trigger `schedule`/`archive`/`monitor` logic paths

---

### Gen-2: fuzz_execute.zig

**Input format**: Four sections separated by `\n---\n`:
- Section 1: `<api_key>\n<api_secret>\n<path_query>`
- Section 2: `<method_byte><params>`
- Section 3: `<ctrl_byte><status_hi><status_lo><response_body>`
- Section 4: optional raw gzip bytes

`ctrl_byte` bits control mock behavior: bits 0-1 = fail_attempts (retry count), bit 2 = use_gzip.

**Entry points called**:
- Direct: `zoqa.openQAReq` (line 261)
- Transitive: `http_client.execute`, `http_client.normalizePathQuery`, `http_client.buildHeaders`, `auth.buildAuthHeaders`, `auth.hmacSha1Hex`, gzip decompression (if ctrl_byte bit 2 set), JSON parsing

**Source coverage potential**:
- `src/http_client.zig`: **91.1%** current (Gaps 7-11 documented in `FUZZER_CORPUS_GAP.md`):
  - Unreached: Accept header already-present check (lines 144-146), connection exhaustion quiet-mode print (lines 205-206), Link header allocation + errdefer cleanup (lines 274, 291-292), ReadFailed error path (lines 316-319), structured `content_type` field fallback (line 297)
- `src/auth.zig`: **100%**
- `src/root.zig`: **100%** (via `openQAReq`)
- `src/config.zig`: **70%** (lower than fuzz_config because it only tests `resolveHost` with fixed flags, not INI parsing)

**Mock vs real**: Uses `ProgrammableMockClient` — a sophisticated mock that simulates:
- Configurable fail-before-succeed retry scenarios (0-3 retries)
- Arbitrary HTTP status codes
- Gzip-compressed responses (with Content-Encoding header)
- JSON response bodies

**What the mock hides**:
- Real network errors (ConnectionRefused is the only error type injected)
- Streaming behavior edge cases (the mock's `streamRemaining` always succeeds on first call)
- Link headers (mock never emits them — Gap 9)
- ReadFailed errors (mock never injects them — Gap 10)
- Structured `content_type` field (mock always uses raw headers — Gap 11)
- Multiple header types (mock emits only Content-Type + optional Content-Encoding)

**Quality assessment**: **Very good**, but mock limitations prevent full coverage. The programmable failure injection is well-designed for testing retry logic. Main weakness: the mock is **too simple** — it doesn't expose the full HTTP response surface that real servers produce.

**Specific architectural defect discovered**: Line 276 comment claims `OPENQA_CLI_RETRY_*` env vars are only read by main.zig CLI parsing and never reach library code — **this is correct**, but the comment on lines 46-48 is misleading. The harness correctly sets `retry_sleep_s = 0` on the `CallOptions` struct (line 276), not via env var. No bug here, but the dual mentions of env vars in comments could confuse future maintainers.

---

### Gen-1: fuzz_ini.zig

**Input format**: `<hostname>\n<ini_content>` — first line is hostname, rest is INI body.

**Entry points called**:
- Direct: `config.parseIni` (line 40)

**Source coverage potential**: `src/config.zig` INI parser only — subset of fuzz_config.

**Gen-2 supersession**: **Fully subsumed** by `fuzz_config.zig`, which calls the same `parseIni` function *plus* `resolveHost`.

**Quality assessment**: Simple, focused harness. No bugs. Obsolete.

---

### Gen-1: fuzz_cli.zig

**Input format**: One argument per line, plus two content blocks (`---FILECONTENT---`, `---DATAFILECONTENT---`).

**Entry points called**:
- Direct: `main_mod.parseArgs` (line 211), `main_mod.buildRequest` (line 224)

**Source coverage potential**: Same as `fuzz_request.zig` for parseArgs + buildRequest, but missing the Link header and JSON blocks.

**Gen-2 supersession**: **Fully subsumed** by `fuzz_request.zig`, which has identical parseArgs + buildRequest coverage *plus* two additional targets (parseLinkHeader, JSON stringify).

**Quality assessment**: Clean harness. No bugs. Obsolete — `fuzz_request` is strictly superior.

---

### Gen-1: fuzz_http.zig

**Input format**: Two sections separated by `\n\n`:
- Section 1: Link header value
- Section 2: JSON body

**Entry points called**:
- Direct: `zoqa.parseLinkHeader` (line 42), `std.json.parseFromSlice` + `Stringify.value` (lines 50-55)

**Source coverage potential**: `src/root.zig` parseLinkHeader only. JSON parsing is stdlib, not src/.

**Gen-2 supersession**: **Fully subsumed** by `fuzz_request.zig`, which includes `---LINKHEADER---` and `---JSON---` blocks that exercise the same code paths.

**Quality assessment**: Clean harness. No bugs. Obsolete.

---

### Gen-1: fuzz_auth.zig

**Input format**: Three sections separated by newlines:
- Line 1: `<api_key>`
- Line 2: `<api_secret>`
- Line 3+: `<path_and_query>`

**Entry points called**:
- Direct: `auth.hmacSha1Hex` (line 126), `auth.buildAuthHeaders` (line 133), `zoqa.openQAReq` via MockClient (line 175)
- Transitive (via openQAReq): `http_client.execute`, `http_client.normalizePathQuery`

**Source coverage potential**:
- `src/auth.zig`: 100%
- `src/http_client.zig`: subset of fuzz_execute (simpler mock, no retry/gzip/status-code variation)

**Gen-2 supersession**: **Fully subsumed** by `fuzz_execute.zig`. Both harnesses call `openQAReq` with mocks, but fuzz_execute's `ProgrammableMockClient` exercises retry logic, gzip, and arbitrary status codes that fuzz_auth's basic `MockClient` cannot reach.

**Quality assessment**: Clean harness. Interesting three-target structure (hmacSha1Hex standalone, buildAuthHeaders standalone, then full openQAReq integration). No bugs. Obsolete — fuzz_execute is strictly superior.

---

### Gen-1: fuzz_gzip.zig

**Input format**: Raw binary gzip stream.

**Entry points called**:
- Direct: `std.compress.flate.Decompress.init` (line 38), `reader.streamRemaining` (line 41), `std.json.parseFromSlice` + `Stringify.value` (lines 47-51) if decompression succeeds

**Source coverage potential**: Stdlib gzip decompressor only — no src/ code. The JSON parsing is incidental post-decompression.

**Gen-2 supersession**: **Fully subsumed** by `fuzz_execute.zig`. When `ctrl_byte` bit 2 is set, fuzz_execute's mock returns `Content-Encoding: gzip` header and section 4 bytes as the gzipped body, triggering the exact same decompression code path (`http_client.zig` lines 246-257) that real responses would hit.

**Quality assessment**: Clean harness. Good gzip bomb safety (line 46 limits decompressed size to 1 MiB). No bugs. Obsolete — the gzip path is better tested *in context* via fuzz_execute where it's integrated with the full HTTP response pipeline.

---

## Coverage matrix

Legend:
- `✓` — directly invoked or fully reachable
- `~` — reachable but only through narrow/partial paths
- `✗` — unreachable

| src/ file + key function | config | request | execute | ini | cli | http | auth | gzip |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **config.zig** |
| `parseIni` | ✓ | ~ | ✗ | ✓ | ~ | ✗ | ✗ | ✗ |
| `resolveHost` | ✓ | ✓ | ~ | ✗ | ✓ | ✗ | ✗ | ✗ |
| `findCredentials` | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| **auth.zig** |
| `hmacSha1Hex` | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✓ | ✗ |
| `buildAuthHeaders` | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✓ | ✗ |
| **http_client.zig** |
| `execute` | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ~ | ✗ |
| `normalizePathQuery` | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✓ | ✗ |
| `buildHeaders` | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ~ | ✗ |
| `sleepForRetry` | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ |
| gzip decompress (lines 246-257) | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✗ | ✓ |
| **root.zig** |
| `openQAReq` | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✓ | ✗ |
| `parseLinkHeader` | ✗ | ✓ | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ |
| `LinkIterator` | ✗ | ✓ | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ |
| **main.zig** |
| `parseArgs` | ✗ | ✓ | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ |
| `buildRequest` | ✗ | ✓ | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ |
| `isAbsoluteUrl` | ✗ | ~ | ✗ | ✗ | ~ | ✗ | ✗ | ✗ |
| `jsonToFormEncoded` | ✗ | ~ | ✗ | ✗ | ~ | ✗ | ✗ | ✗ |
| env-var resolution (lines 2400-2470) | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| credentials resolution (via findCredentials) | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| **schedule.zig** |
| `runSchedule` | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| **archive.zig** |
| `runArchive` | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| **monitor.zig** |
| `checkJobStatus` | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| `runMonitor` | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |

**Key observations**:
- `fuzz_request` reaches `isAbsoluteUrl` and `jsonToFormEncoded` with `~` because corpus lacks seeds for those paths (Gaps 1, 5, 6).
- `fuzz_execute` reaches `resolveHost` and `buildHeaders` with `~` because it doesn't vary credentials or test all header permutations.
- `fuzz_auth` reaches `execute` and `buildHeaders` with `~` because its mock is simpler than fuzz_execute's.
- **No harness reaches `findCredentials`** (called only from main.zig credential-resolution block, lines 2348-2398, which requires filesystem + env vars).
- **No harness reaches env-var resolution** (lines 2400-2470 in main.zig — read only at CLI startup, not exposed to library API).
- **Three entire src files are unreachable**: schedule.zig, archive.zig, monitor.zig.

---

## Gen-1 pruning verdict

> ✅ **Executed 2026-04-29** — all five harnesses below have been deleted. This
> section is preserved as the rationale for *why* the deletions were safe.

### Summary table

| Gen-1 harness | Verdict | Reason |
|---|---|---|
| `fuzz_ini.zig` | **DELETE** | Fully subsumed by `fuzz_config.zig` (same parseIni call, no resolveHost) |
| `fuzz_cli.zig` | **DELETE** | Fully subsumed by `fuzz_request.zig` (same targets, fewer content blocks) |
| `fuzz_http.zig` | **DELETE** | Fully subsumed by `fuzz_request.zig` (Link + JSON blocks cover same paths) |
| `fuzz_auth.zig` | **DELETE** | Fully subsumed by `fuzz_execute.zig` (same auth paths, fewer mock features) |
| `fuzz_gzip.zig` | **DELETE** | Fully subsumed by `fuzz_execute.zig` (gzip tested in-context via mock) |

### Detailed analysis

**fuzz_ini vs fuzz_config**: `fuzz_config` calls `parseIni` (line 81) + `resolveHost` (line 69). `fuzz_ini` calls only `parseIni` (line 40). Strict subset. **Safe to delete**.

**fuzz_cli vs fuzz_request**: Both call `parseArgs` → `buildRequest`. `fuzz_request` adds `---LINKHEADER---` and `---JSON---` blocks that exercise `parseLinkHeader` and JSON stringify paths. `fuzz_cli` has identical coverage for parseArgs + buildRequest but lacks the two extra targets. Strict subset. **Safe to delete**.

**fuzz_http vs fuzz_request**: `fuzz_http` exercises `parseLinkHeader` (line 42) + JSON stringify (lines 50-55). `fuzz_request` exercises the same functions via `---LINKHEADER---` (line 302) and `---JSON---` (lines 311-315) blocks. Identical coverage for these targets, but fuzz_request also exercises parseArgs + buildRequest. Strict superset in fuzz_request. **Safe to delete**.

**fuzz_auth vs fuzz_execute**: Both call `zoqa.openQAReq` with mocks. `fuzz_auth` uses a basic `MockClient` that returns 200 OK with empty JSON (lines 40-94). `fuzz_execute` uses `ProgrammableMockClient` (lines 74-158) that supports:
- Configurable fail_attempts (retry loop testing)
- Arbitrary HTTP status codes
- Gzip responses

`fuzz_auth` also directly calls `hmacSha1Hex` (line 126) and `buildAuthHeaders` (line 133), but these are *transitive dependencies* of `openQAReq` — fuzz_execute reaches them indirectly (via execute → buildAuthHeaders → hmacSha1Hex). The direct calls in fuzz_auth provide no additional coverage that fuzz_execute misses. Strict subset. **Safe to delete**.

**fuzz_gzip vs fuzz_execute**: `fuzz_gzip` feeds raw gzip bytes to `std.compress.flate.Decompress.init` (line 38) and `streamRemaining` (line 41). `fuzz_execute` reaches the *exact same code path* when `ctrl_byte` bit 2 is set — the mock returns `Content-Encoding: gzip` (line 94) and `response_body = section4` (line 244), which triggers `http_client.zig` lines 246-257 (gzip decompression). The difference: fuzz_gzip tests gzip *in isolation*, fuzz_execute tests it *in context* (as part of the full HTTP response handling pipeline). Testing in context is superior — it catches integration bugs (e.g., gzip header parsing, content-type interaction). Strict subset. **Safe to delete**.

**Conclusion**: All 5 gen-1 harnesses are safe to delete. No unique coverage is lost.

---

## Gen-2 improvement opportunities

### 1. Extend fuzz_request to cover subcommands

**Problem**: `fuzz_request` calls `parseArgs` (which parses subcommand tokens like `schedule`, `archive`, `monitor`) but then unconditionally calls `buildRequest`, which only handles the `api` subcommand. The harness cannot reach subcommand-specific logic in `main.zig` lines 2500-2556 (archive/monitor/schedule dispatch).

**Fix**: After calling `parseArgs`, branch on `parsed.subcmd`:
- `.api` → call `buildRequest` (current path)
- `.archive` → extract job_id + output_path from kv_params, construct `ArchiveConfig`, call a mock `runArchive` flow
- `.monitor` → extract job_ids from kv_params, construct `MonitorConfig`, call a mock `runMonitor` flow
- `.schedule` → extract params, construct `ScheduleConfig`, call a mock `runSchedule` flow

**Impact**: Would close the **1182 LoC gap** (schedule + archive + monitor). However, this approach is **architecturally awkward** — `fuzz_request` is designed as a CLI-layer harness, not an integration harness. Better solution: create a dedicated `fuzz_schedule` harness (see recommendation #1).

### 2. Extend ProgrammableMockClient in fuzz_execute

**Gaps closed**: 7, 9, 10, 11 (see `FUZZER_CORPUS_GAP.md`).

**Proposed enhancements**:
- **Emit Link headers**: Add `link_header: ?[]const u8` field to mock config. If set, emit `Link: <value>` in `iterateHeaders` (after Content-Type, Content-Encoding).
- **Set structured content_type field**: Add boolean `use_structured_ct: bool`. If true, set `head.content_type = "application/json"` instead of emitting raw header.
- **Inject ReadFailed**: Add `fail_on_read: bool` field. If true, `streamRemaining` returns `error.ReadFailed` on first call.
- **Vary response headers**: Add `extra_headers: []const std.http.Header` field. Emit these in `iterateHeaders` after the standard headers.

**Corpus changes**: Expand `ctrl_byte` to 16 bits (two bytes in section 3) to encode the new flags:
- Bits 0-1: fail_attempts (unchanged)
- Bit 2: use_gzip (unchanged)
- Bit 3: emit Link header (value from new section 5)
- Bit 4: use structured content_type
- Bit 5: inject ReadFailed
- Bit 6: include Accept header in request (to test "Accept already present" check)

**Implementation effort**: ~100 LoC mock extension + corpus format update.

**Impact**: Would raise fuzz_execute coverage from 91.1% to ~96%, closing the mock-limitation gaps.

### 3. Add absolute URL seeds to fuzz_request corpus

**Gaps closed**: 1, 5 (see `FUZZER_CORPUS_GAP.md`).

**Required seeds** (Gap 5 lists four sub-cases):
1. `https://openqa.opensuse.org/api/v1/jobs` — exercises prefix-stripping path (lines 807-808)
2. `https://openqa.opensuse.org/api/v1` — exercises exact-match path (lines 809-811)
3. `https://custom.host/custom/path` — exercises no-prefix path (lines 812-817)
4. `https://openqa.opensuse.org/api/v1/jobs?limit=5` — exercises query-string preservation (lines 821-823)

**Format**: Plain arguments, e.g.:
```
zoqa
api
https://openqa.opensuse.org/api/v1/jobs
state=running
```

**Impact**: Would raise fuzz_request coverage from 87.42% to ~92%, closing the largest single gap (20+ lines of URL parsing logic).

### 4. Add varied JSON structures to fuzz_request corpus

**Gap closed**: 6 (see `FUZZER_CORPUS_GAP.md`).

**Required seeds**: Use `---JSON---` block with nested objects, arrays, booleans, nulls, numbers to exercise `jsonToFormEncoded` switch arms (lines 467, 475, 734, 755, 778, 780, 858). Also add seeds with `--form` flag + complex JSON to trigger the `jsonToFormEncoded` call in buildRequest (line 1369).

**Example**:
```
zoqa
api
--form
---DATAFILECONTENT---
{"nested":{"key":"val"},"arr":[1,true,null],"bool":false}
---DATAFILECONTENTEND---
isos
```

**Impact**: Moderate — these are switch arms in a robust parser, low crash risk. Closes 7 high-branch-count gaps.

### 5. Add CLI flag seeds to fuzz_request corpus

**Gap closed**: 2 (see `FUZZER_CORPUS_GAP.md`).

**Required seeds**: Add corpus files exercising `--json`, `--data-file`, `--pretty`, `--retries` flags. Low priority — straightforward boolean/value assignments.

---

## Completely uncovered src/ areas

### 1. Subcommand logic (schedule.zig, archive.zig, monitor.zig)

**Why uncovered**: All harnesses target the library API (`zoqa.openQAReq`, `zoqa.parseLinkHeader`, `config.parseIni`) or CLI parsing layer (`parseArgs`, `buildRequest`). The subcommand entry points (`runSchedule`, `runArchive`, `runMonitor`) are exported by `root.zig` (lines 19-31) but never called by any harness.

**How to reach**:
- **Option A** (recommended): Create `fuzz_schedule.zig` that calls `zoqa.runSchedule` with a mock HTTP client (similar to fuzz_execute's approach). Since `runSchedule` can invoke `runMonitor` internally (when `monitor_jobs = true`, line 15), this single harness would cover schedule.zig + monitor.zig. Add a second `fuzz_archive.zig` for archive.zig.
- **Option B**: Extend `fuzz_request` to branch on subcommand and call the appropriate `run*` function (see improvement #1). Less clean — mixes CLI parsing with integration testing.

**Impact**: **Critical** — 1182 LoC (20.7% of codebase) is untested. These are complex functions with HTTP, JSON parsing, polling loops, error handling.

### 2. Credential resolution (config.findCredentials + main.zig lines 2348-2398)

**Why uncovered**: `findCredentials` reads `~/.config/openqa/client.conf` from disk (config.zig line 134). No harness sets up a fake home directory or injects filesystem state. The credential-resolution block in main.zig (lines 2348-2398) is only reachable from the `main()` entry point, which no harness calls.

**How to reach**: Impractical for fuzzing — requires filesystem mocking or temp directory setup. Better covered by unit/integration tests. Skip for fuzzing.

**Impact**: Low — this is a simple INI file read followed by `findCredentials` call. The INI parser is 100% covered by fuzz_config.

### 3. Environment variable resolution (main.zig lines 2400-2470)

**Why uncovered**: This code reads `OPENQA_CLI_RETRIES`, `OPENQA_CLI_CONNECT_TIMEOUT_S`, `OPENQA_CLI_RETRY_SLEEP_TIME_S`, `OPENQA_CLI_RETRY_FACTOR` env vars at CLI startup. No harness calls `main()` or sets env vars.

**How to reach**: Could be reached by a `fuzz_main` harness that:
1. Sets env vars via `std.process.setEnv`
2. Constructs synthetic `argv`
3. Calls `main()` (or a `mainImpl` helper)

**Why not worth it**: The env-var reading logic is trivial (lines 2400-2470 are just four `getEnvVarOwned` + `parseFloat` blocks). The *values* propagate into `CallOptions` structs that fuzz_execute already tests. No unique coverage gain.

**Impact**: Negligible — 70 LoC of boilerplate env-var reading. Skip for fuzzing.

### 4. Specific functions with low/partial coverage

From coverage matrix `~` entries:

- `isAbsoluteUrl` true-branch (Gap 1) — covered by improvement #3
- `jsonToFormEncoded` complex token types (Gap 6) — covered by improvement #4
- `config.parseIni` (10% uncovered via fuzz_request) — already 100% via fuzz_config
- `http_client` gaps 7-11 — covered by improvement #2

---

## Concrete recommendations

Ranked by impact (coverage gained ÷ implementation cost):

### 1. **Create fuzz_schedule.zig** ⭐⭐⭐

**What**: New harness that calls `zoqa.runSchedule` with a mock HTTP client.

**Input format** (sketch):
```
Section 1: <params_encoded>        // form-encoded params for POST /api/v1/isos
Section 2: <ctrl_byte><response_body>
  ctrl_byte bits:
    0: sync_response (ids present in response)
    1: monitor_jobs flag
    2: follow flag
```

**Coverage gain**: 500 LoC (schedule.zig) + 234 LoC (monitor.zig) = **734 LoC** if monitoring path is exercised. 14.6% of codebase.

**Implementation effort**: ~200 LoC harness (copy fuzz_execute structure, adapt mock to return schedule response JSON).

**Priority**: **Highest** — closes the largest uncovered area.

---

### 2. **Extend ProgrammableMockClient (fuzz_execute)** ⭐⭐ ✅ DONE (2026-05-04)

**What**: Added Link header, structured content_type toggle, ReadFailed injection, Accept-header pre-presence (see improvement #2 above).

**Coverage gain**: ~15 LoC in http_client.zig — Gaps 7, 9, 10, 11 all closed.

**Status**: Done in commit `c7a6bc1`. New fields `link_header`, `use_structured_ct`, `inject_read_failed` added to `ProgrammableMockClient` in `mock_client.zig`; ctrl_byte expanded from 3 bits to 7 bits; Section 5 added to the input format for the Link header value; four new seeds committed (`seed_accept_header.bin`, `seed_link_header.bin`, `seed_read_failed.bin`, `seed_structured_ct.bin`).

---

### 2b. **Create fuzz_archive.zig** ⭐⭐

**What**: New harness that calls `zoqa.runArchive` with a mock HTTP client.

**Input format** (sketch):
```
Section 1: <job_id_bytes>           // parsed as u64
Section 2: <ctrl_byte><file_list_json><asset_bytes>
  ctrl_byte bits:
    0: with_thumbnails
    1: simulate download error
```

**Coverage gain**: **448 LoC** (archive.zig). 7.8% of codebase.

**Implementation effort**: ~250 LoC harness (more complex than fuzz_schedule — needs to mock file downloads, progress tracking).

**Priority**: **High** — second-largest uncovered file.

---

### 3. **Add absolute URL seeds to fuzz_request** ⭐⭐⭐ ✅ DONE (2026-05-04)

**What**: Add 4 corpus seeds covering Gap 1 + Gap 5 (see improvement #3).

**Coverage gain**: ~25 LoC in main.zig (lines 790-823, absolute URL parsing).

**Implementation effort**: ~10 minutes (create 4 text files).

**Priority**: **Highest** — trivial effort, closes the largest gap in fuzz_request.

**Status**: Done in commit `c7a6bc1`. Four seeds added (`seed_abs_url_prefix_strip.txt`, `seed_abs_url_exact_match.txt`, `seed_abs_url_custom_host.txt`, `seed_abs_url_with_query.txt`). Note: the commit also added a second set with a slightly different naming convention (`seed_absurl_*.txt`) — these four files have identical content to the `seed_abs_url_*` set and are exact duplicates; the `seed_absurl_*` variants (without the underscore between `abs` and `url`) can be removed the next time the corpus is distilled.

---

### 4. **Extend ProgrammableMockClient (fuzz_execute)** ⭐⭐ ✅ DONE (2026-05-04, see Rec #2 above)

**What**: Add Link header, structured content_type, ReadFailed injection, extra headers (see improvement #2).

**Coverage gain**: ~15 LoC in http_client.zig (Gaps 7, 9, 10, 11).

**Implementation effort**: ~100 LoC mock extension + 2 hours corpus generation.

**Priority**: **Medium** — moderate effort, closes several small gaps.

---

### 5. **Add JSON variety seeds to fuzz_request** ⭐ ✅ DONE (2026-05-04)

**What**: Add seeds with nested objects, arrays, booleans, nulls (see improvement #4).

**Coverage gain**: ~10 LoC in main.zig (`jsonToFormEncoded` switch arms).

**Implementation effort**: ~30 minutes (create 5-10 JSON seeds).

**Priority**: **Low** — low crash risk, switch arms in a mature parser.

**Status**: Done in commit `c7a6bc1`. Eight seeds added (`seed_json_all_types.txt`, `seed_json_nested.txt`, `seed_json_array_root.txt`, `seed_json_complex.txt`, `seed_json_nested_obj.txt`, `seed_json_array_of_objects.txt`, `seed_json_deep_nesting.txt`, `seed_json_stringify_complex.txt`).

---

### 6. **Delete all gen-1 harnesses** ⭐⭐⭐ ✅ DONE (2026-04-29)

**What**: Remove `fuzz_ini.zig`, `fuzz_cli.zig`, `fuzz_http.zig`, `fuzz_auth.zig`, `fuzz_gzip.zig` + their corpus directories + build.zig entries.

**Coverage impact**: None — fully subsumed by gen-2 (see pruning verdict).

**Maintenance benefit**: Reduced fuzzer count from 8 to 3, simplified shell scripts and the build graph, eliminated four `corpus_*/` and `out_*/` trees from disk and from the git-ignored set.

**Implementation effort**: ~30 minutes (delete files, update build.zig, update README.md).

**Priority**: **High** — zero risk, immediate simplification.

**Status**: Done on branch `fuzz_refresh`. Verified with `make build`,
`make zig-test` (106/106 pass), `make zig-lint`, `make fuzz-build`, and
the new `make fuzz-lint` target.

---

### 7. **Add CLI flag seeds to fuzz_request** ⭐ ✅ DONE (2026-05-04)

**What**: Add seeds exercising `--json`, `--data-file`, `--pretty`, `--retries` (Gap 2).

**Coverage gain**: ~10 LoC in main.zig (option parsing).

**Implementation effort**: ~15 minutes (create 4 seeds).

**Priority**: **Lowest** — trivial code paths, low value.

**Status**: Done in commit `c7a6bc1`. Four seeds added (`seed_flags_data_file.txt`, `seed_flags_json_pretty.txt`, `seed_flags_json_verbose.txt`, `seed_flags_retries.txt`).

---

### 8. **Add malformed flag seeds to fuzz_request** ✅ DONE (2026-05-04)

**What**: Add seeds with `--flag=` (empty value after equals) to cover Gap 3.

**Coverage gain**: ~10 LoC in main.zig (error branches in option parser).

**Implementation effort**: ~10 minutes (create 3 seeds).

**Priority**: **Lowest** — error-path coverage, unlikely to find bugs.

**Status**: Done in commit `c7a6bc1`. Three seeds added (`seed_malformed_empty_creds.txt`, `seed_malformed_empty_host.txt`, `seed_malformed_empty_values.txt`).

---

### 9. **Document the fuzz_execute env-var comment clarification**

**What**: Update comment on fuzz_execute.zig lines 46-48 to clarify that env vars are never read by library code, only by main.zig CLI parsing. Current comment is correct but could be misread.

**Coverage impact**: None (documentation only).

**Implementation effort**: 5 minutes.

**Priority**: **Optional** — no functional impact.

---

### 10. **Fix schedule.zig @intCast panic risk** (out of scope but noted)

**What**: Replace `@intCast` with `std.math.cast` + error handling at schedule.zig lines 129, 152, 316 (Gap 12 in `FUZZER_CORPUS_GAP.md`).

**Note**: This is a **source code bug**, not a harness issue. Listed here for completeness because it was discovered during corpus gap analysis.

**Priority**: **Critical** (but outside harness audit scope).

---

## Summary

**Gen-1 status**: ✅ All 5 harnesses deleted on 2026-04-29 (branch `fuzz_refresh`).

**Gen-2 status** (now the only set): Excellent coverage of core library functions (config, auth, HTTP client), but **completely misses subcommand implementations** (20.7% of codebase).

**Highest-ROI actions remaining** (do these first):
1. Create `fuzz_schedule.zig` full version → +734 LoC coverage (async path + `runMonitor`)
2. Create `fuzz_archive.zig` → +448 LoC coverage
3. ~~Add 4 absolute URL seeds to fuzz_request → +25 LoC, trivial effort~~ **DONE (c7a6bc1)**

**Total effort to close major gaps**: ~2 days (1 day for fuzz_schedule full version, 1 day for fuzz_archive).

---

## Update 2026-04-29 — `fuzz_schedule` stub landed, Gap 12 confirmed in the wild

### What landed

| Change | Files |
|---|---|
| Refactored `client: *std.http.Client` → `client: anytype` | `src/schedule.zig` (`runSchedule`, `asyncPollAndMonitor`), `src/monitor.zig` (`runMonitor`, `checkJobStatus`) |
| Extracted `ProgrammableMockClient` for reuse | `tests/fuzz/mock_client.zig` (new), `tests/fuzz/fuzz_execute.zig` (now imports it) |
| Stub harness for `runSchedule` (sync path only) | `tests/fuzz/fuzz_schedule.zig`, `tests/fuzz/cov_harness_schedule.zig`, build/script wiring |
| Bootstrap corpus | `tests/fuzz/corpus_schedule/seed_001_sync_happy.bin` = `{"ids":[1]}` |

The audit's Recommendation #1 originally scoped only `runSchedule`'s signature
for refactor; in practice four signatures had to move because `runSchedule`
forwards its `client` into `runMonitor`. Useful side effect:
`monitor.zig` (234 LoC) is now reachable from any future direct harness — was
listed as "completely uncovered" in the original gap analysis.

### Triage outcome — first 60 seconds of fuzzing

| Metric | Value |
|---|---|
| Distinct crash files | 11 |
| Distinct root causes | 1 |
| Panic site | `src/schedule.zig:435:25` in `extractJobIds` |
| Panic message | `integer does not fit in destination type` |
| Trigger pattern | any `{"ids":[..., -N, ...]}` |
| Minimal reproducer | `{"ids":[-1]}` (12 bytes — id:000004) |

This is exactly Gap 12 (Recommendation #10 below), now demonstrably reachable
through the public `runSchedule` API.

**What AFL did NOT find:** the second `@intCast` site at
`src/schedule.zig:153` (`scheduled_product_id`). Cause: corpus bias. The
single bootstrap seed `{"ids":[1]}` mutates more readily into negative-id
arrays than into objects with `scheduled_product_id`. **Lesson:** seed shape
steers AFL's first hour at least as much as harness reachability does.

### Recommendation #10 — status: validated, fix pending

The original recommendation marked this as "out of scope" for the audit. The
fuzzer has now made the case for fixing it. Concrete edits:

```zig
// schedule.zig:153 — scheduled_product_id  (NOT yet found by AFL but same
// bug pattern; fix it together)
.integer => std.math.cast(u64, sp.integer),

// schedule.zig:435 — extractJobIds  (the one AFL found)
.integer => std.math.cast(u64, id_val.integer) orelse {
    if (!options.quiet) std.debug.print("schedule: negative job ID in response\n", .{});
    return error.InvalidJobId;
},
```

Plus an inline regression test in `schedule.zig`:

```zig
test "extractJobIds: negative integer returns error (regression: Gap 12)" {
    const allocator = testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "[-1]", .{});
    defer parsed.deinit();

    var sink_buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&sink_buf);
    var iface = fbs.writer().interface;

    try testing.expectError(
        error.InvalidJobId,
        extractJobIds(allocator, .{ .quiet = true }, "h", &iface, parsed.value.array),
    );
}
```

### Restart workflow after the fix

Stop the running campaign first (`Ctrl-C` in the afl-fuzz pane), then
`make fuzz-build`, then choose:

1. **`./tests/fuzz/run.sh schedule --continue`** — resume from existing
   `out_schedule/`. Discovered crash inputs stay archived in `crashes/`; the
   queue's accumulated coverage carries over. **Recommended** — fastest path
   to the next bug.

2. **Fresh run** (`rm -rf tests/fuzz/out_schedule` first) — discards the
   accumulated executions. Only worth it if the fix changed the source-edge
   map dramatically, which `@intCast → std.math.cast` will not.

### Bonus before restart — promote crash inputs to seeds

Post-fix, the discovered crash inputs are no longer crashes — they're rich
JSON examples (deeply nested arrays of mixed positive/negative ints with
float and scientific-notation literals) that the bootstrap seed lacked.
Promote at least one into the tracked corpus so future campaigns start with
that variety baked in:

```sh
cp tests/fuzz/out_schedule/main-node/crashes/id:000009,... \
   tests/fuzz/corpus_schedule/seed_002_mixed_ids.bin
```

This is the lightweight version of `distill.sh`'s full promotion workflow,
appropriate when a single bug ate most of the queue.

### Outstanding from the original audit (still applies)

- **Recommendation #1 — `fuzz_schedule.zig` full version.** Current harness
  is a *stub*: single-response mock, sync path only. Async path
  (`scheduled_product_id` + `asyncPollAndMonitor`) and `--monitor` integration
  with `runMonitor` need the multi-section input format and the scripted-
  response mock extension sketched earlier in this audit.
- **Recommendation #2b — `fuzz_archive.zig`.** Unchanged; second-largest
  uncovered file. `runArchive` already takes `client: anytype` so no refactor
  needed; the harness can copy the `fuzz_schedule.zig` skeleton.
- **Direct `monitor.zig` harness** — newly possible after the
  `client: anytype` refactor; was not in the original audit's scope. Same
  shape as `fuzz_schedule.zig`. Low-priority since `runMonitor` is also
  reachable transitively from the eventual full `fuzz_schedule`.
- ~~**Recommendations #2, #3, #4, #5, #7, #8** — all completed in commit
  `c7a6bc1` (2026-05-04). See "Update 2026-05-04" section below.~~

---

## Update 2026-04-30 — Gap 12 fix landed; all four campaigns relaunched

### What changed since the previous update

| Change | Commit / file |
|---|---|
| Gap 12 fixed at both `@intCast` sites | `a58828d` (`schedule.zig:153`, `:435` — now `std.math.cast`) |
| Regression unit test for the `extractJobIds` site | `schedule.zig:556-575` (`schedule.zig` test count 6 → 7) |
| All gen-2 binaries rebuilt against current source | `make fuzz-build` on the VM, timestamps `Apr 29 23:58` |
| Pre-restructure `out_*/` dirs archived | `out_<target>_archived_20260430_000851_pre_restructure/` |
| Corpora re-minimised against the new edge maps | `corpus_<t>_min/`: config 57, request 440, execute 274, schedule 1 |

### Currently running on the VM

Four parallel campaigns in tmux session 2 on `devenv@10.128.98.29`
(see `ideas/FUZZ_VIA_SSH_TMUX.md` for the operational details):

| tmux window | Target | Status at launch |
|---|---|---|
| `2:schedule` | `runSchedule` + `extractJobIds` (sync stub) | clean — 624 queue items in 30s, 0 crashes (no longer re-finding Gap 12) |
| `2:execute` | full HTTP pipeline (auth + retry + gzip) | clean restart |
| `2:request` | CLI args + `buildRequest` + JSON | clean restart |
| `2:config` | INI parser + `resolveHost` | clean restart |

The audit's "Restart workflow after the fix" section is now executed.
Outstanding recommendations (`fuzz_schedule` full version,
`fuzz_archive.zig`, direct `monitor.zig` harness, `ProgrammableMockClient`
extensions) are unchanged and remain the next moves.

---

## Update 2026-05-04 — Generic improvements; Recs #2–5, #7, #8 completed (commit `c7a6bc1`)

### What changed

| Change | File(s) |
|---|---|
| `ProgrammableMockClient` extended: `link_header`, `use_structured_ct`, `inject_read_failed` fields | `tests/fuzz/mock_client.zig` |
| `fuzz_execute` ctrl_byte expanded to 7 bits (bits 3–6 added); Section 5 added for Link header; `headers` field wired into `openQAReq` | `tests/fuzz/fuzz_execute.zig` |
| `fuzz_schedule` stability fix: null `output_writer` passed to eliminate pipe-buffer non-determinism (was 83.91% stability) | `tests/fuzz/fuzz_schedule.zig` |
| `ScheduleOptions.output_writer: ?*std.Io.Writer` field added; `runSchedule` uses it when non-null | `src/schedule.zig` |
| 4 new execute seeds (Gaps 7, 9, 10, 11) | `corpus_execute/seed_accept_header.bin`, `seed_link_header.bin`, `seed_read_failed.bin`, `seed_structured_ct.bin` |
| 4 absolute URL seeds for request corpus (Gaps 1 + 5) | `corpus_request/seed_abs_url_{prefix_strip,exact_match,custom_host,with_query}.txt` |
| Duplicate absolute URL seeds (same content, different naming) | `corpus_request/seed_absurl_{prefix_strip,exact_match,custom_host,with_query}.txt` — identical to the `seed_abs_url_*` set; harmless but can be removed at next distillation |
| 4 CLI flag seeds (Gap 2) | `corpus_request/seed_flags_{data_file,json_pretty,json_verbose,retries}.txt` |
| 8 JSON variety seeds (Gap 6) | `corpus_request/seed_json_{all_types,nested,array_root,complex,nested_obj,array_of_objects,deep_nesting,stringify_complex}.txt` |
| 3 malformed flag seeds (Gap 3) | `corpus_request/seed_malformed_{empty_creds,empty_host,empty_values}.txt` |
| `corpus_config/` distilled | `.tmin_timeouts` file removed; seeds renamed to AFL++ queue format |

### Gaps closed by this commit

| Gap | Description | How closed |
|---|---|---|
| Gap 1 | `isAbsoluteUrl` loop body | `seed_abs_url_*` seeds |
| Gap 2 | CLI option parsing flags | `seed_flags_*` seeds |
| Gap 3 | Option parser error paths | `seed_malformed_*` seeds |
| Gap 5 | Absolute URL parsing in `buildRequest` | `seed_abs_url_*` seeds |
| Gap 6 | `jsonToFormEncoded` token dispatch | `seed_json_*` seeds |
| Gap 7 | Accept header already present | `inject_read_failed` mock field + `seed_accept_header.bin` |
| Gap 9 | Link header + errdefer cleanup | `link_header` mock field + `seed_link_header.bin` |
| Gap 10 | ReadFailed error path | `inject_read_failed` mock field + `seed_read_failed.bin` |
| Gap 11 | Structured `content_type` field fallback | `use_structured_ct` mock field + `seed_structured_ct.bin` |

### Still open

| Gap | Description | Status |
|---|---|---|
| Gap 4 | `buildRequest` method case-normalization (lowercase HTTP methods) | No seed yet — add `get`/`post` method seeds |
| Gap 8 | Connection exhaustion quiet-mode error print (`http_client.zig:205-206`) | Requires mock to exhaust retries with `quiet=false`; not yet wired |

### Outstanding recommendations after this update

1. **`fuzz_schedule.zig` full version** (Rec #1) — async path (`scheduled_product_id` + `asyncPollAndMonitor`) + `--monitor` integration with `runMonitor`. Highest remaining priority.
2. **`fuzz_archive.zig`** (Rec #2b) — `runArchive` already takes `client: anytype`; no refactor needed.
3. **Close Gap 4** — add 4 lowercase-method seeds to `corpus_request/` (~5 minutes).
4. **Close Gap 8** — extend mock to simulate retry exhaustion with `quiet=false`.
