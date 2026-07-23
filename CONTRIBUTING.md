# Contributing to Zoqa

## Development Workflow

### Prerequisites

- Zig 0.15.2 (pinned in `.tool-versions`)
- Podman (for E2E tests)
- shellcheck (for e2e lint)

### Build and Test

```sh
make zig-build-debug    # debug binary at zig-out/bin/zoqa
make zig-build-release  # release binary (ReleaseFast + stripped)
make zig-test           # unit tests (includes discovery guard)
make e2e-lint           # lint all E2E scripts
make zig-build-debug && make e2e-dryrun  # validate E2E harness (no container needed)
make e2e                # full E2E suite (Podman; auto-starts/tears down container)
```

### Pre-PR Checklist

All of these must pass before opening a pull request; they mirror the CI gate:

```sh
make zig-lint             # Zig formatting
make zig-test-discovery   # test discovery guard (Zig issue #10018)
make e2e-lint             # E2E script linting
make manual-lint          # manual script linting
make fuzz-lint            # fuzz script linting
make fuzz-sanitize        # corpus filename safety (Windows-safe)
make zig-build-debug && make e2e-dryrun  # build + E2E dry run
```

Run additionally when relevant:

```sh
make zig-doc-lint       # docstring completeness (when adding/changing pub fn)
make e2e-catalog-lint    # catalog parity (when editing E2E tests)
make e2e SUITES=core     # quick E2E smoke test
```

### Make Targets

```sh
make help  # print full table
```

| Target | Description |
|---|---|
| `zig-build-debug` | `zig build` debug binary at `zig-out/bin/zoqa`. |
| `zig-build-release` | `zig build -Doptimize=ReleaseFast -Dstrip=true`. |
| `zig-test` | Run all unit tests (includes `zig-test-discovery`). |
| `zig-test-discovery` | Guard against Zig issue #10018: verify every `test` block runs. |
| `zig-lint` | `zig fmt --check src/` Zig source formatting. |
| `zig-doc-lint` | Check `///` docstring completeness for `pub`/`export fn` in `src/`. |
| `e2e` | Run the full E2E suite (starts + tears down container). |
| `e2e-keep` | Run E2E keeping the container alive (`--keep-container`). |
| `e2e-dryrun` | Simulate E2E run without starting a container. |
| `e2e-lint` | bash -n + shellcheck + suite registry check on all E2E scripts. |
| `e2e-catalog-lint` | Test prefix naming and `TEST_CATALOG.md` parity. |
| `manual-lint` | bash -n + shellcheck on `tests/manual/` scripts. |
| `fuzz-build` | Build the AFL++ fuzz harness. |
| `fuzz-sanitize` | Check corpus filenames are Windows-safe (no colons). |
| `fuzz-lint` | bash -n + shellcheck on `tests/fuzz/` scripts. |
| `lint` | Aggregate: `zig-lint` + `manual-lint` + `fuzz-lint`. |

### Testing

#### Unit Tests

```sh
make zig-test             # full suite (includes discovery guard)
make zig-test-discovery   # discovery guard only (tools/check_test_count.sh)

# Direct zig commands:
zig build test --summary all
zig test src/config.zig                              # single file
zig test src/main.zig --test-filter "parseIni"       # substring match
```

`zig-test-discovery` counts `test` declarations in `src/*.zig` against the runner's reported count. A mismatch means tests are silently skipped (Zig lazy-analysis [issue #10018](https://github.com/ziglang/zig/issues/10018)). Fix: add `test { _ = @import("missing.zig"); }` to the test root.

#### Near End-to-End (E2E) Tests

Validates CLI behavior, HMAC authentication, and API parity with the Perl reference
using a live official openQA single-instance container managed by Podman.

Requires `zig-out/bin/zoqa` to be built first (`make zig-build-debug`).

```sh
make e2e                                   # start container, run all suites, teardown
make e2e-keep                              # keep container alive after tests
make e2e-dryrun                            # simulate run without container
make e2e SUITES=core,auth                  # run specific suites only
make e2e SUITES=                           # deploy container only, run no tests
make e2e E2E_STORAGE_KEEP_FREE_RATIO=0     # disable isotovideo storage check (low-disk hosts)
```

See [tests/e2e/README.md](tests/e2e/README.md) for prerequisites, script reference,
flags, debugging tips, and the full test coverage table.

##### E2E Test Catalog

