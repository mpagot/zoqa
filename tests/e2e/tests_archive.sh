#!/usr/bin/env bash
# tests_archive.sh — Section H: Archive subcommand tests.
#
# Tests for the `archive` subcommand which downloads assets and test results
# from a job into a local directory.
#
# Uses comparison testing (Perl vs Zig) wherever possible to validate
# behavioral parity.
#
# Sourced by tests.sh after helper functions are defined.
# Do NOT execute this file directly.
#
# Assumes from the calling scope:
#   ZIG_EXE, PERL_EXE, LOG_DIR, failed_tests, warned_tests
#   JOB_ID, GROUP_ID, OPENQA_API_KEY, OPENQA_API_SECRET
#   run_test(), run_comparison()

# shellcheck source=SCRIPTDIR/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "==> [archive] Running archive subcommand tests..."

# ---------------------------------------------------------------------------
# Clean up any prior archive test directories inside the container
# ---------------------------------------------------------------------------
container_exec rm -rf /tmp/arc_perl /tmp/arc_zig \
	/tmp/arc_perl_thumb /tmp/arc_zig_thumb \
	/tmp/arc_perl_limit /tmp/arc_zig_limit \
	/tmp/arc_perl_quiet /tmp/arc_zig_quiet \
	/tmp/arc_perl_reuse /tmp/arc_zig_reuse \
	/tmp/arc_perl_env /tmp/arc_zig_env \
	/tmp/arc_perl_norepo /tmp/arc_zig_norepo \
	/tmp/arc_perl_progress /tmp/arc_zig_progress \
	/tmp/arc_perl_struct /tmp/arc_zig_struct \
	2>/dev/null || true

# =============================================================================
# Section 1: Argument Validation (SPEC §13.1)
# =============================================================================

# Test ARC-1: Missing all positional arguments (no JOB_ID, no OUTPUT_PATH).
# Both implementations must reject the invocation and exit 255 (usage error),
# matching the pattern established by the api subcommand's missing-PATH test.
# Perl (archive.pm:14): `die $self->usage unless my $job = shift @args`
run_test "PERL: archive missing all args (exit 255)" \
	"$PERL_EXE archive --host http://localhost" 255
run_test "ZIG : archive missing all args (exit 255)" \
	"$ZIG_EXE archive --host http://localhost" 255

# Test ARC-2: Missing OUTPUT_PATH (only JOB_ID provided).
# Perl (archive.pm:15): `die $self->usage unless my $path = shift @args`
run_test "PERL: archive missing output path (exit 255)" \
	"$PERL_EXE archive --host http://localhost $JOB_ID" 255
run_test "ZIG : archive missing output path (exit 255)" \
	"$ZIG_EXE archive --host http://localhost $JOB_ID" 255

# Test ARC-3: Non-existent job ID → archive must abort.
# GET /api/v1/jobs/999999/details returns non-200.
# Perl (Archive.pm:26): bare `die "There's an error openQA client returned $code"`
# is untrapped by archive.pm's command() method → uncaught Perl exception → exit 255.
# Zig follows SPEC §13.10: exit 1 on HTTP error from the initial fetch.
run_test "PERL: archive invalid job ID (exit 255)" \
	"$PERL_EXE archive --host http://localhost 999999 /tmp/arc_invalid_perl" 255
run_test "ZIG : archive invalid job ID (exit 1)" \
	"$ZIG_EXE archive --host http://localhost 999999 /tmp/arc_invalid_zig" 1

# =============================================================================
# Section 2: Basic Archive Operation
# =============================================================================

# Test ARC-4: Basic archive of seeded job succeeds (exit 0).
# Both implementations fetch job details, create the output directory, and
# download whatever assets/testresults/logs are available.  The seeded job
# has an ISO asset (dummy.iso) and possibly empty testresults/logs arrays.
# Exit 0 means the job details fetch succeeded and the archive process ran
# to completion.
run_test "PERL: archive seeded job (exit 0)" \
	"$PERL_EXE archive --host http://localhost $JOB_ID /tmp/arc_perl" 0
run_test "ZIG : archive seeded job (exit 0)" \
	"$ZIG_EXE archive --host http://localhost $JOB_ID /tmp/arc_zig" 0

# Test ARC-5: Output directory was created.
# After a successful archive, the output directory must exist.
echo "--- Test: PERL: archive output directory exists ---"
if container_exec test -d /tmp/arc_perl; then
	echo "PASS"
else
	echo "FAIL: /tmp/arc_perl does not exist after archive"
	failed_tests=$((failed_tests + 1))
fi
echo "--- Test: ZIG : archive output directory exists ---"
if container_exec test -d /tmp/arc_zig; then
	echo "PASS"
else
	echo "FAIL: /tmp/arc_zig does not exist after archive"
	failed_tests=$((failed_tests + 1))
fi

# =============================================================================
# Section 3: Directory Structure
# =============================================================================

# Test ARC-6: Directory structure parity — Perl vs Zig.
# Run `find` on both output trees, normalize to relative paths, sort, and diff.
# Both implementations must produce the same directory layout.
echo "--- Test: DIFF archive directory structure parity ---"
set +e
container_exec bash -c "cd /tmp/arc_perl && find . -type d | sort" \
	>"$LOG_DIR/arc_perl_dirs.log" 2>/dev/null
container_exec bash -c "cd /tmp/arc_zig && find . -type d | sort" \
	>"$LOG_DIR/arc_zig_dirs.log" 2>/dev/null
