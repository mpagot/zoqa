#!/usr/bin/env bash
# build_afl.sh - compile vendor/aflplusplus against the LLVM version matching Zig.
#
# Usage:
#   ./tests/fuzz/build_afl.sh [--update]
#   make fuzz-afl-build [UPDATE=1]
#
#   --update   fetch and check out AFL++ 'stable' (and its submodules) first.
#
# Why: Zig emits LLVM bitcode that afl-cc optimizes and links. If afl-cc uses
# a different LLVM major version than Zig, the bitcode can be silently
# miscompiled (see conductor/plan-fuzz-llvm-bitcode-mismatch.md).
#
# Requirements:
#   - zig on PATH (used to query the bundled LLVM version)
#   - openSUSE Tumbleweed with the matching LLVM development tools:
#       sudo zypper install llvm20-devel clang20 lld20
#     llvmXX-devel packages conflict with each other (all ship
#     /usr/bin/llvm-config), so this replaces the installed one.

set -euo pipefail

usage() {
	sed -n '4,8s/^# \{0,1\}//p' "${BASH_SOURCE[0]}" >&2
}

UPDATE=0
for arg in "$@"; do
	case "$arg" in
	--update) UPDATE=1 ;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "[-] Error: unknown argument: $arg" >&2
		usage
		exit 1
		;;
	esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR"
while [[ "$ROOT" != "/" && ! -f "$ROOT/build.zig" ]]; do
	ROOT="$(dirname "$ROOT")"
done
if [[ ! -f "$ROOT/build.zig" ]]; then
	echo "error: could not find project root (no build.zig found)" >&2
	exit 1
fi

AFL_SRC="${AFL_DIR:-$ROOT/vendor/aflplusplus}"
# AFL++'s own build runs afl-cc/afl-showmap, which warn about any unknown
# AFL_* variable in the environment ("Mistyped AFL environment variable").
unset AFL_DIR

if [[ ! -d "$AFL_SRC" ]]; then
	echo "[-] Error: AFL++ directory not found at $AFL_SRC" >&2
	echo "    Run: git clone https://github.com/AFLplusplus/AFLplusplus vendor/aflplusplus" >&2
	exit 1
fi

# Print the clang major version found in the `--version` output of "$@",
# or nothing. A bash regex avoids `| head -n 1`, which under pipefail makes
# the producer die with SIGPIPE (exit 141).
clang_major() {
	local out
	out=$("$@" --version 2>&1) || true
	if [[ "$out" =~ clang\ version\ ([0-9]+)\. ]]; then
		echo "${BASH_REMATCH[1]}"
	fi
}

# 1. Query Zig for its bundled LLVM major version (before any slow step)
if ! command -v zig >/dev/null 2>&1; then
	echo "[-] Error: 'zig' not found in PATH." >&2
	exit 1
fi

ZIG_LLVM_MAJOR=$(clang_major zig cc)
if [[ -z "$ZIG_LLVM_MAJOR" ]]; then
	echo "[-] Error: Could not determine LLVM version from 'zig cc --version'." >&2
	exit 1
fi
echo "[+] Detected Zig using LLVM major: $ZIG_LLVM_MAJOR"

# 2. Locate a llvm-config whose major version matches Zig's.
# On Tumbleweed llvmXX-devel installs the unversioned /usr/bin/llvm-config;
# the versioned names are checked first in case the packaging provides them.
# Every candidate is version-checked: /usr/bin/llvm-config may belong to
# another LLVM (the default llvmXX-devel).
CANDIDATES=(
	"llvm-config-${ZIG_LLVM_MAJOR}"
	"/usr/lib64/llvm${ZIG_LLVM_MAJOR}/bin/llvm-config"
	"llvm-config"
)

MATCHING_LLVM_CONFIG=""
for candidate in "${CANDIDATES[@]}"; do
	path=$(command -v "$candidate" 2>/dev/null) || continue
	version=$("$path" --version 2>/dev/null) || continue
	if [[ "${version%%.*}" == "$ZIG_LLVM_MAJOR" ]]; then
		MATCHING_LLVM_CONFIG="$path"
		break
	fi
	echo "[*] Skipping $path (LLVM $version)"
done

if [[ -z "$MATCHING_LLVM_CONFIG" ]]; then
	echo "[-] Error: LLVM $ZIG_LLVM_MAJOR development tools (llvm-config) not found." >&2
	echo "    Install: sudo zypper install llvm${ZIG_LLVM_MAJOR}-devel clang${ZIG_LLVM_MAJOR} lld${ZIG_LLVM_MAJOR}" >&2
	echo "    (llvmXX-devel packages conflict; this replaces the installed one)" >&2
	exit 1
fi

echo "[+] Using LLVM config: $MATCHING_LLVM_CONFIG ($("$MATCHING_LLVM_CONFIG" --version))"

# 3. Update the vendor clone if requested
if [[ "$UPDATE" == "1" ]]; then
	echo "[*] Updating AFL++ repository and submodules..."
	git -C "$AFL_SRC" fetch origin
	git -C "$AFL_SRC" checkout stable
	git -C "$AFL_SRC" pull --ff-only origin stable
	git -C "$AFL_SRC" submodule update --init --recursive
fi

# 4. Clean and rebuild AFL++.
# source-only also tries optional modes (gcc_plugin, nyx, qemu, ...) whose
# failures it reports in its "Build Summary" without failing; only LLVM mode
# matters here and is verified below.
echo "[*] Compiling AFL++ against LLVM $ZIG_LLVM_MAJOR..."
make -C "$AFL_SRC" clean
LLVM_CONFIG="$MATCHING_LLVM_CONFIG" make -C "$AFL_SRC" source-only -j"$(nproc)"

# 5. Verify the compiled afl-cc
AFL_LLVM_MAJOR=$(clang_major "$AFL_SRC/afl-cc")
if [[ "$AFL_LLVM_MAJOR" != "$ZIG_LLVM_MAJOR" ]]; then
	echo "[-] Error: built afl-cc reports LLVM '${AFL_LLVM_MAJOR:-unknown}', expected $ZIG_LLVM_MAJOR." >&2
	exit 1
fi
echo "[+] Build complete: afl-cc uses LLVM $AFL_LLVM_MAJOR (matches Zig)"
