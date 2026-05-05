# Fuzzer Corpus Gap Analysis

Coverage data collected by running all three kcov targets
(`config`, `request`, `execute`) via `cov_build.zig`.

> **Status as of 2026-05-04 (commit `c7a6bc1`):** Gaps 1–3, 5–7, 9–11, 12 are
> addressed. Gaps 4 and 8 remain open. See `ideas/HARNESS_AUDIT.md` (Update
> 2026-05-04) for full details.

## Summary

| Target | File | Line Cov | Covered/Instrumented |
|---|---|---|---|
| config | `src/config.zig` | 100% | 39/39 |
| request | `src/main.zig` | 80.4% | 218/271 |
| request | `src/root.zig` | 100% | 21/21 |
| request | `src/config.zig` | 90% | 9/10 |
| execute | `src/http_client.zig` | 90.8% | 118/130 |
| execute | `src/auth.zig` | 100% | 8/8 |
| execute | `src/root.zig` | 100% | 20/20 |
| execute | `src/config.zig` | 70% | 7/10 |

Aggregate: config 100%, request 82.1%, execute 91.1%.

Corpus sizes at original analysis: config=71 seeds, request=22 seeds, execute=10 seeds.
Corpus sizes after `c7a6bc1` seed additions (pre-distillation): config=~57 (distilled), request=440+, execute=many.

---

## Gap 1 -- `isAbsoluteUrl` loop body (main.zig:23-26)

**Target:** request

```zig
23:     for (path[0..colon_idx]) |c| {          // "0/4"
24:         if (c == '/' or c == '?' or c == '#') return false;  // "0/2"
25:     }                                         // "0/3"
26:     return true;                              // "0/1"
```

**Why uncovered:** No fuzz seed contains a path with a colon preceded by valid
scheme characters (e.g. `http:`). All colon-containing inputs either have no
colon or have `/:?#` before the colon. The `return true` at line 26 (the
"yes, it's absolute" branch) is completely untested by fuzzing.

**Seed fix:** Add corpus entries with scheme-like paths: `http://host/path`,
`ftp://x`, `custom-scheme:foo`.

**Status (2026-05-04):** ✅ Addressed — `seed_abs_url_*.txt` seeds added (commit `c7a6bc1`).

---

## Gap 2 -- CLI option parsing "else" branches (main.zig:115,129-130,141-142,165-166)

**Target:** request

These are `0/1` hits on option-specific flag values that no seed happens to
produce:

- Line 115: `--data-file` flag handling
- Lines 129-130: `--json` flag
- Lines 141-142: `--retries` value parsing
- Lines 165-166: `--pretty` flag

**Why uncovered:** The 22 request seeds do not exercise these particular CLI
options.

**Seed fix:** Add seeds that include these flags. Low priority -- these are
straightforward boolean/value assignments.

**Status (2026-05-04):** ✅ Addressed — `seed_flags_{data_file,json_pretty,json_verbose,retries}.txt` added (commit `c7a6bc1`).

---

## Gap 3 -- Option parser error paths (main.zig:177,188,199,210,221,232,243,254,265)

**Target:** request

Each of these lines is `0/N` on what appears to be an error path within the
option-parsing switch arms (e.g., missing value after `=` sign for `--host=`,
`--method=`, etc.).

**Why uncovered:** No seed produces a malformed flag like `--host=` with an
empty value or a flag that expects a value but is the last argument.

**Seed fix:** Add seeds with malformed `--flag=` (equals sign with empty value
or missing value).

**Status (2026-05-04):** ✅ Addressed — `seed_malformed_{empty_creds,empty_host,empty_values}.txt` added (commit `c7a6bc1`).

---

## Gap 4 -- `buildRequest` method case-normalization fallback (main.zig:764-770)

**Target:** request

```zig
764:     const method = std.meta.stringToEnum(std.http.Method, args.method) orelse blk: {
765:         var upper_buf: [16]u8 = undefined;                        // "0/1"
766:         if (args.method.len <= upper_buf.len) {                   // "0/1"
767:             const upper = std.ascii.upperString(...)              // "0/3"
768:             break :blk std.meta.stringToEnum(...) orelse .GET;    // "0/3"
769:         }
770:         break :blk .GET;                                          // hit via "1/2"
```

**Why uncovered:** No seed produces a lowercase HTTP method string (like `get`,
`post`) that would enter the `orelse` block. All seeds use already-valid
uppercase methods.

**Seed fix:** Add seeds with lowercase methods: `get`, `post`, `delete`, `put`.

**Status:** ⚠️ Still open — no seeds added yet for lowercase methods.

---

## Gap 5 -- Absolute URL parsing in `buildRequest` (main.zig:793-823)

**Target:** request

This is the **largest single coverage gap** -- 20+ lines of URL parsing logic
are completely untested by fuzzing.

