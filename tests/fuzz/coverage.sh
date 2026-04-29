#!/usr/bin/env bash
# coverage.sh — build, run kcov, and analyse coverage for all fuzz targets.
#
# Usage:
#   ./tests/fuzz/coverage.sh                  # build + run + analyse all targets
#   ./tests/fuzz/coverage.sh --skip-build     # analyse existing coverage/ output only
#   ./tests/fuzz/coverage.sh config request   # build + run + analyse specific targets
#   ./tests/fuzz/coverage.sh --skip-build execute  # analyse only execute
#
# Run from the project root or from tests/fuzz/; the script locates the root
# by walking up from its own directory.
#
# The script performs three phases:
#   1. Build & run:  zig build --build-file tests/fuzz/cov_build.zig coverage[-<name>]
#                    This compiles the coverage harnesses and runs every corpus
#                    seed through kcov, producing merged HTML+JSON reports in
#                    coverage/{config,request,execute}/.
#   2. Collect:      Locate the latest coverage.json and codecov.json per target.
#   3. Analyse:      Parse the JSON data and print a comprehensive report:
#                    - Per-target summary (line counts, percentages)
#                    - Per-file breakdown within each target
#                    - Cross-target file aggregation (best coverage per file)
#                    - Uncovered lines (0/N in codecov.json)
#                    - Partial branch coverage (M/N where M < N)
#
# Output files (written alongside this script):
#   coverage_report.txt  — the full text report (also printed to stdout)
#
# Requirements:
#   - kcov installed and on PATH
#   - jq installed and on PATH  (JSON parsing)
#   - Non-empty corpus_{config,request,execute}/ directories
#
# Options:
#   --skip-build    Skip the build+run phase; analyse existing coverage/ output.
#                   Useful when coverage data already exists from a prior run.
#
# Target names:
#   config   — INI parser + resolveHost          (corpus_config/)
#   request  — CLI args + buildRequest + JSON    (corpus_request/)
#   execute  — full pipeline: auth+retry+gzip    (corpus_execute/)
#   schedule — runSchedule + extractJobIds       (corpus_schedule/)
#              NOTE: coverage data unavailable until corpus_schedule/ is populated.

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
COV_DIR="$ROOT/coverage"
REPORT_FILE="$FUZZ_DIR/coverage_report.txt"
ALL_TARGETS=(config request execute schedule)

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
SKIP_BUILD=0
TARGETS=()

for arg in "$@"; do
	case "$arg" in
	--skip-build)
		SKIP_BUILD=1
		;;
	--help | -h)
		sed -n '2,/^$/{ s/^# \?//; p }' "$0"
		exit 0
		;;
	--*)
		echo "error: unknown option '$arg'." >&2
		echo "       Usage: $0 [--skip-build] [targets...]" >&2
		exit 1
		;;
	*)
		# Validate target name.
		found=0
		for t in "${ALL_TARGETS[@]}"; do
			if [[ "$arg" == "$t" ]]; then
				found=1
				break
			fi
		done
		if [[ $found -eq 0 ]]; then
			echo "error: unknown target '$arg'." >&2
			echo "       Valid targets: ${ALL_TARGETS[*]}" >&2
			exit 1
		fi
		TARGETS+=("$arg")
		;;
	esac
done