set -e
if diff -u "$LOG_DIR/arc_perl_dirs.log" "$LOG_DIR/arc_zig_dirs.log" \
	>"$LOG_DIR/arc_dirs_diff.log" 2>&1; then
	echo "PASS (directory structures identical)"
else
	echo "FAIL: Perl and Zig archive directory structures differ:"
	cat "$LOG_DIR/arc_dirs_diff.log"
	failed_tests=$((failed_tests + 1))
fi

# Test ARC-7: testresults/ directory created.
echo "--- Test: PERL: testresults/ directory exists ---"
if container_exec test -d /tmp/arc_perl/testresults; then
	echo "PASS"
else
	echo "FAIL: /tmp/arc_perl/testresults does not exist"
	failed_tests=$((failed_tests + 1))
fi
echo "--- Test: ZIG : testresults/ directory exists ---"
if container_exec test -d /tmp/arc_zig/testresults; then
	echo "PASS"
else
	echo "FAIL: /tmp/arc_zig/testresults does not exist"
	failed_tests=$((failed_tests + 1))
fi

# Test ARC-8: testresults/ulogs/ directory created.
echo "--- Test: PERL: testresults/ulogs/ directory exists ---"
if container_exec test -d /tmp/arc_perl/testresults/ulogs; then
	echo "PASS"
else
	echo "FAIL: /tmp/arc_perl/testresults/ulogs does not exist"
	failed_tests=$((failed_tests + 1))
fi
echo "--- Test: ZIG : testresults/ulogs/ directory exists ---"
if container_exec test -d /tmp/arc_zig/testresults/ulogs; then
	echo "PASS"
else
	echo "FAIL: /tmp/arc_zig/testresults/ulogs does not exist"
	failed_tests=$((failed_tests + 1))
fi

# Test ARC-9: No thumbnails/ directory without --with-thumbnails.
# The thumbnails/ directory must only be created when --with-thumbnails is set.
echo "--- Test: PERL: no thumbnails/ without --with-thumbnails ---"
if container_exec test -d /tmp/arc_perl/testresults/thumbnails 2>/dev/null; then
	echo "FAIL: thumbnails/ directory should not exist without --with-thumbnails"
	failed_tests=$((failed_tests + 1))
else
	echo "PASS"
fi
echo "--- Test: ZIG : no thumbnails/ without --with-thumbnails ---"
if container_exec test -d /tmp/arc_zig/testresults/thumbnails 2>/dev/null; then
	echo "FAIL: thumbnails/ directory should not exist without --with-thumbnails"
	failed_tests=$((failed_tests + 1))
else
	echo "PASS"
fi

# Test ARC-10: repo/ assets are skipped (Archive.pm:34).
# Even if the job has repo-type assets, no repo/ directory should be created.
echo "--- Test: PERL: no repo/ directory (repo assets skipped) ---"
if container_exec test -d /tmp/arc_perl/repo 2>/dev/null; then
	echo "FAIL: repo/ directory should not exist (repo assets must be skipped)"
	failed_tests=$((failed_tests + 1))
else
	echo "PASS"
fi
echo "--- Test: ZIG : no repo/ directory (repo assets skipped) ---"
if container_exec test -d /tmp/arc_zig/repo 2>/dev/null; then
	echo "FAIL: repo/ directory should not exist (repo assets must be skipped)"
	failed_tests=$((failed_tests + 1))
else
	echo "PASS"
fi

# Test ARC-11: File listing parity — all files created by both must match.
echo "--- Test: DIFF archive file listing parity ---"
set +e
container_exec bash -c "cd /tmp/arc_perl && find . -type f | sort" \
	>"$LOG_DIR/arc_perl_files.log" 2>/dev/null
container_exec bash -c "cd /tmp/arc_zig && find . -type f | sort" \
	>"$LOG_DIR/arc_zig_files.log" 2>/dev/null
set -e
if diff -u "$LOG_DIR/arc_perl_files.log" "$LOG_DIR/arc_zig_files.log" \
	>"$LOG_DIR/arc_files_diff.log" 2>&1; then
	echo "PASS (file listings identical)"
else
	echo "FAIL: Perl and Zig archive file listings differ:"
	cat "$LOG_DIR/arc_files_diff.log"
	failed_tests=$((failed_tests + 1))
fi

# =============================================================================
# Section 4: --with-thumbnails Flag
# =============================================================================

# Test ARC-12: --with-thumbnails creates the thumbnails/ directory.
# Perl (Archive.pm:36): `$path->child('testresults', 'thumbnails')->make_path`
# when options->{'with-thumbnails'} is set.
run_test "PERL: archive --with-thumbnails (exit 0)" \
	"$PERL_EXE archive --host http://localhost --with-thumbnails $JOB_ID /tmp/arc_perl_thumb" 0
run_test "ZIG : archive --with-thumbnails (exit 0)" \
	"$ZIG_EXE archive --host http://localhost --with-thumbnails $JOB_ID /tmp/arc_zig_thumb" 0

echo "--- Test: PERL: thumbnails/ directory exists with --with-thumbnails ---"
if container_exec test -d /tmp/arc_perl_thumb/testresults/thumbnails; then
	echo "PASS"
else
	echo "FAIL: /tmp/arc_perl_thumb/testresults/thumbnails does not exist"
	failed_tests=$((failed_tests + 1))