```zig
793:     const uri = try std.Uri.parse(api_path);                      // "0/4"
794:     const host_part = if (uri.host) |h| ...                       // "0/3"
798:     host_buf = try std.fmt.allocPrint(...)                        // "0/4"
802:     resolved_host = host_buf.?;                                   // "0/3"
805:     const raw_path = uri.path.percent_encoded;                    // "0/3"
807:     if (std.mem.startsWith(u8, raw_path, api_prefix)) {          // "0/1"
808:         relative_path = raw_path[api_prefix.len..];              // "0/1"
809:     } else if (std.mem.startsWith(u8, raw_path, "/api/v1")) {    // "0/2"
811:         relative_path = "";                                       // "0/1"
817:         relative_path = if (...) raw_path[1..] else raw_path;    // "0/2"
821:     if (uri.query) |q| {                                         // "0/1"
822:         path_buf = try std.fmt.allocPrint(...)                   // "0/4"
823:         relative_path = path_buf.?;                              // "0/4"
```

**Why uncovered:** This entire block is gated on `isAbsoluteUrl(api_path)`
returning `true` (line 790). Since the `isAbsoluteUrl` true-branch is never
taken (Gap 1), no seed ever reaches this code.

**Seed fix:** The `fuzz_request` harness feeds `parseArgs` + `buildRequest`, so
seeds need to contain argument sequences encoding absolute URLs. Four sub-cases
need separate seeds:

1. URL with `/api/v1/` prefix (lines 807-808)
2. URL with `/api/v1` exact, no trailing slash (lines 809-811)
3. URL without the prefix (lines 812-817)
4. URL with a query string (lines 821-823)

**Status (2026-05-04):** ✅ Addressed — four `seed_abs_url_*.txt` seeds added (commit `c7a6bc1`). Also note: four `seed_absurl_*.txt` seeds with identical content exist as exact duplicates; remove the `seed_absurl_*` set (without underscore between `abs` and `url`) at next distillation.

---

## Gap 6 -- `jsonToFormEncoded` token dispatch (main.zig:467,475,734,755,778,780,858)

**Target:** request

Several `0/N` entries in the JSON-to-form encoding function with high branch
counts (`0/13`, `0/11`, `0/19`, `0/18`, `0/18`, `0/10`). These correspond to
switch arms for different JSON token types or specific error conditions in
deeply nested JSON handling.

**Why uncovered:** The 22 request seeds do not produce varied JSON structures.
Most seeds likely use simple flat key=value pairs.

**Seed fix:** Add corpus seeds with varied JSON structures: arrays, nested
objects, different value types (numbers, booleans, nulls).

**Status (2026-05-04):** ✅ Addressed — eight `seed_json_*.txt` seeds added (commit `c7a6bc1`).

---

## Gap 7 -- Accept header already present (http_client.zig:144-146)

**Target:** execute

```zig
144:             if (std.ascii.eqlIgnoreCase(h.name, "Accept")) {   // "0/1"
145:                 has_accept = true;                               // "0/1"
146:                 break;                                           // "0/1"
```

**Why uncovered:** No seed provides a pre-existing `Accept` header in the
request. The mock client always receives a request without one, so the default
`application/json` Accept header is always added.

**Seed fix:** Add a seed that includes an `Accept` header in the request
headers.

**Status (2026-05-04):** ✅ Addressed — `ProgrammableMockClient` extended with `include_accept_header` ctrl bit (bit 6); `seed_accept_header.bin` added to `corpus_execute/` (commit `c7a6bc1`).

---

## Gap 8 -- Connection exhaustion quiet-mode error print (http_client.zig:205-206)

**Target:** execute

```zig
205:             if (!req.quiet) {                                    // "0/1"
206:                 std.debug.print("Connection error: {s}\n", ...);// "0/1"
```

**Why uncovered:** The `ProgrammableMockClient` in `fuzz_execute` does not
simulate the specific scenario where `client.request()` fails AND retries are
exhausted AND `quiet` is false. The mock either succeeds or triggers retry
paths, but never the final "give up" path.

**Seed fix:** Add seeds where the mock is programmed with more failures than
retries allow.

**Status:** ⚠️ Still open — requires mock to exhaust retries with `quiet=false`. Not yet wired in `ProgrammableMockClient`.

---

## Gap 9 -- Link header + errdefer cleanup (http_client.zig:274,291-292)

**Target:** execute

```zig
274:                 link_buf = try req.allocator.dupe(u8, hdr.value);  // "0/2"
291:             if (content_type_buf) |ct| req.allocator.free(ct);     // "0/10"
292:             if (link_buf) |l| req.allocator.free(l);               // "0/9"
```

**Why uncovered:** Line 274: no seed produces a response with a `Link` header.
Lines 291-292: the `errdefer` only fires on error after headers are parsed, but
the mock does not produce errors at that point.

**Seed fix:** Program the mock to return `Link` headers in responses. The
errdefer paths (291-292) are harder to trigger -- they require an allocation
failure or error between header parsing and function return.

