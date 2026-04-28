#!/usr/bin/env bash
# distill.sh — distill fuzzer queue, minimise files, and promote into the
#               tracked seed corpus for one or all fuzz targets.
#
# Usage:
#   ./tests/fuzz/distill.sh                              # distill all targets with queue output
#   ./tests/fuzz/distill.sh config                       # distill only the config target
#   ./tests/fuzz/distill.sh config request               # distill multiple specific targets
#   ./tests/fuzz/distill.sh --no-backup config           # skip creating a backup of the old corpus
#   ./tests/fuzz/distill.sh --timeout=3600 request       # allow 3600s total for tmin (Step 2)
#   ./tests/fuzz/distill.sh --tmin-files=tests/fuzz/corpus_request/.tmin_timeouts request   # re-run tmin only on timed-out files (Step 2 only)
#
# For each selected target the script runs five steps:
#   1. afl-cmin on out_<target>/main-node/queue/ → corpus_<target>_distilled/
#   2. afl-tmin on every file in the distilled corpus (in-place)
#   3. Backs up corpus_<target>/ → corpus_<target>_backup/ (unless --no-backup)
#   4. Moves corpus_<target>_distilled/ → corpus_<target>/
#   5. Re-runs cmin.sh <target> to regenerate corpus_<target>_min/
#
# When --tmin-files is given only Step 2 is executed (no cmin, no backup, no
# promote).  This is designed for re-running minimisation on the small set of
# files that previously hit the per-file timeout.
#
# Run from the project root or from tests/fuzz/; the script locates the root
# by walking up from its own directory.
#
# Requirements:
#   - vendor/aflplusplus built (see README.md §Setup step 2)
#   - zig build -Dfuzz already run (fuzz binaries must exist in zig-out/)
#   - A completed fuzzing campaign with a non-empty queue in out_<target>/
#
# Options:
#   --no-backup            Skip creating corpus_<target>_backup/ before
#                          replacing the tracked corpus.
#
#   --timeout=<seconds>    Total wall-clock budget in seconds for the tmin
#                          step (Step 2).  The per-file limit is derived by
#                          dividing this budget by the number of files to
#                          minimise.  Files that exceed their per-file limit
#                          are left unminimised and their paths are appended
#                          to corpus_<target>_distilled/.tmin_timeouts so the
#                          user can re-run them later with --tmin-files.
#                          Without this flag tmin runs without any timeout.
#
#   --tmin-files=<file>    Path to a newline-delimited file of paths to
#                          (re-)minimise (pass corpus_<target>/.tmin_timeouts
#                          directly).  Only Step 2 is executed; the rest of
#                          the pipeline is skipped.  Paths may be absolute or
#                          bare basenames; basenames are resolved inside
#                          corpus_<target>/.
#
# Target names:
#
#     config   — INI parser + resolveHost          (zoqa-fuzz-config)
#     request  — CLI args + buildRequest + JSON    (zoqa-fuzz-request)
#     execute  — full pipeline: auth+retry+gzip    (zoqa-fuzz-execute)

set -euo pipefail

# ---------------------------------------------------------------------------
# Graceful interrupt handling
# ---------------------------------------------------------------------------
# STOP_REQUESTED is checked at key points in the loop so that the current
# afl-tmin invocation is always allowed to finish before we stop.
STOP_REQUESTED=0
_stop_notice_shown=0
_handle_stop() {
	STOP_REQUESTED=1
	if [[ $_stop_notice_shown -eq 0 ]]; then
		_stop_notice_shown=1
		echo "" >&2
		echo "==> Ctrl+C received — will stop after current afl-tmin finishes." >&2
	fi
}
trap '_handle_stop' INT TERM

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

for tool in afl-cmin afl-tmin; do
	if [[ ! -f "$AFL_DIR/$tool" ]]; then
		echo "error: $AFL_DIR/$tool not found." >&2
		echo "       Build AFL++ first: make source-only -j\$(nproc) -C vendor/aflplusplus" >&2
		exit 1
	fi
done

export PATH="$AFL_DIR:$PATH"

# ---------------------------------------------------------------------------
# Target definitions: name -> (corpus_dir, binary_name)
# ---------------------------------------------------------------------------
declare -A CORPUS_DIR=(
	[config]="corpus_config"
	[request]="corpus_request"
	[execute]="corpus_execute"
)
declare -A BINARY=(
	[config]="zoqa-fuzz-config"
	[request]="zoqa-fuzz-request"
	[execute]="zoqa-fuzz-execute"
)
ALL_TARGETS=(config request execute)

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
NO_BACKUP=0
GLOBAL_TIMEOUT="" # empty = no timeout
TMIN_FILES=()     # empty = minimise all files in distilled corpus
TARGETS=()