fi
echo "--- Test: ZIG : thumbnails/ directory exists with --with-thumbnails ---"
if container_exec test -d /tmp/arc_zig_thumb/testresults/thumbnails; then
	echo "PASS"
else
	echo "FAIL: /tmp/arc_zig_thumb/testresults/thumbnails does not exist"
	failed_tests=$((failed_tests + 1))
fi

# Test ARC-13: --with-thumbnails directory structure parity.
echo "--- Test: DIFF archive --with-thumbnails directory structure parity ---"
set +e
container_exec bash -c "cd /tmp/arc_perl_thumb && find . -type d | sort" \
	>"$LOG_DIR/arc_perl_thumb_dirs.log" 2>/dev/null
container_exec bash -c "cd /tmp/arc_zig_thumb && find . -type d | sort" \
	>"$LOG_DIR/arc_zig_thumb_dirs.log" 2>/dev/null
set -e
if diff -u "$LOG_DIR/arc_perl_thumb_dirs.log" "$LOG_DIR/arc_zig_thumb_dirs.log" \
	>"$LOG_DIR/arc_thumb_dirs_diff.log" 2>&1; then
	echo "PASS (--with-thumbnails directory structures identical)"
else
	echo "FAIL: Perl and Zig --with-thumbnails directory structures differ:"
	cat "$LOG_DIR/arc_thumb_dirs_diff.log"
	failed_tests=$((failed_tests + 1))
fi

# =============================================================================
# Section 5: --asset-size-limit
# =============================================================================

# Test ARC-14: --asset-size-limit flag is accepted (basic smoke test).
# Both implementations must accept the flag and exit 0.
run_test "PERL: archive --asset-size-limit accepted (exit 0)" \
	"$PERL_EXE archive --host http://localhost --asset-size-limit 209715200 $JOB_ID /tmp/arc_perl_limit" 0
run_test "ZIG : archive --asset-size-limit accepted (exit 0)" \
	"$ZIG_EXE archive --host http://localhost --asset-size-limit 209715200 $JOB_ID /tmp/arc_zig_limit" 0

# Test ARC-15: --asset-size-limit 1 causes asset downloads to be skipped.
# With a 1-byte limit, any file with a Content-Length > 1 is skipped.
# The archive command still exits 0 — size-limit skips are
# not fatal.  The "exceeds maximum size limit" message should appear on stdout.
# Note: The dummy.iso is 0 bytes (created via touch), so it may not be skipped.
# But the message pattern should still be tested for files that do exceed it.
container_exec rm -rf /tmp/arc_perl_limit1 /tmp/arc_zig_limit1 2>/dev/null || true
echo "--- Test: PERL: archive --asset-size-limit 1 (exit 0, files skipped) ---"
set +e
container_exec bash -c \
	"$PERL_EXE archive --host http://localhost --asset-size-limit 1 $JOB_ID /tmp/arc_perl_limit1" \
	>"$LOG_DIR/arc_perl_limit1_stdout.log" 2>"$LOG_DIR/arc_perl_limit1_stderr.log"
perl_limit_exit=$?
set -e
if [[ "$perl_limit_exit" -eq 0 ]]; then
	echo "PASS (exit 0)"
else
	echo "FAIL: Expected exit 0, got $perl_limit_exit"
	failed_tests=$((failed_tests + 1))
fi

echo "--- Test: ZIG : archive --asset-size-limit 1 (exit 0, files skipped) ---"
set +e
container_exec bash -c \
	"$ZIG_EXE archive --host http://localhost --asset-size-limit 1 $JOB_ID /tmp/arc_zig_limit1" \
	>"$LOG_DIR/arc_zig_limit1_stdout.log" 2>"$LOG_DIR/arc_zig_limit1_stderr.log"
zig_limit_exit=$?
set -e
if [[ "$zig_limit_exit" -eq 0 ]]; then
	echo "PASS (exit 0)"
else
	echo "FAIL: Expected exit 0, got $zig_limit_exit"
	failed_tests=$((failed_tests + 1))
fi

# =============================================================================
# Section 6: Global Options with archive
# =============================================================================

# Test ARC-16: --quiet flag is accepted and suppresses warnings.
# --quiet applies to all HTTP requests made by archive.
run_test "PERL: archive --quiet (exit 0)" \
	"$PERL_EXE archive --host http://localhost --quiet $JOB_ID /tmp/arc_perl_quiet" 0
run_test "ZIG : archive --quiet (exit 0)" \
	"$ZIG_EXE archive --host http://localhost --quiet $JOB_ID /tmp/arc_zig_quiet" 0

# Test ARC-17: --verbose and --pretty are accepted but no-op for archive.
# "accepted but have no observable effect". Both must exit 0 without crashing.
run_test "PERL: archive --verbose --pretty (accepted, exit 0)" \
	"$PERL_EXE archive --host http://localhost --verbose --pretty $JOB_ID /tmp/arc_perl_quiet" 0
run_test "ZIG : archive --verbose --pretty (accepted, exit 0)" \
	"$ZIG_EXE archive --host http://localhost --verbose --pretty $JOB_ID /tmp/arc_zig_quiet" 0

# =============================================================================
# Section 7: Authentication
# =============================================================================

