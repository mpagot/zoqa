#!/usr/bin/env bash
# tests_auth.sh — Section B: Authentication tests.
#
# Covers all credential sources and their priority chain:
#   CLI flags > environment variables > config file
#
# Sourced by tests.sh after helper functions are defined.
# Do NOT execute this file directly.
#
# Assumes from the calling scope:
#   ZIG_EXE, PERL_EXE, LOG_DIR, failed_tests, warned_tests
#   OPENQA_API_KEY, OPENQA_API_SECRET
#   run_test(), run_comparison_api()


# Prepare a client.conf with wrong credentials inside the container at
# /tmp/wrongsecret/client.conf so that OPENQA_CONFIG=/tmp/wrongsecret/wrongsecret points at it.  Tests in this
# file that want to isolate a higher-priority source set OPENQA_CONFIG=/tmp/wrongsecret/wrongsecret
# to ensure the config file can never accidentally supply valid credentials.
container_exec bash -c "mkdir -p /tmp/wrongsecret && printf '[localhost]\nkey=WRONG\nsecret=WRONG\n' > /tmp/wrongsecret/client.conf"

echo "==> [AUT] Running authentication tests..."

# Test AUT-1: DELETE 404 — verifies HMAC signing is applied on DELETE requests.
# Deleted job us untentionally not existing, not to have to seed a job
# only for the purpose of delete it.
# But this no matter, the test is still effective because the server
# evaluates authentication middleware before resource lookup.
# If the HMAC signature was missing or invalid, the server would return
# 401/403. Receiving a 404 proves the signature for the DELETE method was
# perfectly constructed, allowing us to test authentication without needing
# to create and destroy a real fixture.
# Uses the credentials from the system config (seeded by setup.sh).
run_comparison_api "DELETE non-existent (404) — HMAC on DELETE" "" \
	"-X DELETE assets/999999" 1 "404 Not Found"

# Test AUT-2: Authenticated POST via system config file credentials.
# The system client.conf (written by setup.sh) must supply a valid key/secret.
# DISTRI=test does not match any registered product (only distri=example is
# seeded), so no jobs are scheduled. The server still creates a
# scheduled_product record and returns {"count":0,...} with HTTP 200.
# Exit 0 proves the config file credentials authenticated the request;
# grepping "count":0 confirms no jobs were scheduled as a minor side-effect.
run_comparison_api "POST isos — authenticated via config file" "" \
	"-X POST isos DISTRI=test VERSION=1 FLAVOR=test ARCH=x86_64" 0 '"count":0'

# Test AUT-3: Wrong secret supplied via CLI flag → 403.
run_comparison_api "Wrong --apisecret (403)" "" \
	"--apisecret WRONG_SECRET -X POST jobs" 1 "403 Forbidden"

# Test AUT-4: CLI flags override wrong credentials in config file.
# OPENQA_CONFIG=/tmp/wrongsecret points at the wrong client.conf created above.
# Supplying correct --apikey/--apisecret via CLI must win.
run_comparison_api "CLI flags override wrong config file credentials" \
	"OPENQA_CONFIG=/tmp/wrongsecret" \
	"--apikey '$OPENQA_API_KEY' --apisecret '$OPENQA_API_SECRET' jobs/overview" \
	0

# Test AUT-5: OPENQA_API_KEY + OPENQA_API_SECRET env vars as sole credential source.
# OPENQA_CONFIG=/tmp/wrongsecret points at the wrong client.conf, so the env vars are the
# only valid source.  The signed POST must succeed (exit 0).
run_test "PERL : OPENQA_API_KEY+SECRET env vars authenticate request" \
	"bash -c \
	\"OPENQA_CONFIG=/tmp/wrongsecret OPENQA_API_KEY='$OPENQA_API_KEY' OPENQA_API_SECRET='$OPENQA_API_SECRET' \
	$PERL_EXE api --host http://localhost -X POST isos DISTRI=envtest VERSION=1 FLAVOR=test ARCH=x86_64\"" \
	0
run_test "ZIG : OPENQA_API_KEY+SECRET env vars authenticate request" \
	"bash -c \
	\"OPENQA_CONFIG=/tmp/wrongsecret OPENQA_API_KEY='$OPENQA_API_KEY' OPENQA_API_SECRET='$OPENQA_API_SECRET' \
	$ZIG_EXE api --host http://localhost -X POST isos DISTRI=envtest VERSION=1 FLAVOR=test ARCH=x86_64\"" \
	0

