#!/usr/bin/env bash
# cmin.sh — reduce corpus (afl-cmin) for one or all fuzz targets.
#
# Usage:
#   ./tests/fuzz/cmin.sh                       # minimise all targets
#   ./tests/fuzz/cmin.sh config                # minimise only the config target
#   ./tests/fuzz/cmin.sh config request        # minimise multiple specific targets
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
#
# Target names:
#
#     config   — INI parser + resolveHost          (zoqa-fuzz-config)
#     request  — CLI args + buildRequest + JSON    (zoqa-fuzz-request)
#     execute  — full pipeline: auth+retry+gzip    (zoqa-fuzz-execute)
#     schedule — runSchedule + extractJobIds       (zoqa-fuzz-schedule)
#                NOTE: corpus_schedule/ is not yet populated; cmin will warn
#                and skip until seeds are added.

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
	[config]="corpus_config"
	[request]="corpus_request"
	[execute]="corpus_execute"
	[schedule]="corpus_schedule"
)
declare -A BINARY=(
	[config]="zoqa-fuzz-config"
	[request]="zoqa-fuzz-request"
	[execute]="zoqa-fuzz-execute"
	[schedule]="zoqa-fuzz-schedule"
)
ALL_TARGETS=(config request execute schedule)

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

	count=$(find "$corpus_min" -maxdepth 1 -type f | wc -l)
	echo "    Done: $count seeds in $corpus_min"
done

echo ""
echo "==> Corpus minimisation complete."