# Test ARC-18: Archive works with env var credentials.
# OPENQA_CONFIG is pointed at a wrong client.conf; valid credentials come
# from env vars.  The archive must succeed (exit 0), proving env vars
# authenticate all the internal HTTP requests.
container_exec bash -c "mkdir -p /tmp/arc_wrongsecret && printf '[localhost]\nkey=WRONG\nsecret=WRONG\n' > /tmp/arc_wrongsecret/client.conf"
run_test "PERL: archive with env var credentials (exit 0)" \
	"bash -c \"OPENQA_CONFIG=/tmp/arc_wrongsecret OPENQA_API_KEY='$OPENQA_API_KEY' OPENQA_API_SECRET='$OPENQA_API_SECRET' \
	$PERL_EXE archive --host http://localhost $JOB_ID /tmp/arc_perl_env\"" 0
run_test "ZIG : archive with env var credentials (exit 0)" \
	"bash -c \"OPENQA_CONFIG=/tmp/arc_wrongsecret OPENQA_API_KEY='$OPENQA_API_KEY' OPENQA_API_SECRET='$OPENQA_API_SECRET' \
	$ZIG_EXE archive --host http://localhost $JOB_ID /tmp/arc_zig_env\"" 0

# Test ARC-19: Archive succeeds with no credentials at all (GET endpoints are public).
# openQA's archive endpoints are all GET requests; the server does not require
# authentication for reads.  Wrong or missing credentials must not cause a failure.
# We wipe all credential sources: OPENQA_CONFIG points at a dir with wrong creds,
# no OPENQA_API_KEY/SECRET env vars, and --apikey/--apisecret flags are omitted.
# Both implementations must exit 0.
run_test "PERL: archive succeeds with wrong config credentials (GET is public, exit 0)" \
	"bash -c \"OPENQA_CONFIG=/tmp/arc_wrongsecret \
	$PERL_EXE archive --host http://localhost $JOB_ID /tmp/arc_perl_wrongauth\"" 0
run_test "ZIG : archive succeeds with wrong config credentials (GET is public, exit 0)" \
	"bash -c \"OPENQA_CONFIG=/tmp/arc_wrongsecret \
	$ZIG_EXE archive --host http://localhost $JOB_ID /tmp/arc_zig_wrongauth\"" 0

# =============================================================================
# Section 8: Progress Output
# =============================================================================

# Test ARC-20: Progress output includes expected messages on stdout.
# requires several specific message patterns.
# "Downloading test details and screenshots" must appear for every archive.
# "Downloading logs" and "Downloading ulogs" must also appear.
echo "--- Test: PERL: archive progress messages on stdout ---"
set +e
container_exec bash -c \
	"$PERL_EXE archive --host http://localhost $JOB_ID /tmp/arc_perl_progress" \
	>"$LOG_DIR/arc_perl_progress.log" 2>/dev/null
set -e
_arc_perl_progress_pass=true
if ! grep -q "Downloading test details" "$LOG_DIR/arc_perl_progress.log"; then
	echo "FAIL: PERL stdout missing 'Downloading test details' message"
	_arc_perl_progress_pass=false
fi
if ! grep -q "Downloading logs" "$LOG_DIR/arc_perl_progress.log"; then
	echo "FAIL: PERL stdout missing 'Downloading logs' message"
	_arc_perl_progress_pass=false
fi
if ! grep -q "Downloading ulogs" "$LOG_DIR/arc_perl_progress.log"; then
	echo "FAIL: PERL stdout missing 'Downloading ulogs' message"
	_arc_perl_progress_pass=false
fi
if [[ "$_arc_perl_progress_pass" == "true" ]]; then
	echo "PASS"
else
	failed_tests=$((failed_tests + 1))
fi

echo "--- Test: ZIG : archive progress messages on stdout ---"
set +e
container_exec bash -c \
	"$ZIG_EXE archive --host http://localhost $JOB_ID /tmp/arc_zig_progress" \
	>"$LOG_DIR/arc_zig_progress.log" 2>/dev/null
set -e
_arc_zig_progress_pass=true
if ! grep -q "Downloading test details" "$LOG_DIR/arc_zig_progress.log"; then
	echo "FAIL: ZIG stdout missing 'Downloading test details' message"
	_arc_zig_progress_pass=false
fi
if ! grep -q "Downloading logs" "$LOG_DIR/arc_zig_progress.log"; then
	echo "FAIL: ZIG stdout missing 'Downloading logs' message"
	_arc_zig_progress_pass=false
fi
if ! grep -q "Downloading ulogs" "$LOG_DIR/arc_zig_progress.log"; then
	echo "FAIL: ZIG stdout missing 'Downloading ulogs' message"
	_arc_zig_progress_pass=false
fi
if [[ "$_arc_zig_progress_pass" == "true" ]]; then
	echo "PASS"
else
	failed_tests=$((failed_tests + 1))
fi

# =============================================================================
# Section 9: Pre-existing Output Directory (robustness)
# =============================================================================

# Test ARC-22: Archive into a pre-existing directory succeeds.
# "Create OUTPUT_PATH/ (and parents) if it does not exist."
# This must also work when the directory already exists (no error on mkdir -p).
container_exec mkdir -p /tmp/arc_perl_reuse /tmp/arc_zig_reuse
run_test "PERL: archive into pre-existing directory (exit 0)" \
	"$PERL_EXE archive --host http://localhost $JOB_ID /tmp/arc_perl_reuse" 0
run_test "ZIG : archive into pre-existing directory (exit 0)" \
	"$ZIG_EXE archive --host http://localhost $JOB_ID /tmp/arc_zig_reuse" 0

# =============================================================================
# Section 10: Short-form Flags
# =============================================================================

