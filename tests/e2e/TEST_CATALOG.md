# E2E Test Catalog

Per-test reference for the openQAclient near end-to-end suite. For an overview
of the harness and how to run it, see [README.md](README.md).

---

| File | Section | Description | Tests |
|---|---|---|---|
| `tests_core.sh` | A | Core protocol, CLI flags, cross-subcommand rejection | COR-1–COR-43 |
| `tests_auth.sh` | B | Authentication (HMAC-SHA1), credential priority chain | AUT-1–AUT-7 |
| `tests_data.sh` | C | Seeded data: pagination, DELETE, output parity, path handling | DAT-18–DAT-24 |
| `tests_output.sh` | D | Output formatting: `--verbose`, `--pretty`, `--name`, header count | OUT-25–OUT-45 |
| `tests_robustness.sh` | E | Broken pipe, non-2xx stderr, `--quiet` suppression | ROB-1–ROB-3 |
| `tests_retry_knobs.sh` | F | Retry/timeout env vars and CLI flags | RET-2–RET-9 |
| `tests_perf.sh` | G | Performance: timing, peak RSS, interpreter baseline | PERF-B1–PERF-R9 |
| `tests_archive.sh` | H | Archive subcommand | ARC-1–ARC-63 |
| `tests_help.sh` | I | Help output structure and stream routing | HEL-1–HEL-8 |
| `tests_monitor.sh` | I | Monitor subcommand | MON-1–MON-51 |
| `tests_schedule.sh` | J | Schedule subcommand | SCH-1–SCH-RK-3 |
| `tests_clone_smoke.sh` | K | Clone-job: smoke (--help, no-args, bare integer) | CLO-1–CLO-11 |
| `tests_clone_single.sh` | K | Clone-job: single-job flags (--reproduce, --repeat, assets, …) | CLO-12–CLO-83, CLO-RK-1, CLO-84–CLO-89 |
| `tests_clone_topology.sh` | K | Clone-job: graph topologies (chained, fan-out, diamond, parallel) | CLO-20–M42 |
| `tests_clone_maxdepth.sh` | K | Clone-job: --max-depth traversal limits | CLO-90–CLO-97 |
| `tests_stress.sh` | L | Large response stress and gzip negotiation tests | STRESS-1–STRESS-3 |


## Test Coverage

### Core Protocol & CLI Flags (`tests_core.sh`)
| # | Test | Verification |
|---|---|---|
| COR-1 | GET `jobs/overview` | Basic endpoint connectivity and JSON array response. |
| COR-2 | GET `workers` | Basic endpoint connectivity. |
| COR-3 | GET with query params | Appending filters (e.g., `distri=opensuse`) to the URL. |
| COR-4 | GET 404 | Standard API error propagation (`jobs/999999`). |
| COR-5 | Missing PATH argument | Both Perl and Zig exit 255 with usage text when PATH is omitted. |
| COR-6 | Invalid host | Connection refused on unreachable port (exit 1). |
| COR-7 | `--host` before subcommand | Flags placed before `api` rejected (exit 255). |
| COR-8 | `--` stop accepted | `-- jobs/overview` behaves same as without `--` (exit 0). |
| COR-9 | `--` dash-prefixed path | `-- -X` used as literal path (404, not flag error). |
| COR-10 | `--param-file` | Reading key/value pairs from external files. |
| COR-10b | `--param-file` matching | `--param-file` with a value that matches seeded data returns results. |
| COR-36 | `--data` / `-d` raw body POST | Raw body sent verbatim via `--data`. |
| COR-36b | `--data-file` POST | `--data-file` with matching product schedules a job (`count:1`). |
| COR-37 | `--form` JSON to form-encoded | `--form` converts JSON body to `application/x-www-form-urlencoded`. |
| COR-38 | `-a` / `--header` | Custom request header injected without breaking the request. |
| COR-39 | `--json` + `--data-file` + PUT | Content-Type set to `application/json`; raw JSON body via file. |
| COR-40 | `--param-file` + positional KV | File value merged with inline `key=value` parameter. |
| COR-41a | Bare hostname to `https://` | Bare `--host localhost` prepends `https://` (TLS error, exit 1). |
| COR-41b | Unresolvable hostname | DNS failure on non-existent hostname (exit 1). |
| COR-41c | Explicit URL wrong port | Fully-qualified URL with wrong port (ECONNREFUSED, exit 1). |
| COR-42 | Combined short flags `-vp` | Flag bundling rejected (exit 255). |
| COR-43 | Cross-subcommand flag rejection | Archive-only `--with-thumbnails` rejected for `api` (exit 255). |

