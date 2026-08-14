# Deviations from the Perl reference (`openqa-cli` / `openqa-clone-job`)

This document catalogs every known behavioural difference between the Zig
implementation (`zoqa` / `zoqa-clone-job`) and the upstream Perl reference
clients (`openqa-cli` / `openqa-clone-job`).

It was compiled by grepping `ideas/SPEC.md`, the code comments in `src/`, and
the end-to-end suite in `tests/e2e/`. Each entry cites its authoritative source
so it can be re-verified.

**Guiding principle** ([[feedback_perl_parity_scope]]): the upstream Perl client
is the behavioural oracle for *user-visible behaviour only*; internal
architecture is free to improve. The deviations below fall into two buckets:

- **Deliberate divergence** — an intentional, documented, and tested departure,
  usually because the Perl behaviour is a bug or a footgun.
- **Accepted / cosmetic** — output-format differences that are structurally
  equivalent and not worth matching byte-for-byte.

---

## 1. Host / URL resolution

| # | Area | Perl | Zig | Type | Source |
|---|------|------|-----|------|--------|
| 1.1 | `zoqa api` host resolution | bare hostname → `https://` | same, but **`localhost` is special-cased to `http://`** for `zoqa-clone-job` (`Client.pm:url_from_host`) | Parity (matches Perl) | SPEC §2.1, §18.2 |
| 1.2 | `--osd` alias | — | uses plain `http://` (not `https://`); credentials travel in cleartext (internal SUSE infra) | Deliberate | SPEC §2.1 (line 53) |
| 1.3 | clone-job `--host` rules | `Client.pm:url_from_host`: `://` or `/` → as-is; `localhost` → `http://`; else `https://` | matches Perl, but **differs from `zoqa api`'s own §2.1 rules** | Parity (differs across binaries) | SPEC §18.2 |

`clone_job_main.zig:157` — URL JOBREF gets `http://` prepended when it has no
scheme, matching Perl.

---

## 2. `zoqa api` (vs `openqa-cli api`)

### 2.1 Body on a bodiless method — **deliberate divergence**
- **Perl:** silently sends a body on a `GET` (e.g. `--data-file` without `-X POST`); the server ignores it and Perl exits `0`.
- **Zig:** rejects the request up front with `error.BodyOnBodilessMethod`, non-zero exit, stderr message: `Error: a request body was provided for GET, which does not allow a body (use -X POST/PUT/PATCH)`.
- **Why:** Perl's behaviour is a footgun (silently discarded body ≈ a forgotten `-X POST`), and Zig's `std.http.Client` would otherwise *assert*/panic (SIGABRT / exit 134) when sending a body on GET. The guard runs once before the retry loop.
- **Source:** SPEC §7.1; `src/http_client.zig:259`; e2e ROB-8 (`tests_robustness.sh:200`).

### 2.2 `--data-file` / stdin size cap — **deliberate divergence**
- **Perl:** no size limit — reads the entire file regardless of size.
- **Zig:** hard **10 MiB cap**; an oversized file is rejected with a non-zero exit before the request is built (memory-safety bound — body read into a single allocation).
- **Source:** SPEC §7.2; e2e ROB-7 (`tests_robustness.sh:168`); TEST_CATALOG ROB-7.

### 2.3 `-X form` — flat-object-only, **stricter than Perl**
- **Perl:** silently passes nested values to Mojolicious, producing undefined/garbled output.
- **Zig:** only flat JSON objects (string/number/bool/null values) are accepted; nested objects/arrays are rejected with `error.FormUnsupportedValueType`.
- **Source:** SPEC §7 (lines 212–221).

### 2.4 `--retries` flag spelling & default
- **`zoqa api`:** `--retries` (plural, `-r`, default `0`) — inherited from `openqa-cli api`.
- **`zoqa-clone-job`:** `--retry` (singular, no short form, default `5`) — inherited from `openqa-clone-job`. See §4.
- Both spellings match upstream verbatim; the cross-binary difference is deliberate, not a typo.
- **Source:** SPEC §8 note (lines 296–301).

### 2.5 `--param-file` trailing-newline handling (cosmetic)
- **Perl:** `path->slurp` retains the trailing newline in the file value.
- **Zig:** `trimRight` strips it.
- e2e COR-40 sidesteps this by writing files without a trailing newline.
- **Source:** `tests_core.sh:147`.

---

## 3. Output formatting (mostly accepted / cosmetic)

