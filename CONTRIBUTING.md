# Contributing to zoqa

## Development Workflow

### Prerequisites

- Zig 0.15.2 (pinned in `.tool-versions`)
- Podman (for E2E tests)
- shellcheck (for e2e lint)

### Build and Test

```sh
# Build
zig build

# Unit tests
zig build test --summary all

# Lint (bash -n + shellcheck on all E2E scripts)
make e2e-lint

# Near end-to-end tests (starts an openQA container via Podman)
# Requires the binary to be built first:
zig build
make e2e
```

Before submitting a PR:
1. Run `zig fmt src/` to format all source files.
2. Ensure `zig build test` passes with no failures.
3. Ensure `make e2e-lint` passes cleanly.

### Make Targets

```sh
make help  # print this table
```

| Target | Description |
|---|---|
| `zig-build-debug` | Build the zoqa executable and static library (debug). |
| `zig-release` | Build with release optimizations and strip symbols. |
| `test` | Run all Zig unit tests. |
| `e2e` | Run the full E2E suite (starts + tears down container). |
| `e2e-keep` | Run E2E keeping the container alive (`--keep-container`). |
| `e2e-lint` | Bash `-n` syntax check and shellcheck on all E2E scripts. |
| `zig-docstring` | Check `///` docstring completeness for fn declarations in src/. |
| `fuzz-build` | Build the instrumented AFL++ fuzz binaries. |

### Testing

#### Unit Tests

```sh
zig build test --summary all         # all unit tests
zig test src/config.zig              # single file
zig test src/main.zig --test-filter "parseIni"  # substring match
```

Shortcut: `make test`.

#### Near End-to-End (E2E) Tests

Validates CLI behavior, HMAC authentication, and API parity with the Perl reference
using a live official openQA single-instance container managed by Podman.

See [tests/e2e/README.md](tests/e2e/README.md) for prerequisites, script reference,
flags, debugging tips, and the full test coverage table.

Shortcuts: `make e2e` and `make e2e-keep`.

#### Fuzz Testing

Coverage-guided fuzz testing using AFL++ in Persistent Mode with LLVM instrumentation.

See [tests/fuzz/README.md](tests/fuzz/README.md) for setup, workflow, crash triage,
corpus distillation, and coverage reporting.

Shortcut: `make fuzz-build`.

---

## Creating a Release

Releases are fully automated via the [Release workflow](.github/workflows/release.yml).
Pushing a `v*` tag triggers it: the workflow builds cross-compiled binaries for all
six targets, packages them, and publishes a GitHub Release with SHA-256 checksums.

### Step-by-step

**1. Ensure `main` is in the desired state**

All changes for the release must already be merged to `main`.

```sh
git checkout main
git pull
```

**2. Create and push the tag**

Use [Semantic Versioning](https://semver.org/).  Pre-release versions use a hyphen
suffix (e.g. `-rc1`, `-beta.1`) — these are automatically marked as pre-releases on
GitHub.

```sh
# Stable release
git tag v1.2.3

# Pre-release / release candidate
git tag v1.2.3-rc1

# Push only the new tag (preferred — avoids triggering builds for old tags)
git push origin v1.2.3-rc1
```

> **Important:** use `git push origin <tag>` rather than `git push --tags`.
> Pushing `--tags` sends *all* local tags that the remote doesn't have yet.
> If you have older un-pushed tags, that would trigger a separate release
> workflow run for each one.  The workflow has a guard that skips tags whose
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

### Re-running a failed release

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

### Tagging conventions

| Pattern | Meaning | Marked as pre-release |
|---|---|---|
| `v1.2.3` | Stable release | No |
| `v1.2.3-rc1` | Release candidate | Yes |
| `v1.2.3-beta.1` | Beta | Yes |
| `v1.2.3-alpha.1` | Alpha | Yes |

Any tag whose version string contains a hyphen is automatically marked as a
pre-release by the workflow.