### Authentication (`tests_auth.sh`)
| # | Test | Verification |
|---|---|---|
| AUT-1 | DELETE HMAC | Correct signature generation for `DELETE` requests (verified via 404). |
| AUT-2 | POST HMAC | Correct signature generation for `POST` requests via config file credentials. |
| AUT-3 | Wrong `--apisecret` (403) | Graceful handling of invalid secrets/signatures. |
| AUT-4 | CLI flags override config | `--apikey`/`--apisecret` override wrong `client.conf` credentials. |
| AUT-5 | Env var credentials | `OPENQA_API_KEY`+`OPENQA_API_SECRET` as sole credential source. |
| AUT-6 | Wrong env var secret (403) | Invalid `OPENQA_API_SECRET` env var is rejected by server. |
| AUT-7 | CLI flags override env vars | `--apikey`/`--apisecret` override wrong env var credentials. |

### Seeded Data (`tests_data.sh`)
| # | Test | Verification |
|---|---|---|
| DAT-18 | GET `jobs/overview` (non-empty) | After seeding, response contains test name. |
| DAT-19 | Nested JSON Parsing | Correctly parsing and returning complex nested objects (e.g., `settings`). |
| DAT-20 | Pagination `--links` + follow | `--links` prints `next:` URL to stderr; following it returns expected data. |
| DAT-21 | Authenticated DELETE | Successful deletion of a real asset using full HMAC handshake (exit 0). |
| DAT-22 | Resource Discovery | Retrieving seeded job groups and verifying data persistence. |
| DAT-23 | Output Parity | Hard `diff` comparison between Perl and Zig output for a nested object. |
| DAT-24 | Relative vs Absolute Path | `zoqa api jobs/1` and `zoqa api http://localhost/api/v1/jobs/1` produce identical output. |

### Authentication (`tests_auth.sh`)
| # | Test | Verification |
|---|---|---|
| AUT-1 | DELETE HMAC | Correct signature generation for `DELETE` requests (verified via 404). |
| AUT-2 | POST HMAC | Correct signature generation for `POST` requests via config file credentials. |
| AUT-3 | Wrong `--apisecret` (403) | Graceful handling of invalid secrets/signatures. |
| AUT-4 | CLI flags override config | `--apikey`/`--apisecret` override wrong `client.conf` credentials. |
| AUT-5 | Env var credentials | `OPENQA_API_KEY`+`OPENQA_API_SECRET` as sole credential source. |
| AUT-6 | Wrong env var secret (403) | Invalid `OPENQA_API_SECRET` env var is rejected by server. |
| AUT-7 | CLI flags override env vars | `--apikey`/`--apisecret` override wrong env var credentials. |

### Output Formatting (`tests_output.sh`)
| # | Test | Verification |
|---|---|---|
| OUT-25 | `--verbose` | HTTP status line and `Content-Type` header present in output. |
| OUT-26 | `--pretty` (non-empty) | JSON indentation logic on populated response. |
| OUT-27 | `--name` Flag | Accepted by both Perl and Zig; sets `User-Agent` header. |
| OUT-28 | Verbose Header Count | Perl vs Zig header line count comparison — both print matching header lines. |
| OUT-42 | `--pretty` (empty result) | No crash on empty JSON array response. |
| OUT-43 | `--links` outputs `next:` | Link header's `rel=next` URL printed to stderr for paginated response. |
| OUT-44 | `--verbose` on 404 | HTTP status line printed even on error responses. |
| OUT-45 | `--quiet --verbose` on 404 | `--quiet` suppresses stderr error; `--verbose` still prints headers to stdout. |