**Status (2026-05-04):** ✅ Addressed — `ProgrammableMockClient` extended with `link_header` field and emit_link_header ctrl bit (bit 3); `seed_link_header.bin` added to `corpus_execute/` (commit `c7a6bc1`).

---

## Gap 10 -- ReadFailed error path (http_client.zig:316-317,319)

**Target:** execute

```zig
316:                 if (!req.quiet) std.debug.print("Read error\n", .{});  // "0/2"
317:                 return err;                                             // "0/2"
319:             else => |e| return e,                                       // "0/1"
```

**Why uncovered:** The mock's `streamRemaining` never returns `ReadFailed`.
This would require simulating a truncated or corrupt response body.

**Seed fix:** Enhance the `ProgrammableMockClient` to support injecting
`ReadFailed` errors during body reading.

**Status (2026-05-04):** ✅ Addressed — `inject_read_failed` field added to `ProgrammableMockClient`; ctrl bit 5 wired; `seed_read_failed.bin` added to `corpus_execute/` (commit `c7a6bc1`).

---

## Gap 11 -- Structured `content_type` field fallback (http_client.zig:297)

**Target:** execute

```zig
297:             if (response.head.content_type) |ct| {                // "0/2"
```

**Why uncovered:** The mock always sets JSON content type via response headers,
never via the structured `content_type` field on the response head.

**Seed fix:** Have the mock set content type through the structured field
instead of (or in addition to) raw headers.

**Status (2026-05-04):** ✅ Addressed — `use_structured_ct` field added to `ProgrammableMockClient`; ctrl bit 4 (CLEAR = use structured fallback) wired; `seed_structured_ct.bin` added to `corpus_execute/` (commit `c7a6bc1`).

---

## Recommendations

> **Updated 2026-05-04**: Recommendations 1–3, 5–8 are now complete (commit
> `c7a6bc1`). Only recommendations 4 and the connection-exhaustion mock scenario
> (Gap 8) remain open.

### High Priority

These address the largest uncovered logic blocks and would have the greatest
impact on overall coverage.

1. ~~**Absolute URL seeds for request corpus (Gaps 1 + 5)**~~ ✅ DONE (`c7a6bc1`)

2. ~~**JSON variety for request corpus (Gap 6)**~~ ✅ DONE (`c7a6bc1`)

### Medium Priority

These address error/edge-case paths that real-world usage could trigger.

3. **Mock failure scenarios for execute corpus (Gap 8)** — ⚠️ Still open.
   Extend mock to hit connection exhaustion with `quiet=false` (lines 205-206).
   Gap 10 (ReadFailed) is now closed; only connection exhaustion remains.

4. ~~**Lowercase HTTP methods (Gap 4)**~~ — ⚠️ Still open. Add seeds with
   `get`/`post`/`delete` to cover the case-normalization block at lines 764-770.

5. ~~**Link header in mock responses (Gap 9)**~~ ✅ DONE (`c7a6bc1`)

### Low Priority

These cover minor flag paths and edge cases with minimal risk.

6. ~~**CLI flag seeds (Gap 2)**~~ ✅ DONE (`c7a6bc1`)

7. ~~**Malformed flag seeds (Gap 3)**~~ ✅ DONE (`c7a6bc1`)

8. ~~**Accept header and content_type field (Gaps 7 + 11)**~~ ✅ DONE (`c7a6bc1`)

---

## Gap 12 -- `@intCast` panic risk on negative server values (schedule.zig:129,152,316)

**Target:** request (via `schedule` subcommand)

```zig
129:             .integer => @intCast(@as(i64, sp.integer)),
...
152:                 .integer => @intCast(@as(i64, id_val.integer)),
...
316:                     .integer => @intCast(@as(i64, id_val.integer)),
```

**Why uncovered/Problem:** The JSON parser represents all integers as `i64`. The `schedule` subcommand extracts job IDs and casts them to `u64` using `@intCast`. If the openQA server ever returns a negative integer (or malformed JSON that parses as a negative integer) in the `ids` array or `scheduled_product_id` field, `@intCast` will trigger a runtime panic in safe build modes (`Debug`, `ReleaseSafe`), crashing the CLI instead of returning a graceful error.

The E2E suite cannot easily reproduce this because it runs against a real openQA instance which will not return negative job IDs.

**Proposed fix:** Replace `@intCast` with `std.math.cast(u64, json_int) orelse return error.InvalidResponse` (or handle it by printing an error and returning `1`).

**Seed fix:** Once fixed to return an error, add a fuzzer seed that mocks an openQA response containing negative integers in the `ids` array to ensure the error path is covered.

**Status (2026-04-30):** ✅ Fixed — both `@intCast` sites in `schedule.zig` replaced with `std.math.cast` (commit `a58828d`). Regression test added at `schedule.zig:556-575`. AFL found this bug in the first 60 seconds of the `fuzz_schedule` campaign.
