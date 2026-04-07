#!/usr/bin/env bash
# tests_core.sh — Section A: Core protocol and CLI flag tests.
#
# Sourced by tests.sh after helper functions are defined.
# Do NOT execute this file directly.
#
# Assumes from the calling scope:
#   ZIG_EXE, PERL_EXE, LOG_DIR, failed_tests, warned_tests
#   run_test(), run_comparison(), run_diff_test()

echo "==> [core] Running core protocol and CLI flag tests..."

# Test 1: Basic GET jobs/overview (verifies the endpoint responds)
run_comparison "GET jobs/overview" "" "jobs/overview" 0

# Test 2: GET workers
run_comparison "GET workers" "" "workers" 0

# Test 3: GET with query params
run_comparison "GET jobs with filter" "" "jobs distri=opensuse" 0 "\[\]"

# Test 4: GET 404
run_comparison "GET non-existent (404)" "" "jobs/999999" 1 "404 Not Found"

# Test 5: Missing PATH positional argument
# Both Perl and Zig exit 255 and print the api usage block to stderr.
run_comparison "Missing PATH" "" "" 255

# Test 6: Invalid host (connection refused)
# Both Perl and Zig exit 1. Messages differ (Perl: ANSI-colored, Zig: plain),
# so no grep pattern is used.
run_test "PERL: Invalid Host" \
	"$PERL_EXE api --host http://localhost:12345 jobs/overview" 1
run_test "ZIG : Invalid Host" \
	"$ZIG_EXE api --host http://localhost:12345 jobs/overview" 1

# Test 7: Flags placed before the subcommand name must be rejected (exit 255).
# run_comparison cannot be used: it always emits "$EXE api --host http://localhost
# …", which would make '--host' appear *after* 'api', not before it. The
# scenario under test requires the argument order '$EXE --host … api …', which
# can only be expressed with explicit run_test calls.
# Perl's Mojolicious dispatcher treats ARGV[0] as the subcommand name; if it
# starts with '--', it dies with "Invalid command --host" → exit 255.
# Zig mirrors this: a leading '--' token before the subcommand token returns
# error.InvalidCommand → exit 255.
run_test "PERL: --host before api rejected (exit 255)" \
	"$PERL_EXE --host http://localhost api jobs/overview" 255
run_test "ZIG : --host before api rejected (exit 255)" \
	"$ZIG_EXE --host http://localhost api jobs/overview" 255

# Test 8: -- is silently accepted and has no practical effect.
# API paths are URL segments (never starting with '-') and query parameters are
# 'key=value' pairs whose key must be alphanumeric, so no argument to 'api' can
# ever be mistaken for a flag. -- is therefore a no-op: both implementations
# must drop it, produce the same HTTP request as without it, and exit 0.
run_comparison "-- stop before API path accepted (exit 0)" "" \
	"-- jobs/overview" 0

# Test 9: -- causes a dash-prefixed token to be used as the literal API path.
# This is the only scenario where -- has any observable effect: without it,
# '-X' would be rejected as an unknown flag; with it, '-X' is passed verbatim
# as the API path. The server has no such route → 404 Not Found (exit 1).
run_comparison "-- stop: dash-prefixed path is a 404, not a flag error" "" \
	"-- -X" 1 "404 Not Found"

# Test 10: --param-file support.
# Create the param file inside the container that --param-file will read.
# The file contains the value "opensuse" which will be used as the `distri` query parameter.
container_exec bash -c "printf 'opensuse' > /tmp/distri.txt"
run_comparison "--param-file" "" "--param-file distri=/tmp/distri.txt jobs" 0 "\[\]"

# Test 10b: --param-file returns a non-empty result when the value matches seeded data.
# The seeded job has DISTRI=example; querying with that value must return a
# response containing a "jobs" key, confirming --param-file values are actually
# sent to the server and filter results correctly (contrast with test 10 which
# returns an empty list []).
container_exec bash -c "printf 'example' > /tmp/distri_example.txt"
run_comparison "--param-file with matching distri returns results" "" \
	"--param-file distri=/tmp/distri_example.txt jobs" 0 '"jobs"'

# Test 36: --data / -d raw body POST.
# Both Perl (api.pm:27 → @data = ($data)) and Zig (main.zig --data path) send
# the raw body string verbatim. An explicit Content-Type header is required so
# that the openQA isos endpoint can parse the form parameters.
# DISTRI=rawtest does not match any registered product, so openQA returns
# {"count":0,"ids":[]} — confirming the body was parsed but no job is scheduled.
run_comparison "--data raw body POST to isos" "" \
	"-X POST -a 'Content-Type: application/x-www-form-urlencoded' -d 'DISTRI=rawtest&VERSION=1.0&FLAVOR=DVD&ARCH=x86_64&BUILD=raw36&MACHINE=64bit' isos" \
	0 '"count":0'