# Test AUT-6: Wrong OPENQA_API_SECRET env var → 403.
# Verifies the env var value is actually passed to HMAC — a wrong secret must
# be rejected by the server.
run_test "ZIG : Wrong OPENQA_API_SECRET env var → 403" \
	"bash -c \"OPENQA_CONFIG=/tmp/wrongsecret OPENQA_API_KEY='$OPENQA_API_KEY' OPENQA_API_SECRET='WRONG_ENV_SECRET' \
	$ZIG_EXE api --host http://localhost -X POST jobs\"" \
	1 "403 Forbidden"

# Test AUT-7: CLI flags override wrong env var credentials (CLI > env priority).
# Env vars carry garbage values; correct credentials are supplied via flags.
run_test "ZIG : CLI flags override wrong env var credentials" \
	"bash -c \"OPENQA_CONFIG=/tmp/wrongsecret OPENQA_API_KEY='GARBAGE_KEY' OPENQA_API_SECRET='GARBAGE_SECRET' \
	$ZIG_EXE api --host http://localhost --apikey '$OPENQA_API_KEY' --apisecret '$OPENQA_API_SECRET' \
	-X POST isos DISTRI=envtest VERSION=1 FLAVOR=test ARCH=x86_64\"" \
	0

# =============================================================================
# Section B2: Asset Authentication and Redirection
# =============================================================================

# Test AUT-8: Asset download with require_for_assets = 1 (unauthenticated returns 403 Forbidden; authenticated with valid HMAC follows 302 and returns 200 OK).
# AUT-8: Asset download with require_for_assets = 1
# Under default require_for_assets = 1, unauthenticated requests to /assets or
# to asset redirect endpoints return 403 Forbidden.
# Authenticated requests with valid HMAC credentials follow the 302 redirect
# and succeed with 200 OK.
ensure_basic_job

run_test "Unauthenticated /assets request returns 403 (require_for_assets = 1)" \
	"bash -c \"curl -s -o /dev/null -w '%{http_code}' http://localhost/assets/iso/dummy.iso | grep -q '^403$'\"" \
	0

run_test "Unauthenticated /tests/{id}/asset redirect returns 403 on target hop" \
	"bash -c \"curl -s -L -o /dev/null -w '%{http_code}' http://localhost/tests/${JOB_ID}/asset/iso/seed-nocloud.iso | grep -q '^403$'\"" \
	0

container_exec rm -rf /tmp/aut8_perl /tmp/aut8_zig
run_test "PERL: Authenticated asset download follows 302 and re-signs HMAC" \
	"bash -c \"$PERL_EXE archive --host http://localhost ${JOB_ID} /tmp/aut8_perl && test -f /tmp/aut8_perl/iso/seed-nocloud.iso\"" \
	0
run_test "ZIG : Authenticated asset download follows 302 and re-signs HMAC" \
	"bash -c \"$ZIG_EXE archive --host http://localhost ${JOB_ID} /tmp/aut8_zig && test -f /tmp/aut8_zig/iso/seed-nocloud.iso\"" \
	0
container_exec rm -rf /tmp/aut8_perl /tmp/aut8_zig

# Test AUT-9: Runtime toggle with set_require_for_assets 0 (unauthenticated asset request succeeds with 200 OK).
# AUT-9: Runtime toggle with set_require_for_assets 0
# Overwriting configuration with require_for_assets = 0 and reloading Mojolicious
# allows unauthenticated access to /assets (returns 200 OK).
set_require_for_assets 0

run_test "Unauthenticated /assets request succeeds (200 OK) when require_for_assets = 0" \
	"bash -c \"curl -s -o /dev/null -w '%{http_code}' http://localhost/assets/iso/dummy.iso | grep -q '^200$'\"" \
	0

run_test "Unauthenticated /tests/{id}/asset redirect succeeds (200 OK) when require_for_assets = 0" \
	"bash -c \"curl -s -L -o /dev/null -w '%{http_code}' http://localhost/tests/${JOB_ID}/asset/iso/seed-nocloud.iso | grep -q '^200$'\"" \
	0

# Test AUT-10: Restoring set_require_for_assets 1 (unauthenticated asset request is rejected again with 403 Forbidden).
# AUT-10: Restoring set_require_for_assets 1
# Overwriting configuration with require_for_assets = 1 and reloading Mojolicious
# re-enforces HMAC authentication on assets, rejecting unauthenticated requests with 403.
set_require_for_assets 1

run_test "Unauthenticated /assets request returns 403 again after restoring require_for_assets = 1" \
	"bash -c \"curl -s -o /dev/null -w '%{http_code}' http://localhost/assets/iso/dummy.iso | grep -q '^403$'\"" \
	0

run_test "Unauthenticated /tests/{id}/asset redirect returns 403 again after restoring require_for_assets = 1" \
	"bash -c \"curl -s -L -o /dev/null -w '%{http_code}' http://localhost/tests/${JOB_ID}/asset/iso/seed-nocloud.iso | grep -q '^403$'\"" \
	0