for arg in "$@"; do
	case "$arg" in
	--no-backup)
		NO_BACKUP=1
		;;
	--timeout=*)
		val="${arg#--timeout=}"
		if [[ ! "$val" =~ ^[1-9][0-9]*$ ]]; then
			echo "error: --timeout requires a positive integer (seconds), got '$val'." >&2
			exit 1
		fi
		GLOBAL_TIMEOUT="$val"
		;;
	--tmin-files=*)
		tmin_list_file="${arg#--tmin-files=}"
		if [[ ! -f "$tmin_list_file" ]]; then
			echo "error: --tmin-files: file not found: '$tmin_list_file'." >&2
			exit 1
		fi
		mapfile -t TMIN_FILES <"$tmin_list_file"
		;;
	--*)
		echo "error: unknown option '$arg'." >&2
		echo "       Usage: $0 [--no-backup] [--timeout=<s>] [--tmin-files=<file>] [targets...]" >&2
		exit 1
		;;
	*)
		if [[ -z "${CORPUS_DIR[$arg]+set}" ]]; then
			echo "error: unknown target '$arg'." >&2
			echo "       Valid targets: ${ALL_TARGETS[*]}" >&2
			exit 1
		fi
		TARGETS+=("$arg")
		;;
	esac
done

# Default: all targets that have a non-empty queue.
if [[ ${#TARGETS[@]} -eq 0 ]]; then
	for t in "${ALL_TARGETS[@]}"; do
		queue_dir="$FUZZ_DIR/out_${t}/main-node/queue"
		if [[ -d "$queue_dir" ]] && [[ -n "$(ls -A "$queue_dir" 2>/dev/null)" ]]; then
			TARGETS+=("$t")
		fi
	done
	if [[ ${#TARGETS[@]} -eq 0 ]]; then
		echo "error: no targets have a non-empty queue in out_*/main-node/queue/." >&2
		echo "       Run a fuzzing campaign first: ./tests/fuzz/run.sh <target>" >&2
		exit 1
	fi
	echo "==> Auto-selected targets with queue output: ${TARGETS[*]}"
fi

TMIN_FILES_ONLY=0
if [[ ${#TMIN_FILES[@]} -gt 0 ]]; then
	TMIN_FILES_ONLY=1
fi

# ---------------------------------------------------------------------------
# Helper: run the tmin loop over a list of files
#
# Arguments:
#   $1  corpus_distilled dir  (for resolving basenames and writing .tmin_timeouts)
#   $2  final_corpus_dir      (post-promotion path, used in the re-run hint;
#                              pass the same value as $1 when no promotion occurs)
#   $3  binary path
#   $4  global timeout in seconds, or "" for no timeout
#   $5+ absolute paths of files to minimise
#
# Files that time out are appended to $1/.tmin_timeouts (one path per line).
# The re-run hint shown to the user references $2 (the final location after
# any mv promotion step), so the paths remain valid after the run completes.
# ---------------------------------------------------------------------------
run_tmin_loop() {
	local corpus_distilled="$1"
	local final_corpus_dir="$2"
	local binary="$3"
	local budget="$4"
	shift 4
	local files=("$@")
	local total=${#files[@]}
	local timeouts_file="$corpus_distilled/.tmin_timeouts"

	if [[ $total -eq 0 ]]; then
		echo "    No files to minimise."
		return 0
	fi

	# Derive per-file limit from the global budget.
	local per_file_timeout=""
	if [[ -n "$budget" ]]; then
		# Integer division; minimum 10s so afl-tmin has a chance to start.
		per_file_timeout=$((budget / total))
		if [[ $per_file_timeout -lt 10 ]]; then
			per_file_timeout=10
		fi
		echo "    Global budget     : ${budget}s"
		echo "    Files to minimise : ${total}"
		echo "    Per-file limit    : ${per_file_timeout}s  (budget / count)"
		echo "    Timeout log       : $timeouts_file"
	else
		echo "    Files to minimise : ${total}  (no timeout)"
	fi

	local current=0
	local timed_out=0

	for f in "${files[@]}"; do
		if [[ $STOP_REQUESTED -eq 1 ]]; then
			local remaining=$((total - current))
			echo "" >&2
			echo "==> Interrupted — $current/$total files minimised, $remaining remaining (not recorded to .tmin_timeouts)." >&2
			return 1
		fi

		[[ -f "$f" ]] || continue
		current=$((current + 1))
		local basename_f
		basename_f=$(basename "$f")
		local size_before
		size_before=$(stat -c%s "$f")

		local tmin_exit
		# shellcheck disable=SC2016  # $1/$2 are bash -c positional args, not outer-shell vars
		if [[ -n "$per_file_timeout" ]]; then
			AFL_IGNORE_PROBLEMS=1 \
				time timeout "${per_file_timeout}s" \
				bash -c 'trap "" INT; exec afl-tmin -i "$1" -o "${1}.tmin" -- "$2"' \
				_ "$f" "$binary" \
				2>/dev/null || tmin_exit=$?
		else
			AFL_IGNORE_PROBLEMS=1 \
				time \
				bash -c 'trap "" INT; exec afl-tmin -i "$1" -o "${1}.tmin" -- "$2"' \
				_ "$f" "$binary" \
				2>/dev/null || tmin_exit=$?
		fi
		tmin_exit=${tmin_exit:-0}

		if [[ $tmin_exit -eq 124 ]]; then
			# Per-file timeout hit — record for later retry.
			echo "$f" >>"$timeouts_file"
			timed_out=$((timed_out + 1))
			echo "    [$current/$total] $basename_f: TIMED OUT (${per_file_timeout}s) — recorded in .tmin_timeouts"
		elif [[ -f "${f}.tmin" ]]; then
			mv "${f}.tmin" "$f"
			local size_after
			size_after=$(stat -c%s "$f")
			echo "    [$current/$total] $basename_f: $size_before -> $size_after bytes"
		else
			echo "    [$current/$total] $basename_f: FAILED (size unchanged)"
		fi
	done

	if [[ $timed_out -gt 0 ]]; then
		# The timeout log is written to corpus_distilled during this run.
		# After the promotion step (mv corpus_distilled → corpus_dst) it will
		# live at final_corpus_dir/.tmin_timeouts, which is the path the user
		# should reference when re-running.
		local final_timeouts_file="$final_corpus_dir/.tmin_timeouts"
		echo ""
		echo "    WARNING: $timed_out file(s) hit the per-file timeout and were not minimised."
		echo "             Their paths will be recorded in (after this run completes):"
		echo "               $final_timeouts_file"
		echo "             Re-run with a larger budget or no timeout:"
		echo "               $0 --tmin-files=$final_timeouts_file [--timeout=<s>] <target>"
	fi
}

# ---------------------------------------------------------------------------
# Process each target
# ---------------------------------------------------------------------------
cd "$ROOT"

for target in "${TARGETS[@]}"; do
	if [[ $STOP_REQUESTED -eq 1 ]]; then
		echo "==> Interrupted — skipping remaining target(s)." >&2
		exit 130
	fi

	queue_dir="$FUZZ_DIR/out_${target}/main-node/queue"
	corpus_distilled="$FUZZ_DIR/${CORPUS_DIR[$target]}_distilled"
	corpus_dst="$FUZZ_DIR/${CORPUS_DIR[$target]}"
	corpus_backup="$FUZZ_DIR/${CORPUS_DIR[$target]}_backup"
	binary="$ROOT/zig-out/${BINARY[$target]}"

	echo ""
	echo "================================================================"
	echo "==> Target: $target"
	echo "================================================================"

	if [[ ! -x "$binary" ]]; then
		echo "    error: binary '$binary' not found or not executable." >&2
		echo "           Run: ./tests/fuzz/build.sh" >&2
		exit 1
	fi

	# -----------------------------------------------------------------------
	# --tmin-files mode: Step 2 only, on the specified files
	# -----------------------------------------------------------------------
	if [[ $TMIN_FILES_ONLY -eq 1 ]]; then
		echo "    Mode: --tmin-files (Step 2 only)"
		echo "    Binary: $binary"
		echo ""

		# Resolve each entry: if it is a bare basename, look it up inside
		# corpus_distilled; otherwise use the path as-is.
		resolved_files=()
		for entry in "${TMIN_FILES[@]}"; do
			if [[ "$entry" == */* ]]; then
				# Looks like a path — use directly.
				resolved_files+=("$entry")
			else
				# Bare basename — resolve against corpus_distilled.
				candidate="$corpus_distilled/$entry"
				if [[ -f "$candidate" ]]; then
					resolved_files+=("$candidate")
				else
					echo "    WARNING: '$entry' not found in $corpus_distilled — skipping." >&2
				fi
			fi
		done

		echo "--- Step 2 (tmin-files): File minimisation (afl-tmin) ---"
		# No promotion step in this mode, so final_corpus_dir == corpus_distilled.
		run_tmin_loop "$corpus_distilled" "$corpus_distilled" "$binary" "$GLOBAL_TIMEOUT" "${resolved_files[@]}" || true
		echo ""
		if [[ $STOP_REQUESTED -eq 1 ]]; then
			echo "==> Interrupted — skipping remaining target(s)." >&2
			exit 130
		fi
		continue
	fi

	# -----------------------------------------------------------------------
	# Normal mode: all five steps
	# -----------------------------------------------------------------------

	# -- Validate ----------------------------------------------------------

	if [[ ! -d "$queue_dir" ]]; then
		echo "    WARNING: queue directory '$queue_dir' not found — skipping." >&2
		continue
	fi

	if [[ -z "$(ls -A "$queue_dir" 2>/dev/null)" ]]; then
		echo "    WARNING: queue directory '$queue_dir' is empty — skipping." >&2
		continue
	fi

	queue_count=$(find "$queue_dir" -maxdepth 1 -type f | wc -l)
	echo "    Queue:   $queue_dir ($queue_count files)"
	echo "    Binary:  $binary"
	echo ""

	# -- Step 1: Corpus distillation (afl-cmin) ---------------------------

	echo "--- Step 1/5: Corpus distillation (afl-cmin) ---"
	rm -rf "$corpus_distilled"

	(
		trap '' INT
		exec afl-cmin \
			-i "$queue_dir" \
			-o "$corpus_distilled" \
			-- "$binary"
	)

	distilled_count=$(find "$corpus_distilled" -maxdepth 1 -type f | wc -l)
	echo "    Distilled: $distilled_count files (from $queue_count queue entries)"
	echo ""

	if [[ $STOP_REQUESTED -eq 1 ]]; then
		echo "==> Interrupted after Step 1 — skipping Steps 2–5 for '$target' and all remaining targets." >&2
		exit 130
	fi

	# -- Step 2: Individual file minimisation (afl-tmin) ------------------

	echo "--- Step 2/5: File minimisation (afl-tmin) ---"

	# Collect files to minimise (regular files only, skip dot-files).
	tmin_input_files=()
	for f in "$corpus_distilled"/*; do
		[[ -f "$f" ]] || continue
		tmin_input_files+=("$f")
	done

	run_tmin_loop "$corpus_distilled" "$corpus_dst" "$binary" "$GLOBAL_TIMEOUT" "${tmin_input_files[@]}" || true
	echo ""

	if [[ $STOP_REQUESTED -eq 1 ]]; then
		echo "==> Interrupted after Step 2 — skipping Steps 3–5 for '$target' and all remaining targets." >&2
		echo "    corpus_distilled/ left in place at: $corpus_distilled" >&2
		exit 130
	fi

	# -- Step 3: Backup old corpus -----------------------------------------

	echo "--- Step 3/5: Backup ---"
	if [[ -d "$corpus_dst" ]]; then
		old_count=$(find "$corpus_dst" -maxdepth 1 -type f | wc -l)
		if [[ "$NO_BACKUP" -eq 1 ]]; then
			rm -rf "$corpus_dst"
			echo "    Removed: $corpus_dst ($old_count files) — --no-backup"
		else
			rm -rf "$corpus_backup"
			mv "$corpus_dst" "$corpus_backup"
			echo "    Backup:  $corpus_backup ($old_count files)"
		fi
	else
		echo "    Nothing to back up — $corpus_dst does not exist."
	fi
	echo ""

	# -- Step 4: Promote distilled corpus ----------------------------------

	echo "--- Step 4/5: Promote ---"
	mv "$corpus_distilled" "$corpus_dst"
	echo "    Promoted: $corpus_distilled -> $corpus_dst ($distilled_count files)"
	# If a timeout log exists, rewrite its recorded paths from the old
	# corpus_distilled location to the new corpus_dst location so that
	# the re-run hint printed earlier remains valid.
	if [[ -f "$corpus_dst/.tmin_timeouts" ]]; then
		sed -i "s|${corpus_distilled}/|${corpus_dst}/|g" "$corpus_dst/.tmin_timeouts"
		echo "    Timeout log updated: $corpus_dst/.tmin_timeouts (paths rewritten to new location)"
	fi
	echo ""

	# -- Step 5: Regenerate _min corpus ------------------------------------

	echo "--- Step 5/5: Regenerate minimised corpus (cmin.sh) ---"
	"$FUZZ_DIR/cmin.sh" "$target"

	min_count=$(find "$FUZZ_DIR/${CORPUS_DIR[$target]}_min" -maxdepth 1 -type f 2>/dev/null | wc -l)
	echo ""
	echo "    Summary for '$target':"
	echo "      Queue entries:     $queue_count"
	echo "      After afl-cmin:   $distilled_count"
	echo "      After promotion:  $distilled_count files in ${CORPUS_DIR[$target]}/"
	echo "      After cmin.sh:    $min_count files in ${CORPUS_DIR[$target]}_min/"
	if [[ -f "$corpus_dst/.tmin_timeouts" ]]; then
		timeout_count=$(wc -l <"$corpus_dst/.tmin_timeouts")
		echo "      Timed-out files:  $timeout_count (see ${CORPUS_DIR[$target]}/.tmin_timeouts)"
	fi
done

echo ""
echo "================================================================"
echo "==> Distillation complete."
echo "================================================================"
