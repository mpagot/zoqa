#!/usr/bin/env bash
# run.sh — run afl-fuzz for exactly one fuzz target.
#
# Usage:
#   ./tests/fuzz/run.sh <target>             # fresh run from corpus_<target>_min/
#   ./tests/fuzz/run.sh <target> --continue  # resume from existing out_<target>/ (-i -)
#
# A target name is mandatory.  The script exits with an error if it is omitted
# or unknown.
#
# Run from the project root or from tests/fuzz/; the script locates the root
# by walking up from its own directory.
#
# Requirements:
#   - vendor/aflplusplus built (see README.md §Setup step 2)
#   - zig build -Dfuzz already run (fuzz binaries must exist in zig-out/)
#   - For a fresh run: corpus_<target>_min/ must exist and be non-empty
#     (run ./tests/fuzz/cmin.sh <target> first if needed)
#   - For --continue: out_<target>/ must already contain a prior campaign
#
# Environment variables honoured (set before calling this script):
#   AFL_SKIP_CPUFREQ                  — skip CPU frequency check (useful on laptops)
#   AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES — skip /proc/sys/kernel/core_pattern check
#   Any other AFL_* variable is passed through to afl-fuzz unchanged.
#
# Target names:
#
#     config   — INI parser + resolveHost          (zoqa-fuzz-config, config.dict)
#     request  — CLI args + buildRequest + JSON    (zoqa-fuzz-request, cli.dict)
#     execute  — full pipeline: auth+retry+gzip    (zoqa-fuzz-execute, no dict)
#     schedule — runSchedule + extractJobIds       (zoqa-fuzz-schedule, no dict)
#                NOTE: corpus_schedule_min/ is not yet populated; run will
#                error with a helpful message until seeds are added via cmin.sh.

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

if [[ ! -f "$AFL_DIR/afl-fuzz" ]]; then
	echo "error: $AFL_DIR/afl-fuzz not found." >&2
	echo "       Build AFL++ first: make source-only -j\$(nproc) -C vendor/aflplusplus" >&2
	exit 1
fi

export PATH="$AFL_DIR:$PATH"

# ---------------------------------------------------------------------------
# Target definitions
# ---------------------------------------------------------------------------
declare -A BINARY=(
	[config]="zoqa-fuzz-config"
	[request]="zoqa-fuzz-request"
	[execute]="zoqa-fuzz-execute"
	[schedule]="zoqa-fuzz-schedule"
)
# Optional dictionary per target; empty string means no -x flag.
declare -A DICT=(
	[config]="config.dict"
	[request]="cli.dict"
	[execute]=""
	[schedule]=""
)
ALL_TARGETS=(config request execute schedule)

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
TARGET=""
CONTINUE=0

for arg in "$@"; do
	case "$arg" in
	--continue)
		CONTINUE=1
		;;
	--*)
		echo "error: unknown option '$arg'." >&2
		echo "       Usage: $0 <target> [--continue]" >&2
		exit 1
		;;
	*)
		if [[ -n "$TARGET" ]]; then
			echo "error: more than one target specified ('$TARGET' and '$arg')." >&2
			echo "       Usage: $0 <target> [--continue]" >&2
			exit 1
		fi
		TARGET="$arg"
		;;
	esac
done

if [[ -z "$TARGET" ]]; then
	echo "error: no target specified." >&2
	echo "       Usage: $0 <target> [--continue]" >&2
	echo "       Valid targets: ${ALL_TARGETS[*]}" >&2
	exit 1
fi

if [[ -z "${BINARY[$TARGET]+set}" ]]; then
	echo "error: unknown target '$TARGET'." >&2
	echo "       Valid targets: ${ALL_TARGETS[*]}" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
BINARY_PATH="$ROOT/zig-out/${BINARY[$TARGET]}"
CORPUS_MIN="$FUZZ_DIR/corpus_${TARGET}_min"
OUT_DIR="$FUZZ_DIR/out_${TARGET}"
DICT_FILE="$FUZZ_DIR/${DICT[$TARGET]}"

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
if [[ ! -x "$BINARY_PATH" ]]; then
	echo "error: binary '$BINARY_PATH' not found or not executable." >&2
	echo "       Run: ./tests/fuzz/build.sh" >&2
	exit 1
fi

if [[ "$CONTINUE" -eq 1 ]]; then
	# Resuming: out_<target>/ must exist with a prior campaign inside.
	if [[ ! -d "$OUT_DIR/main-node" ]]; then
		echo "error: no prior campaign found at '$OUT_DIR/main-node'." >&2
		echo "       Run without --continue to start a fresh campaign first." >&2
		exit 1
	fi
	INPUT_FLAG="-"
else
	# Fresh start: corpus_<target>_min/ must exist and be non-empty.
	if [[ ! -d "$CORPUS_MIN" ]]; then
		echo "error: minimised corpus '$CORPUS_MIN' not found." >&2
		echo "       Run: ./tests/fuzz/cmin.sh $TARGET" >&2
		exit 1
	fi
	if [[ -z "$(ls -A "$CORPUS_MIN" 2>/dev/null)" ]]; then
		echo "error: minimised corpus '$CORPUS_MIN' is empty." >&2
		echo "       Run: ./tests/fuzz/cmin.sh $TARGET" >&2
		exit 1
	fi
	INPUT_FLAG="$CORPUS_MIN"
fi

# ---------------------------------------------------------------------------
# Print summary and run
# ---------------------------------------------------------------------------
echo "==> Target:  $TARGET  (${BINARY[$TARGET]})"
if [[ "$CONTINUE" -eq 1 ]]; then
	echo "    Mode:    resume  (-i -)"
else
	echo "    Mode:    fresh   (-i $INPUT_FLAG)"
fi
echo "    Output:  $OUT_DIR"
if [[ -n "${DICT[$TARGET]}" ]]; then
	echo "    Dict:    $DICT_FILE"
else
	echo "    Dict:    (none)"
fi
echo ""

# Build the afl-fuzz argument list.
AFL_ARGS=(
	-M main-node
	-i "$INPUT_FLAG"
	-o "$OUT_DIR"
)
if [[ -n "${DICT[$TARGET]}" ]]; then
	AFL_ARGS+=(-x "$DICT_FILE")
fi
AFL_ARGS+=(-- "$BINARY_PATH")

# Provide sensible defaults for the two env vars that are always set in the
# shell history, but allow the caller to override them beforehand.
export AFL_SKIP_CPUFREQ="${AFL_SKIP_CPUFREQ:-1}"
export AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES="${AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES:-1}"

cd "$ROOT"
exec afl-fuzz "${AFL_ARGS[@]}"
