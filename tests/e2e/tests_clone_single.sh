#!/usr/bin/env bash
# shellcheck disable=SC2153
# test_clone_single.sh — Single-job clone tests (CLO-12 to CLO-17, M43–M44, CLO-50 to CLO-83).
#
# All tests in this file operate on a single base job ($JOB_ID) produced by
# ensure_basic_job, plus CLO-80–83 which create their own phantom fixture job.
# No graph-topology fixtures (chained, fanout, multilayer, …) are needed.
#
# Sourced by tests.sh after helper functions are defined.
# Do NOT execute this file directly.
#
# Goal: every test here is a PERL vs ZIG comparison against the same input,
# using the upstream `openqa-clone-job` Perl script as the behavioural oracle
# for our new `zoqa-clone-job` Zig binary.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_topology.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "==> [clone_job/single] Running single-job clone tests (CLO-12–17, M43–M44, CLO-50–83)..."

# Local binary handles — different from the global PERL_EXE/ZIG_EXE which
# point at openqa-cli / zoqa.
PERL_CLONE_EXE="openqa-clone-job"
ZIG_CLONE_EXE="/app/zig-out/bin/zoqa-clone-job"

# =============================================================================
# Section Real: Real API Interaction Tests (CLO-12 to CLO-17)
# =============================================================================
#
# These tests make real HTTP calls against the live openQA container seeded
# by run.sh.  All M12+ tests clone an existing completed job, verify the
# clone output, and check job settings via the API.
#
# Single-worker constraint: clone-job itself is fast (one API call); the
# CLONED job runs in the container queue. We wait for each batch of cloned
# jobs to finish before scheduling more, so the worker is always free.

# Ensure a completed base job exists (idempotent; sets and exports $JOB_ID).
ensure_basic_job

# CLO-12: --within-instance exits 0 for a known job.
tag="CLO-12_with-instance_exit0"
run_clone_both "$tag" \
	"--within-instance http://localhost $JOB_ID"
assert_capture_exits "$tag" 0

# CLO-13: stdout from CLO-12 contains a creation message and a job URL.
assert_stdout_pattern "$tag" "has been created"
assert_stdout_pattern "$tag" 'http://localhost/tests/[0-9]+'

# CLO-14: The cloned job has CLONED_FROM = http://localhost/tests/$JOB_ID.
# Wait for both CLO12 clones to finish first (single worker, sequential queue).
wait_for_cloned_jobs "$tag"

_clo14_pass=true
_clo14_expected="http://localhost/tests/$JOB_ID"
for _lbl_ids in "perl:$_CLONE_PERL_IDS" "zig:$_CLONE_ZIG_IDS"; do
	_impl="${_lbl_ids%%:*}"
	_new_id=$(echo "${_lbl_ids##*:}" | head -n1)
	if [[ -z "$_new_id" ]]; then
		echo "  FAIL: could not determine $_impl cloned job ID from M12 stdout"
		_clo14_pass=false
		continue
	fi
	_cloned_from=$(container_exec openqa-cli api --host http://localhost \
		"jobs/$_new_id" 2>/dev/null | jq -r '.job.settings.CLONED_FROM // empty')
	if [[ "$_cloned_from" != "$_clo14_expected" ]]; then
		echo "  FAIL: $_impl CLONED_FROM='$_cloned_from' (expected '$_clo14_expected')"
		_clo14_pass=false
	fi
done
if [[ "$_clo14_pass" == "true" ]]; then
	echo "PASS"
else
	failed_tests=$((failed_tests + 1))
fi

# CLO-15: Setting override — BUILD=e2e-clone-override is applied to the cloned job.
# Perl clone runs first and its job waits before Zig starts (single worker).
echo "--- Test M15: clone-job with BUILD override exits 0 ---"
run_capture "clone15" perl \
	"$PERL_CLONE_EXE --within-instance http://localhost $JOB_ID BUILD=e2e-clone-override"
_PERL_EXIT=$_LAST_EXIT
_m15_perl_new_id=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone15_perl_stdout.log" | head -1) || true
if [[ -n "$_m15_perl_new_id" ]]; then
	wait_for_job "$_m15_perl_new_id" 300 >/dev/null ||
		echo "  WARNING: timeout waiting for Perl M15 clone"