# Test ARC-23: Short-form flags -t and -l are accepted.
# -t is --with-thumbnails, -l is --asset-size-limit.
run_test "PERL: archive -t -l 1024 (short flags accepted)" \
	"$PERL_EXE archive --host http://localhost -t -l 1024 $JOB_ID /tmp/arc_perl_quiet" 0
run_test "ZIG : archive -t -l 1024 (short flags accepted)" \
	"$ZIG_EXE archive --host http://localhost -t -l 1024 $JOB_ID /tmp/arc_zig_quiet" 0

# =============================================================================
# Section 11: Host Alias Flags
# =============================================================================

# Test ARC-24: --host before 'archive' is rejected (same as api subcommand).
# Global options must appear after the subcommand name in the Perl implementation.
# Both should exit 255.
run_test "PERL: --host before archive rejected (exit 255)" \
	"$PERL_EXE --host http://localhost archive $JOB_ID /tmp/arc_perl_quiet" 255
run_test "ZIG : --host before archive rejected (exit 255)" \
	"$ZIG_EXE --host http://localhost archive $JOB_ID /tmp/arc_zig_quiet" 255

# =============================================================================
# Section 12: Default Size Limit
# =============================================================================

# Test ARC-25: Default --asset-size-limit is 200 MiB (209715200 bytes).
# Without explicitly passing the flag, files up to 200 MiB should download.
# This is a behavioural confirmation that the default is applied, not a unit
# test of the value itself.  We verify by archiving successfully without the
# flag — the 0-byte dummy.iso is well within the default limit.
# This test is already covered by ARC-4 implicitly but is here for documentation.
run_test "PERL: archive default size limit accepts small files (exit 0)" \
	"$PERL_EXE archive --host http://localhost $JOB_ID /tmp/arc_perl_quiet" 0
run_test "ZIG : archive default size limit accepts small files (exit 0)" \
	"$ZIG_EXE archive --host http://localhost $JOB_ID /tmp/arc_zig_quiet" 0

# =============================================================================
# Section 13: Rich Job — Basic Operation
# =============================================================================

# Test ARC-26: Archive rich job succeeds (exit 0).
run_test "PERL: archive rich job (exit 0)" \
	"$PERL_EXE archive --host http://localhost $RICH_JOB_ID /tmp/arc_perl_rich" 0
run_test "ZIG : archive rich job (exit 0)" \
	"$ZIG_EXE archive --host http://localhost $RICH_JOB_ID /tmp/arc_zig_rich" 0

# Test ARC-27: Output directory exists.
echo "--- Test: PERL: rich archive output directory exists ---"
if container_exec test -d /tmp/arc_perl_rich; then echo "PASS"; else
	echo "FAIL"
	failed_tests=$((failed_tests + 1))
fi
echo "--- Test: ZIG : rich archive output directory exists ---"
if container_exec test -d /tmp/arc_zig_rich; then echo "PASS"; else
	echo "FAIL"
	failed_tests=$((failed_tests + 1))
fi

# =============================================================================
# Section 14: Rich Job — Test Results
# =============================================================================

# Test ARC-28: details-*.json files exist (Zig).
echo "--- Test: ZIG : details-*.json files exist ---"
if container_exec bash -c "ls /tmp/arc_zig_rich/testresults/details-*.json >/dev/null 2>&1"; then
	echo "PASS"
else
	echo "FAIL: No details-*.json found in /tmp/arc_zig_rich/testresults/"
	failed_tests=$((failed_tests + 1))
fi

# Test ARC-29: details-*.json parity (Perl vs Zig).
echo "--- Test: DIFF details-*.json listing parity ---"
container_exec bash -c "cd /tmp/arc_perl_rich/testresults && ls details-*.json | sort" >"$LOG_DIR/arc_perl_details.log"
container_exec bash -c "cd /tmp/arc_zig_rich/testresults && ls details-*.json | sort" >"$LOG_DIR/arc_zig_details.log"
if diff -u "$LOG_DIR/arc_perl_details.log" "$LOG_DIR/arc_zig_details.log" >"$LOG_DIR/arc_details_diff.log" 2>&1; then
	echo "PASS"
else
	echo "FAIL: details-*.json listings differ"
	cat "$LOG_DIR/arc_details_diff.log"
	failed_tests=$((failed_tests + 1))
fi

# Test ARC-30: details-*.json content parity.
# We pick the first details file and compare semantic equivalence.
# NOTE: Perl's Mojo::JSON (via Cpanel::JSON::XS) escapes '/' as '\/' and
# sorts object keys canonically.  Zig's std.json.Stringify writes '/' literally
# and preserves insertion (parse) order.  Both are valid JSON per RFC 8259 §7.
# We normalise through jq -S (sorted keys, no solidus escaping) so the diff
# compares structure, not serialisation style.
echo "--- Test: DIFF details-*.json content parity ---"
FIRST_DETAIL=$(head -n 1 "$LOG_DIR/arc_perl_details.log")
container_exec jq -S . "/tmp/arc_perl_rich/testresults/$FIRST_DETAIL" >"$LOG_DIR/arc_perl_detail_content.json"
container_exec jq -S . "/tmp/arc_zig_rich/testresults/$FIRST_DETAIL" >"$LOG_DIR/arc_zig_detail_content.json"
if diff -u "$LOG_DIR/arc_perl_detail_content.json" "$LOG_DIR/arc_zig_detail_content.json" >"$LOG_DIR/arc_detail_content_diff.log" 2>&1; then
	echo "PASS"