| # | Area | Perl | Zig | Type | Source |
|---|------|------|-----|------|--------|
| 3.1 | `testresults/details-*.json` | `Cpanel::JSON::XS` with `->canonical` (sorted keys) + `->escape_slash` (`/`→`\/`) | `std.json.Stringify` defaults: minified, insertion-order keys, no slash escaping | Accepted (structurally equal per `jq`) | SPEC §13 (lines 561–568) |
| 3.2 | Pagination `Link:` lines | wrapped in ANSI colour codes (`\e[32m…\e[0m`) | plain text | Accepted (tests strip ANSI) | `tests_data.sh:39` |
| 3.3 | `--pretty` on empty result | prints `"[\n]\n"` | prints `"[]\n"` | Accepted (no pattern asserted) | `tests_output.sh:83` |
| 3.4 | Archive progress output | progress via `print` to stdout | stdout (TODO: consider stderr for pipe-cleanliness) | Open / under review | SPEC §13.8 (lines 610–618) |

---

## 4. `zoqa-clone-job` (vs `openqa-clone-job`)

### 4.1 Error stream routing — bare integer JOBREF without `--from`
- **Perl:** calls `pod2usage(1)`; per `Pod::Usage` convention `exitval < 2` → **stdout** (a quirk).
- **Zig:** always writes error messages to **stderr** (idiomatic POSIX).
- Exit code is non-zero for both.
- **Source:** SPEC §17.1, §18.11 (line 1563); e2e CLO-11 (`tests_clone_smoke.sh:72`); TEST_CATALOG CLO-11.

### 4.2 Retry semantics — `--retry` applied uniformly
- **`zoqa api`:** retries default to `0`, apply to `api` calls only.
- **`zoqa-clone-job`:** `--retry` (default `5`) applies uniformly to **all** HTTP operations — BFS GETs, POST to destination, and asset downloads. `OPENQA_CLI_RETRIES` fallback is bypassed. Exponential backoff (base 3s, factor 2 → 3/6/12/24/48s) is the effective default, matching Perl's `OPENQA_CLI_RETRY_FACTOR //= 2`.
- **Source:** SPEC §18.18.2; e2e CLO-84…CLO-89.

### 4.3 Exit code on download failure — **deliberate divergence**
- **Perl:** invokes `curl` without `--fail`, so curl exits `0` on 404/503; the `mirror()` error check is a no-op. **The process exits `0` even when every asset download failed** (upstream bug).
- **Zig:** exits `1` immediately on HTTP 404 (no retry), exits `1` after exhausting `--retry` on transient errors, and only exits `0` if all assets downloaded (or were skipped via `--ignore-missing-assets`).
- **Source:** SPEC §18.18.1; e2e CLO-86 (404), CLO-88 (`--retry 0`) — the suite explicitly accepts Perl's buggy exit-0 without failing (`tests_clone_single.sh:1129`); TEST_CATALOG CLO-86/CLO-88.