fi

run_capture "clone15" zig \
	"$ZIG_CLONE_EXE --within-instance http://localhost $JOB_ID BUILD=e2e-clone-override"
_ZIG_EXIT=$_LAST_EXIT
_m15_zig_new_id=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone15_zig_stdout.log" | head -1) || true
if [[ -n "$_m15_zig_new_id" ]]; then
	wait_for_job "$_m15_zig_new_id" 300 >/dev/null ||
		echo "  WARNING: timeout waiting for Zig M15 clone"
fi

assert_capture_exits "clone15" 0

echo "--- Test M15b: BUILD override is reflected in cloned job settings ---"
_m15b_pass=true
for _lbl_id in "perl:$_m15_perl_new_id" "zig:$_m15_zig_new_id"; do
	_impl="${_lbl_id%%:*}"
	_new_id="${_lbl_id##*:}"
	if [[ -z "$_new_id" ]]; then
		echo "  FAIL: could not determine $_impl cloned job ID from M15 stdout"
		_m15b_pass=false
		continue
	fi
	_build=$(container_exec openqa-cli api --host http://localhost \
		"jobs/$_new_id" 2>/dev/null | jq -r '.job.settings.BUILD // empty')
	if [[ "$_build" != "e2e-clone-override" ]]; then
		echo "  FAIL: $_impl clone BUILD='$_build' (expected 'e2e-clone-override')"
		_m15b_pass=false
	fi
done
if [[ "$_m15b_pass" == "true" ]]; then
	echo "PASS"
else
	failed_tests=$((failed_tests + 1))
fi

# CLO-16: Cloning a non-existent job exits non-zero.
echo "--- Test CLO-16: clone-job non-existent job 999999 exits non-zero ---"
run_test_exit_nonzero "PERL: clone-job non-existent job exits non-zero" "$PERL_CLONE_EXE --within-instance http://localhost 999999"
run_test_exit_nonzero "ZIG : clone-job non-existent job exits non-zero" "$ZIG_CLONE_EXE --within-instance http://localhost 999999"

# CLO-17: Explicit --from --host --skip-download flags (long-form equivalent of
# --within-instance).  Exercises flag parsing for the three-flag form.
echo "--- Test CLO-17: clone-job --from --host --skip-download exits 0 ---"
run_clone_both "clone17" \
	"--from http://localhost --host http://localhost --skip-download $JOB_ID"
assert_capture_exits "clone17" 0

# Wait for CLO-17 clones to avoid leaving running jobs that would block future suites.
_m17_perl_new_id=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone17_perl_stdout.log" | head -1) || true
if [[ -n "$_m17_perl_new_id" ]]; then
	wait_for_job "$_m17_perl_new_id" 300 >/dev/null ||
		echo "  WARNING: timeout waiting for Perl CLO-17 clone"
fi
_m17_zig_new_id=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/clone17_zig_stdout.log" | head -1) || true
if [[ -n "$_m17_zig_new_id" ]]; then
	wait_for_job "$_m17_zig_new_id" 300 >/dev/null ||
		echo "  WARNING: timeout waiting for Zig CLO-17 clone"
fi

# =============================================================================
# Section M-Host: Host Resolution Tests (M43–M44)
#
# Validates that zoqa-clone-job uses different host resolution rules from zoqa api:
#   - Bare "localhost" → http:// (not https://).  Matches Perl Client.pm:url_from_host.
#   - Bare non-localhost → https://.
# Contrast with test 41a in tests_core.sh where zoqa api bare "localhost" → https://.
# =============================================================================

echo "--- Test M43: bare --host localhost → http:// (clone succeeds) ---"
# Clone-job special-cases bare 'localhost' → http:// (not https://).
# The container serves openQA on http://localhost, so the clone should succeed.
# If normalizeHostUrl wrongly used https://, this would fail with a TLS error.
run_clone_both "clone43" \
	"--from http://localhost --host localhost --skip-download $JOB_ID"
assert_capture_exits "clone43" 0
assert_stdout_pattern "clone43" "http://localhost/tests/"