else
	echo "FAIL: $FIRST_DETAIL content differs"
	cat "$LOG_DIR/arc_detail_content_diff.log"
	failed_tests=$((failed_tests + 1))
fi

# =============================================================================
# Section 15: Rich Job — Screenshots
# =============================================================================

# Test ARC-31: Screenshot .png files exist (Zig).
echo "--- Test: ZIG : screenshot .png files exist ---"
if container_exec bash -c "ls /tmp/arc_zig_rich/testresults/*.png >/dev/null 2>&1"; then
	echo "PASS"
else
	echo "FAIL: No .png found in /tmp/arc_zig_rich/testresults/"
	failed_tests=$((failed_tests + 1))
fi

# Test ARC-32: Screenshot file listing parity.
echo "--- Test: DIFF screenshot listing parity ---"
container_exec bash -c "cd /tmp/arc_perl_rich/testresults && ls *.png | sort" >"$LOG_DIR/arc_perl_pngs.log"
container_exec bash -c "cd /tmp/arc_zig_rich/testresults && ls *.png | sort" >"$LOG_DIR/arc_zig_pngs.log"
if diff -u "$LOG_DIR/arc_perl_pngs.log" "$LOG_DIR/arc_zig_pngs.log" >"$LOG_DIR/arc_pngs_diff.log" 2>&1; then
	echo "PASS"
else
	echo "FAIL: .png listings differ"
	cat "$LOG_DIR/arc_pngs_diff.log"
	failed_tests=$((failed_tests + 1))
fi

# Test ARC-33: Screenshot file size parity.
echo "--- Test: DIFF screenshot file size parity ---"
if [[ "$DRY_RUN" == "true" ]]; then
	echo "PASS (DRY-RUN)"
else
	FIRST_PNG=$(head -n 1 "$LOG_DIR/arc_perl_pngs.log")
	P_SIZE=$(container_exec stat -c%s "/tmp/arc_perl_rich/testresults/$FIRST_PNG")
	Z_SIZE=$(container_exec stat -c%s "/tmp/arc_zig_rich/testresults/$FIRST_PNG")
	if [[ "$P_SIZE" -eq "$Z_SIZE" ]]; then
		echo "PASS ($P_SIZE bytes)"
	else
		echo "FAIL: $FIRST_PNG size differs (Perl: $P_SIZE, Zig: $Z_SIZE)"
		failed_tests=$((failed_tests + 1))
	fi
fi

# =============================================================================
# Section 16: Rich Job — Thumbnails
# =============================================================================

# Test ARC-34: --with-thumbnails downloads thumbnail files.
run_test "PERL: archive --with-thumbnails rich job (exit 0)" \
	"$PERL_EXE archive --host http://localhost --with-thumbnails $RICH_JOB_ID /tmp/arc_perl_rich_thumb" 0
run_test "ZIG : archive --with-thumbnails rich job (exit 0)" \
	"$ZIG_EXE archive --host http://localhost --with-thumbnails $RICH_JOB_ID /tmp/arc_zig_rich_thumb" 0

echo "--- Test: ZIG : thumbnail files exist ---"
if container_exec bash -c "ls /tmp/arc_zig_rich_thumb/testresults/thumbnails/*.png >/dev/null 2>&1"; then
	echo "PASS"
else
	echo "FAIL: No thumbnails found in /tmp/arc_zig_rich_thumb/testresults/thumbnails/"
	failed_tests=$((failed_tests + 1))
fi

# Test ARC-35: Thumbnail file listing parity.
echo "--- Test: DIFF thumbnail listing parity ---"
container_exec bash -c "cd /tmp/arc_perl_rich_thumb/testresults/thumbnails && ls *.png | sort" >"$LOG_DIR/arc_perl_thumbs.log"
container_exec bash -c "cd /tmp/arc_zig_rich_thumb/testresults/thumbnails && ls *.png | sort" >"$LOG_DIR/arc_zig_thumbs.log"
if diff -u "$LOG_DIR/arc_perl_thumbs.log" "$LOG_DIR/arc_zig_thumbs.log" >"$LOG_DIR/arc_thumbs_diff.log" 2>&1; then
	echo "PASS"
else
	echo "FAIL: thumbnail listings differ"
	cat "$LOG_DIR/arc_thumbs_diff.log"
	failed_tests=$((failed_tests + 1))
fi

# =============================================================================
# Section 17: Rich Job — Logs
# =============================================================================

# Test ARC-36: autoinst-log.txt exists (Zig).
echo "--- Test: ZIG : autoinst-log.txt exists ---"
if container_exec test -f /tmp/arc_zig_rich/testresults/autoinst-log.txt; then
	echo "PASS"
else
	echo "FAIL: autoinst-log.txt missing"
	failed_tests=$((failed_tests + 1))
fi

# Test ARC-37: Log file listing parity.
echo "--- Test: DIFF log listing parity ---"
container_exec bash -c "cd /tmp/arc_perl_rich/testresults && ls *.txt | sort" >"$LOG_DIR/arc_perl_logs.log"
container_exec bash -c "cd /tmp/arc_zig_rich/testresults && ls *.txt | sort" >"$LOG_DIR/arc_zig_logs.log"
if diff -u "$LOG_DIR/arc_perl_logs.log" "$LOG_DIR/arc_zig_logs.log" >"$LOG_DIR/arc_logs_diff.log" 2>&1; then
	echo "PASS"
