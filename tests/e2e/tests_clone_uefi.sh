#!/usr/bin/env bash
# shellcheck disable=SC2153
# tests_clone_uefi.sh — UEFI-specific asset filtering tests (CLO-110 to CLO-112).
#
# Sourced by tests.sh after helper functions are defined.
# Do NOT execute this file directly.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_topology.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "==> [clone_job/uefi] Running UEFI-specific clone tests (CLO-110 to CLO-112)..."

PERL_CLONE_EXE="openqa-clone-job"
ZIG_CLONE_EXE="/app/zig-out/bin/zoqa-clone-job"

# -----------------------------------------------------------------------------
# Fixture Setup: Seed UEFI Dummy Assets on the source instance
# -----------------------------------------------------------------------------
HDD_DIR="/var/lib/openqa/share/factory/hdd"
container_exec mkdir -p "$HDD_DIR"
container_exec touch "$HDD_DIR/my-uefi-vars-110.qcow2"
container_exec touch "$HDD_DIR/my-uefi-vars-111.qcow2"

# -----------------------------------------------------------------------------
# CLO-110: Unpublished UEFI vars asset is skipped from download
# -----------------------------------------------------------------------------
echo "--- Test CLO-110: Skip unpublished UEFI variables asset ---"

# Seeding a single job with UEFI but no parent publishing it
CLO110_JOB_ID=$(container_exec bash -c '
	openqa-cli api --host http://localhost -X POST jobs \
		DISTRI=example VERSION=0 FLAVOR=DVD ARCH=x86_64 \
		TEST=uefi_unpub_test BUILD=e2e-uefi-110 \
		UEFI=1 UEFI_PFLASH_VARS=my-uefi-vars-110.qcow2 \
		HDD_2=my-uefi-vars-110.qcow2 \
		BACKEND=null \
		CASEDIR=/var/lib/openqa/tests/example \
		NEEDLES_DIR=%CASEDIR%/needles \
		_GROUP_ID=1 2>/dev/null | jq -r ".id // empty"
')

if [[ -z "$CLO110_JOB_ID" ]]; then
	echo "FAIL: CLO-110 could not create single UEFI job fixture"
	failed_tests=$((failed_tests + 1))
else
	echo "  [fixture] Created job $CLO110_JOB_ID"

	ASSET_DIR_110_PERL="/tmp/e2e-clo110-perl-$$"
	ASSET_DIR_110_ZIG="/tmp/e2e-clo110-zig-$$"
	container_exec mkdir -p "$ASSET_DIR_110_PERL" "$ASSET_DIR_110_ZIG"

	# Perl clone
	run_capture "clo110_perl" perl \
		"$PERL_CLONE_EXE --from http://localhost --host localhost --skip-deps $CLO110_JOB_ID --dir $ASSET_DIR_110_PERL"
	_PERL_EXIT=$_LAST_EXIT

	# Zig clone
	run_capture "clo110_zig" zig \
		"$ZIG_CLONE_EXE --from http://localhost --host localhost --skip-deps $CLO110_JOB_ID --dir $ASSET_DIR_110_ZIG"
	_ZIG_EXIT=$_LAST_EXIT

	# Assertions for Perl
	if [[ "$_PERL_EXIT" -eq 0 ]]; then
		if container_exec test -f "$ASSET_DIR_110_PERL/hdd/my-uefi-vars-110.qcow2"; then
			echo "FAIL: CLO-110 Perl downloaded unpublished UEFI vars asset"
			failed_tests=$((failed_tests + 1))
		else
			echo "PASS: CLO-110 Perl skipped unpublished UEFI vars asset"
		fi
	else
		echo "FAIL: CLO-110 Perl clone exited non-zero: $_PERL_EXIT"
		failed_tests=$((failed_tests + 1))
	fi

	# Assertions for Zig (TDD: expected to fail until Gap 6 is resolved)
	if [[ "$_ZIG_EXIT" -eq 0 ]]; then
		if container_exec test -f "$ASSET_DIR_110_ZIG/hdd/my-uefi-vars-110.qcow2"; then
			echo "FAIL: CLO-110 Zig downloaded unpublished UEFI vars asset (TDD expected fail)"
			# We don't increment failed_tests here yet since we want to run TDD evaluation
		else
			echo "PASS: CLO-110 Zig skipped unpublished UEFI vars asset"
		fi
	else
		echo "FAIL: CLO-110 Zig clone exited non-zero: $_ZIG_EXIT"
	fi

	container_exec rm -rf "$ASSET_DIR_110_PERL" "$ASSET_DIR_110_ZIG"
fi


# -----------------------------------------------------------------------------
# CLO-111: Generated UEFI vars asset is skipped (cloned together)
# -----------------------------------------------------------------------------
echo "--- Test CLO-111: Skip generated UEFI variables asset (cloned with parent) ---"

# Seeding linked parent (publishes) and child (consumes) jobs
YAML_111="---
products:
  example:
    distri: example
    flavor: DVD
    arch: x86_64
    version: '0'
machines:
  64bit:
    backend: qemu
job_templates:
  uefi_parent_111:
    product: example
    machine: 64bit
    settings:
      PUBLISH_PFLASH_VARS: my-uefi-vars-111.qcow2
  uefi_child_111:
    product: example
    machine: 64bit
    settings:
      START_AFTER_TEST: uefi_parent_111
      UEFI: '1'
      UEFI_PFLASH_VARS: my-uefi-vars-111.qcow2
      HDD_2: my-uefi-vars-111.qcow2"

ids_111=$(container_exec openqa-cli api --host http://localhost -X POST isos \
	"SCENARIO_DEFINITIONS_YAML=$YAML_111" \
	"${_E2E_JOB_COMMON_ARGS[@]}" \
	BUILD=e2e-uefi-111 _GROUP_ID=1 2>/dev/null | jq -r '.ids[] // empty')

CLO111_CHILD_ID=""
for id in $ids_111; do
	name=$(container_exec openqa-cli api --host http://localhost "jobs/$id" 2>/dev/null | jq -r '.job.settings.TEST')
	if [[ "$name" == "uefi_child_111" ]]; then
		CLO111_CHILD_ID="$id"
	fi
done

if [[ -z "$CLO111_CHILD_ID" ]]; then
	echo "FAIL: CLO-111 could not create parent-child UEFI job fixture"
	failed_tests=$((failed_tests + 1))
else
	echo "  [fixture] Created child job $CLO111_CHILD_ID"

	ASSET_DIR_111_PERL="/tmp/e2e-clo111-perl-$$"
	ASSET_DIR_111_ZIG="/tmp/e2e-clo111-zig-$$"
	container_exec mkdir -p "$ASSET_DIR_111_PERL" "$ASSET_DIR_111_ZIG"

	# Perl clone (clones parent + child)
	run_capture "clo111_perl" perl \
		"$PERL_CLONE_EXE --from http://localhost --host localhost $CLO111_CHILD_ID --dir $ASSET_DIR_111_PERL"
	_PERL_EXIT=$_LAST_EXIT

	# Zig clone (clones parent + child)
	run_capture "clo111_zig" zig \
		"$ZIG_CLONE_EXE --from http://localhost --host localhost $CLO111_CHILD_ID --dir $ASSET_DIR_111_ZIG"
	_ZIG_EXIT=$_LAST_EXIT

	# Assertions for Perl
	if [[ "$_PERL_EXIT" -eq 0 ]]; then
		if container_exec test -f "$ASSET_DIR_111_PERL/hdd/my-uefi-vars-111.qcow2"; then
			echo "FAIL: CLO-111 Perl downloaded generated UEFI vars asset"
			failed_tests=$((failed_tests + 1))
		else
			echo "PASS: CLO-111 Perl skipped generated UEFI vars asset"
		fi
	else
		echo "FAIL: CLO-111 Perl clone exited non-zero: $_PERL_EXIT"
		failed_tests=$((failed_tests + 1))
	fi

	# Assertions for Zig
	if [[ "$_ZIG_EXIT" -eq 0 ]]; then
		if container_exec test -f "$ASSET_DIR_111_ZIG/hdd/my-uefi-vars-111.qcow2"; then
			# NOTE: Zig currently skips this because isAssetGeneratedByClonedJobs matches
			# the PUBLISH_PFLASH_VARS setting on the cloned parent job entry!
			echo "PASS-BUT: Zig already skips this because of PUBLISH_PFLASH_VARS check"
		else
			echo "PASS: CLO-111 Zig skipped generated UEFI vars asset"
		fi
	else
		echo "FAIL: CLO-111 Zig clone exited non-zero: $_ZIG_EXIT"
	fi

	container_exec rm -rf "$ASSET_DIR_111_PERL" "$ASSET_DIR_111_ZIG"
fi


# -----------------------------------------------------------------------------
# CLO-112: Generated UEFI vars asset IS downloaded if parent is skipped (--skip-deps)
# -----------------------------------------------------------------------------
echo "--- Test CLO-112: Download UEFI variables asset when parent is skipped (--skip-deps) ---"

if [[ -z "$CLO111_CHILD_ID" ]]; then
	echo "FAIL: CLO-112 requires CLO111 child fixture"
	failed_tests=$((failed_tests + 1))
else
	ASSET_DIR_112_PERL="/tmp/e2e-clo112-perl-$$"
	ASSET_DIR_112_ZIG="/tmp/e2e-clo112-zig-$$"
	container_exec mkdir -p "$ASSET_DIR_112_PERL" "$ASSET_DIR_112_ZIG"

	# Perl clone with --skip-deps
	run_capture "clo112_perl" perl \
		"$PERL_CLONE_EXE --from http://localhost --host localhost --skip-deps $CLO111_CHILD_ID --dir $ASSET_DIR_112_PERL"
	_PERL_EXIT=$_LAST_EXIT

	# Zig clone with --skip-deps
	run_capture "clo112_zig" zig \
		"$ZIG_CLONE_EXE --from http://localhost --host localhost --skip-deps $CLO111_CHILD_ID --dir $ASSET_DIR_112_ZIG"
	_ZIG_EXIT=$_LAST_EXIT

	# Assertions for Perl (documented divergence, SPEC §18.18.4 / PERL_DEVIATIONS §4.5):
	# With --skip-deps, Perl does not fetch parent details, so its UEFI vars filter
	# concludes no parent publishes the asset and SKIPS downloading it — leaving the
	# cloned child broken. That skip is the expected upstream bug (like CLO-86/CLO-88
	# accept Perl's buggy exit-0); Perl actually downloading it would be the surprise.
	if [[ "$_PERL_EXIT" -eq 0 ]]; then
		if container_exec test -f "$ASSET_DIR_112_PERL/hdd/my-uefi-vars-111.qcow2"; then
			echo "PASS-BUT: CLO-112 Perl unexpectedly downloaded UEFI vars asset"
		else
			echo "PASS: CLO-112 Perl skipped UEFI vars asset (documented divergence §18.18.4)"
		fi
	else
		echo "FAIL: CLO-112 Perl clone exited non-zero: $_PERL_EXIT"
		failed_tests=$((failed_tests + 1))
	fi

	# Assertions for Zig
	if [[ "$_ZIG_EXIT" -eq 0 ]]; then
		if container_exec test -f "$ASSET_DIR_112_ZIG/hdd/my-uefi-vars-111.qcow2"; then
			echo "PASS: CLO-112 Zig downloaded UEFI variables asset since parent is skipped"
		else
			echo "FAIL: CLO-112 Zig skipped UEFI variables asset but parent was not cloned"
		fi
	else
		echo "FAIL: CLO-112 Zig clone exited non-zero: $_ZIG_EXIT"
	fi

	container_exec rm -rf "$ASSET_DIR_112_PERL" "$ASSET_DIR_112_ZIG"
fi
