#!/usr/bin/env bash
# build.sh — build all AFL++-instrumented fuzz binaries.
#
# Usage:
#   ./tests/fuzz/build.sh [ZIG_BUILD_ARGS...]
#
# Run from the project root or from tests/fuzz/; the script locates the root
# by walking up from its own directory.
#
# Requirements:
#   - vendor/aflplusplus built (see README.md §Setup step 2)
#   - afl-cc reachable via vendor/aflplusplus/ (added to PATH below)
#
# Targets built (all registered via -Dfuzz in build.zig):
#
#     zoqa-fuzz-config   — INI parser + resolveHost (all 7 branches)
#     zoqa-fuzz-request  — CLI arg parser + buildRequest + parseLinkHeader + JSON
#     zoqa-fuzz-execute  — full pipeline: auth + retry + gzip + openQAReq

set -euo pipefail

# Locate project root (directory that contains build.zig).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR"
while [[ "$ROOT" != "/" && ! -f "$ROOT/build.zig" ]]; do
	ROOT="$(dirname "$ROOT")"
done
if [[ ! -f "$ROOT/build.zig" ]]; then
	echo "error: could not find project root (no build.zig found)" >&2
	exit 1
fi

AFL_DIR="$ROOT/vendor/aflplusplus"

if [[ ! -f "$AFL_DIR/afl-cc" ]]; then
	echo "error: $AFL_DIR/afl-cc not found." >&2
	echo "       Build AFL++ first: make source-only -j\$(nproc) -C vendor/aflplusplus" >&2
	exit 1
fi

export PATH="$AFL_DIR:$PATH"

echo "==> Building all fuzz binaries (project root: $ROOT)"
cd "$ROOT"
zig build -Dfuzz "$@"
echo "==> Done. Binaries written to zig-out/:"
ls -1 zig-out/zoqa-fuzz-* 2>/dev/null || echo "    (no fuzz binaries found in zig-out/)"