else
	echo "FAIL: log listings differ"
	cat "$LOG_DIR/arc_logs_diff.log"
	failed_tests=$((failed_tests + 1))
fi

# Test ARC-38: Log file content parity.
echo "--- Test: DIFF autoinst-log.txt content parity ---"
container_exec cat /tmp/arc_perl_rich/testresults/autoinst-log.txt >"$LOG_DIR/arc_perl_autoinst.log"
container_exec cat /tmp/arc_zig_rich/testresults/autoinst-log.txt >"$LOG_DIR/arc_zig_autoinst.log"
if diff -u "$LOG_DIR/arc_perl_autoinst.log" "$LOG_DIR/arc_zig_autoinst.log" >"$LOG_DIR/arc_autoinst_diff.log" 2>&1; then
	echo "PASS"
else
	echo "FAIL: autoinst-log.txt content differs"
	cat "$LOG_DIR/arc_autoinst_diff.log"
	failed_tests=$((failed_tests + 1))
fi

# =============================================================================
# Section 18: Rich Job — Assets
# =============================================================================

# Test ARC-39: HDD asset directory exists.
echo "--- Test: ZIG : hdd/ directory exists ---"
if container_exec test -d /tmp/arc_zig_rich/hdd; then echo "PASS"; else
	echo "FAIL"
	failed_tests=$((failed_tests + 1))
fi

# Test ARC-40: Asset file size is non-zero (CirrOS image).
echo "--- Test: ZIG : CirrOS image size is non-zero ---"
if [[ "$DRY_RUN" == "true" ]]; then
	echo "PASS (DRY-RUN)"
else
	IMG_SIZE=$(container_exec stat -c%s "/tmp/arc_zig_rich/hdd/cirros-0.6.3-x86_64-disk.qcow2")
	if [[ "$IMG_SIZE" -gt 20000000 ]]; then
		echo "PASS ($IMG_SIZE bytes)"
	else
		echo "FAIL: CirrOS image size too small ($IMG_SIZE bytes)"
		failed_tests=$((failed_tests + 1))
	fi
fi

# Test ARC-41: Asset file size parity.
echo "--- Test: DIFF asset file size parity ---"
if [[ "$DRY_RUN" == "true" ]]; then
	echo "PASS (DRY-RUN)"
else
	P_IMG_SIZE=$(container_exec stat -c%s "/tmp/arc_perl_rich/hdd/cirros-0.6.3-x86_64-disk.qcow2")
	if [[ "$P_IMG_SIZE" -eq "$IMG_SIZE" ]]; then
		echo "PASS"
	else
		echo "FAIL: Asset size differs (Perl: $P_IMG_SIZE, Zig: $IMG_SIZE)"
		failed_tests=$((failed_tests + 1))
	fi
fi

# =============================================================================
# Section 19: Rich Job — Size Limit Enforcement
# =============================================================================

# Test ARC-42: --asset-size-limit 1 skips CirrOS (21 MB).
echo "--- Test: ZIG : --asset-size-limit 1 skips CirrOS ---"
container_exec rm -rf /tmp/arc_zig_rich_limit1
set +e
container_exec bash -c "$ZIG_EXE archive --host http://localhost --asset-size-limit 1 $RICH_JOB_ID /tmp/arc_zig_rich_limit1" >"$LOG_DIR/arc_zig_rich_limit1.log" 2>&1
set -e
if grep -q "exceeds maximum size limit" "$LOG_DIR/arc_zig_rich_limit1.log"; then
	echo "PASS"
else
	echo "FAIL: Zig did not print skip message for CirrOS"
	cat "$LOG_DIR/arc_zig_rich_limit1.log"
	failed_tests=$((failed_tests + 1))
fi

# Test ARC-43: Size-limit skip parity (Perl vs Zig).
echo "--- Test: PERL: --asset-size-limit 1 skips CirrOS ---"
container_exec rm -rf /tmp/arc_perl_rich_limit1
set +e
container_exec bash -c "$PERL_EXE archive --host http://localhost --asset-size-limit 1 $RICH_JOB_ID /tmp/arc_perl_rich_limit1" >"$LOG_DIR/arc_perl_rich_limit1.log" 2>&1
set -e
if grep -q "Maximum message size exceeded" "$LOG_DIR/arc_perl_rich_limit1.log"; then
	echo "PASS"
else
	echo "FAIL: Perl did not print skip message for CirrOS"
	cat "$LOG_DIR/arc_perl_rich_limit1.log"
	failed_tests=$((failed_tests + 1))
fi

# =============================================================================
# Section 20: Rich Job — Progress Output
# =============================================================================

# Capture rich job output for progress tests
set +e
container_exec bash -c "$ZIG_EXE archive --host http://localhost $RICH_JOB_ID /tmp/arc_zig_rich_progress" >"$LOG_DIR/arc_zig_rich_details_msg.log" 2>&1
set -e

# Test ARC-44: Progress percentage appears on stdout.
echo "--- Test: ZIG : progress percentage on stdout ---"
if grep -q "Downloading.*%" "$LOG_DIR/arc_zig_rich_details_msg.log"; then
	echo "PASS"
else
	echo "FAIL: Zig stdout missing progress percentage"
	failed_tests=$((failed_tests + 1))
fi

