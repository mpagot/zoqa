#!/usr/bin/env bash
# shellcheck disable=SC2153
# test_clone_topology.sh — Graph-topology clone tests (CLO-20 to CLO-42).
#
# Tests cloning across chained, fan-out, multi-layer, diamond, and parallel
# job topologies.  Each section is guarded by its own idempotent ensure_*
# fixture call, so the sections are independent of each other.
#
# CLO-39 (--skip-chained-deps on layer_child) is grouped here with the
# multi-layer section (CLO-30–33) because both share the LAYER_CHILD_ID
# fixture variable set by ensure_multilayer_jobs.
#
# Sourced by tests.sh after helper functions are defined.
# Do NOT execute this file directly.
#
# Goal: every test here is a PERL vs ZIG comparison against the same input,
# using the upstream `openqa-clone-job` Perl script as the behavioural oracle
# for our new `zoqa-clone-job` Zig binary.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_topology.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "==> [clone_job/topology] Running graph-topology clone tests (CLO-20 to CLO-42)..."

# Local binary handles — different from the global PERL_EXE/ZIG_EXE which
# point at openqa-cli / zoqa.
PERL_CLONE_EXE="openqa-clone-job"
ZIG_CLONE_EXE="/app/zig-out/bin/zoqa-clone-job"

# =============================================================================
# Section M-Deps: Dependency Cloning Tests (CLO-20 to CLO-26)
# =============================================================================
ensure_chained_jobs

# CLO-20: Default clone of chained child clones both parent and child
echo "--- Test CLO-20: clone-job chained child clones both ---"
run_clone_both "clone20" \
	"--within-instance http://localhost $CHAIN_CHILD_ID"
assert_capture_exits "clone20" 0

# Check stdout for "2 jobs have been created:"
echo "--- Test M20b: stdout contains '2 jobs have been created:' ---"
assert_stdout_pattern "clone20" "2 jobs have been created:"

# Wait for CLO-20 cloned jobs to finish (otherwise subsequent clones will pile up)
wait_for_cloned_jobs "clone20"

