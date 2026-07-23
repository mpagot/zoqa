<p align="center">
  <img src="docs/logo.png" alt="zoqa logo" width="280" />
</p>

<h1 align="center">zoqa</h1>

<p align="center"><code>alias openqa-cli=zoqa</code></p>

<p align="center">
  A fast, statically linked reimplementation of
  <a href="https://github.com/os-autoinst/openQA"><code>openqa-cli</code></a>
  and friends, written in Zig.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--2.0-blue.svg" alt="License: GPL-2.0" /></a>
  <a href="https://ziglang.org/"><img src="https://img.shields.io/badge/zig-0.15.2-F7A41D.svg?logo=zig&logoColor=white" alt="Zig 0.15.2" /></a>
  <a href="https://github.com/mpagot/zoqa/actions/workflows/ci.yml"><img src="https://github.com/mpagot/zoqa/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="https://github.com/mpagot/zoqa/actions/workflows/release.yml"><img src="https://github.com/mpagot/zoqa/actions/workflows/release.yml/badge.svg" alt="Release workflow" /></a>
  <a href="https://github.com/mpagot/zoqa/releases"><img src="https://img.shields.io/github/v/release/mpagot/zoqa?include_prereleases&label=latest" alt="Latest release" /></a>
  <img src="https://img.shields.io/badge/platforms-linux%20%7C%20macOS%20%7C%20windows-lightgrey.svg" alt="Platforms: Linux, macOS, Windows" />
  <img src="https://img.shields.io/badge/runtime%20deps-none-success.svg" alt="No runtime dependencies" />
</p>

---

## The story

[openQA](https://open.qa/) is the test framework used to test openSUSE, SUSE Linux
Enterprise, Fedora, Debian, and other distributions. Every day, thousands of
automated test jobs run against new builds, and the primary way to talk to an openQA
server from the command line is `openqa-cli` Perl script bundled with the openQA
package.

`openqa-cli` is the standard tool for the job and is actively maintained. But it
carries the weight of a full Perl runtime, a tree of CPAN dependencies, and the
startup cost that comes with an interpreted language. If you want to run the client on
a minimal container image, or distribute it to machines without pulling in Perl and
its dependency tree, that weight starts to matter.

**zoqa** is a from-scratch reimplementation of `openqa-cli` and its companion
scripts in [Zig](https://ziglang.org/). The goal is full coverage of the openQA
command-line toolset: the four `openqa-cli` subcommands (`api`, `archive`,
`monitor`, `schedule`) and standalone scripts such as `openqa-clone-job` and
`openqa-clone-custom-git-refspec`. Each tool aims to be a drop-in replacement:
same flags, same config file format (`~/.config/openqa/client.conf`), same
HMAC-SHA1 authentication, same output. You should be able to swap any of them
in your scripts and see no difference, except that they start faster, ship as
single static binaries, and need zero runtime dependencies.


## Why zoqa?

| | `openqa-cli` (Perl) | `zoqa` (Zig) |
|---|---|---|
| **Runtime deps** | Perl 5, ~15 CPAN modules | None (static binary) |
| **Binary size** | N/A (interpreted) | ~2 MB |
| **Startup** | Perl interpreter + module loading | Instant (compiled native code) |
| **Platforms** | Wherever Perl runs | Linux, macOS, Windows (x86_64 + aarch64) 6 targets from a single build host |
| **Container-friendly** | Needs Perl + deps installed | Copy one file, done |
| **Wall-time per `api` call** | ~0.6–1.3 s | ~0.13–0.35 s (4–5× faster) |
| **Peak memory (`api`)** | ~61 MB | ~5.3 MB (91% less) |
| **Wall-time `archive` (~3.4 GB)** | ~18m 42s | ~14m 23s |
| **CPU user time `archive` (~3.4 GB)** | ~151 s | ~2.9 s (52× less) |
| **Peak memory (`archive`, ~3.4 GB)** | ~70 MB | ~11 MB (6.3× less) |

Measured against a production openQA server over the network. The `api` speedup
is **Mojolicious startup overhead**: both tools complete the network round-trip
in similar time. The `archive` gap is a genuine **architectural difference**:
zoqa streams to disk; openqa-cli double-writes through a temp file, using 52×
more CPU.

See [docs/compare_performance.md](docs/compare_performance.md) for the full
analysis, interpreter baseline measurements, and methodology.


## Quick start

Download the latest binary for your platform from the
[Releases page](https://github.com/mpagot/zoqa/releases), extract it, and put it
on your `$PATH`:

```sh
# Example for Linux x86_64
curl -LO https://github.com/mpagot/zoqa/releases/latest/download/zoqa-linux-x86_64.tar.gz
tar xzf zoqa-linux-x86_64.tar.gz
sudo mv zoqa /usr/local/bin/
```

No runtime dependencies. One binary, copy it anywhere.


## Usage

Run `openqa-cli --help` sorry, force of habit, I meant `zoqa --help`. They're
the same. I keep telling you.

The full guide: **[docs/Usage.md](docs/Usage.md)**. Or just:

```sh
zoqa --help
zoqa <subcommand> --help   # api | archive | monitor | schedule
```


## Building from source

You need [Zig 0.15.2](https://ziglang.org/download/):

```sh
git clone https://github.com/mpagot/zoqa.git
cd zoqa
zig build -Doptimize=ReleaseSafe
```

The binary is at `zig-out/bin/zoqa`.


## Project status

zoqa is in active development. All four `openqa-cli` subcommands
(`api`, `archive`, `monitor`, and `schedule`) are fully implemented, with a
comprehensive suite of end-to-end tests passing against a containerized openQA
instance.

The standalone companion scripts (`openqa-clone-job`,
`openqa-clone-custom-git-refspec`) are still planned.


## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for build
instructions, test commands (unit, E2E, fuzz), formatting rules, and the release
process.

### Running the tests

```sh
zig build test --summary all   # unit tests
make e2e                       # end-to-end tests (requires Podman)
make e2e-lint                  # lint the E2E test scripts
```


## Architecture

zoqa is structured as a set of focused modules, one per subcommand plus
shared infrastructure:

| Module | Purpose |
|---|---|
| `src/main.zig` | CLI entry point, argument parsing, subcommand dispatching |
| `src/config.zig` | INI config parser, credential and host resolution |
| `src/auth.zig` | HMAC-SHA1 authentication header generation |
| `src/http_client.zig` | HTTP client wrapper with retry logic |
| `src/archive.zig` | `archive` subcommand: stream a job's assets and test results to disk |
| `src/monitor.zig` | `monitor` subcommand: poll until specified jobs reach a final state |
| `src/schedule.zig` | `schedule` subcommand: POST `/api/v1/isos` to start jobs |
| `src/root.zig` | Library root, re-exports core modules and C-ABI functions |

The project also ships as a static library (`libzoqa.a`) for embedding in other
applications.


## Credits

zoqa would not exist without [openQA](https://github.com/os-autoinst/openQA) and
its `openqa-cli` tool. The entire command-line interface, authentication scheme,
configuration format, and behavioral semantics are derived from the Perl reference
implementation. Full credit goes to the openQA team and contributors at SUSE and the
openSUSE community.


## License

zoqa is licensed under the [GNU General Public License v2.0](LICENSE), the same
license used by the openQA project.