# Default: all targets.
if [[ ${#TARGETS[@]} -eq 0 ]]; then
	TARGETS=("${ALL_TARGETS[@]}")
fi

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
if [[ $SKIP_BUILD -eq 0 ]]; then
	if ! command -v kcov &>/dev/null; then
		echo "error: kcov not found on PATH." >&2
		echo "       Install it: sudo zypper install kcov  (openSUSE)" >&2
		echo "                   sudo apt-get install kcov (Debian/Ubuntu)" >&2
		echo "                   sudo dnf install kcov     (Fedora)" >&2
		exit 1
	fi
fi

if ! command -v jq &>/dev/null; then
	echo "error: jq not found on PATH (required for JSON analysis)." >&2
	echo "       Install it: sudo zypper install jq  (openSUSE)" >&2
	echo "                   sudo apt-get install jq (Debian/Ubuntu)" >&2
	echo "                   sudo dnf install jq     (Fedora)" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Phase 1: Build & run kcov
# ---------------------------------------------------------------------------
cd "$ROOT"

if [[ $SKIP_BUILD -eq 0 ]]; then
	echo "================================================================"
	echo "Phase 1: Build coverage harnesses and run kcov"
	echo "================================================================"
	echo ""

	if [[ ${#TARGETS[@]} -eq ${#ALL_TARGETS[@]} ]]; then
		# All targets — use the aggregate "coverage" step.
		echo "==> zig build -p . --build-file tests/fuzz/cov_build.zig coverage"
		echo ""
		zig build -p . --build-file tests/fuzz/cov_build.zig coverage
	else
		# Specific targets — run each coverage-<name> step.
		for target in "${TARGETS[@]}"; do
			echo "==> zig build -p . --build-file tests/fuzz/cov_build.zig coverage-${target}"
			echo ""
			zig build -p . --build-file tests/fuzz/cov_build.zig "coverage-${target}"
		done
	fi

	echo ""
	echo "==> Build and kcov run complete."
	echo ""
fi

# ---------------------------------------------------------------------------
# Phase 2: Collect JSON files
# ---------------------------------------------------------------------------
echo "================================================================"
echo "Phase 2: Collect coverage JSON"
echo "================================================================"
echo ""

# For each target, find the latest (most recently modified) subdirectory
# that contains a non-empty coverage.json.  kcov creates subdirectories
# named <exe-name>.<hash>/ and auto-merges successive runs into the same
# hash directory.  The most recently modified one is the final merged result.
declare -A COV_JSON     # target -> path to coverage.json
declare -A CODECOV_JSON # target -> path to codecov.json

for target in "${TARGETS[@]}"; do
	target_dir="$COV_DIR/$target"
	if [[ ! -d "$target_dir" ]]; then
		echo "    WARNING: $target_dir not found — skipping '$target'." >&2
		continue
	fi

	# Find the subdirectory with the most recently modified coverage.json
	# that has actual data (total_lines > 0).
	latest=""
	latest_mtime=0
	for cj in "$target_dir"/zoqa-cov-*/coverage.json; do
		[[ -f "$cj" ]] || continue
		total=$(jq -r '.total_lines' "$cj" 2>/dev/null || echo 0)
		if [[ "$total" -gt 0 ]]; then
			mtime=$(stat -c%Y "$cj")
			if [[ $mtime -gt $latest_mtime ]]; then
				latest_mtime=$mtime
				latest="$cj"
			fi
		fi
	done

	if [[ -z "$latest" ]]; then
		echo "    WARNING: no valid coverage.json found for '$target' — skipping." >&2
		continue
	fi

	subdir=$(dirname "$latest")
	COV_JSON[$target]="$latest"
	CODECOV_JSON[$target]="$subdir/codecov.json"
	echo "    $target: $(basename "$subdir")/"
done

echo ""

if [[ ${#COV_JSON[@]} -eq 0 ]]; then
	echo "error: no coverage data found for any target." >&2
	echo "       Run without --skip-build to generate coverage data first." >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Phase 3: Analyse and report
# ---------------------------------------------------------------------------
echo "================================================================"
echo "Phase 3: Analyse coverage data"
echo "================================================================"
echo ""

# Start building the report in a temp file, then copy to REPORT_FILE.
REPORT=$(mktemp)
trap 'rm -f "$REPORT"' EXIT

{
	echo "====================================================================="
	echo " openQAclient — Fuzz Coverage Report"
	echo " Generated: $(date '+%Y-%m-%d %H:%M:%S')"
	echo "====================================================================="
	echo ""

	# -------------------------------------------------------------------
	# Section 1: Per-target summary
	# -------------------------------------------------------------------
	echo "---------------------------------------------------------------------"
	echo " Per-Target Summary"
	echo "---------------------------------------------------------------------"
	echo ""
	printf "  %-12s %8s %10s %10s   %s\n" "TARGET" "COVERED" "TOTAL" "PERCENT" "CORPUS"
	printf "  %-12s %8s %10s %10s   %s\n" "------" "-------" "-----" "-------" "------"

	total_covered_all=0
	total_lines_all=0

	for target in "${TARGETS[@]}"; do
		[[ -n "${COV_JSON[$target]+set}" ]] || continue
		covered=$(jq -r '.covered_lines' "${COV_JSON[$target]}")
		total=$(jq -r '.total_lines' "${COV_JSON[$target]}")
		pct=$(jq -r '.percent_covered' "${COV_JSON[$target]}")
		corpus_dir="$FUZZ_DIR/corpus_${target}"
		seed_count=0
		if [[ -d "$corpus_dir" ]]; then
			seed_count=$(find "$corpus_dir" -maxdepth 1 -type f | wc -l)
		fi
		printf "  %-12s %8d %10d %9s%%   %d seeds\n" "$target" "$covered" "$total" "$pct" "$seed_count"
		total_covered_all=$((total_covered_all + covered))
		total_lines_all=$((total_lines_all + total))
	done

	if [[ $total_lines_all -gt 0 ]]; then
		agg_pct=$(echo "scale=2; $total_covered_all * 100 / $total_lines_all" | bc)
		printf "  %-12s %8d %10d %9s%%\n" "TOTAL" "$total_covered_all" "$total_lines_all" "$agg_pct"
	fi
	echo ""

	# -------------------------------------------------------------------
	# Section 2: Per-file breakdown within each target
	# -------------------------------------------------------------------
	echo "---------------------------------------------------------------------"
	echo " Per-File Breakdown (by target)"
	echo "---------------------------------------------------------------------"

	for target in "${TARGETS[@]}"; do
		[[ -n "${COV_JSON[$target]+set}" ]] || continue
		echo ""
		echo "  Target: $target"
		printf "    %-30s %8s %8s %9s\n" "FILE" "COVERED" "TOTAL" "PERCENT"
		printf "    %-30s %8s %8s %9s\n" "----" "-------" "-----" "-------"

		jq -r '.files[] | "\(.file)\t\(.covered_lines)\t\(.total_lines)\t\(.percent_covered)"' \
			"${COV_JSON[$target]}" |
			while IFS=$'\t' read -r filepath covered total pct; do
				fname=$(basename "$filepath")
				printf "    %-30s %8s %8s %8s%%\n" "$fname" "$covered" "$total" "$pct"
			done
	done
	echo ""

	# -------------------------------------------------------------------
	# Section 3: Cross-target file aggregation
	# -------------------------------------------------------------------
	# A source file may appear in multiple targets.  For each unique file,
	# show the best (highest) line coverage achieved across all targets.
	echo "---------------------------------------------------------------------"
	echo " Cross-Target Aggregation (best coverage per source file)"
	echo "---------------------------------------------------------------------"
	echo ""
	printf "  %-25s %10s %8s %8s %9s\n" "FILE" "BEST_IN" "COVERED" "TOTAL" "PERCENT"
	printf "  %-25s %10s %8s %8s %9s\n" "----" "-------" "-------" "-----" "-------"

	# Build a temporary file mapping: file -> target covered total pct
	CROSS_TMP=$(mktemp)
	for target in "${TARGETS[@]}"; do
		[[ -n "${COV_JSON[$target]+set}" ]] || continue
		jq -r --arg target "$target" \
			'.files[] | "\(.file)\t\($target)\t\(.covered_lines)\t\(.total_lines)\t\(.percent_covered)"' \
			"${COV_JSON[$target]}" >>"$CROSS_TMP"
	done

	# For each unique file, find the target with the highest covered_lines.
	sort -t$'\t' -k1,1 -k3,3nr "$CROSS_TMP" |
		awk -F'\t' '!seen[$1]++ {
			fname = $1; sub(/.*\//, "", fname)
			printf "  %-25s %10s %8s %8s %8s%%\n", fname, $2, $3, $4, $5
		}'
	rm -f "$CROSS_TMP"
	echo ""

	# -------------------------------------------------------------------
	# Section 4: Uncovered lines (0/N in codecov.json)
	# -------------------------------------------------------------------
	echo "---------------------------------------------------------------------"
	echo " Uncovered Lines (0 hits)"
	echo "---------------------------------------------------------------------"
	echo ""
	echo "  Lines with 0/N in codecov.json — code never executed by any seed."
	echo ""

	for target in "${TARGETS[@]}"; do
		[[ -n "${CODECOV_JSON[$target]+set}" ]] || continue
		[[ -f "${CODECOV_JSON[$target]}" ]] || continue

		has_uncovered=0

		# Iterate over each file in the codecov.json coverage map.
		while IFS= read -r file_key; do
			# Collect uncovered lines for this file.
			uncovered_lines=$(
				jq -r --arg f "$file_key" \
					'.coverage[$f] | to_entries[] | select(.value | startswith("0/")) | .key' \
					"${CODECOV_JSON[$target]}" |
					sort -n |
					paste -sd, -
			)

			if [[ -n "$uncovered_lines" ]]; then
				if [[ $has_uncovered -eq 0 ]]; then
					echo "  Target: $target"
					has_uncovered=1
				fi

				count=$(echo "$uncovered_lines" | tr ',' '\n' | wc -l)
				# Strip path to just filename for readability.
				fname="$file_key"
				[[ "$fname" == */* ]] && fname=$(basename "$fname")
				echo "    $fname ($count lines): $uncovered_lines"
			fi
		done < <(jq -r '.coverage | keys[]' "${CODECOV_JSON[$target]}")

		if [[ $has_uncovered -eq 1 ]]; then
			echo ""
		fi
	done

	# -------------------------------------------------------------------
	# Section 5: Partial branch coverage (M/N where 0 < M < N)
	# -------------------------------------------------------------------
	echo "---------------------------------------------------------------------"
	echo " Partial Branch Coverage (M/N where 0 < M < N)"
	echo "---------------------------------------------------------------------"
	echo ""
	echo "  Lines where some but not all instrumentation points were taken."
	echo ""

	for target in "${TARGETS[@]}"; do
		[[ -n "${CODECOV_JSON[$target]+set}" ]] || continue
		[[ -f "${CODECOV_JSON[$target]}" ]] || continue

		has_partial=0

		while IFS= read -r file_key; do
			# A line is "partial" if its value is "M/N" where M > 0 and M < N.
			partial_lines=$(
				jq -r --arg f "$file_key" '
					.coverage[$f] | to_entries[] |
					(.value | split("/") | map(tonumber)) as [$m, $n] |
					select($m > 0 and $m < $n) |
					"\(.key)(\(.value))"
				' "${CODECOV_JSON[$target]}" 2>/dev/null |
					sort -t'(' -k1,1n |
					paste -sd' ' -
			)

			if [[ -n "$partial_lines" ]]; then
				if [[ $has_partial -eq 0 ]]; then
					echo "  Target: $target"
					has_partial=1
				fi
				fname="$file_key"
				[[ "$fname" == */* ]] && fname=$(basename "$fname")
				echo "    $fname: $partial_lines"
			fi
		done < <(jq -r '.coverage | keys[]' "${CODECOV_JSON[$target]}")

		if [[ $has_partial -eq 1 ]]; then
			echo ""
		fi
	done

	# -------------------------------------------------------------------
	# Section 6: Coverage statistics
	# -------------------------------------------------------------------
	echo "---------------------------------------------------------------------"
	echo " Coverage Statistics"
	echo "---------------------------------------------------------------------"
	echo ""

	for target in "${TARGETS[@]}"; do
		[[ -n "${CODECOV_JSON[$target]+set}" ]] || continue
		[[ -f "${CODECOV_JSON[$target]}" ]] || continue

		# Count instrumented lines, fully covered (M/N where M==N), partial,
		# and uncovered across all files in this target.
		stats=$(
			jq -r '
				[.coverage | to_entries[] | .value | to_entries[]] |
				map(.value | split("/") | map(tonumber)) |
				{
					total: length,
					full: map(select(.[0] == .[1])) | length,
					partial: map(select(.[0] > 0 and .[0] < .[1])) | length,
					uncovered: map(select(.[0] == 0)) | length,
					branch_points: map(.[1]) | add,
					branch_hits: map(.[0]) | add
				} |
				"\(.total)\t\(.full)\t\(.partial)\t\(.uncovered)\t\(.branch_hits)\t\(.branch_points)"
			' "${CODECOV_JSON[$target]}" 2>/dev/null
		)

		IFS=$'\t' read -r total full partial uncovered branch_hits branch_points <<<"$stats"
		if [[ -n "$total" && "$total" -gt 0 ]]; then
			full_pct=$(echo "scale=1; $full * 100 / $total" | bc)
			partial_pct=$(echo "scale=1; $partial * 100 / $total" | bc)
			uncov_pct=$(echo "scale=1; $uncovered * 100 / $total" | bc)
			branch_pct="n/a"
			if [[ "$branch_points" -gt 0 ]]; then
				branch_pct=$(echo "scale=1; $branch_hits * 100 / $branch_points" | bc)
			fi

			echo "  Target: $target"
			echo "    Instrumented lines : $total"
			echo "    Fully covered      : $full ($full_pct%)"
			echo "    Partially covered  : $partial ($partial_pct%)"
			echo "    Uncovered          : $uncovered ($uncov_pct%)"
			echo "    Branch points hit  : $branch_hits / $branch_points ($branch_pct%)"
			echo ""
		fi
	done

	echo "====================================================================="
	echo " End of report"
	echo "====================================================================="
} >"$REPORT" 2>&1

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
cat "$REPORT"
cp "$REPORT" "$REPORT_FILE"
echo ""
echo "Report saved to: $REPORT_FILE"