### Robustness (`tests_robustness.sh`)
| # | Test | Verification |
|---|---|---|
| ROB-1 | Broken Pipe | `zoqa ... \| head -c 1` exits cleanly without crashing on SIGPIPE. |
| ROB-2 | Non-2xx stderr | `404` reported on stderr without `--quiet`. |
| ROB-3 | `--quiet` suppresses stderr | `--quiet` suppresses the non-2xx status line on stderr. |

### Retry & Timeout Knobs (`tests_retry_knobs.sh`)
| # | Test | Verification |
|---|---|---|
| RET-2 | `OPENQA_CLI_RETRIES=0` | Explicit zero accepted; both Perl and Zig exit 0 on a healthy request. |
| RET-3 | `OPENQA_CLI_RETRIES=abc` | Invalid value falls back gracefully; both exit 0, no crash. |
| RET-4 | `RETRY_SLEEP_TIME_S` + `RETRY_FACTOR` | Valid numeric values accepted; both exit 0. |
| RET-5 | Invalid sleep/factor values | Invalid env var values fall back gracefully; both exit 0, no crash. |
| RET-6 | `--retries 0` CLI flag | CLI flag accepted by both implementations (exit 0). |
| RET-7 | `OPENQA_CLI_CONNECT_TIMEOUT` valid | Valid numeric connect timeout accepted (exit 0). |
| RET-8 | `OPENQA_CLI_CONNECT_TIMEOUT` invalid | Invalid (non-numeric) value rejected (exit 1). |
| RET-9 | `OPENQA_CLI_RETRIES=2` functional | Fault proxy injects 2×503 then forwards; `OPENQA_CLI_RETRIES=2` → both retry and exit 0; exactly 3 proxy hits confirms retrying occurred. |

### Help Output Structure (`tests_help.sh`)
| # | Test | Verification |
|---|---|---|
| HEL-1 | Global `--help` | Contains "Options (for all commands):" and lists subcommands. |
| HEL-2 | `api --help` | Contains "Options for api:", global options, and "Usage:". |
| HEL-3 | `archive --help` | Contains "Options for archive:", global options, and "Usage:". |
| HEL-4 | `monitor --help` | Contains "Options for monitor:", global options, and "Usage:". |
| HEL-5 | `schedule --help` | Contains "Options for schedule:", global options, and "Usage:". |
| HEL-6 | Global help hides subcommand options | Global `--help` does NOT show "Options for api:". |
| HEL-7 | `--help` stream routing | `--help` writes to stdout and exits 0; bare invocation does the same. |
| HEL-8 | Error stream routing | Unknown subcmd writes to stderr (non-zero); missing PATH writes to stderr (non-zero). |

