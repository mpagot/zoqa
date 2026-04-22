# E2E Test Catalog

Per-test reference for the openQAclient near end-to-end suite. For an overview
of the harness and how to run it, see [README.md](README.md).

---

## Test Coverage

### API & Protocol
| # | Test | Verification |
|---|---|---|
| 1 | GET `jobs/overview` | Basic endpoint connectivity and JSON array response. |
| 2 | GET `workers` | Basic endpoint connectivity. |
| 3 | Query Parameters | Appending filters (e.g., `distri=opensuse`) to the URL. |
| 14 | Nested JSON Parsing | Correctly parsing and returning complex nested objects (e.g., `settings`). |
| 19 | Resource Discovery | Retrieving seeded groups and verifying data persistence. |
| 21 | Relative vs Absolute Path | `zoqa api jobs/1` and `zoqa api http://localhost/api/v1/jobs/1` produce identical output. |

### Authentication (HMAC-SHA1)
| # | Test | Verification |
|---|---|---|
| 5 | DELETE HMAC | Correct signature generation for `DELETE` requests (verified via 404). |
| 6 | POST HMAC | Correct signature generation for `POST` requests. |
| 18 | Authenticated DELETE | Successful deletion of a real asset using full HMAC handshake. |
| 9 | Auth Failure (403) | Graceful handling of invalid secrets/signatures. |

### CLI Flags & Configuration
| # | Test | Verification |
|---|---|---|
| 7 | `--param-file` | Reading key/value pairs from external files. |
| 8 | CLI Overrides | Explicit flags (`--apikey`) take precedence over `client.conf`. |
| 15 | `--links` Flag | Parsing and displaying `Link` pagination headers. |
| 16 | `--verbose` Flag | HTTP status line and `Content-Type` header present in output. |
| 12, 17 | `--pretty` Flag | JSON indentation logic for both empty and populated responses. |
| 22 | `--name` Flag | Accepted by both Perl and Zig; sets `User-Agent` header. |

### Error Handling & Edge Cases
| # | Test | Verification |
|---|---|---|
| 4 | 404 Not Found | Standard API error propagation. |
| 10 | Missing Arguments | Both Perl and Zig exit 255 with usage text when PATH is omitted. |
| 11 | Connection Refused | Graceful exit when the host is unreachable. |
| 11b | Arg-order Divergence | Both Perl and Zig reject `--host` before the subcommand with exit 255. |
| 20 | Output Parity | Hard `diff` comparison between Perl and Zig output for a nested object. |
| 23 | Broken Pipe | `zoqa … \| head -c 1` exits cleanly without crashing on SIGPIPE. |
| 25, 26 | Non-2xx stderr | `404` reported on stderr without `--quiet`; suppressed with `--quiet`. |

### Verbose Headers (Phase 1.3)
| # | Test | Verification |
|---|---|---|
| 24 | Verbose Header Count | Perl vs Zig header line count comparison — both print 5 header lines. |

### Archive Subcommand
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
| ARC-44 | Progress Percentage | stdout contains "Downloading…%" for rich job (Zig). |
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

### Monitor Subcommand
| # | Test | Verification |
|---|---|---|
| MON-1,2 | Missing JOB_ID | `monitor` with no arguments exits 255. |
| MON-3,4 | Non-numeric JOB_ID | `monitor abc` exits 255 in Zig. |
| MON-5,6 | Completed Job | `monitor RICH_JOB_ID` exits based on final state (0 or 2). |
| MON-7 | Stdout Format | Contains "Job state of job ID". |
| MON-9,10 | Cancelled Job | `monitor JOB_ID` exits 2 when job is cancelled. |
| MON-11,12 | Missing Job | `monitor 999999999` exits 1. |
| MON-13,14 | --follow | Flag accepted (returns newest clone). |
| MON-15,16 | --poll-interval | Flag accepted with numeric argument. |
| MON-17,18 | Multiple Jobs | Multiple IDs passed; exits 2 if any fail. |
| MON-19 | Already-terminal Fast Return | `monitor` on a completed job returns in < 5s (regression: off-by-one sleep bug). |
| MON-50,51 | Invalid Flag | `monitor --extract` exits 255. |

### Schedule Subcommand
| # | Test | Verification |
|---|---|---|
| SCH-1 | Sync Schedule (inline) | Both Perl and Zig schedule via `schedule` with inline `SCENARIO_DEFINITIONS_YAML`, exit 0, stdout contains `"has/have been created"` and job URLs. |
| SCH-2 | Sync Schedule (--param-file) | Both schedule using `--param-file SCENARIO_DEFINITIONS_YAML=/tmp/scenario.yaml`, exit 0, stdout contains `"has/have been created"`. |
| SCH-3 | Async Without --monitor | Both schedule with `async=1` (no `--monitor`), exit 0. No `"has been created"` line expected. |
| SCH-4 | Async With --monitor | Both schedule with `async=1 --monitor`, poll until jobs complete, exit 0. |
| SCH-6 | --follow Without --monitor | Both schedule with `--follow` (no `--monitor`), exit 0 immediately after printing job URLs. `--follow` is a modifier, not a trigger. |
| SCH-7 | --poll-interval + async --monitor | Both schedule with `--poll-interval 1 --monitor async=1`, poll and exit 0. |
| SCH-8 | Missing Mandatory Params | Both schedule with `BOGUS=1` only, server returns 400, exit 1. |
| SCH-9 | Zero Products Scheduled | Both schedule with non-matching `FLAVOR=NONEXISTENT`, exit 1. |
| SCH-10 | Repeated --param-file | Two `--param-file` flags in one invocation; both Perl and Zig exit 0 and produce job URLs. |
| SCH-50 | Invalid Flag (--extract) | `schedule --extract` exits 255 (cross-subcommand flag rejection). |

### Stress Subcommand
| # | Test | Verification |
|---|---|---|
| STRESS-1 | Response Size Sanity | Large job details response is > 10 000 bytes (Zig). |
| STRESS-2 | Output Parity | Full JSON output identical between Perl and Zig for large response. |
| STRESS-3 | Gzip Negotiation | `Accept-Encoding` header contains "gzip" (Zig sends compression request). |
