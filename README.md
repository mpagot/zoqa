<p align="center">
  <img src="docs/logo.png" alt="zoqa logo" width="280" />
</p>

<h1 align="center">zoqa</h1>

<p align="center">
  A fast, statically linked reimplementation of
  <a href="https://github.com/os-autoinst/openQA"><code>openqa-cli</code></a>
  and its companion scripts — written in Zig.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--2.0-blue.svg" alt="License: GPL-2.0" /></a>
  <a href="https://ziglang.org/"><img src="https://img.shields.io/badge/zig-0.15.2-F7A41D.svg?logo=zig&logoColor=white" alt="Zig 0.15.2" /></a>
  <a href="https://github.com/mpagot/zoqa/actions/workflows/release.yml"><img src="https://github.com/mpagot/zoqa/actions/workflows/release.yml/badge.svg" alt="Release workflow" /></a>
  <a href="https://github.com/mpagot/zoqa/releases"><img src="https://img.shields.io/github/v/release/mpagot/zoqa?include_prereleases&label=latest" alt="Latest release" /></a>
</p>

---

## The story

[openQA](https://open.qa/) is the test framework used to test openSUSE, SUSE Linux
Enterprise, Fedora, Debian, and other distributions. Every day, thousands of
automated test jobs run against new builds, and the primary way to talk to an openQA
server from the command line is `openqa-cli` — a Perl script bundled with the openQA
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
in your scripts and see no difference — except that they start faster, ship as
single static binaries, and need zero runtime dependencies.


## Why zoqa?

| | `openqa-cli` (Perl) | `zoqa` (Zig) |
|---|---|---|
| **Runtime deps** | Perl 5, ~15 CPAN modules | None (static binary) |
| **Binary size** | N/A (interpreted) | ~2 MB |
| **Startup** | Perl interpreter + module loading | Instant (compiled native code) |
| **Cross-compilation** | N/A | 6 targets from a single build host |
| **Platforms shipped** | Wherever Perl runs | Linux, macOS, Windows (x86_64 + aarch64) |
| **Container-friendly** | Needs Perl + deps installed | Copy one file, done |


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

zoqa mirrors the `openqa-cli api` interface:

```sh
# List recent jobs
zoqa api --host openqa.opensuse.org /api/v1/jobs

# GET with query parameters
zoqa api --o3 /api/v1/jobs groupid=1 limit=5

# POST with form data
zoqa api --host localhost -X POST /api/v1/jobs DISTRI=opensuse VERSION=Tumbleweed

# PUT with JSON body
zoqa api --host localhost -X PUT -j -d '{"priority":50}' /api/v1/jobs/12345

# Pretty-print the JSON response
zoqa api --o3 -p /api/v1/jobs/1

# Verbose output (shows status line and response headers)
zoqa api --o3 -v /api/v1/jobs/1

# Retry on transient errors (502/503)
zoqa api --osd -r 3 /api/v1/jobs
```

### Authentication

zoqa reads API credentials from `~/.config/openqa/client.conf` — the same INI file
used by `openqa-cli`:

```ini
[openqa.opensuse.org]
key = YOUR_API_KEY
secret = YOUR_API_SECRET
```

You can also pass credentials directly:

```sh
zoqa api --host openqa.opensuse.org --apikey KEY --apisecret SECRET /api/v1/jobs
```

Priority order: CLI flags > environment variables > config file.

### Host aliases

| Flag | Resolves to |
|---|---|
| `--o3` | `https://openqa.opensuse.org` |
| `--osd` | `http://openqa.suse.de` |
| `--odn` | `https://openqa.debian.net` |


## Building from source

You need [Zig 0.15.2](https://ziglang.org/download/):

```sh
git clone https://github.com/mpagot/zoqa.git
cd zoqa
zig build -Doptimize=ReleaseSafe
```

The binary is at `zig-out/bin/zoqa`.


## Project status

zoqa is in active development. The `api` subcommand is fully implemented, with all
35 of 35 end-to-end tests passing against a live openQA instance.

The remaining `openqa-cli` subcommands (`archive`, `monitor`, `schedule`) and the
companion scripts (`openqa-clone-job`, `openqa-clone-custom-git-refspec`) are
planned.


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

zoqa is structured as five focused modules:

| Module | Purpose |
|---|---|
| `src/main.zig` | CLI entry point, argument parsing, request dispatching |
| `src/config.zig` | INI config parser, credential and host resolution |
| `src/auth.zig` | HMAC-SHA1 authentication header generation |
| `src/http_client.zig` | HTTP client wrapper with retry logic |
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