### Archive Subcommand (`tests_archive.sh`)
| # | Test | Verification |
|---|---|---|
| ARC-1 | Missing All Arguments | `archive` with no JOB_ID or OUTPUT_PATH exits 255 (usage error). |
| ARC-2 | Missing Output Path | `archive JOB_ID` with no path exits 255 (usage error). |
| ARC-3 | Invalid Job ID | `archive 999999 /tmp/out` exits 1 (non-200 job details response). |
| ARC-4 | Basic Archive | Both Perl and Zig archive a seeded job and exit 0. |
| ARC-5 | Output Dir Exists | Output directory is created after a successful archive. |
| ARC-6 | Dir Structure Parity | `find -type d` comparison between Perl and Zig output trees. |
| ARC-7 | testresults/ Created | The `testresults/` directory exists after archive. |
| ARC-8 | ulogs/ Created | The `testresults/ulogs/` directory exists after archive. |
| ARC-9 | No thumbnails/ Default | `testresults/thumbnails/` absent without `--with-thumbnails`. |
| ARC-10 | No repo/ Directory | `repo/` directory never created (repo assets are skipped). |
| ARC-11 | File Listing Parity | `find -type f` comparison between Perl and Zig output trees. |
| ARC-12 | --with-thumbnails | Flag accepted; `testresults/thumbnails/` directory created. |
| ARC-13 | Thumbnails Dir Parity | Dir structure comparison with `--with-thumbnails`. |
| ARC-14 | --asset-size-limit | Flag accepted with default value (exit 0). |
| ARC-15 | Size Limit 1 Byte | `--asset-size-limit 1` exits 0 (skips are not fatal). |
| ARC-16 | --quiet Flag | `--quiet` accepted on archive (exit 0). |
| ARC-17 | --verbose --pretty | Both no-op flags accepted on archive (exit 0). |
| ARC-18 | Env Var Credentials | Archive works with `OPENQA_API_KEY`/`SECRET` env vars. |
| ARC-19 | Wrong Credentials (GET public) | Wrong config credentials do not cause failure (GET endpoints are public). |
| ARC-20 | Progress Messages | stdout contains "Downloading test details", "logs", "ulogs". |
| ARC-21 | Asset Group Message | stdout contains "Attempt {type} download:" for asset groups. |
| ARC-22 | Pre-existing Dir | Archive into an existing directory succeeds (exit 0). |
| ARC-23 | Short Flags -t -l | Short-form flags `-t` and `-l` are accepted. |
| ARC-24 | --host Before archive | Global `--host` before subcommand name rejected (exit 255). |
| ARC-25 | Default Size Limit | Default 200 MiB limit allows small files (exit 0). |
| ARC-26 | Rich Job Archive | Both Perl and Zig archive the rich job (exit 0). |
| ARC-27 | Rich Output Dir Exists | Rich archive output directory created. |
| ARC-28 | details-*.json Exist | `details-*.json` files present in `testresults/` (Zig). |
| ARC-29 | details-*.json Parity | `ls details-*.json` listing identical between Perl and Zig. |
| ARC-30 | details-*.json Content | First details file content identical after `jq -S` normalisation. |
| ARC-31 | Screenshot .png Exist | `.png` files present in `testresults/` (Zig). |
| ARC-32 | Screenshot Listing Parity | `ls *.png` listing identical between Perl and Zig. |
| ARC-33 | Screenshot Size Parity | First `.png` byte size identical between Perl and Zig. |
| ARC-34 | Thumbnails Rich Job | `--with-thumbnails` on rich job; thumbnail `.png` files created. |
| ARC-35 | Thumbnail Listing Parity | `ls *.png` in `thumbnails/` identical between Perl and Zig. |
| ARC-36 | autoinst-log.txt Exists | `autoinst-log.txt` present in `testresults/` (Zig). |
| ARC-37 | Log Listing Parity | `ls *.txt` listing identical between Perl and Zig. |
| ARC-38 | Log Content Parity | `autoinst-log.txt` content identical between Perl and Zig. |
| ARC-39 | hdd/ Dir Exists | HDD asset directory present after rich archive (Zig). |
| ARC-40 | CirrOS Size Non-zero | CirrOS `.qcow2` image size is > 20 MB. |
| ARC-41 | Asset Size Parity | CirrOS image byte size identical between Perl and Zig. |
| ARC-42 | Size Limit Skips CirrOS (Zig) | `--asset-size-limit 1` prints "exceeds maximum size limit" (Zig). |
| ARC-43 | Size Limit Skips CirrOS (Perl) | `--asset-size-limit 1` prints "Maximum message size exceeded" (Perl). |
| ARC-44 | Progress Percentage | stdout contains "Downloading...%" for rich job (Zig). |
| ARC-45 | Saved Details Message | stdout contains "Saved details for" (Zig). |
| ARC-46 | Full Dir Structure Parity | `find -type d` full comparison on rich archive. |
| ARC-47 | Full File Listing Parity | `find -type f` full comparison on rich archive. |
| ARC-50 | --form Rejected | `archive --form` exits 255 (api-only flag). |
| ARC-51 | --json Rejected | `archive --json` exits 255 (api-only flag). |
| ARC-52 | -X Rejected | `archive -X POST` exits 255 (api-only flag). |
| ARC-53 | --data Rejected | `archive --data body` exits 255 (api-only flag). |
| ARC-60 | CLI Flags Override Config | `--apikey`/`--apisecret` override a wrong config file. |
| ARC-61 | CLI Flags Override Env Vars | `--apikey`/`--apisecret` override wrong env var credentials. |
| ARC-62 | Wrong Env Secret (GET public) | Wrong `OPENQA_API_SECRET` env var does not fail read-only archive. |
| ARC-63 | --osd Alias | `archive --osd` resolves to `openqa.suse.de` (connection fails as expected). |

