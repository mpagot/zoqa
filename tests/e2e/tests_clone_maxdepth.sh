#!/usr/bin/env bash
# shellcheck disable=SC2153
# test_clone_maxdepth.sh — --max-depth tests (CLO-90 to CLO-97).
#
# Uses the deeplayer fixture: 17-layer linear chain (layer_a → … → layer_s;
# letters j and k absent from the YAML, giving 17 nodes total):
#   pos 1:layer_a  2:layer_b  3:layer_c  4:layer_d  5:layer_e
#   pos 6:layer_f  7:layer_g  8:layer_h  9:layer_i  10:layer_l
#   pos 11:layer_m 12:layer_n 13:layer_o 14:layer_p 15:layer_q
#   pos 16:layer_r 17:layer_s
#
# BFS depth counting: the cloned root job is at depth 1.  With --clone-children
# --max-depth N, a node at depth d is always collected; its children are pushed
# only when d ≤ N (i.e. the depth check gates child enqueuing, not collection):
#   N=1 (default)  → 2 jobs   (root + 1 child; root's children pushed, child's not)
#   N=3             → 4 jobs   (root + 3 descendant layers)
#   N≥17 or N=0    → 17 jobs  (full chain, effectively unlimited)
#
# --max-depth does NOT apply to parents: the parent BFS always traverses
# the full ancestor chain regardless of N.
#
# Known Zig gap (CLONE_JOB_TODO.md §Gap 1): Zig default is currently unlimited
# instead of 1 — CLO-90b is a TDD test that documents this gap.
# All other tests supply an explicit --max-depth flag so that Perl and Zig
# exercise the same code path and can be compared.
#
# Sourced by tests.sh after helper functions are defined.
# Do NOT execute this file directly.
#
# Goal: every test here is a PERL vs ZIG comparison against the same input,
# using the upstream `openqa-clone-job` Perl script as the behavioural oracle
# for our new `zoqa-clone-job` Zig binary.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_topology.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "==> [clone_job/maxdepth] Running --max-depth tests (CLO-90 to CLO-97)..."

# Local binary handles — different from the global PERL_EXE/ZIG_EXE which
# point at openqa-cli / zoqa.
PERL_CLONE_EXE="openqa-clone-job"
ZIG_CLONE_EXE="/app/zig-out/bin/zoqa-clone-job"

ensure_deeplayer_jobs

# Helper: cancel all jobs created by a clone run (avoids blocking the worker queue
# when large numbers of sequential jobs would otherwise pile up).
_cancel_cloned_jobs() {
	local tag=$1
	local impl
	for impl in perl zig; do
		local id
		for id in $(grep -oP '(?<=tests/)\d+' "$LOG_DIR/${tag}_${impl}_stdout.log" 2>/dev/null || true); do
			[[ -n "$id" ]] && container_exec openqa-cli api --host http://localhost \
				-X POST "jobs/$id/cancel" >/dev/null 2>&1 || true
		done
	done
}

# ---------------------------------------------------------------------------
# CLO-90: Perl oracle — default (no flag) --max-depth is 1 → 2 jobs
# ---------------------------------------------------------------------------
echo "--- Test CLO-90: Perl oracle: default --max-depth (no flag) → 2 jobs ---"
run_capture "clone90" perl \
	"$PERL_CLONE_EXE --within-instance http://localhost --clone-children $DEEPLAY_LAYER_A_ID"
_PERL_EXIT=$_LAST_EXIT
_m90_perl_count=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone90_perl_stdout.log" | wc -l || echo 0)
if [[ "$_PERL_EXIT" -eq 0 && "$_m90_perl_count" -eq 2 ]]; then
	echo "PASS"
else
	echo "FAIL: Perl exit=$_PERL_EXIT, jobs=$_m90_perl_count (expected 2)"
	failed_tests=$((failed_tests + 1))