echo "--- Test M44: bare --host 127.0.0.1 → https:// → TLS error ---"
# 127.0.0.1 doesn't match the 'localhost' substring check, so gets https://.
# Container's HTTPS uses a self-signed cert → TLS handshake failure → exit non-zero.
# This mirrors test 41a in tests_core.sh but for the clone-job binary.
run_test_exit_nonzero "PERL: bare --host 127.0.0.1 → https:// → TLS error (exit non-zero)" \
	"$PERL_CLONE_EXE --from http://localhost --host 127.0.0.1 --skip-download $JOB_ID"
run_test_exit_nonzero "ZIG : bare --host 127.0.0.1 → https:// → TLS error (exit non-zero)" \
	"$ZIG_CLONE_EXE --from http://localhost --host 127.0.0.1 --skip-download $JOB_ID"

echo "--- Test CLO-50 CLO-54: --export-command ---"
tag="clone_export"
run_clone_both "${tag}" \
	"--within-instance http://localhost --export-command $JOB_ID BUILD=export-test"
assert_capture_exits "${tag}" 0

# Perl outputs openqa-cli api, Zig outputs zoqa api. Check logs directly on host.
if grep -q "openqa-cli api.*-X POST jobs" "$LOG_DIR/${tag}_perl_stdout.log"; then
	echo "PASS: Perl export-command outputs openqa-cli"
else
	echo "FAIL: Perl export-command outputs openqa-cli"
	failed_tests=$((failed_tests + 1))
fi

if grep -q "zoqa api.*-X POST jobs" "$LOG_DIR/${tag}_zig_stdout.log"; then
	echo "PASS: Zig export-command outputs zoqa api"
else
	echo "FAIL: Zig export-command outputs zoqa api"
	failed_tests=$((failed_tests + 1))
fi

if grep -q "BUILD:.*=export-test" "$LOG_DIR/clone_export_zig_stdout.log"; then
	echo "PASS: Zig export-command includes overrides"
else
	echo "FAIL: Zig export-command includes overrides"
	failed_tests=$((failed_tests + 1))
fi

# =============================================================================
# Test CLO-55 to CLO-M59: --reproduce
#
# Clones a job with the exact test code version and needles version of the original.
#
# Behavioral Oracle / Mapping rules:
#   1. Fetches `/tests/{id}/file/vars.json` from the source openQA instance.
#   2. Extracts the git repositories and specific commit hashes used at runtime:
#      - CASEDIR            <- TEST_GIT_URL (test suite git URL)
#      - TEST_GIT_REFSPEC   <- TEST_GIT_HASH (exact test suite commit hash)
#      - NEEDLES_DIR        <- NEEDLES_GIT_URL (needles git URL)
#      - NEEDLES_GIT_REFSPEC <- NEEDLES_GIT_HASH (exact needles commit hash)
#   3. Injects/appends these settings into the multi-job POST payload.
#   4. Custom CLI overrides specified by the user (e.g. KEY=VALUE) are processed
#      *after* this injection step, allowing manual overrides to take precedence.
# =============================================================================
echo "--- Test CLO-56: clone-job --reproduce exits 0 ---"
# Make sure the basic complete job exists
ensure_basic_job

# Intercept and modify the completed basic job's vars.json inside the container
# to inject valid git repositories and hashes. This allows us to test --reproduce
# offline without openQA attempting real git clones (which would hang/timeout).
if [[ "$DRY_RUN" != "true" ]]; then
	_vars_json_path=$(container_exec find /var/lib/openqa/testresults/ -name "vars.json" | grep -E "00000${JOB_ID}-" | head -n1)
	if [[ -n "$_vars_json_path" ]]; then
		container_exec jq \
			' .TEST_GIT_URL = "https://github.com/my-test-repo.git"
			| .TEST_GIT_HASH = "abcdef123456"
			| .NEEDLES_GIT_URL = "https://github.com/my-needles-repo.git"
			| .NEEDLES_GIT_HASH = "7890abcdef12" ' \
			"$_vars_json_path" > /tmp/vars.json.tmp
		podman cp /tmp/vars.json.tmp "${CONTAINER_NAME:?}:$_vars_json_path"
		rm -f /tmp/vars.json.tmp
	fi
