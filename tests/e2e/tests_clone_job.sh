#!/usr/bin/env bash
# tests_clone_job.sh — Section M: clone-job command tests (TDD baseline).
#
# Sourced by tests.sh after helper functions are defined.
# Do NOT execute this file directly.
#
# Goal: every test here is a PERL vs ZIG comparison against the same input,
# using the upstream `openqa-clone-job` Perl script as the behavioural oracle
# for our new `zoqa-clone-job` Zig binary.  In this initial phase the Zig
# binary is a stub (src/clone_job_main.zig), so the ZIG: rows are EXPECTED
# to FAIL.  Each failure is a TDD checkpoint — the FAIL message names the
# behaviour that needs to be implemented next.
#
# Reference for upstream behaviour: ideas/OPENQA_CLONE_JOB_ANALYSIS.md
#
# When implementing zoqa-clone-job, the rough order to make these tests pass:
#   1. --help on stdout, exit 0  (covers tests 1, 2, 7)
#   2. Mention key flags in --help (covers 3–6)
#   3. No-args error on stderr, non-zero exit (covers 8, 9)

echo "==> [clone_job] Running clone-job command tests..."

# Local binary handles — different from the global PERL_EXE/ZIG_EXE which
# point at openqa-cli / zoqa.
PERL_CLONE_EXE="openqa-clone-job"
ZIG_CLONE_EXE="/app/zig-out/bin/zoqa-clone-job"

# 1. --help exits 0
run_test "PERL: clone-job --help exits 0" "$PERL_CLONE_EXE --help" 0
run_test "ZIG : clone-job --help exits 0" "$ZIG_CLONE_EXE --help" 0

# 2. --help prints Usage: header on stdout
run_test "PERL: clone-job --help has Usage: header" "$PERL_CLONE_EXE --help" 0 "Usage:"
run_test "ZIG : clone-job --help has Usage: header" "$ZIG_CLONE_EXE --help" 0 "Usage:"

# 3. --help advertises --within-instance
run_test "PERL: clone-job --help mentions --within-instance" "$PERL_CLONE_EXE --help" 0 "within-instance"
run_test "ZIG : clone-job --help mentions --within-instance" "$ZIG_CLONE_EXE --help" 0 "within-instance"

# 4. --help advertises --skip-download
run_test "PERL: clone-job --help mentions --skip-download" "$PERL_CLONE_EXE --help" 0 "skip-download"
run_test "ZIG : clone-job --help mentions --skip-download" "$ZIG_CLONE_EXE --help" 0 "skip-download"

# 5. --help advertises --from
# Pattern uses [-] to match a literal '-' as the first char without grep
# treating it as an option flag, and without the stray-escape warning that
# "\\-\\-from" produces.
run_test "PERL: clone-job --help mentions --from" "$PERL_CLONE_EXE --help" 0 "[-]-from"
run_test "ZIG : clone-job --help mentions --from" "$ZIG_CLONE_EXE --help" 0 "[-]-from"

# 6. --help advertises --host
run_test "PERL: clone-job --help mentions --host" "$PERL_CLONE_EXE --help" 0 "[-]-host"
run_test "ZIG : clone-job --help mentions --host" "$ZIG_CLONE_EXE --help" 0 "[-]-host"

# 7. --help writes to stdout, not stderr
run_test "PERL: clone-job --help writes to stdout, not stderr" \
	"bash -c \"$PERL_CLONE_EXE --help > /tmp/out 2> /tmp/err; test -s /tmp/out && ! test -s /tmp/err\"" 0
run_test "ZIG : clone-job --help writes to stdout, not stderr" \
	"bash -c \"$ZIG_CLONE_EXE --help > /tmp/out 2> /tmp/err; test -s /tmp/out && ! test -s /tmp/err\"" 0

# 8. No args exits non-zero
run_test "PERL: clone-job with no args exits non-zero" \
	"bash -c \"$PERL_CLONE_EXE; exit_code=\\\$?; test \\\$exit_code -ne 0\"" 0
run_test "ZIG : clone-job with no args exits non-zero" \
	"bash -c \"$ZIG_CLONE_EXE; exit_code=\\\$?; test \\\$exit_code -ne 0\"" 0

# 9. No args writes to stderr, not stdout
run_test "PERL: clone-job with no args writes to stderr, not stdout" \
	"bash -c \"$PERL_CLONE_EXE > /tmp/out 2> /tmp/err; test -s /tmp/err && ! test -s /tmp/out\"" 0
run_test "ZIG : clone-job with no args writes to stderr, not stdout" \
	"bash -c \"$ZIG_CLONE_EXE > /tmp/out 2> /tmp/err; test -s /tmp/err && ! test -s /tmp/out\"" 0
