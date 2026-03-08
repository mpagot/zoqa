#!/usr/bin/env bash
# cmin.sh — reduce corpus (afl-cmin) for one or all fuzz targets.
#
# Usage:
#   ./tests/fuzz/cmin.sh                  # minimise all targets
#   ./tests/fuzz/cmin.sh ini              # minimise only the INI target
#   ./tests/fuzz/cmin.sh cli http auth    # minimise multiple specific targets
#
# For each target the minimised corpus is written to corpus_<name>_min/ inside
# the tests/fuzz/ directory (existing _min directories are removed first).
#
# Run from the project root or from tests/fuzz/; the script locates the root
# by walking up from its own directory.
#
# Requirements:
#   - vendor/aflplusplus built (see README.md §Setup step 2)
#   - zig build -Dfuzz already run (fuzz binaries must exist in zig-out/)

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate project root
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR"
while [[ "$ROOT" != "/" && ! -f "$ROOT/build.zig" ]]; do
	ROOT="$(dirname "$ROOT")"
done
if [[ ! -f "$ROOT/build.zig" ]]; then
	echo "error: could not find project root (no build.zig found)" >&2
	exit 1
fi

FUZZ_DIR="$ROOT/tests/fuzz"
AFL_DIR="$ROOT/vendor/aflplusplus"

if [[ ! -f "$AFL_DIR/afl-cmin" ]]; then
	echo "error: $AFL_DIR/afl-cmin not found." >&2
	echo "       Build AFL++ first: make source-only -j\$(nproc) -C vendor/aflplusplus" >&2
	exit 1
fi

export PATH="$AFL_DIR:$PATH"

# ---------------------------------------------------------------------------
# Target definitions: name -> (corpus_dir, binary_name)
# ---------------------------------------------------------------------------
declare -A CORPUS_DIR=(
	[ini]="corpus"
	[cli]="corpus_cli"
	[http]="corpus_http"
	[auth]="corpus_auth"
	[gzip]="corpus_gzip"
)
declare -A BINARY=(
	[ini]="openQAclient-fuzz-ini"
	[cli]="openQAclient-fuzz-cli"
	[http]="openQAclient-fuzz-http"
	[auth]="openQAclient-fuzz-auth"
	[gzip]="openQAclient-fuzz-gzip"
)
ALL_TARGETS=(ini cli http auth gzip)

# ---------------------------------------------------------------------------
# Determine which targets to process
# ---------------------------------------------------------------------------
if [[ $# -eq 0 ]]; then
	TARGETS=("${ALL_TARGETS[@]}")
else
	TARGETS=()
	for arg in "$@"; do
		if [[ -z "${CORPUS_DIR[$arg]+set}" ]]; then
			echo "error: unknown target '$arg'." >&2
			echo "       Valid targets: ${ALL_TARGETS[*]}" >&2
			exit 1
		fi
		TARGETS+=("$arg")
	done
fi

# ---------------------------------------------------------------------------
# Run afl-cmin for each selected target
# ---------------------------------------------------------------------------
cd "$ROOT"

for target in "${TARGETS[@]}"; do
	corpus_src="$FUZZ_DIR/${CORPUS_DIR[$target]}"
	corpus_min="$FUZZ_DIR/${CORPUS_DIR[$target]}_min"
	binary="$ROOT/zig-out/${BINARY[$target]}"

	echo ""
	echo "==> Target: $target"

	if [[ ! -d "$corpus_src" ]]; then
		echo "    WARNING: corpus directory '$corpus_src' not found — skipping." >&2
		continue
	fi

	if [[ -z "$(ls -A "$corpus_src" 2>/dev/null)" ]]; then
		echo "    WARNING: corpus directory '$corpus_src' is empty — skipping." >&2
		continue
	fi

	if [[ ! -x "$binary" ]]; then
		echo "    error: binary '$binary' not found or not executable." >&2
		echo "           Run: ./tests/fuzz/build.sh" >&2
		exit 1
	fi

	echo "    Input:  $corpus_src"
	echo "    Output: $corpus_min"
	echo "    Binary: $binary"

	rm -rf "$corpus_min"

	afl-cmin \
		-i "$corpus_src" \
		-o "$corpus_min" \
		-- "$binary"

	count=$(ls "$corpus_min" | wc -l)
	echo "    Done: $count seeds in $corpus_min"
done

echo ""
echo "==> Corpus minimisation complete."