fi

tag="clone_reproduce"
run_clone_both "$tag" \
        "--within-instance http://localhost --reproduce $JOB_ID"
assert_capture_exits "$tag" 0

echo "--- Test CLO-57: cloned job settings are correctly injected by --reproduce ---"
# =============================================================================
# How the CLO-57 Test Works, Where/How vars.json is Injected & Expected Failures:
#
# 1. WHERE/HOW WE INJECT DUMMY VALUES IN vars.json:
#    - Normally, passing remote Git settings when scheduling a test job causes openQA
#      to attempt a git checkout during the test run, which hangs/fails in our offline sandbox.
#    - To bypass this, we utilize the already completed, static JOB_ID.
#    - We locate its vars.json on the container's disk:
#      /var/lib/openqa/testresults/00000/00000${JOB_ID}-*/vars.json
#    - We run jq in the container to inject our custom mock git reference variables:
#      TEST_GIT_URL, TEST_GIT_HASH, NEEDLES_GIT_URL, NEEDLES_GIT_HASH
#    - We overwrite the container file by outputting to a host temp-file and copying it
#      back via "podman cp". This safely mocks a concluded job that ran via Git.
#
# 2. RETRIEVING THE JOB ID:
#    The newly created cloned job IDs are printed to stdout during step CLO-56.
#    We extract them directly from the logs using a positive lookbehind regex:
#    grep -oP '(?<=tests/)\d+' -> This matches digits following 'tests/' (e.g. 103).
#    Using "head -n1" isolates the first created clone ID for subsequent Web API checks.
#
# 3. WHY CLONED JOB EXECUTION IS EXPECTED TO FAIL (AND WHY IT IS OK):
#    - The vars.json of the parent job was seeded with fake/mock repository URLs:
#      https://github.com/my-test-repo.git and https://github.com/my-needles-repo.git
#    - Since the container operates in an isolated, offline network sandbox and these repos
#      are mocks, openQA's background scheduler (openqa-gru / Minion) will fail to run
#      "git clone" (exits 128) and keep the cloned job stuck in the 'scheduled' state.
#    - This failure is completely OK: our E2E test validates client-side behavior. The moment
#      the client POSTs the clone request, openQA immediately persists the mapped settings in the DB.
#      Therefore, we can inspect and verify the settings from the Web API immediately without waiting.
#
# 4. PERFORMING THE TEST:
#    We query GET "jobs/$_new_id" and parse the values with jq. We assert that:
#      - CASEDIR             -> https://github.com/my-test-repo.git
#      - TEST_GIT_REFSPEC    -> abcdef123456
#      - NEEDLES_DIR         -> https://github.com/my-needles-repo.git
#      - NEEDLES_GIT_REFSPEC -> 7890abcdef12
#
# 5. CLEANUP & CANCELLATION:
#    To prevent the background worker queue from continuously spinning on the failed git clones,
#    we cleanly cancel the stuck jobs immediately after verification:
#    POST jobs/$_new_id/cancel
# =============================================================================
_CLONE_PERL_IDS=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/${tag}_perl_stdout.log" || true)
_CLONE_ZIG_IDS=$(grep -oP '(?<=tests/)\d+' "$LOG_DIR/${tag}_zig_stdout.log" || true)