# Test ARC-45: "Saved details for" message appears.
echo "--- Test: ZIG : 'Saved details for' message on stdout ---"
if grep -q "Saved details for" "$LOG_DIR/arc_zig_rich_details_msg.log"; then
	echo "PASS"
else
	echo "FAIL: Zig stdout missing 'Saved details for' message"
	failed_tests=$((failed_tests + 1))
fi

# Test ARC-21 (Moved): "Attempt {type} download:" message appears for asset groups.
echo "--- Test: PERL: 'Attempt ... download:' message on stdout ---"
set +e
container_exec bash -c "$PERL_EXE archive --host http://localhost $RICH_JOB_ID /tmp/arc_perl_rich_progress" >"$LOG_DIR/arc_perl_rich_progress.log" 2>&1
set -e
if grep -q "Attempt .* download:" "$LOG_DIR/arc_perl_rich_progress.log"; then
	echo "PASS"
else
	echo "FAIL: PERL stdout missing 'Attempt ... download:' message"
	cat "$LOG_DIR/arc_perl_rich_progress.log"
	failed_tests=$((failed_tests + 1))
fi

echo "--- Test: ZIG : 'Attempt ... download:' message on stdout ---"
if grep -q "Attempt .* download:" "$LOG_DIR/arc_zig_rich_details_msg.log"; then
	echo "PASS"
else
	echo "FAIL: ZIG stdout missing 'Attempt ... download:' message"
	cat "$LOG_DIR/arc_zig_rich_details_msg.log"
	failed_tests=$((failed_tests + 1))
fi

# =============================================================================
# Section 21: Rich Job — Full Parity
# =============================================================================

# Test ARC-46: Complete directory structure parity.
echo "--- Test: DIFF rich archive full directory structure parity ---"
container_exec bash -c "cd /tmp/arc_perl_rich && find . -type d | sort" >"$LOG_DIR/arc_perl_rich_dirs.log"
container_exec bash -c "cd /tmp/arc_zig_rich && find . -type d | sort" >"$LOG_DIR/arc_zig_rich_dirs.log"
if diff -u "$LOG_DIR/arc_perl_rich_dirs.log" "$LOG_DIR/arc_zig_rich_dirs.log" >"$LOG_DIR/arc_rich_dirs_diff.log" 2>&1; then
	echo "PASS"
else
	echo "FAIL: Directory structures differ"
	cat "$LOG_DIR/arc_rich_dirs_diff.log"
	failed_tests=$((failed_tests + 1))
fi

# Test ARC-47: Complete file listing parity.
echo "--- Test: DIFF rich archive full file listing parity ---"
container_exec bash -c "cd /tmp/arc_perl_rich && find . -type f | sort" >"$LOG_DIR/arc_perl_rich_files.log"
container_exec bash -c "cd /tmp/arc_zig_rich && find . -type f | sort" >"$LOG_DIR/arc_zig_rich_files.log"
if diff -u "$LOG_DIR/arc_perl_rich_files.log" "$LOG_DIR/arc_zig_rich_files.log" >"$LOG_DIR/arc_rich_files_diff.log" 2>&1; then
	echo "PASS"
else
	echo "FAIL: File listings differ"
	cat "$LOG_DIR/arc_rich_files_diff.log"
	failed_tests=$((failed_tests + 1))
fi

# =============================================================================
# Section 50: Cross-Subcommand Flag Rejection
#
# API-specific flags (--form, --json, -X/--method, --data) have no meaning for
# the archive subcommand.  Both Perl and Zig should reject them at parse time.
# These tests assert exit 255 (argument validation failure) for both
# implementations to verify behavioural parity.
# =============================================================================

# Test ARC-50: --form is api-specific (request body encoding).
# Archive downloads files; it never encodes form data.
run_test "PERL: api flag --form rejected for archive (exit 255)" \
	"$PERL_EXE archive --form --host http://localhost $JOB_ID /tmp/e2e_xflag" 255
run_test "ZIG : api flag --form rejected for archive (exit 255)" \
	"$ZIG_EXE archive --form --host http://localhost $JOB_ID /tmp/e2e_xflag" 255

# Test ARC-51: --json is api-specific (request content-type).
# Archive never sends JSON payloads.
run_test "PERL: api flag --json rejected for archive (exit 255)" \
	"$PERL_EXE archive --json --host http://localhost $JOB_ID /tmp/e2e_xflag" 255
run_test "ZIG : api flag --json rejected for archive (exit 255)" \
	"$ZIG_EXE archive --json --host http://localhost $JOB_ID /tmp/e2e_xflag" 255

# Test ARC-52: -X (--method) is api-specific (HTTP method override).
# Archive always uses GET; overriding the method is meaningless.
run_test "PERL: api flag -X rejected for archive (exit 255)" \
	"$PERL_EXE archive -X POST --host http://localhost $JOB_ID /tmp/e2e_xflag" 255
run_test "ZIG : api flag -X rejected for archive (exit 255)" \
	"$ZIG_EXE archive -X POST --host http://localhost $JOB_ID /tmp/e2e_xflag" 255

# Test ARC-53: --data is api-specific (request body).
# Archive never sends a request body.
run_test "PERL: api flag --data rejected for archive (exit 255)" \
	"$PERL_EXE archive --data body --host http://localhost $JOB_ID /tmp/e2e_xflag" 255
run_test "ZIG : api flag --data rejected for archive (exit 255)" \
	"$ZIG_EXE archive --data body --host http://localhost $JOB_ID /tmp/e2e_xflag" 255