### Monitor Subcommand (`tests_monitor.sh`)
| # | Test | Verification |
|---|---|---|
| MON-1 | PERL: No JOB_ID | Captures Perl behaviour (no validation, exits 0 — known divergence). |
| MON-2 | ZIG: No JOB_ID | `monitor` with no arguments exits 255. |
| MON-3 | PERL: Non-numeric JOB_ID | Captures Perl behaviour (no upfront validation). |
| MON-4 | ZIG: Non-numeric JOB_ID | `monitor abc` exits 255 in Zig. |
| MON-5,6 | Completed Job | `monitor RICH_JOB_ID` exits based on final state (Zig matches Perl). |
| MON-7 | Stdout Format | Diff comparison of stdout output between Perl and Zig. |
| MON-9,10 | Cancelled Job | `monitor JOB_ID` exits 2 when job is cancelled. |
| MON-11,12 | Missing Job | `monitor 999999999` exits 1. |
| MON-13,14 | --follow | Flag accepted (returns newest clone). |
| MON-15,16 | --poll-interval | Flag accepted with numeric argument. |
| MON-17,18 | Multiple Jobs | Multiple IDs passed; exits 2 if any fail. |
| MON-19 | Already-terminal Fast Return | `monitor` on a completed job returns in < 5s (regression: off-by-one sleep bug). |
| MON-50,51 | Invalid Flag | `monitor --extract` exits 255. |

### Schedule Subcommand (`tests_schedule.sh`)
| # | Test | Verification |
|---|---|---|
| SCH-1 | Sync Schedule (inline) | Both Perl and Zig schedule via `schedule` with inline `SCENARIO_DEFINITIONS_YAML`, exit 0, stdout contains `"has/have been created"` and job URLs. |
| SCH-2 | Sync Schedule (--param-file) | Both schedule using `--param-file SCENARIO_DEFINITIONS_YAML=/tmp/scenario.yaml`, exit 0, stdout contains `"has/have been created"`. |
| SCH-3 | Async Without --monitor | Both schedule with `async=1` (no `--monitor`), exit 0. |
| SCH-4 | Async With --monitor | Both schedule with `async=1 --monitor`, poll until jobs complete, exit 0. |
| SCH-6 | --follow Without --monitor | Both schedule with `--follow` (no `--monitor`), exit 0 immediately after printing job URLs. `--follow` is a modifier, not a trigger. |
| SCH-7 | --poll-interval + async --monitor | Both schedule with `--poll-interval 1 --monitor async=1`, poll and exit 0. |
| SCH-8 | Missing Mandatory Params | Both schedule with `BOGUS=1` only, server returns 400, exit 1. |
| SCH-9 | Zero Products Scheduled | Both schedule with non-matching `FLAVOR=NONEXISTENT`, exit 1. |
| SCH-10 | Repeated --param-file | Two `--param-file` flags in one invocation; both Perl and Zig exit 0 and produce job URLs. |
| SCH-11 | Sync All Entries Fail | Parity test: all job_template entries reference nonexistent machine. Both exit non-zero with stderr output. |
| SCH-12 | Sync Partial Success | Parity test: one valid + one invalid entry. Both print URLs AND exit with error. |
| SCH-13 | Async --monitor All Fail | Parity test: async polling with all-failed entries. Both exit non-zero. |
| SCH-14 | Async --monitor Partial | Parity test: async polling with mixed results. `failed` wins over `successful_job_ids`. |
| SCH-15 | Cancelled Mid-poll | SKIPPED (timing non-deterministic; deferred to unit test with stubbed server). |
| SCH-EX1 | No YAML, FLAVOR=NONEXISTENT | Failure-trigger experiment: parity on exit code (TRIGGERED or PERMISSIVE). |
| SCH-EX2 | Inline YAML, undefined product | Failure-trigger experiment: parity + audit (no `job_create` events). |
| SCH-EX3 | Inline YAML, empty job_templates | Failure-trigger experiment: parity + audit (no `job_create` events). |
| SCH-EX4 | Nonexistent _GROUP_ID | Failure-trigger experiment: parity on exit code. |
| SCH-EX5 | Nonexistent HDD_1 asset | Failure-trigger experiment: parity on exit code. |
| SCH-EX6 | Partial bogus product ref | Failure-trigger experiment: valid + undefined product in YAML. |
| SCH-EX7 | Async --monitor, FLAVOR mismatch | Failure-trigger experiment: captures `failed_job_info` shape. |
| SCH-50 | Invalid Flag (--extract) | `schedule --extract` exits 255 (cross-subcommand flag rejection). |
| SCH-RK-1 | `OPENQA_CLI_RETRIES=0` | Retry env var accepted by schedule (exit 1, not crash). |
| SCH-RK-2 | `OPENQA_CLI_RETRIES=abc` | Invalid retry env var falls back gracefully. |
| SCH-RK-3 | `--retries 0` CLI flag | Perl rejects (exit 255); Zig accepts (exit 1). |