_reproduce_pass=true
for _lbl_ids in "perl:$_CLONE_PERL_IDS" "zig:$_CLONE_ZIG_IDS"; do
        _impl="${_lbl_ids%%:*}"
        _new_id=$(echo "${_lbl_ids##*:}" | head -n1)
        if [[ -z "$_new_id" ]]; then
                if [[ "$DRY_RUN" == "true" ]]; then
                        continue
                fi
                echo "  FAIL: could not determine $_impl cloned job ID from clone_reproduce stdout"
                _reproduce_pass=false
                continue
        fi
        _casedir=$(container_exec openqa-cli api --host http://localhost \
                "jobs/$_new_id" 2>/dev/null | jq -r '.job.settings.CASEDIR // empty')
        _test_git_refspec=$(container_exec openqa-cli api --host http://localhost \
                "jobs/$_new_id" 2>/dev/null | jq -r '.job.settings.TEST_GIT_REFSPEC // empty')
        _needles_dir=$(container_exec openqa-cli api --host http://localhost \
                "jobs/$_new_id" 2>/dev/null | jq -r '.job.settings.NEEDLES_DIR // empty')
        _needles_git_refspec=$(container_exec openqa-cli api --host http://localhost \
                "jobs/$_new_id" 2>/dev/null | jq -r '.job.settings.NEEDLES_GIT_REFSPEC // empty')

        if [[ "$_casedir" != "https://github.com/my-test-repo.git" ]]; then
                echo "  FAIL: $_impl CASEDIR='$_casedir' (expected 'https://github.com/my-test-repo.git')"
                _reproduce_pass=false
        fi
        if [[ "$_test_git_refspec" != "abcdef123456" ]]; then
                echo "  FAIL: $_impl TEST_GIT_REFSPEC='$_test_git_refspec' (expected 'abcdef123456')"
                _reproduce_pass=false
        fi
        if [[ "$_needles_dir" != "https://github.com/my-needles-repo.git" ]]; then
                echo "  FAIL: $_impl NEEDLES_DIR='$_needles_dir' (expected 'https://github.com/my-needles-repo.git')"
                _reproduce_pass=false
        fi
        if [[ "$_needles_git_refspec" != "7890abcdef12" ]]; then
                echo "  FAIL: $_impl NEEDLES_GIT_REFSPEC='$_needles_git_refspec' (expected '7890abcdef12')"
                _reproduce_pass=false
        fi

        # Clean up: cancel the stuck scheduled job so it doesn't pollute the container worker queue
        if [[ "$DRY_RUN" != "true" ]]; then
                container_exec openqa-cli api --host http://localhost -X POST "jobs/$_new_id/cancel" >/dev/null 2>&1 || true
        fi
done

if [[ "$_reproduce_pass" == "true" ]]; then
	echo "PASS"
else
	failed_tests=$((failed_tests + 1))
fi

echo "--- Test CLO-60 to CLO-63: --repeat ---"
run_clone_both "clone_repeat" \
	"--within-instance http://localhost --repeat 2 $JOB_ID"
assert_capture_exits "clone_repeat" 0

if [ "$(grep -c '1 job has been created:' "$LOG_DIR/clone_repeat_perl_stdout.log" || true)" -eq 2 ]; then
	echo "PASS: Perl repeat 2 creates 2 jobs"
else
	echo "FAIL: Perl repeat 2 creates 2 jobs"
	failed_tests=$((failed_tests + 1))
fi

if [ "$(grep -c '1 job has been created:' "$LOG_DIR/clone_repeat_zig_stdout.log" || true)" -eq 2 ]; then
	echo "PASS: Zig repeat 2 creates 2 jobs"
else
	echo "FAIL: Zig repeat 2 creates 2 jobs"
	failed_tests=$((failed_tests + 1))
fi

echo "--- Test CLO-65 to CLO-67: --badge ---"
run_clone_both "clone_badge" \
	"--within-instance http://localhost --badge $JOB_ID"
assert_capture_exits "clone_badge" 0
# Both should output markdown badge format `[![`
assert_stdout_pattern "clone_badge" "\[\!\["

echo "--- Test CLO-68 to CLO-70: --json-output ---"
run_clone_both "clone_json_output" \
	"--within-instance http://localhost --json-output $JOB_ID"
assert_capture_exits "clone_json_output" 0

# Validate non-empty valid JSON with at least one numeric value (new job ID).
if jq -e 'to_entries | length > 0' "$LOG_DIR/clone_json_output_perl_stdout.log" >/dev/null 2>&1; then
	echo "PASS: Perl json-output is valid non-empty JSON"
else
	echo "FAIL: Perl json-output is valid non-empty JSON"
	failed_tests=$((failed_tests + 1))
fi

if jq -e 'to_entries | length > 0' "$LOG_DIR/clone_json_output_zig_stdout.log" >/dev/null 2>&1; then
	echo "PASS: Zig json-output is valid non-empty JSON"
else
	echo "FAIL: Zig json-output is valid non-empty JSON"
	failed_tests=$((failed_tests + 1))