# Test 36b: --data-file POST with a matching product schedules a job (count:1).
# DISTRI=example VERSION=0 matches the registered product and job group template
# loaded by seed_fixtures.sh. _GROUP_ID routes the job to the "example" group.
# The response must contain "count":1 confirming a job was actually scheduled
# server-side — the only test that verifies a POST to isos has a real effect.
container_exec bash -c "printf 'DISTRI=example&VERSION=0&FLAVOR=DVD&ARCH=x86_64&BUILD=raw36b&ISO=dummy.iso&_GROUP_ID=$GROUP_ID' > /tmp/body36b.txt"
run_comparison "--data-file POST matching product schedules a job (count:1)" "" \
	"-X POST -a 'Content-Type: application/x-www-form-urlencoded' --data-file /tmp/body36b.txt isos" \
	0 '"count":1'

# Test 37: --form converts a JSON object body to application/x-www-form-urlencoded.
# Perl (api.pm:26): decode_json($data) → form => $params.
# Zig (main.zig): --form flag calls jsonToFormEncoded().
# The JSON is written to a file to avoid double-quote nesting issues in the
# shell evaluation chain used by run_comparison.
container_exec bash -c 'printf %s "{\"DISTRI\":\"ftest\",\"VERSION\":\"1.0\",\"FLAVOR\":\"DVD\",\"ARCH\":\"x86_64\",\"BUILD\":\"form37\",\"MACHINE\":\"64bit\"}" > /tmp/form37.json'
run_comparison "--form JSON→form-encoded POST to isos" "" \
	"-X POST --form --data-file /tmp/form37.json isos" \
	0

# Test 38: -a / --header injects a custom request header.
# Both Perl (Command.pm:80-81 parse_headers) and Zig split on the first ':'
# and append the header verbatim. The custom header must not interfere with
# the request; expected exit 0.
run_comparison "-a custom header does not break request" "" \
	"-a 'X-E2E-Test: zoqa' jobs/overview" \
	0

# Test 39: --json + --data-file + PUT.
# --json sets Content-Type: application/json; --data-file provides the raw JSON
# body. Canonical example from openqa-cli.yaml (line 109).
# PUT /api/v1/jobs/:id (route apiv1_put_job → job#update) updates job settings.
# The JSON is written to a file to avoid double-quote nesting in run_comparison.
#
# Server-side effect: none (deliberate no-op).
# The seeded job already belongs to group_id=1 (GROUP_ID=1 set by
# seed_fixtures.sh). Sending {"group_id":1} sets the field to the value it
# already holds, so the PUT is accepted (exit 0) but produces no observable
# state change on the server. This is intentional: the goal is to exercise
# the --json + --data-file + -X PUT flag combination in isolation, without
# mutating fixture state in a way that could affect downstream tests that
# rely on the job's group membership.
container_exec bash -c 'printf %s "{\"group_id\":1}" > /tmp/put39.json'
run_comparison "--json + --data-file + PUT jobs/:id" "" \
	"--json --data-file /tmp/put39.json -X PUT jobs/$JOB_ID" \
	0

# Test 40: --param-file combined with a positional key=value parameter.
# The file is written without a trailing newline (printf, not echo) to sidestep
# the Perl (path->slurp retains newline) vs Zig (trimRight strips it) divergence.
# Both must merge the file value with the inline param and return an empty list.
container_exec bash -c "printf '1.0' > /tmp/pf_version.txt"
run_comparison "--param-file + positional KV" "" \
	"--param-file version=/tmp/pf_version.txt jobs distri=opensuse" \
	0 "\[\]"

# Tests 41a-c: Host resolution and scheme handling.
# run_comparison cannot be used here because these tests supply a custom --host
# that must replace the harness default (http://localhost). Two run_test calls
# per sub-test assert identical expected behaviour — same pattern as tests 6/7.

# Test 41a: Bare hostname → https://.
# Both Perl (Command.pm:106) and Zig (config.zig resolveHost) prepend https://
# when the host has no scheme or leading slash.
# https://localhost:443 hits Apache inside the container with a self-signed cert
# that the system CA bundle does not trust → TLS handshake failure → exit 1.
# If a test unexpectedly passes (exit 0), the CA bundle already trusts the cert;
# adjust the expected code accordingly.
run_test "PERL: bare --host → https:// → TLS error (exit 1)" \
	"$PERL_EXE api --host localhost jobs/overview" 1
run_test "ZIG : bare --host → https:// → TLS error (exit 1)" \
	"$ZIG_EXE api --host localhost jobs/overview" 1

# Test 41b: Unresolvable hostname → DNS failure (exit 1).
run_test "PERL: unresolvable hostname (exit 1)" \
	"$PERL_EXE api --host nonexistent.e2e.invalid jobs/overview" 1
run_test "ZIG : unresolvable hostname (exit 1)" \
	"$ZIG_EXE api --host nonexistent.e2e.invalid jobs/overview" 1

# Test 41c: Fully-qualified URL with explicit scheme + unused port → ECONNREFUSED.
# Port 8428 is not bound inside the container; both exit 1.
run_test "PERL: explicit URL wrong port (exit 1)" \
	"$PERL_EXE api --host http://localhost:8428 jobs/overview" 1
run_test "ZIG : explicit URL wrong port (exit 1)" \
	"$ZIG_EXE api --host http://localhost:8428 jobs/overview" 1
