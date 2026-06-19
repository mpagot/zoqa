#!/usr/bin/env bash
# shellcheck disable=SC2153
# test_clone_smoke.sh — CLO-1 to CLO-11: pure-CLI smoke tests.
#
# Tests --help, no-args, and bare-integer invocations.  No container or API
# access required — these run against the binary on PATH only.
#
# Sourced by tests.sh after helper functions are defined.
# Do NOT execute this file directly.
#
# Goal: every test here is a PERL vs ZIG comparison against the same input,
# using the upstream `openqa-clone-job` Perl script as the behavioural oracle
# for our new `zoqa-clone-job` Zig binary.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_topology.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "==> [clone_job/smoke] Running clone-job smoke tests (CLO-1 to CLO-11)..."

# Local binary handles — different from the global PERL_EXE/ZIG_EXE which
# point at openqa-cli / zoqa.
PERL_CLONE_EXE="openqa-clone-job"
ZIG_CLONE_EXE="/app/zig-out/bin/zoqa-clone-job"

# CLO-1 --help exits 0
run_comparison_clone "clone-job --help exits 0" "--help" 0

# CLO-2 --help prints Usage: header on stdout
# CLO-3 --help advertises --within-instance
# CLO-4 --help advertises --skip-download
# CLO-5 --help advertises --from
# Pattern uses [-] to match a literal '-' as the first char without grep
# treating it as an option flag, and without the stray-escape warning that
# "\\-\\-from" produces.
# CLO-6 --help advertises --host
tests=(
	"clone-job --help has Usage: header|Usage:"
	"clone-job --help mentions --within-instance|within-instance"
	"clone-job --help mentions --skip-download|skip-download"
	"clone-job --help mentions --from|[-]-from"
	"clone-job --help mentions --host|[-]-host"
)

for t in "${tests[@]}"; do
	desc="${t%%|*}"
	pat="${t#*|}"
	run_comparison_clone "$desc" "--help" 0 "$pat"
done

# CLO-7 --help writes to stdout, not stderr
run_test "PERL: clone-job --help writes to stdout, not stderr" \
	"bash -c \"$PERL_CLONE_EXE --help > /tmp/out 2> /tmp/err; test -s /tmp/out && ! test -s /tmp/err\"" 0
run_test "ZIG : clone-job --help writes to stdout, not stderr" \
	"bash -c \"$ZIG_CLONE_EXE --help > /tmp/out 2> /tmp/err; test -s /tmp/out && ! test -s /tmp/err\"" 0

# CLO-8 No args exits non-zero
run_test_exit_nonzero "PERL: clone-job no args" "$PERL_CLONE_EXE"
run_test_exit_nonzero "ZIG : clone-job no args" "$ZIG_CLONE_EXE"

# CLO-9 No args writes to stderr, not stdout
run_test "PERL: clone-job with no args writes to stderr, not stdout" \
	"bash -c \"$PERL_CLONE_EXE > /tmp/out 2> /tmp/err; test -s /tmp/err && ! test -s /tmp/out\"" 0
run_test "ZIG : clone-job with no args writes to stderr, not stdout" \
	"bash -c \"$ZIG_CLONE_EXE > /tmp/out 2> /tmp/err; test -s /tmp/err && ! test -s /tmp/out\"" 0

# CLO-10 Bare integer JOBREF without --from exits non-zero
#        Both tools should fail because no source host is known.
run_test_exit_nonzero "PERL: bare integer without --from" "$PERL_CLONE_EXE 42"
run_test_exit_nonzero "ZIG : bare integer without --from" "$ZIG_CLONE_EXE 42"

# CLO-11 Bare integer without --from — output stream routing.
# NOTE: Perl calls pod2usage(1) here (exitval 1 → stdout by default per Pod::Usage
# convention: exitval < 2 → STDOUT, exitval >= 2 → STDERR).  So Perl writes its
# usage text to stdout and nothing to stderr — same routing as --help (test 7).
# Zig writes the error message to stderr only, keeping stdout clean.
run_test "PERL: bare integer without --from writes to stdout (pod2usage quirk)" \
	"bash -c \"$PERL_CLONE_EXE 42 > /tmp/out 2> /tmp/err; test -s /tmp/out && ! test -s /tmp/err\"" 0
run_test "ZIG : bare integer without --from writes to stderr" \
	"bash -c \"$ZIG_CLONE_EXE 42 > /tmp/out 2> /tmp/err; test -s /tmp/err && ! test -s /tmp/out\"" 0