### Clone-Job Subcommand (`tests_clone_smoke.sh`, `tests_clone_single.sh`, `tests_clone_topology.sh`, `tests_clone_maxdepth.sh`)
| # | Test | Verification |
|---|---|---|
| CLO-1 | `--help` exits 0 | Both `openqa-clone-job --help` and `zoqa-clone-job --help` exit 0. |
| CLO-2 | `--help` has Usage: | Help output contains "Usage:" header. |
| CLO-3 | `--help` mentions --within-instance | Flag advertised in help text. |
| CLO-4 | `--help` mentions --skip-download | Flag advertised in help text. |
| CLO-5 | `--help` mentions --from | Flag advertised in help text. |
| CLO-6 | `--help` mentions --host | Flag advertised in help text. |
| CLO-7 | `--help` writes to stdout | Help output on stdout, nothing on stderr. |
| CLO-8 | No args exits non-zero | Both tools exit non-zero without arguments. |
| CLO-9 | No args writes to stderr | Error output on stderr, nothing on stdout. |
| CLO-10 | Bare integer without --from | Exits non-zero (no source host known). |
| CLO-11 | Stream routing for bare integer | Perl writes to stdout (pod2usage quirk); Zig writes to stderr. |
| CLO-12 | --within-instance exits 0 | Clone of a known job succeeds. |
| CLO-13 | Stdout creation message + URL | stdout has "has been created" and `http://localhost/tests/N`. |
| CLO-14 | CLONED_FROM setting correct | Cloned job's `CLONED_FROM` matches original job URL. |
| CLO-15 | BUILD override | `BUILD=e2e-clone-override` reflected in cloned job settings. |
| CLO-16 | Non-existent job | Cloning job 999999 exits non-zero. |
| CLO-17 | --from --host --skip-download | Long-form flag equivalent of `--within-instance` exits 0. |
| CLO-20 | Chained child clones both | Default clone of chained child creates parent + child (2 jobs). |
| CLO-21 | Cloned parent CLONED_FROM | Correct `CLONED_FROM` on the cloned parent job. |
| CLO-22 | Child points to cloned parent | `_START_AFTER` dependency links to the new parent, not the original. |
| CLO-23 | --skip-deps | Only the child is cloned (1 job); no chained parents. |
| CLO-24 | --skip-chained-deps | Same as M23 but with the specific chained-dep flag. |
| CLO-25 | Override applies to child only | `BUILD=dep-override` on child; parent retains original BUILD. |
| CLO-26 | --parental-inheritance | Override propagates to ALL ancestors (parent + child get same BUILD). |
| CLO-27 | Fan-out child_a clones 2 | Cloning one sibling creates parent + that sibling only (not other siblings). |
| CLO-28 | --clone-children | Cloning parent with `--clone-children` creates all 4 fan-out jobs. |
| CLO-29 | Fan-out override isolation | Override on child_b doesn't leak to parent. |
| CLO-30 | Multi-layer child clones all 3 | Grandparent + parent + child all created. |
| CLO-31 | Multi-layer dependency chain | `_START_AFTER` chain preserved through all layers. |
| CLO-32 | Multi-layer override isolation | Override at child doesn't reach grandparent or parent. |
| CLO-33 | Multi-layer --parental-inheritance | Override propagates to all ancestors. |
| CLO-34 | Diamond merge clones all 4 | Root + left + right + merge all created. |
| CLO-35 | Diamond dependencies preserved | Merge depends on left+right; both depend on root. |
| CLO-37 | Diamond override isolation | Override on merge doesn't reach root/left/right. |
| CLO-38 | Diamond --skip-deps | Only merge is cloned (1 job). |
| CLO-39 | Multi-layer --skip-chained-deps | Only the leaf is cloned (1 job). |
| CLO-41 | Parallel child clones parent | `parallel_child` clone creates parent + child (2 jobs). |
| CLO-42 | --clone-children (parallel) | Cloning parallel parent with `--clone-children` creates both (2 jobs). |
| CLO-43 | Bare --host localhost to http:// | Clone-job special-cases bare `localhost` to `http://` (not `https://`). |
| CLO-44 | Bare --host 127.0.0.1 to https:// | Non-localhost bare host gets `https://` (TLS error expected). |
| CLO-90 | Default --max-depth is 1 (Perl == Zig) | No `--max-depth` flag → both clone only 2 jobs (layer_a + layer_b) from a 17-layer chain. |
| CLO-91 | Explicit --max-depth 1 | Both Perl and Zig clone 2 jobs from the deeplayer root. |
| CLO-91b | --max-depth 1 layer identity | Cloned jobs are layer_a and layer_b; layer_c is absent. |
| CLO-92 | --max-depth 3 | Both clone 4 jobs (layer_a–layer_d); layer_e is absent. |
| CLO-93 | --max-depth 0 (unlimited) | Both clone all 17 layers from the root. |
| CLO-94 | --max-depth > chain depth | `--max-depth 20` on a 17-node chain clones all 17 (no artificial clamp). |
| CLO-95 | --max-depth does not limit parents | Cloning leaf (layer_s) with `--max-depth 1` still produces all 17 ancestors. |
| CLO-96 | Clone from middle + --max-depth 2 | layer_i (position 9) as root: 8 ancestors + layer_i + layer_l = 11 jobs; layer_m (child-depth 3) absent. |
| CLO-97 | Middle + --skip-deps + --max-depth 0 | layer_i + all 8 descendants (l–s) = 9 jobs; no parents (--skip-deps). |
| CLO-RK-1 | `OPENQA_CLI_RETRY_SLEEP_TIME_S` + `RETRY_FACTOR` for clone-job | Both Perl and Zig accept these env vars on a healthy server and exit 0. |
| CLO-84 | Perl retries on 503 | Fault proxy injects 2×503 then forwards; Perl retries and exits 0; ≥3 proxy hits confirmed; MD5 of downloaded asset verified against source. |
| CLO-85 | Zig retry on 503 [TDD] | Same fault scenario as CLO-84; Zig currently exits non-zero (Gap 2 unimplemented); exactly 1 proxy hit; no partial file must remain (TDD). |
| CLO-86 | 404 → no retry (both) | Proxy always returns 404; Zig exits non-zero (correct) and must leave no partial file; Perl exits 0 (known bug) and must also leave no partial file (TDD for cleanup). |
| CLO-87 | Perl exhausts retries | Proxy always 503; `--retry 2` → Perl exits 0 after exactly 3 attempts (known curl bug); no partial file must remain (TDD for cleanup). |
| CLO-88 | `--retry 0` disables retries | Proxy always 503; `--retry 0` → both tools make minimal attempts; Zig exits non-zero and must leave no partial file; Perl exits 0 (known bug) and must also leave no partial file (TDD). |
| CLO-89 | Default --retry retries BFS GET [TDD] | Proxy faults `/api/v1/jobs/` with 2×503 then forwards; Perl retries by default and succeeds; Zig currently fails (wrong default of 0 retries instead of 5). |
| CLO-98 | Perl retries after mid-transfer TCP drop | Proxy sends 200 + 64 bytes then RST (partial mode) × 2, then forwards cleanly; Perl's curl retries on CURLE_RECV_ERROR (56) and exits 0; ≥3 proxy hits confirmed; MD5 verified — file must not be a concatenation of partial attempts. |
| CLO-99 | Zig mid-transfer TCP drop [TDD] | Same partial fault scenario as CLO-98; Zig currently exits non-zero (Gap 2 unimplemented — no retry in `downloadAssets`); exactly 1 proxy hit; no partial file must remain (TDD). |