fi
for id in $(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone90_perl_stdout.log" || true); do
	wait_for_job "$id" 300 >/dev/null || true
done

# ---------------------------------------------------------------------------
# CLO-90b: Zig TDD — default must be 1, but Zig currently uses unlimited (Gap 1)
# ---------------------------------------------------------------------------
echo "--- Test CLO-90b: Zig TDD: default --max-depth should be 1 (Gap 1 — currently unlimited) ---"
run_capture "clone90b" zig \
	"$ZIG_CLONE_EXE --within-instance http://localhost --clone-children $DEEPLAY_LAYER_A_ID"
_ZIG_EXIT=$_LAST_EXIT
_m90b_count=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone90b_zig_stdout.log" | wc -l || echo 0)
if [[ "$_ZIG_EXIT" -eq 0 && "$_m90b_count" -eq 2 ]]; then
	echo "PASS (Zig gap resolved)"
else
	echo "TDD-FAIL: Zig exit=$_ZIG_EXIT, jobs=$_m90b_count (expected 2; fix: max_depth = args.max_depth orelse 1)"
	failed_tests=$((failed_tests + 1))
fi
# Cancel whatever Zig created — up to 17 stray jobs while the gap is unfixed.
for id in $(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone90b_zig_stdout.log" 2>/dev/null || true); do
	[[ -n "$id" ]] && container_exec openqa-cli api --host http://localhost \
		-X POST "jobs/$id/cancel" >/dev/null 2>&1 || true
done

# ---------------------------------------------------------------------------
# CLO-91: Explicit --max-depth 1 → 2 jobs for both Perl and Zig
# ---------------------------------------------------------------------------
echo "--- Test CLO-91: --max-depth 1 (explicit) → 2 jobs ---"
run_clone_both "clone91" \
	"--within-instance http://localhost --clone-children --max-depth 1 $DEEPLAY_LAYER_A_ID"
assert_capture_exits "clone91" 0

_m91_pass=true
for _lbl in "perl" "zig"; do
	_count=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone91_${_lbl}_stdout.log" | wc -l || echo 0)
	if [[ "$_count" -ne 2 ]]; then
		echo "  FAIL: $_lbl cloned $_count jobs (expected 2)"
		_m91_pass=false
	fi
done
[[ "$_m91_pass" == "true" ]] && echo "PASS" || failed_tests=$((failed_tests + 1))

wait_for_cloned_jobs "clone91"

# CLO-91b: Confirm cloned jobs are specifically layer_a and layer_b (not deeper)
echo "--- Test CLO-91b: --max-depth 1 clones layer_a and layer_b only ---"
_m91b_pass=true
for _lbl in "perl" "zig"; do
	if [[ "$_lbl" == "perl" ]]; then _ids="$_CLONE_PERL_IDS"; else _ids="$_CLONE_ZIG_IDS"; fi
	_found_tests=""
	for id in $_ids; do
		_t=$(container_exec openqa-cli api --host http://localhost \
			"jobs/$id" 2>/dev/null | jq -r '.job.settings.TEST')
		_found_tests="$_found_tests $_t"
	done
	for expected in layer_a layer_b; do
		if ! echo "$_found_tests" | grep -qw "$expected"; then
			echo "  FAIL: $_lbl missing $expected (found:$_found_tests)"
			_m91b_pass=false
		fi
	done
	if echo "$_found_tests" | grep -qw "layer_c"; then
		echo "  FAIL: $_lbl cloned layer_c (depth 3) — beyond --max-depth 1"
		_m91b_pass=false
	fi
done
[[ "$_m91b_pass" == "true" ]] && echo "PASS" || failed_tests=$((failed_tests + 1))

# ---------------------------------------------------------------------------
# CLO-92: --max-depth 3 → 4 jobs (layer_a through layer_d)
# ---------------------------------------------------------------------------
echo "--- Test CLO-92: --max-depth 3 → 4 jobs (layer_a … layer_d) ---"
run_clone_both "clone92" \
	"--within-instance http://localhost --clone-children --max-depth 3 $DEEPLAY_LAYER_A_ID"
assert_capture_exits "clone92" 0
assert_stdout_pattern "clone92" "4 jobs have been created:"

_m92_pass=true
for _lbl in "perl" "zig"; do
	_found_tests=""
	for id in $(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone92_${_lbl}_stdout.log" || true); do
		_t=$(container_exec openqa-cli api --host http://localhost \
			"jobs/$id" 2>/dev/null | jq -r '.job.settings.TEST')
		_found_tests="$_found_tests $_t"
	done
	for expected in layer_a layer_b layer_c layer_d; do
		if ! echo "$_found_tests" | grep -qw "$expected"; then
			echo "  FAIL: $_lbl missing $expected (found:$_found_tests)"
			_m92_pass=false
		fi
	done
	if echo "$_found_tests" | grep -qw "layer_e"; then
		echo "  FAIL: $_lbl cloned layer_e (depth 5) — beyond --max-depth 3"
		_m92_pass=false
	fi
done
[[ "$_m92_pass" == "true" ]] && echo "PASS" || failed_tests=$((failed_tests + 1))
_cancel_cloned_jobs "clone92"

# ---------------------------------------------------------------------------
# CLO-93: --max-depth 0 (unlimited) → all 17 layers
# ---------------------------------------------------------------------------
echo "--- Test CLO-93: --max-depth 0 (unlimited) → all 17 layers ---"
run_clone_both "clone93" \
	"--within-instance http://localhost --clone-children --max-depth 0 $DEEPLAY_LAYER_A_ID"
assert_capture_exits "clone93" 0
assert_stdout_pattern "clone93" "17 jobs have been created:"
_cancel_cloned_jobs "clone93"

# ---------------------------------------------------------------------------
# CLO-94: --max-depth > chain length → same result as unlimited (all 17)
# Corner case: N=20, chain has only 17 nodes, so N>chain → full chain cloned.
# ---------------------------------------------------------------------------
echo "--- Test CLO-94: --max-depth 20 (> chain depth of 17) → all 17 layers ---"
run_clone_both "clone94" \
	"--within-instance http://localhost --clone-children --max-depth 20 $DEEPLAY_LAYER_A_ID"
assert_capture_exits "clone94" 0
assert_stdout_pattern "clone94" "17 jobs have been created:"
_cancel_cloned_jobs "clone94"

# ---------------------------------------------------------------------------
# CLO-95: --max-depth does NOT apply to parents
# Cloning layer_s (the leaf, position 17) with --max-depth 1 still walks all
# 16 ancestors — parent BFS is always unlimited regardless of --max-depth.
# ---------------------------------------------------------------------------
echo "--- Test CLO-95: --max-depth 1 does not limit parent traversal (layer_s → 17 jobs) ---"
run_clone_both "clone95" \
	"--within-instance http://localhost --max-depth 1 $DEEPLAY_LAYER_S_ID"
assert_capture_exits "clone95" 0
assert_stdout_pattern "clone95" "17 jobs have been created:"
_cancel_cloned_jobs "clone95"

# ---------------------------------------------------------------------------
# CLO-96: Clone from middle of chain (layer_i, position 9) with --max-depth 2
#
# ===========================================================================
# 1. Graph Theory Definition of "Depth" (The Hop-Count Model)
#    - In standard graph theory, "depth" is defined as the length of the path
#      (the number of edges or hops) from the starting root node to a target.
#    - Under a pure Hop-Count model, the root job itself sits at depth 0,
#      its direct child is at depth 1, its grandchild is at depth 2, etc.
#
# 2. How the --max-depth Limit is Calculated (The Lookahead Enqueue Gate)
#    - To simplify programmatic bounds checks, openQA represents the BFS tree using
#      a 1-based root depth offset (depth = 1 for the root "layer_i").
#    - The depth limit (--max-depth 2) is evaluated as a "lookahead gate" for child
#      enqueuing rather than an execution gate for node collection (depth <= max_depth):
#
#        * Popping layer_i (depth 1):
#          Since depth (1) <= max_depth (2) is true, direct child layer_l
#          is enqueued at depth 2.
#
#        * Popping layer_l (depth 2):
#          Since depth (2) <= max_depth (2) is true, grandchild layer_m
#          is enqueued at depth 3.
#
#        * Popping layer_m (depth 3):
#          Since layer_m was enqueued, it is legitimately processed and collected.
#          However, depth (3) <= max_depth (2) is false, so great-grandchild 
#          layer_n is blocked from being enqueued.
#
#    - Expected result:
#      * layer_i itself (root, depth 1)                             →  1 job
#      * layer_l (direct child, depth 2)                             →  1 job
#      * layer_m (grandchild, depth 3)                               →  1 job
#      * Parents of layer_i (unlimited): layer_h down to layer_a      →  8 jobs
#      Total: 1 + 1 + 1 + 8 = 11 jobs (and layer_n is skipped)
# ===========================================================================
# ---------------------------------------------------------------------------
echo "--- Test CLO-96: layer_i (middle) --clone-children --max-depth 2 → 11 jobs ---"
run_clone_both "clone96" \
	"--within-instance http://localhost --clone-children --max-depth 2 $DEEPLAY_LAYER_I_ID"
assert_capture_exits "clone96" 0
assert_stdout_pattern "clone96" "11 jobs have been created:"

_m96_pass=true
for _lbl in "perl" "zig"; do
	_found_tests=""
	for id in $(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone96_${_lbl}_stdout.log" || true); do
		_t=$(container_exec openqa-cli api --host http://localhost \
			"jobs/$id" 2>/dev/null | jq -r '.job.settings.TEST')
		_found_tests="$_found_tests $_t"
	done
	# layer_i (depth 1), layer_l (depth 2), and layer_m (depth 3) must all be present
	for expected in layer_i layer_l layer_m; do
		if ! echo "$_found_tests" | grep -qw "$expected"; then
			echo "  FAIL: $_lbl missing $expected (found:$_found_tests)"
			_m96_pass=false
		fi
	done
	# layer_n must be absent: layer_m at depth 3, 3 ≤ 2 = false → layer_n not enqueued
	if echo "$_found_tests" | grep -qw "layer_n"; then
		echo "  FAIL: $_lbl cloned layer_n — layer_m (depth 3) should not enqueue children (3 ≤ 2 = false)"
		_m96_pass=false
	fi
	# All 8 ancestors must be present (parent BFS is unlimited)
	for ancestor in layer_a layer_b layer_c layer_d layer_e layer_f layer_g layer_h; do
		if ! echo "$_found_tests" | grep -qw "$ancestor"; then
			echo "  FAIL: $_lbl missing ancestor $ancestor"
			_m96_pass=false
		fi
	done
done
[[ "$_m96_pass" == "true" ]] && echo "PASS" || failed_tests=$((failed_tests + 1))
_cancel_cloned_jobs "clone96"

# ---------------------------------------------------------------------------
# CLO-97: Clone from middle (layer_i) + --skip-deps + --clone-children --max-depth 0
# --skip-deps suppresses all parent traversal; --max-depth 0 is unlimited for
# children.  Result: layer_i plus all 8 descendants (l … s) = 9 jobs.
# ---------------------------------------------------------------------------
echo "--- Test CLO-97: layer_i --skip-deps --clone-children --max-depth 0 → 9 jobs ---"
run_clone_both "clone97" \
	"--within-instance http://localhost --skip-deps --clone-children --max-depth 0 $DEEPLAY_LAYER_I_ID"
assert_capture_exits "clone97" 0
assert_stdout_pattern "clone97" "9 jobs have been created:"

_m97_pass=true
for _lbl in "perl" "zig"; do
	_found_tests=""
	for id in $(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone97_${_lbl}_stdout.log" || true); do
		_t=$(container_exec openqa-cli api --host http://localhost \
			"jobs/$id" 2>/dev/null | jq -r '.job.settings.TEST')
		_found_tests="$_found_tests $_t"
	done
	# Descendants layer_i through layer_s must all be present
	for expected in layer_i layer_l layer_m layer_n layer_o layer_p layer_q layer_r layer_s; do
		if ! echo "$_found_tests" | grep -qw "$expected"; then
			echo "  FAIL: $_lbl missing $expected (found:$_found_tests)"
			_m97_pass=false
		fi
	done
	# No ancestors — --skip-deps must suppress parent traversal
	if echo "$_found_tests" | grep -qw "layer_h"; then
		echo "  FAIL: $_lbl cloned layer_h — --skip-deps should have suppressed parent traversal"
		_m97_pass=false
	fi
done
[[ "$_m97_pass" == "true" ]] && echo "PASS" || failed_tests=$((failed_tests + 1))
_cancel_cloned_jobs "clone97"
