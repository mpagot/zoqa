#!/usr/bin/env bash
# build.sh - build all AFL++-instrumented fuzz binaries.
#
# Usage:
#   ./tests/fuzz/build.sh [ZIG_BUILD_ARGS...]
#   PCGUARD=1 ./tests/fuzz/build.sh [ZIG_BUILD_ARGS...]
#   CMPLOG=1 PCGUARD=1 ./tests/fuzz/build.sh [ZIG_BUILD_ARGS...]
#
# Run from the project root or from tests/fuzz/; the script locates the root
# by walking up from its own directory.
#
# Build modes:
#   (default)      Bitcode path: Zig emits .bc, afl-cc reads it. Requires
#                  afl-cc's LLVM major version to match Zig's bundled LLVM.
#   PCGUARD=1      Trace-pc-guard path: Zig instruments itself (no bitcode
#                  handoff). Only needs afl-compiler-rt.o from AFL++. No
#                  LLVM version match required.
#   CMPLOG=1       (with PCGUARD=1) Also build -cmplog variants per target
#                  for use as afl-fuzz -c secondary node.
#
# Requirements:
#   - vendor/aflplusplus built (make fuzz-afl-build; any LLVM works for
#     PCGUARD mode, matching LLVM required for default mode).
#   - Default mode: afl-cc on PATH with matching LLVM major version.
#     Set ZOQA_FUZZ_ALLOW_LLVM_MISMATCH=1 to bypass the check.
#   - PCGUARD mode: only afl-compiler-rt.o must exist in AFL_DIR.
#
# Targets built (all registered via -Dfuzz in build.zig):
#
#     zoqa-fuzz-config   - INI parser + resolveHost (all 7 branches)
#     zoqa-fuzz-request  - CLI arg parser + buildRequest + parseLinkHeader + JSON
#     zoqa-fuzz-execute  - full pipeline: auth + retry + gzip + openQAReq
#     zoqa-fuzz-schedule - runSchedule (sync + async paths) + runMonitor
#     zoqa-fuzz-clone-job - clone-job dependency graph (I/O-free library)

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

# Use the AFL_DIR environment variable if provided, otherwise default to vendor/
AFL_DIR="${AFL_DIR:-$ROOT/vendor/aflplusplus}"

PCGUARD="${PCGUARD:-0}"
CMPLOG="${CMPLOG:-0}"

if [[ "$PCGUARD" == "1" ]]; then
	# PCGUARD mode: only need afl-compiler-rt.o, no afl-cc, no LLVM check.
	if [[ ! -f "$AFL_DIR/afl-compiler-rt.o" ]]; then
		echo "error: $AFL_DIR/afl-compiler-rt.o not found." >&2
		echo "       Build AFL++ first: make fuzz-afl-build (or ./tests/fuzz/build_afl.sh)" >&2
		exit 1
	fi
else
	# Default (bitcode) mode: need afl-cc with matching LLVM version.
	if [[ ! -f "$AFL_DIR/afl-cc" ]]; then
		echo "error: $AFL_DIR/afl-cc not found." >&2
		echo "       Build AFL++ first: make fuzz-afl-build (or ./tests/fuzz/build_afl.sh)" >&2
		exit 1
	fi

	# Verify LLVM version parity between Zig and AFL++
	if ! command -v zig >/dev/null 2>&1; then
		echo "error: 'zig' not found in PATH." >&2
		exit 1
	fi

	# Print the clang major version found in the `--version` output of "$@",
	# or nothing. Uses a bash regex instead of `| head -n 1`: with pipefail,
	# head closing the pipe early makes the producer die with SIGPIPE (141).
	clang_major() {
		local out
		out=$("$@" --version 2>&1) || true
		if [[ "$out" =~ clang\ version\ ([0-9]+)\. ]]; then
			echo "${BASH_REMATCH[1]}"
		fi
	}

	ZIG_LLVM_MAJOR=$(clang_major zig cc)
	AFL_LLVM_MAJOR=$(clang_major "$AFL_DIR/afl-cc")

	# Fail closed: an undetectable version is treated like a mismatch.
	if [[ -z "$ZIG_LLVM_MAJOR" || -z "$AFL_LLVM_MAJOR" || "$ZIG_LLVM_MAJOR" != "$AFL_LLVM_MAJOR" ]]; then
		ZIG_LLVM_MAJOR="${ZIG_LLVM_MAJOR:-unknown}"
		AFL_LLVM_MAJOR="${AFL_LLVM_MAJOR:-unknown}"
		if [[ "${ZOQA_FUZZ_ALLOW_LLVM_MISMATCH:-0}" == "1" ]]; then
			echo "warning: LLVM mismatch allowed by ZOQA_FUZZ_ALLOW_LLVM_MISMATCH=1 (Zig: $ZIG_LLVM_MAJOR, AFL++: $AFL_LLVM_MAJOR)" >&2
		else
			echo "error: LLVM major version mismatch between Zig ($ZIG_LLVM_MAJOR) and AFL++ ($AFL_LLVM_MAJOR)." >&2
			echo "       Zig emits LLVM $ZIG_LLVM_MAJOR bitcode, but afl-cc links using LLVM $AFL_LLVM_MAJOR." >&2
			echo "       This mismatch corrupts bitcode optimization and causes false crashes." >&2
			echo "       Run './tests/fuzz/build_afl.sh' (or 'make fuzz-afl-build') to recompile AFL++ with LLVM $ZIG_LLVM_MAJOR." >&2
			echo "       Or use PCGUARD=1 to avoid the bitcode handoff entirely." >&2
			exit 1
		fi
	fi

	export PATH="$AFL_DIR:$PATH"
fi

# Save the resolved path for the zig build arg, then unset AFL_DIR so
# afl-cc (clang) does not flag it as a mistyped AFL environment variable.
FUZZ_AFL_DIR="$AFL_DIR"
unset AFL_DIR

# Build the zig build arguments.
BUILD_ARGS=(-Dfuzz "-Dfuzz_afl_dir=$FUZZ_AFL_DIR")
if [[ "$PCGUARD" == "1" ]]; then
	BUILD_ARGS+=(-Dfuzz_pcguard)
	if [[ "$CMPLOG" == "1" ]]; then
		BUILD_ARGS+=(-Dfuzz_cmplog)
	fi
fi

MODE="bitcode"
[[ "$PCGUARD" == "1" ]] && MODE="pcguard"
[[ "$CMPLOG" == "1" && "$PCGUARD" == "1" ]] && MODE="pcguard+cmplog"

echo "==> Building all fuzz binaries [mode: $MODE] (project root: $ROOT)"
cd "$ROOT"
zig build "${BUILD_ARGS[@]}" "$@"
echo "==> Done. Binaries written to zig-out/:"
ls -1 zig-out/zoqa-fuzz-* 2>/dev/null || echo "    (no fuzz binaries found in zig-out/)"