### 4.4 Mid-transfer TCP drop / short-read validation — **deliberate divergence**
- **Perl:** on a length-bearing TCP drop, curl detects `CURLE_PARTIAL_FILE` (18) but **does not retry** it (curl's `--retry` excludes error 18), so the clone fails immediately even when retries are configured. On a *length-less* response it interprets the reset as clean EOF, exits `0`, and leaves a corrupt truncated file.
- **Zig:** strictly compares bytes-streamed against `Content-Length`; a short read raises `error.HttpTransferTruncated`, treated as a **transient** error → exponential-backoff retry up to the limit. Partial files are deleted between attempts (no concatenation). Net effect: **Zig self-heals and completes where Perl fails.** (Length-less responses currently still mirror curl's silent truncation — Gap 8b.)
- **Source:** SPEC §18.18.3; e2e CLO-98 (Perl fails), CLO-99 (Zig); `tests_clone_single.sh:1426`.

### 4.5 UEFI vars asset on skipped parents — **deliberate divergence**
- **Perl:** with `--skip-deps`, parent details aren't fetched, so its filter concludes no parent publishes the `UEFI_PFLASH_VARS` asset and **skips downloading it** → the cloned child lands in a broken, unrunnable state (asset missing, parent not regenerated).
- **Zig:** if a `UEFI_PFLASH_VARS` asset is requested and parent enqueuing was skipped (via `--skip-deps`/`--skip-chained-deps`) while parent deps exist, Zig **downloads** the asset from the source, keeping the cloned child runnable.
- **Source:** SPEC §18.18.4; e2e CLO-110 (`tests_clone_uefi.sh`), CLO-112.

### 4.6 `--export-command` tool name
- **Perl:** would emit `openqa-cli api …`.
- **Zig:** emits `zoqa api …` (intentional divergence).
- **Source:** SPEC §18.13 (lines 1601–1602).

### 4.7 Error exit codes collapsed to `1` — **deliberate divergence (Gap 7)**
- **Perl:** unhandled errors, invalid arguments, or `die` (e.g. from `Getopt::Long` / `pod2usage`) yield exit `255`.
- **Zig (clone-job Tier A):** all error conditions (including argument parsing and job-ref resolution errors) collapse to `1`. Perl's `255` is not modelled per spec.
- **Verification:** verified side-by-side via E2E tests `CLO-105` to `CLO-108`.
- **Source:** SPEC §18.11 (line 1573); `ideas/CLONE_JOB_TODO.md` (Gap 7); `tests/e2e/tests_clone_single.sh` (line 1747).

### 4.8 Reserved flags accepted but inert
- `--check-repos` and `--show-progress` are parsed by `parseCloneArgs` but currently have **no behavioural effect** (reserved for upstream parity).
- **Source:** SPEC §18.12.

### 4.9 Skip-if-complete probe order — **deliberate divergence**
- **Perl:** uses `curl -C -` (resume mode), which opens the destination file for
  writing *before* querying the server. If the file is already complete, the
  server returns HTTP 416 and curl closes the file untouched. However, the
  upfront open-for-write fails on certain container overlay filesystems
  (observed with curl 8.21.0 on overlayfs: `CURLE_WRITE_ERROR` exit 23,
  even as root on a `-rw-rw-rw-` file).
- **Zig:** reverses the order — `stat()` reads the local file size (read-only),
  then a ranged HTTP GET asks the server whether the file is complete (416 →
  already complete). Only if a write is actually needed does Zig open the file.
  For already-complete assets, no write occurs at all.
- **Net effect:** Zig is immune to the overlayfs open-for-write failure that
  affects Perl/curl in same-host clone scenarios (`--from` and default `--dir`
  targeting the same factory path).
- **Source:** `src/http_client.zig` (`isRemoteComplete`, `openQADownloadToFile`);
  e2e CLO-75 (`tests_clone_single.sh`); `ideas/CLONE_JOB_TODO.md` (Gap 9).

---

## 5. `schedule` (vs `openqa-cli schedule`)

### 5.1 `failed_job_info` field name — **deliberate divergence (improvement)**
- **Perl:** `_error_from_json` inspects only `results.failed`, so it **silently misses async-side scheduler errors** and reports success when the server reported partial/total failure.
- **Zig:** `schedule --monitor` inspects, in order: `results.failed_job_info`, then `results.failed`, then `results.error` / top-level `error`. Non-empty → joined messages to stderr, exit `1`. Catches an error class Perl misses.
- **Source:** SPEC §15.6.1.

### 5.2 Empty-result rule (resolves `ISSUE_SCHEDULA_DIVERGED`)
- When the sync response has `count:0`, empty `ids`, empty/absent `failed`, and no `error`, the command exits `0` — matching Perl's `_create_jobs`/`_error_from_json` returning undef. The Zig code distinguishes sync-empty-ids (key present, exit 0) from async (key absent → `scheduled_product_id`).
- **Source:** SPEC §15.5–§15.6 (lines 860–867); `src/schedule.zig:163–170`; `tests_schedule.sh` DIVERGED-gated cases.

### 5.3 `--retries` accepted by `schedule`
- **Perl:** `schedule` does not accept `--retries` → unknown option → exit `255`.
- **Zig:** accepts `--retries` as a global flag (→ server rejects the bogus payload → exit `1`).
- **Source:** `tests_schedule.sh:1007` (SCH-RK-3).

---

## 6. `monitor` (vs `openqa-cli monitor`)

### 6.1 Missing / invalid JOB_ID validation
- **Perl:** performs no upfront validation — `monitor` with no JOB_ID (or a non-numeric one) exits `0`.
- **Zig:** validates the argument and exits `255`.
- **Source:** `tests_monitor.sh:29` (MON-1/MON-2), `:42` (MON-3/MON-4); TEST_CATALOG MON-1.

---

## 7. `archive` (vs `openqa-cli archive`)

### 7.1 Exit-0-on-partial-failure (under review)
- **Perl:** `archive.pm:command()` unconditionally returns `0` after `run(...)`; per-file errors are printed but never propagated. Only the initial job-details fetch and fatal I/O errors produce non-zero.
- **Zig:** currently mirrors this (file-level errors like 404/timeout/size-skip don't change the exit code). Flagged as a TODO to research whether Perl's behaviour is intentional.
- **Source:** SPEC §13 (lines 650–656).

### 7.2 JSON slash-escaping in archived details
- Same as §3.1 — Perl's `Mojo::JSON` escapes `/` as `\/`; Zig does not.
- **Source:** `tests_archive.sh:547`.

---

## Notes on scope

- E2E tests under `tests_clone_maxdepth.sh`, `tests_clone_smoke.sh`,
  `tests_clone_topology.sh`, and `tests_clone_single.sh` run every scenario as a
  **PERL-vs-ZIG comparison against the same input**, using upstream
  `openqa-clone-job` as the behavioural oracle. Only the entries above are known
  *intended* deviations; everything else is expected to match.
- The default `--max-depth` is `1` for both Perl and Zig
  (`tests_clone_maxdepth.sh:22`).
- Behavioural rationale for clone-job lives in
  `ideas/OPENQA_CLONE_JOB_ANALYSIS.md` and `ideas/OPENQA_CLONE_DEP_GRAPH.md`;
  the normative contract is `ideas/SPEC.md` §18.