### Stress Tests (`tests_stress.sh`)
| # | Test | Verification |
|---|---|---|
| STRESS-1 | Response Size Sanity | Large job details response is >= 30 MB (Perl). |
| STRESS-2 | Output Parity | Full JSON output identical between Perl and Zig for large response. |
| STRESS-3 | Gzip Negotiation | `Accept-Encoding` header contains "gzip" (Zig sends compression request). |
| (info) | Wall-clock timing | Informational: timing comparison for large response (no PASS/FAIL). |
| (info) | Peak RSS | Informational: memory comparison for large response (no PASS/FAIL). |

### Performance (`tests_perf.sh`)

All performance tests are **informational only** (no PASS/FAIL threshold).

| # | Test | Metric |
|---|---|---|
| PERF-B1 | Bare Perl startup (`perl -e '1'`) | Wall-clock + RSS baseline. |
| PERF-B2 | Perl + Mojo::UserAgent load | Wall-clock + RSS baseline (framework overhead). |
| PERF-T1 | Plain `jobs/overview` | Wall-clock timing (3 runs, min/avg/max). |
| PERF-T2 | Plain `jobs/:id` | Wall-clock timing (3 runs). |
| PERF-T3 | Config-file creds `jobs/overview` | Wall-clock with `OPENQA_CONFIG=/etc/openqa`. |
| PERF-T4 | CLI-flag creds `jobs/overview` | Wall-clock with `--apikey`/`--apisecret`. |
| PERF-T5 | `--pretty jobs/overview` | Wall-clock with JSON re-indentation. |
| PERF-T6 | Archive baseline (dummy job) | Wall-clock for archive subcommand (3 runs). |
| PERF-T7 | Archive `--asset-size-limit 1` | Wall-clock with assets skipped (3 runs). |
| PERF-T8 | Archive rich job (~21 MB) | Wall-clock with real I/O throughput (3 runs). |
| PERF-R1 | Plain `jobs/overview` | Peak RSS (Perl ~50-60 MB, Zig ~3-8 MB). |
| PERF-R2 | Plain `jobs/:id` | Peak RSS. |
| PERF-R3 | Config-file creds | Peak RSS with config-file code path. |
| PERF-R4 | CLI-flag creds | Peak RSS with argument-parser credential path. |
| PERF-R5 | `--pretty jobs/overview` | Peak RSS with formatting code path. |
| PERF-R6 | Archive baseline (dummy job) | Peak RSS for archive subcommand. |
| PERF-R7 | Archive `--asset-size-limit 1` | Peak RSS with assets skipped. |
| PERF-R8 | Archive rich job (~21 MB) | Peak RSS with real I/O. |
| PERF-R9 | Monitor 5 completed jobs | Peak RSS for monitor subcommand (5 simultaneous jobs). |