fi

set -x
echo "--- Test CLO-71 CLO-78: Asset download ---"
# --dir path must exist inside the container (commands run via container_exec).
# Use separate dirs so Perl's downloads don't mask Zig's absence.
ASSET_DIR_PERL="/tmp/e2e-assets-perl-$$"
ASSET_DIR_ZIG="/tmp/e2e-assets-zig-$$"
container_exec mkdir -p "$ASSET_DIR_PERL" "$ASSET_DIR_ZIG"
run_capture "clone_assets" perl \
        "$PERL_CLONE_EXE --from http://localhost --host localhost $JOB_ID --dir $ASSET_DIR_PERL"
_PERL_EXIT=$_LAST_EXIT

run_capture "clone_assets" zig \
        "$ZIG_CLONE_EXE --from http://localhost --host localhost $JOB_ID --dir $ASSET_DIR_ZIG"
_ZIG_EXIT=$_LAST_EXIT

assert_capture_exits "clone_assets" 0

# Verify Perl downloaded at least one asset file (HDD or ISO).
if container_exec find "$ASSET_DIR_PERL" -type f | grep -q .; then
	echo "PASS: Perl asset download produced files"
else
	echo "FAIL: Perl asset download produced files"
	failed_tests=$((failed_tests + 1))
fi

# Verify Zig downloaded at least one asset file.
if container_exec find "$ASSET_DIR_ZIG" -type f | grep -q .; then
	echo "PASS: Zig asset download produced files"
else
	echo "FAIL: Zig asset download produced files"
	failed_tests=$((failed_tests + 1))
fi

container_exec rm -rf "$ASSET_DIR_PERL" "$ASSET_DIR_ZIG"
set +x

# =============================================================================
# CLO-80 to CLO-83: --ignore-missing-assets
#
# CLO-80: Without --ignore-missing-assets, clone of a job with a non-existent
#      asset exits non-zero (both Perl and Zig should fail).
# CLO-81: WITH --ignore-missing-assets, Perl succeeds (exit 0).
# CLO-82: With the flag, stderr contains a warning about the missing asset (Perl).
# CLO-83: With the flag, stdout contains "has been created" (job POST succeeded).
# =============================================================================
echo "--- Test CLO-80 to CLO-83: --ignore-missing-assets ---"

