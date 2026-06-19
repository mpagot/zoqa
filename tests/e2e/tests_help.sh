#!/usr/bin/env bash
# tests_help.sh — Section I: Help output structure tests.
#
# Sourced by tests.sh after helper functions are defined.
# Do NOT execute this file directly.

echo "==> [help] Running help output structure tests..."

# 1. Global help
run_test "PERL: Global help has Options (for all commands)" "$PERL_EXE --help" 0 "Options (for all commands):"
run_test "ZIG : Global help has Options (for all commands)" "$ZIG_EXE --help" 0 "Options (for all commands):"

run_test "PERL: Global help lists subcommands" "$PERL_EXE --help" 0 "api "
run_test "ZIG : Global help lists subcommands" "$ZIG_EXE --help" 0 "api "

# 2. api help
run_test "PERL: api help has Options for api" "$PERL_EXE api --help" 0 "Options for api:"
run_test "ZIG : api help has Options for api" "$ZIG_EXE api --help" 0 "Options for api:"

run_test "PERL: api help has global options" "$PERL_EXE api --help" 0 "Options (for all commands):"
run_test "ZIG : api help has global options" "$ZIG_EXE api --help" 0 "Options (for all commands):"

run_test "PERL: api help has Usage" "$PERL_EXE api --help" 0 "Usage:"
run_test "ZIG : api help has Usage" "$ZIG_EXE api --help" 0 "Usage:"

# 3. archive help
run_test "PERL: archive help has Options for archive" "$PERL_EXE archive --help" 0 "Options for archive:"
run_test "ZIG : archive help has Options for archive" "$ZIG_EXE archive --help" 0 "Options for archive:"

run_test "PERL: archive help has global options" "$PERL_EXE archive --help" 0 "Options (for all commands):"
run_test "ZIG : archive help has global options" "$ZIG_EXE archive --help" 0 "Options (for all commands):"

run_test "PERL: archive help has Usage" "$PERL_EXE archive --help" 0 "Usage:"
run_test "ZIG : archive help has Usage" "$ZIG_EXE archive --help" 0 "Usage:"

# 4. monitor help
run_test "PERL: monitor help has Options for monitor" "$PERL_EXE monitor --help" 0 "Options for monitor:"
run_test "ZIG : monitor help has Options for monitor" "$ZIG_EXE monitor --help" 0 "Options for monitor:"

run_test "PERL: monitor help has global options" "$PERL_EXE monitor --help" 0 "Options (for all commands):"
run_test "ZIG : monitor help has global options" "$ZIG_EXE monitor --help" 0 "Options (for all commands):"

run_test "PERL: monitor help has Usage" "$PERL_EXE monitor --help" 0 "Usage:"
run_test "ZIG : monitor help has Usage" "$ZIG_EXE monitor --help" 0 "Usage:"

# 5. schedule help
run_test "PERL: schedule help has Options for schedule" "$PERL_EXE schedule --help" 0 "Options for schedule:"
run_test "ZIG : schedule help has Options for schedule" "$ZIG_EXE schedule --help" 0 "Options for schedule:"

run_test "PERL: schedule help has global options" "$PERL_EXE schedule --help" 0 "Options (for all commands):"
run_test "ZIG : schedule help has global options" "$ZIG_EXE schedule --help" 0 "Options (for all commands):"

run_test "PERL: schedule help has Usage" "$PERL_EXE schedule --help" 0 "Usage:"
run_test "ZIG : schedule help has Usage" "$ZIG_EXE schedule --help" 0 "Usage:"

# 6. Negative test (global help hides subcommand options)
run_test "PERL: Global help hides api options" "bash -c \"$PERL_EXE --help | grep -q 'Options for api:'; test \\\$? -eq 1\"" 0
run_test "ZIG : Global help hides api options" "bash -c \"$ZIG_EXE --help | grep -q 'Options for api:'; test \\\$? -eq 1\"" 0

# 7. Exit codes and stdout/stderr routing
run_test "PERL: --help writes to stdout, exits 0" "bash -c \"$PERL_EXE --help > /tmp/out 2> /tmp/err; test -s /tmp/out && ! test -s /tmp/err\"" 0
run_test "ZIG : --help writes to stdout, exits 0" "bash -c \"$ZIG_EXE --help > /tmp/out 2> /tmp/err; test -s /tmp/out && ! test -s /tmp/err\"" 0

run_test "PERL: bare invocation writes to stdout, exits 0" "bash -c \"$PERL_EXE > /tmp/out 2> /tmp/err; test -s /tmp/out && ! test -s /tmp/err\"" 0
run_test "ZIG : bare invocation writes to stdout, exits 0" "bash -c \"$ZIG_EXE > /tmp/out 2> /tmp/err; test -s /tmp/out && ! test -s /tmp/err\"" 0

run_test "PERL: unknown subcmd writes to stderr, exits non-zero" "bash -c \"! $PERL_EXE fake > /tmp/out 2> /tmp/err && test -s /tmp/err && ! test -s /tmp/out\"" 0
run_test "ZIG : unknown subcmd writes to stderr, exits non-zero" "bash -c \"! $ZIG_EXE fake > /tmp/out 2> /tmp/err && test -s /tmp/err && ! test -s /tmp/out\"" 0

run_test "PERL: missing PATH writes to stderr, exits non-zero" "bash -c \"! $PERL_EXE api > /tmp/out 2> /tmp/err && test -s /tmp/err && ! test -s /tmp/out\"" 0
run_test "ZIG : missing PATH writes to stderr, exits non-zero" "bash -c \"! $ZIG_EXE api > /tmp/out 2> /tmp/err && test -s /tmp/err && ! test -s /tmp/out\"" 0

run_test "PERL: archive missing args writes to stderr, exits non-zero" "bash -c \"! $PERL_EXE archive > /tmp/out 2> /tmp/err && test -s /tmp/err && ! test -s /tmp/out\"" 0
run_test "ZIG : archive missing args writes to stderr, exits non-zero" "bash -c \"! $ZIG_EXE archive > /tmp/out 2> /tmp/err && test -s /tmp/err && ! test -s /tmp/out\"" 0