`tools/check_test_catalog.sh` enforces:
1. Each `tests/e2e/tests_<suite>.sh` uses a 3-letter prefix from its filename (e.g. `tests_archive.sh` → `ARC`).
2. Every test execution line is preceded within 40 lines by a `# <PREFIX>-N:` comment.
3. Every prefix comment has a bidirectional match in `tests/e2e/TEST_CATALOG.md`.

```sh
make e2e-catalog-lint                               # check all E2E test files
bash tools/check_test_catalog.sh tests_archive.sh   # check a single file
```

`tools/check_test_catalog.sh` enforces:
#### Fuzz Testing

Coverage-guided fuzz testing using AFL++ in Persistent Mode with LLVM instrumentation.

```sh
make fuzz-build     # build the AFL++ fuzz harness
make fuzz-sanitize  # check corpus filenames are Windows-safe (no colons)
```

See [tests/fuzz/README.md](tests/fuzz/README.md) for setup, workflow, crash triage,
corpus distillation, and coverage reporting.

#### Docstring Completeness

```sh
make zig-doc-lint                  # check pub/export fn docstrings in src/*.zig
make zig-doc-lint WITH_PRIVATE=1   # also include private functions
```

`tools/check_docstrings.py` requires every `pub fn` / `export fn` to have:
- A summary `///` line
- `Arguments:` section when the function has non-self/non-underscore params
- `Returns:` section when the return type is not `void`/`noreturn`
- `Errors:` section when the return type is an error union (`!T`)


## CI Compliance — GitHub Checks at Every PR

`.github/workflows/ci.yml` defines four required jobs:

| Job | Runner | Commands |
|---|---|---|
| `lint` | ubuntu | `make zig-lint` |
| `build-and-test` | ubuntu + macos + windows | `zig build --summary all`, `zig build test --summary all` |
| `cross-compile` | ubuntu | Cross-compile for 6 targets (x86_64/aarch64 × linux-musl / macos / windows) |
| `tests-check` | ubuntu | `make e2e-lint`, `make manual-lint`, `make fuzz-lint`, `make fuzz-sanitize`, `make zig-build-debug`, `make e2e-dryrun`, `make zig-test-discovery` |

The `ci` aggregation job is the required status check for branch protection.

**Not gated in CI (local only):** `make e2e` (full suite requires Podman), `make e2e-catalog-lint`, `make zig-doc-lint`.


## Creating a Release

Releases are fully automated via the [Release workflow](.github/workflows/release.yml).
Pushing a `v*` tag triggers it: the workflow builds cross-compiled binaries for all
six targets, packages them, and publishes a GitHub Release with SHA-256 checksums.

**1. Ensure `main` is in the desired state**

All changes for the release must already be merged to `main`.

```sh
git checkout main
git pull
```

**2. Create and push the tag**

Use [Semantic Versioning](https://semver.org/). Pre-release versions use a hyphen
suffix (e.g. `-rc1`, `-beta.1`); these are automatically marked as pre-releases on
GitHub.

```sh
# Stable release
git tag v1.2.3

# Pre-release / release candidate
git tag v1.2.3-rc1

# Push only the new tag (preferred, avoids triggering builds for old tags)
git push origin v1.2.3-rc1
```

> **Important:** use `git push origin <tag>` rather than `git push --tags`.
> Pushing `--tags` sends *all* local tags that the remote doesn't have yet.
> If you have older un-pushed tags, that would trigger a separate release
> workflow run for each one. The workflow has a guard that skips tags whose
> releases already exist, but it still wastes runner time.

**3. Monitor the workflow**

```sh
gh run list --repo mpagot/zoqa --workflow release.yml --limit 5
gh run watch <run-id>
```

**4. Verify the release**

```sh
gh release view v1.2.3-rc1 --repo mpagot/zoqa
```

Confirm all six platform archives and `SHA256SUMS` are attached.

### Re-Running a Failed Release

If a build step fails after the release was already created (partial artifacts),
delete the release and tag, then re-tag:

```sh
gh release delete v1.2.3-rc1 --repo mpagot/zoqa --yes
git tag -d v1.2.3-rc1
git push origin :refs/tags/v1.2.3-rc1
# fix the issue, then:
git tag v1.2.3-rc1
git push origin v1.2.3-rc1
```

### Tagging Conventions

| Pattern | Meaning | Marked as pre-release |
|---|---|---|
| `v1.2.3` | Stable release | No |
| `v1.2.3-rc1` | Release candidate | Yes |
| `v1.2.3-beta.1` | Beta | Yes |
| `v1.2.3-alpha.1` | Alpha | Yes |

Any tag whose version string contains a hyphen is automatically marked as a
pre-release by the workflow.