# Fixture: create a job that references a non-existent ISO.
# POST directly to /api/v1/jobs so it appears in the DB with the phantom asset
# in its settings.  The job will be in 'scheduled' state but we don't need it
# to run — clone-job only fetches its settings.
MISSING_ASSET_JOB_ID=$(container_exec bash -c '
	openqa-cli api --host http://localhost -X POST jobs \
		DISTRI=example VERSION=0 FLAVOR=DVD ARCH=x86_64 \
		TEST=phantom_asset_test BUILD=e2e-phantom \
		ISO_1=phantom-nonexist-e2e.iso \
		BACKEND=null \
		CASEDIR=/var/lib/openqa/tests/example \
		NEEDLES_DIR=%CASEDIR%/needles \
		_GROUP_ID=1 2>/dev/null | jq -r ".id // empty"
')

if [[ -z "$MISSING_ASSET_JOB_ID" ]]; then
	echo "FAIL: could not create fixture job with missing asset"
	failed_tests=$((failed_tests + 1))
else
	echo "  [fixture] Created job $MISSING_ASSET_JOB_ID with phantom ISO"

	# CLO-80: Without --ignore-missing-assets, both should exit non-zero.
	tag="clo-80"
	echo "--- Test CLO-80: clone missing-asset job WITHOUT flag → exit non-zero ---"
	ASSET_DIR_CLO_80_PERL="/tmp/e2e-${tag}-perl-$$"
	ASSET_DIR_CLO_80_ZIG="/tmp/e2e-${tag}-zig-$$"
	container_exec mkdir -p "$ASSET_DIR_CLO_80_PERL" "$ASSET_DIR_CLO_80_ZIG"

	run_capture "${tag}" perl \
		"$PERL_CLONE_EXE --from http://localhost --host http://localhost --skip-deps $MISSING_ASSET_JOB_ID --dir $ASSET_DIR_CLO_80_PERL"
	_PERL_EXIT=$_LAST_EXIT
	run_capture "${tag}" zig \
		"$ZIG_CLONE_EXE --from http://localhost --host http://localhost --skip-deps $MISSING_ASSET_JOB_ID --dir $ASSET_DIR_CLO_80_ZIG"
	_ZIG_EXIT=$_LAST_EXIT

	if [[ "$_PERL_EXIT" -ne 0 ]]; then
		echo "PASS: Perl exits non-zero without --ignore-missing-assets"
	else
		echo "FAIL: Perl exits non-zero without --ignore-missing-assets (got $_PERL_EXIT)"
		failed_tests=$((failed_tests + 1))
	fi
	if [[ "$_ZIG_EXIT" -ne 0 ]]; then
		echo "PASS: Zig exits non-zero without --ignore-missing-assets"
	else
		echo "FAIL: Zig exits non-zero without --ignore-missing-assets (got $_ZIG_EXIT)"
		failed_tests=$((failed_tests + 1))
	fi

	container_exec rm -rf "$ASSET_DIR_CLO_80_PERL" "$ASSET_DIR_CLO_80_ZIG"

	# CLO-81: WITH --ignore-missing-assets, Perl continues and creates the job.
	echo "--- Test CLO-81: clone missing-asset job WITH flag → exit 0 ---"
	tag="clo-81"
	ASSET_DIR_CLO_81_PERL="/tmp/e2e-${tag}-perl-$$"
	ASSET_DIR_CLO_81_ZIG="/tmp/e2e-${tag}-zig-$$"
	container_exec mkdir -p "$ASSET_DIR_CLO_81_PERL" "$ASSET_DIR_CLO_81_ZIG"

	run_clone_both "${tag}" \
	"--from http://localhost --host http://localhost --skip-deps --ignore-missing-assets $MISSING_ASSET_JOB_ID --dir $ASSET_DIR_CLO_81_PERL"

	if [[ "$_PERL_EXIT" -eq 0 ]]; then
		echo "PASS: Perl exits 0 with --ignore-missing-assets"
	else
		echo "FAIL: Perl exits 0 with --ignore-missing-assets (got $_PERL_EXIT)"
		cat "$LOG_DIR/${tag}_perl_stderr.log"
		failed_tests=$((failed_tests + 1))
	fi
	if [[ "$_ZIG_EXIT" -eq 0 ]]; then
		echo "PASS: Zig exits 0 with --ignore-missing-assets"
	else
		echo "FAIL: Zig exits 0 with --ignore-missing-assets (got $_ZIG_EXIT)"
		cat "$LOG_DIR/${tag}_zig_stderr.log"
		failed_tests=$((failed_tests + 1))
	fi

	# =====================================================================
	# CLO-82 & CLO-83: Verification of Output/Error Logs with --ignore-missing-assets
	#
	# Implementation Note:
	#   We use the dynamic variable "${tag}" (which evaluates to "clo-81") as the
	#   first parameter for assert_impl_log_pattern because the clone commands
	#   were executed above under that exact tag. This aligns our grep checks
	#   with the actual log files written to disk (e.g. clo-81_perl_stderr.log).
	# =====================================================================

	# CLO-82: With the flag, stderr contains a warning about the missing asset.
	echo "--- Test CLO-82: stderr warns about missing asset ---"
	assert_impl_log_pattern "${tag}" perl stderr "missing|phantom-nonexist|skipping|unavailable" "Perl stderr mentions missing asset"
	assert_impl_log_pattern "${tag}" zig stderr  "missing|phantom-nonexist|skipping|unavailable" "Zig  stderr mentions missing asset"

	# CLO-83: With the flag, stdout shows job was created (POST succeeded).
	echo "--- Test CLO-83: stdout shows job created ---"
	assert_impl_log_pattern "${tag}" perl stdout "has been created" "Perl stdout has 'has been created'"
	assert_impl_log_pattern "${tag}" zig  stdout "has been created" "Zig  stdout has 'has been created'"

	container_exec rm -rf "$ASSET_DIR_CLO_81_PERL" "$ASSET_DIR_CLO_81_ZIG"
fi