# We need to extract the new parent and child IDs from the API to verify them.
_m21_pass=true
for _lbl in "perl" "zig"; do
    if [[ "$_lbl" == "perl" ]]; then _ids="$_CLONE_PERL_IDS"; else _ids="$_CLONE_ZIG_IDS"; fi
    _new_parent=""
    _new_child=""
    for id in $_ids; do
        _test=$(container_exec openqa-cli api --host http://localhost "jobs/$id" 2>/dev/null | jq -r '.job.settings.TEST')
        if [[ "$_test" == "chain_parent" ]]; then
            _new_parent=$id
        elif [[ "$_test" == "chain_child" ]]; then
            _new_child=$id
        fi
    done

    # CLO-21: Cloned parent has correct CLONED_FROM
    echo "--- Test CLO-21 ($_lbl): Cloned parent has correct CLONED_FROM ---"
    if [[ -n "$_new_parent" ]]; then
        _cloned_from=$(container_exec openqa-cli api --host http://localhost "jobs/$_new_parent" 2>/dev/null | jq -r '.job.settings.CLONED_FROM')
        if [[ "$_cloned_from" != "http://localhost/tests/$CHAIN_PARENT_ID" ]]; then
            echo "  FAIL: $_lbl parent CLONED_FROM='$_cloned_from' (expected http://localhost/tests/$CHAIN_PARENT_ID)"
            _m21_pass=false
        fi
    else
        echo "  FAIL: $_lbl did not create a chain_parent job"
        _m21_pass=false
    fi

    # CLO-22: Cloned child has _START_AFTER pointing to cloned parent
    echo "--- Test CLO-22 ($_lbl): Cloned child points to cloned parent ---"
    if [[ -n "$_new_child" && -n "$_new_parent" ]]; then
        if ! assert_job_has_chained_parent "$_new_child" "$_new_parent"; then
            _m21_pass=false
        fi
    else
        echo "  FAIL: $_lbl child or parent ID missing"
        _m21_pass=false
    fi
done
if [[ "$_m21_pass" == "true" ]]; then echo "PASS"; else failed_tests=$((failed_tests + 1)); fi

# CLO-23: --skip-deps -> only the child is cloned
echo "--- Test M23: clone-job --skip-deps clones only child ---"
run_clone_both "clone23" \
	"--within-instance http://localhost --skip-deps $CHAIN_CHILD_ID"
assert_capture_exits "clone23" 0

echo "--- Test M23b: stdout contains '1 job has been created:' ---"
assert_stdout_pattern "clone23" "1 job has been created:"

wait_for_cloned_jobs "clone23"

# Verify CLO-23 has no chained parents
_m23_pass=true
for _lbl in "perl" "zig"; do
    if [[ "$_lbl" == "perl" ]]; then _ids="$_CLONE_PERL_IDS"; else _ids="$_CLONE_ZIG_IDS"; fi
    for id in $_ids; do
        _parents=$(container_exec openqa-cli api --host http://localhost "jobs/$id" 2>/dev/null | jq -r '.job.parents.Chained | length')
        if [[ "$_parents" != "0" && "$_parents" != "null" ]]; then
            echo "  FAIL: $_lbl job $id has $_parents chained parents (expected 0)"
            _m23_pass=false
        fi
    done
done
if [[ "$_m23_pass" == "true" ]]; then echo "PASS"; else failed_tests=$((failed_tests + 1)); fi

# CLO-24: --skip-chained-deps
echo "--- Test CLO-24: clone-job --skip-chained-deps clones only child ---"
run_clone_both "clone24" \
	"--within-instance http://localhost --skip-chained-deps $CHAIN_CHILD_ID"
assert_capture_exits "clone24" 0
assert_stdout_pattern "clone24" "1 job has been created:"

wait_for_cloned_jobs "clone24"

# CLO-25: Settings override applies to child but NOT to parent (default)
echo "--- Test CLO-25: clone-job override applies to child only ---"
run_clone_both "clone25" \
	"--within-instance http://localhost $CHAIN_CHILD_ID BUILD=dep-override"
assert_capture_exits "clone25" 0

wait_for_cloned_jobs "clone25"

_m25_pass=true
for _lbl in "perl" "zig"; do
    if [[ "$_lbl" == "perl" ]]; then _ids="$_CLONE_PERL_IDS"; else _ids="$_CLONE_ZIG_IDS"; fi
    for id in $_ids; do
        _test=$(container_exec openqa-cli api --host http://localhost "jobs/$id" 2>/dev/null | jq -r '.job.settings.TEST')
        _build=$(container_exec openqa-cli api --host http://localhost "jobs/$id" 2>/dev/null | jq -r '.job.settings.BUILD')
        if [[ "$_test" == "chain_parent" && "$_build" == "dep-override" ]]; then
            echo "  FAIL: $_lbl parent got BUILD=dep-override (should be untouched)"
            _m25_pass=false
        elif [[ "$_test" == "chain_child" && "$_build" != "dep-override" ]]; then
            echo "  FAIL: $_lbl child got BUILD=$_build (should be dep-override)"
            _m25_pass=false
        fi
    done
done
if [[ "$_m25_pass" == "true" ]]; then echo "PASS"; else failed_tests=$((failed_tests + 1)); fi

# CLO-26: --parental-inheritance applies overrides to parents too
echo "--- Test M26: clone-job --parental-inheritance ---"
run_clone_both "clone26" \
	"--within-instance http://localhost --parental-inheritance $CHAIN_CHILD_ID BUILD=inherit-all"
assert_capture_exits "clone26" 0

wait_for_cloned_jobs "clone26"

_m26_pass=true
for _lbl in "perl" "zig"; do
    if [[ "$_lbl" == "perl" ]]; then _ids="$_CLONE_PERL_IDS"; else _ids="$_CLONE_ZIG_IDS"; fi
    for id in $_ids; do
        _build=$(container_exec openqa-cli api --host http://localhost "jobs/$id" 2>/dev/null | jq -r '.job.settings.BUILD')
        if [[ "$_build" != "inherit-all" ]]; then
            echo "  FAIL: $_lbl job $id got BUILD=$_build (should be inherit-all)"
            _m26_pass=false
        fi
    done
done
if [[ "$_m26_pass" == "true" ]]; then echo "PASS"; else failed_tests=$((failed_tests + 1)); fi

# =============================================================================
# Section M-Fanout: Fan-out Topology Tests (CLO-27 to CLO-29)
# =============================================================================
ensure_fanout_jobs

# CLO-27: Cloning fanout_child_a clones parent + child_a only (2 jobs), not siblings
echo "--- Test CLO-27: clone-job fanout_child_a clones only 2 jobs ---"
tag="clone27"
run_clone_both "${tag}" \
	"--within-instance http://localhost $FANOUT_CHILD_A_ID"
assert_capture_exits "${tag}" 0
assert_stdout_pattern "${tag}" "2 jobs have been created:"

wait_for_cloned_jobs "${tag}"

# Check that the 2 jobs are parent and child_a
_clo_27_pass=true
for _lbl in "perl" "zig"; do
    if [[ "$_lbl" == "perl" ]]; then _ids="$_CLONE_PERL_IDS"; else _ids="$_CLONE_ZIG_IDS"; fi
    _count=0
    for id in $_ids; do
        _test=$(container_exec openqa-cli api --host http://localhost "jobs/$id" 2>/dev/null | jq -r '.job.settings.TEST')
        if [[ "$_test" != "fanout_parent" && "$_test" != "fanout_child_a" ]]; then
            echo "  FAIL: $_lbl cloned unexpected job type $_test"
            _clo_27_pass=false
        fi
        _count=$((_count + 1))
    done
    if [[ "$_count" -gt 0 && "$_count" -ne 2 ]]; then
        echo "  FAIL: $_lbl cloned $_count jobs instead of 2"
        _clo_7_pass=false
    fi
done
if [[ "$_clo_27_pass" == "true" ]]; then echo "PASS"; else failed_tests=$((failed_tests + 1)); fi

# CLO-28: Cloning fanout_parent with --clone-children clones all 4 jobs
echo "--- Test CLO-28: clone-job parent with --clone-children ---"
tag="clone28"
run_clone_both "${tag}" \
	"--within-instance http://localhost --clone-children $FANOUT_PARENT_ID"
assert_capture_exits "${tag}" 0
assert_stdout_pattern "${tag}" "4 jobs have been created:"

wait_for_cloned_jobs "${tag}"

# CLO-29: Overrides on child_a clone don't leak to parent (same as M25 but confirms with different topology)
echo "--- Test CLO-29: clone-job child override doesn't leak to parent ---"
tag="clone29"
run_clone_both "${tag}" \
	"--within-instance http://localhost $FANOUT_CHILD_B_ID BUILD=fanout-override"
assert_capture_exits "${tag}" 0

wait_for_cloned_jobs "${tag}"

_m29_pass=true
for _lbl in "perl" "zig"; do
    if [[ "$_lbl" == "perl" ]]; then _ids="$_CLONE_PERL_IDS"; else _ids="$_CLONE_ZIG_IDS"; fi
    for id in $_ids; do
        _test=$(container_exec openqa-cli api --host http://localhost "jobs/$id" 2>/dev/null | jq -r '.job.settings.TEST')
        _build=$(container_exec openqa-cli api --host http://localhost "jobs/$id" 2>/dev/null | jq -r '.job.settings.BUILD')
        if [[ "$_test" == "fanout_parent" && "$_build" == "fanout-override" ]]; then
            echo "  FAIL: $_lbl parent got BUILD=fanout-override (should be untouched)"
            _m29_pass=false
        elif [[ "$_test" == "fanout_child_b" && "$_build" != "fanout-override" ]]; then
            echo "  FAIL: $_lbl child got BUILD=$_build (should be fanout-override)"
            _m29_pass=false
        fi
    done
done
if [[ "$_m29_pass" == "true" ]]; then echo "PASS"; else failed_tests=$((failed_tests + 1)); fi

# =============================================================================
# Multi-layer Topology Tests (CLO-30 to CLO-33, CLO-39)
# =============================================================================
ensure_multilayer_jobs

# CLO-30: Cloning layer_child clones all 3
echo "--- Test CLO-30: clone-job layer_child clones all 3 ancestors ---"
run_clone_both "clone30" \
	"--within-instance http://localhost $LAYER_CHILD_ID"
assert_capture_exits "clone30" 0
assert_stdout_pattern "clone30" "3 jobs have been created:"

wait_for_cloned_jobs "clone30"

# CLO-31: Dependency chain preserved
echo "--- Test CLO-31: Multi-layer dependency chain preserved ---"
_m31_pass=true
for _lbl in "perl" "zig"; do
    if [[ "$_lbl" == "perl" ]]; then _ids="$_CLONE_PERL_IDS"; else _ids="$_CLONE_ZIG_IDS"; fi
    _new_grandparent=""
    _new_parent=""
    _new_child=""
    for id in $_ids; do
        _test=$(container_exec openqa-cli api --host http://localhost "jobs/$id" 2>/dev/null | jq -r '.job.settings.TEST')
        case "$_test" in
            layer_grandparent) _new_grandparent=$id ;;
            layer_parent)      _new_parent=$id ;;
            layer_child)       _new_child=$id ;;
        esac
    done

    if [[ -n "$_new_child" && -n "$_new_parent" && -n "$_new_grandparent" ]]; then
        if ! assert_job_has_chained_parent "$_new_child" "$_new_parent"; then
            _m31_pass=false
        fi
        if ! assert_job_has_chained_parent "$_new_parent" "$_new_grandparent"; then
            _m31_pass=false
        fi
    else
        echo "  FAIL: $_lbl missing one or more layers in clone output"
        _m31_pass=false
    fi
done
if [[ "$_m31_pass" == "true" ]]; then echo "PASS"; else failed_tests=$((failed_tests + 1)); fi

# CLO-32: Override at child only (depth 1)
echo "--- Test CLO-32: Multi-layer depth-based override isolation ---"
run_clone_both "clone32" \
	"--within-instance http://localhost $LAYER_CHILD_ID BUILD=layer-override"
assert_capture_exits "clone32" 0

wait_for_cloned_jobs "clone32"

_m32_pass=true
for _lbl in "perl" "zig"; do
    if [[ "$_lbl" == "perl" ]]; then _ids="$_CLONE_PERL_IDS"; else _ids="$_CLONE_ZIG_IDS"; fi
    for id in $_ids; do
        _test=$(container_exec openqa-cli api --host http://localhost "jobs/$id" 2>/dev/null | jq -r '.job.settings.TEST')
        _build=$(container_exec openqa-cli api --host http://localhost "jobs/$id" 2>/dev/null | jq -r '.job.settings.BUILD')
        if [[ "$_test" != "layer_child" && "$_build" == "layer-override" ]]; then
            echo "  FAIL: $_lbl $_test got BUILD=layer-override (should be untouched)"
            _m32_pass=false
        elif [[ "$_test" == "layer_child" && "$_build" != "layer-override" ]]; then
            echo "  FAIL: $_lbl child got BUILD=$_build (should be layer-override)"
            _m32_pass=false
        fi
    done
done
if [[ "$_m32_pass" == "true" ]]; then echo "PASS"; else failed_tests=$((failed_tests + 1)); fi

# CLO-33: --parental-inheritance propagates to all ancestors
echo "--- Test CLO-33: Multi-layer --parental-inheritance ---"
run_clone_both "clone33" \
	"--within-instance http://localhost --parental-inheritance $LAYER_CHILD_ID BUILD=inherit-all"
assert_capture_exits "clone33" 0

wait_for_cloned_jobs "clone33"

_m33_pass=true
for _lbl in "perl" "zig"; do
    if [[ "$_lbl" == "perl" ]]; then _ids="$_CLONE_PERL_IDS"; else _ids="$_CLONE_ZIG_IDS"; fi
    for id in $_ids; do
        _build=$(container_exec openqa-cli api --host http://localhost "jobs/$id" 2>/dev/null | jq -r '.job.settings.BUILD')
        if [[ "$_build" != "inherit-all" ]]; then
            echo "  FAIL: $_lbl job $id got BUILD=$_build (should be inherit-all)"
            _m33_pass=false
        fi
    done
done
if [[ "$_m33_pass" == "true" ]]; then echo "PASS"; else failed_tests=$((failed_tests + 1)); fi

# CLO-39: --skip-chained-deps on layer_child (grouped here; uses LAYER_CHILD_ID)
echo "--- Test CLO-39: Multi-layer --skip-chained-deps ---"
run_clone_both "clone39" \
	"--within-instance http://localhost --skip-chained-deps $LAYER_CHILD_ID"
assert_capture_exits "clone39" 0
assert_stdout_pattern "clone39" "1 job has been created:"

wait_for_cloned_jobs "clone39"

# =============================================================================
# Diamond Topology Tests (CLO-34 to CLO-38)
# =============================================================================
ensure_diamond_jobs

# CLO-34: Cloning diamond_merge clones all 4 jobs
echo "--- Test CLO-34: clone-job diamond_merge clones all 4 jobs ---"
run_clone_both "clone34" \
	"--within-instance http://localhost $DIAMOND_MERGE_ID"
assert_capture_exits "clone34" 0
assert_stdout_pattern "clone34" "4 jobs have been created:"

wait_for_cloned_jobs "clone34"

# CLO-35: Check dependencies of the merged diamond
echo "--- Test CLO-35: Diamond merge dependencies preserved ---"
_m35_pass=true
for _lbl in "perl" "zig"; do
    if [[ "$_lbl" == "perl" ]]; then _ids="$_CLONE_PERL_IDS"; else _ids="$_CLONE_ZIG_IDS"; fi
    _new_root=""
    _new_left=""
    _new_right=""
    _new_merge=""
    for id in $_ids; do
        _test=$(container_exec openqa-cli api --host http://localhost "jobs/$id" 2>/dev/null | jq -r '.job.settings.TEST')
        case "$_test" in
            diamond_root)  _new_root=$id ;;
            diamond_left)  _new_left=$id ;;
            diamond_right) _new_right=$id ;;
            diamond_merge) _new_merge=$id ;;
        esac
    done

    if [[ -n "$_new_merge" && -n "$_new_left" && -n "$_new_right" && -n "$_new_root" ]]; then
        if ! assert_job_has_chained_parent "$_new_merge" "$_new_left"; then _m35_pass=false; fi
        if ! assert_job_has_chained_parent "$_new_merge" "$_new_right"; then _m35_pass=false; fi
        if ! assert_job_has_chained_parent "$_new_left" "$_new_root"; then _m35_pass=false; fi
        if ! assert_job_has_chained_parent "$_new_right" "$_new_root"; then _m35_pass=false; fi
    else
        echo "  FAIL: $_lbl missing one or more diamond nodes in clone output"
        _m35_pass=false
    fi
done
if [[ "$_m35_pass" == "true" ]]; then echo "PASS"; else failed_tests=$((failed_tests + 1)); fi

# CLO-36: Cycle prevention is already tested by M34 successfully returning 4 jobs
# instead of infinite looping, but we can note it.

# CLO-37: Override doesn't reach root
echo "--- Test CLO-37: Diamond override isolation ---"
run_clone_both "clone37" \
	"--within-instance http://localhost $DIAMOND_MERGE_ID BUILD=diamond-override"
assert_capture_exits "clone37" 0

wait_for_cloned_jobs "clone37"

# CLO-38: --skip-deps on diamond
echo "--- Test CLO-38: Diamond --skip-deps ---"
run_clone_both "clone38" \
	"--within-instance http://localhost --skip-deps $DIAMOND_MERGE_ID"
assert_capture_exits "clone38" 0
assert_stdout_pattern "clone38" "1 job has been created:"

wait_for_cloned_jobs "clone38"

# =============================================================================
# Section M-Parallel: Parallel Topology Tests (CLO-41 to CLO-42)
#
# Parallel clusters require two simultaneous workers. Start worker instance 2
# here and stop it after M42 so the extra process exists only for this section.
# =============================================================================
start_worker2
ensure_parallel_jobs

echo "--- Test CLO-41: clone-job parallel_child clones parallel_parent ---"
run_clone_both "clone41" \
	"--within-instance http://localhost $PARALLEL_CHILD_ID"
assert_capture_exits "clone41" 0
assert_stdout_pattern "clone41" "2 jobs have been created:"

wait_for_cloned_jobs "clone41"

echo "--- Test CLO-42: clone-job parallel_parent with --clone-children clones parallel_child ---"
run_clone_both "clone42" \
	"--within-instance http://localhost --clone-children $PARALLEL_PARENT_ID"
assert_capture_exits "clone42" 0
assert_stdout_pattern "clone42" "2 jobs have been created:"

wait_for_cloned_jobs "clone42"
stop_worker2
