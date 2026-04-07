# run_tests.ps1 — Windows E2E test runner for zoqa.
#
# Runs the zoqa Windows binary directly against the openQA container that was
# started by run_container.sh (running in WSL).  Does NOT run openqa-cli (Perl)
# comparisons — this is a zoqa-only subset of the full Linux E2E suite.
#
# Usage (normally invoked by run_windows.ps1):
#   pwsh tests\e2e\run_tests.ps1 `
#       -ZoqaExe  zig-out\bin\zoqa.exe `
#       -BaseUrl  http://192.168.x.x:8080 `
#       -ApiKey   <key> `
#       -ApiSecret <secret> `
#       -JobId    <id> `
#       -GroupId  <id>
#
# All parameters have defaults that read from $env:* variables so that
# run_windows.ps1 (which dot-sources the PS env file written by
# run_container.sh) can call this script with no explicit arguments.
#
# Exit codes:
#   0  — all tests passed
#   1  — one or more tests failed

[CmdletBinding()]
param(
    # Path to the zoqa Windows executable (x86_64-windows build).
    [string]$ZoqaExe    = $(if ($env:ZOQA_EXE)    { $env:ZOQA_EXE }    else { "zig-out\bin\zoqa.exe" }),

    # Base URL of the openQA API, e.g. http://192.168.x.x:8080
    [string]$BaseUrl    = $(if ($env:OPENQA_E2E_HOST) { $env:OPENQA_E2E_HOST } else { "http://localhost:8080" }),

    # API credentials (sourced from /tmp/openqa_e2e_env.ps1 by run_windows.ps1)
    [string]$ApiKey     = $env:OPENQA_API_KEY,
    [string]$ApiSecret  = $env:OPENQA_API_SECRET,

    # Seeded fixture IDs (sourced from /tmp/openqa_e2e_env.ps1)
    [string]$JobId      = $env:JOB_ID,
    [string]$GroupId    = $env:GROUP_ID
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================================================
# Helpers
# =============================================================================

$script:FailedTests  = 0
$script:WarnedTests  = 0
$script:LogDir       = Join-Path $env:TEMP ("zoqa_e2e_" + (Get-Date -Format "yyyyMMddTHHmmss"))
New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
Write-Host "==> Log directory: $script:LogDir"

# Run-Test
#   Runs $Cmd as an external process, checks exit code, optionally checks for a
#   pattern in the combined stdout+stderr output.
#
# Parameters:
#   Label        — human-readable test name
#   Cmd          — script block that invokes zoqa (e.g. { & $ZoqaExe ... })
#   ExpectedExit — expected exit code (default 0)
#   GrepPattern  — optional regex; FAIL if not found in output
function Run-Test {
    param(
        [string]      $Label,
        [scriptblock] $Cmd,
        [int]         $ExpectedExit  = 0,
        [string]      $GrepPattern   = ""
    )

    Write-Host ""
    Write-Host "--- Test: $Label ---"

    $outFile = Join-Path $script:LogDir "test_output.log"

    # Redirect both stdout and stderr into a single log file.
    # We use Start-Process so we can capture the exit code reliably without
    # $LASTEXITCODE being polluted by intermediate cmdlets.
    $combined = ""
    try {
        $combined = & $Cmd 2>&1 | Out-String
    } catch {
        $combined = $_.ToString()
    }
    $exitCode = $LASTEXITCODE
    $combined | Set-Content -Path $outFile -Encoding UTF8

    Write-Host "Exit code: $exitCode"

    if ($exitCode -ne $ExpectedExit) {
        Write-Host "FAIL: expected exit $ExpectedExit, got $exitCode"
        Write-Host $combined
        $script:FailedTests++
        return
    }

    if ($GrepPattern -ne "") {
        if ($combined -notmatch $GrepPattern) {
            Write-Host "FAIL: output did not match pattern '$GrepPattern'"
            Write-Host $combined
            $script:FailedTests++
            return
        }
    }

    Write-Host "PASS"
}

# Shorthand: run a zoqa api call and check it.
function Run-ZoqaTest {
    param(
        [string] $Label,
        [string] $ApiArgs,
        [int]    $ExpectedExit = 0,
        [string] $GrepPattern  = "",
        # Extra environment variables as a hashtable, e.g. @{ OPENQA_CONFIG = "C:\tmp" }
        [hashtable] $ExtraEnv  = @{}
    )

    Run-Test -Label $Label -ExpectedExit $ExpectedExit -GrepPattern $GrepPattern -Cmd {
        # Apply extra env vars for the duration of this invocation
        $saved = @{}
        foreach ($k in $ExtraEnv.Keys) {
            $saved[$k] = [System.Environment]::GetEnvironmentVariable($k)
            [System.Environment]::SetEnvironmentVariable($k, $ExtraEnv[$k])
        }
        try {
            # Split ApiArgs carefully; Invoke-Expression on the full command string
            # is equivalent to what run_test() does with eval in Bash.
            $argList = "api --host $BaseUrl $ApiArgs"
            $output  = & $ZoqaExe ($argList -split '\s+(?=(?:[^"]*"[^"]*")*[^"]*$)') 2>&1
            $output | Out-String
        } finally {
            foreach ($k in $saved.Keys) {
                [System.Environment]::SetEnvironmentVariable($k, $saved[$k])
            }
        }
    }
}

# =============================================================================
# Pre-flight
# =============================================================================

Write-Host ""
Write-Host "==> zoqa Windows E2E test suite"
Write-Host "    Binary : $ZoqaExe"
Write-Host "    Host   : $BaseUrl"
Write-Host "    JobId  : $JobId   GroupId: $GroupId"
Write-Host ""

if (-not (Test-Path $ZoqaExe)) {
    Write-Host "ERROR: zoqa executable not found at '$ZoqaExe'." -ForegroundColor Red
    Write-Host "       Build it first:  zig build -Dtarget=x86_64-windows-gnu"
    exit 1
}

# =============================================================================
# Section A — Core protocol and CLI flag tests
# (mirrors tests_core.sh, zoqa-only)
# =============================================================================

Write-Host "==> [core] Running core protocol and CLI flag tests..."

# Test W-01: Basic GET jobs/overview
Run-Test -Label "W-01: GET jobs/overview" -ExpectedExit 0 -Cmd {
    & $ZoqaExe api --host $BaseUrl jobs/overview 2>&1
}

# Test W-02: GET workers
Run-Test -Label "W-02: GET workers" -ExpectedExit 0 -Cmd {
    & $ZoqaExe api --host $BaseUrl workers 2>&1
}

# Test W-03: GET with query parameter
Run-Test -Label "W-03: GET jobs with filter" -ExpectedExit 0 -GrepPattern '\[\]' -Cmd {
    & $ZoqaExe api --host $BaseUrl jobs distri=opensuse 2>&1
}

# Test W-04: GET 404 — exit 1 and status line in output
Run-Test -Label "W-04: GET non-existent (404)" -ExpectedExit 1 -GrepPattern '404 Not Found' -Cmd {
    & $ZoqaExe api --host $BaseUrl jobs/999999 2>&1
}

# Test W-05: Missing PATH positional argument — exit 255
Run-Test -Label "W-05: Missing PATH argument (exit 255)" -ExpectedExit 255 -Cmd {
    & $ZoqaExe api --host $BaseUrl 2>&1
}

# Test W-06: Invalid host (connection refused) — exit 1
Run-Test -Label "W-06: Invalid host (connection refused)" -ExpectedExit 1 -Cmd {
    & $ZoqaExe api --host http://127.0.0.1:19999 jobs/overview 2>&1
}

# Test W-07: Flag placed before subcommand name is rejected — exit 255
Run-Test -Label "W-07: --host before 'api' rejected (exit 255)" -ExpectedExit 255 -Cmd {
    & $ZoqaExe --host $BaseUrl api jobs/overview 2>&1
}

# Test W-08: -- stop flag is accepted; path after -- is used as API route
Run-Test -Label "W-08: -- stop flag accepted (exit 0)" -ExpectedExit 0 -Cmd {
    & $ZoqaExe api --host $BaseUrl -- jobs/overview 2>&1
}

# Test W-09: -- stop makes dash-prefixed token a 404 path, not a flag
Run-Test -Label "W-09: -- stop; dash path is 404 not flag error" -ExpectedExit 1 -GrepPattern '404 Not Found' -Cmd {
    & $ZoqaExe api --host $BaseUrl -- -X 2>&1
}

# Test W-10: --param-file support
$paramFile = Join-Path $env:TEMP "zoqa_e2e_distri.txt"
[System.IO.File]::WriteAllText($paramFile, "opensuse")
Run-Test -Label "W-10: --param-file" -ExpectedExit 0 -GrepPattern '\[\]' -Cmd {
    & $ZoqaExe api --host $BaseUrl --param-file "distri=$paramFile" jobs 2>&1
}
Remove-Item -Path $paramFile -Force -ErrorAction SilentlyContinue

# =============================================================================
# Section B — Authentication tests
# (mirrors tests_auth.sh, zoqa-only; no Perl comparisons)
# =============================================================================

Write-Host ""
Write-Host "==> [auth] Running authentication tests..."

# Write a wrong client.conf to a temp directory so OPENQA_CONFIG can point at it.
$wrongConfDir = Join-Path $env:TEMP "zoqa_e2e_wrongconf"
New-Item -ItemType Directory -Path $wrongConfDir -Force | Out-Null
$wrongConf = Join-Path $wrongConfDir "client.conf"
@"
[$(([System.Uri]$BaseUrl).Host)]
key=WRONG
secret=WRONG
"@ | Set-Content -Path $wrongConf -Encoding UTF8

# Test W-11: DELETE non-existent — HMAC is applied on DELETE (returns 404, not 403)
Run-Test -Label "W-11: DELETE non-existent (404) — HMAC on DELETE" -ExpectedExit 1 -GrepPattern '404 Not Found' -Cmd {
    & $ZoqaExe api --host $BaseUrl -X DELETE assets/999999 2>&1
}

# Test W-12: Wrong --apisecret via CLI → 403
Run-Test -Label "W-12: Wrong --apisecret (403)" -ExpectedExit 1 -GrepPattern '403 Forbidden' -Cmd {
    & $ZoqaExe api --host $BaseUrl --apisecret WRONG_SECRET -X POST jobs 2>&1
}

# Test W-13: CLI flags override wrong config-file credentials
#   OPENQA_CONFIG points at the wrong client.conf; correct creds via CLI must win.
Run-Test -Label "W-13: CLI flags override wrong config-file creds" -ExpectedExit 0 -Cmd {
    $saved = $env:OPENQA_CONFIG
    $env:OPENQA_CONFIG = $wrongConfDir
    try {
        & $ZoqaExe api --host $BaseUrl `
            --apikey $ApiKey --apisecret $ApiSecret `
            jobs/overview 2>&1
    } finally {
        $env:OPENQA_CONFIG = $saved
    }
}

# Test W-14: OPENQA_API_KEY + OPENQA_API_SECRET env vars as sole credential source
#   OPENQA_CONFIG points at wrong conf; env vars are the only valid source.
Run-Test -Label "W-14: OPENQA_API_KEY+SECRET env vars authenticate request" -ExpectedExit 0 -Cmd {
    $savedCfg = $env:OPENQA_CONFIG
    $savedKey = $env:OPENQA_API_KEY
    $savedSec = $env:OPENQA_API_SECRET
    $env:OPENQA_CONFIG     = $wrongConfDir
    $env:OPENQA_API_KEY    = $ApiKey
    $env:OPENQA_API_SECRET = $ApiSecret
    try {
        & $ZoqaExe api --host $BaseUrl `
            -X POST isos DISTRI=winenvtest VERSION=1 FLAVOR=test ARCH=x86_64 2>&1
    } finally {
        $env:OPENQA_CONFIG     = $savedCfg
        $env:OPENQA_API_KEY    = $savedKey
        $env:OPENQA_API_SECRET = $savedSec
    }
}

# Test W-15: Wrong OPENQA_API_SECRET env var → 403
Run-Test -Label "W-15: Wrong OPENQA_API_SECRET env var -> 403" -ExpectedExit 1 -GrepPattern '403 Forbidden' -Cmd {
    $savedCfg = $env:OPENQA_CONFIG
    $savedKey = $env:OPENQA_API_KEY
    $savedSec = $env:OPENQA_API_SECRET
    $env:OPENQA_CONFIG     = $wrongConfDir
    $env:OPENQA_API_KEY    = $ApiKey
    $env:OPENQA_API_SECRET = "WRONG_ENV_SECRET"
    try {
        & $ZoqaExe api --host $BaseUrl -X POST jobs 2>&1
    } finally {
        $env:OPENQA_CONFIG     = $savedCfg
        $env:OPENQA_API_KEY    = $savedKey
        $env:OPENQA_API_SECRET = $savedSec
    }
}

# Test W-16: CLI flags override wrong env var credentials (CLI > env priority)
Run-Test -Label "W-16: CLI flags override wrong env var creds" -ExpectedExit 0 -Cmd {
    $savedCfg = $env:OPENQA_CONFIG
    $savedKey = $env:OPENQA_API_KEY
    $savedSec = $env:OPENQA_API_SECRET
    $env:OPENQA_CONFIG     = $wrongConfDir
    $env:OPENQA_API_KEY    = "GARBAGE_KEY"
    $env:OPENQA_API_SECRET = "GARBAGE_SECRET"
    try {
        & $ZoqaExe api --host $BaseUrl `
            --apikey $ApiKey --apisecret $ApiSecret `
            -X POST isos DISTRI=winenvtest VERSION=1 FLAVOR=test ARCH=x86_64 2>&1
    } finally {
        $env:OPENQA_CONFIG     = $savedCfg
        $env:OPENQA_API_KEY    = $savedKey
        $env:OPENQA_API_SECRET = $savedSec
    }
}

Remove-Item -Path $wrongConfDir -Recurse -Force -ErrorAction SilentlyContinue

# =============================================================================
# Section C — Seeded data tests
# (mirrors tests_data.sh, zoqa-only; diff tests skipped)
# =============================================================================

Write-Host ""
Write-Host "==> [data] Running seeded data tests..."

# Test W-17: GET jobs/overview returns non-empty list after seeding
Run-Test -Label "W-17: GET jobs/overview (non-empty after seeding)" -ExpectedExit 0 -GrepPattern 'simple_boot' -Cmd {
    & $ZoqaExe api --host $BaseUrl jobs/overview 2>&1
}

# Test W-18: GET jobs/:id returns a real nested job object
Run-Test -Label "W-18: GET jobs/$JobId (nested object)" -ExpectedExit 0 -GrepPattern '"settings"' -Cmd {
    & $ZoqaExe api --host $BaseUrl "jobs/$JobId" 2>&1
}

# Test W-19: GET job_groups returns the seeded group
Run-Test -Label "W-19: GET job_groups (seeded group present)" -ExpectedExit 0 -GrepPattern '"example"' -Cmd {
    & $ZoqaExe api --host $BaseUrl job_groups 2>&1
}

# Test W-20: Relative and absolute path produce identical output
Write-Host ""
Write-Host "--- Test: W-20: relative vs absolute path parity ---"
$relOut = & $ZoqaExe api --host $BaseUrl "jobs/$JobId" 2>&1 | Out-String
$absOut = & $ZoqaExe api "$BaseUrl/api/v1/jobs/$JobId" 2>&1 | Out-String
# Normalise trailing whitespace before comparing
$relNorm = $relOut.TrimEnd()
$absNorm = $absOut.TrimEnd()
if ($relNorm -eq $absNorm) {
    Write-Host "PASS (relative and absolute outputs identical)"
} else {
    Write-Host "FAIL: relative and absolute path outputs differ"
    Write-Host "--- relative ---"
    Write-Host $relNorm
    Write-Host "--- absolute ---"
    Write-Host $absNorm
    $script:FailedTests++
}

# =============================================================================
# Section D — Output formatting tests
# (mirrors tests_output.sh; header-count comparison skipped)
# =============================================================================

Write-Host ""
Write-Host "==> [output] Running output formatting tests..."

# Test W-21: --verbose shows HTTP status line
Run-Test -Label "W-21: --verbose shows HTTP status line" -ExpectedExit 0 -GrepPattern 'HTTP/' -Cmd {
    & $ZoqaExe api --host $BaseUrl --verbose jobs/overview 2>&1
}

# Test W-22: --verbose includes Content-Type header
Run-Test -Label "W-22: --verbose includes Content-Type" -ExpectedExit 0 -GrepPattern 'Content-Type:' -Cmd {
    & $ZoqaExe api --host $BaseUrl --verbose jobs/overview 2>&1
}

# Test W-23: --pretty on a non-empty response produces indented JSON
Run-Test -Label "W-23: --pretty (non-empty, indented)" -ExpectedExit 0 -GrepPattern '(?m)^\s{2,}' -Cmd {
    & $ZoqaExe api --host $BaseUrl --pretty jobs/overview 2>&1
}

# Test W-24: --name flag accepted (exit 0)
Run-Test -Label "W-24: --name flag accepted (exit 0)" -ExpectedExit 0 -Cmd {
    & $ZoqaExe api --host $BaseUrl --name zoqa-e2e-windows jobs/overview 2>&1
}

# Test W-31: --links stream separation — next: must appear on stderr, not stdout.
# Mirrors test 43b from tests_output.sh.
# run_test / Run-ZoqaTest captures combined stdout+stderr; explicit per-stream
# redirects are required here to assert the stream-routing contract.
Write-Host ""
Write-Host "--- Test: W-31: --links next: on stderr, not stdout ---"
$linksStdout = Join-Path $script:LogDir "w31_stdout.log"
$linksStderr = Join-Path $script:LogDir "w31_stderr.log"
& $ZoqaExe api --host $BaseUrl --links "machines?limit=2" `
    2>$linksStderr 1>$linksStdout
$linksStderrContent = Get-Content -Path $linksStderr -Raw -ErrorAction SilentlyContinue
$linksStdoutContent = Get-Content -Path $linksStdout -Raw -ErrorAction SilentlyContinue
if (($linksStderrContent -match 'next:') -and (-not ($linksStdoutContent -match 'next:'))) {
    Write-Host "PASS (next: on stderr, not on stdout)"
} else {
    Write-Host "FAIL: --links stream routing incorrect"
    Write-Host "stdout: $linksStdoutContent"
    Write-Host "stderr: $linksStderrContent"
    $script:FailedTests++
}

# =============================================================================
# Section E — Robustness tests
# (mirrors tests_robustness.sh; broken pipe test skipped — complex in PS)
# =============================================================================

Write-Host ""
Write-Host "==> [robustness] Running robustness tests..."

# Test W-25: Non-2xx status line appears on stderr without --quiet
Write-Host ""
Write-Host "--- Test: W-25: non-2xx stderr without --quiet ---"
$stdoutFile = Join-Path $script:LogDir "w25_stdout.log"
$stderrFile = Join-Path $script:LogDir "w25_stderr.log"
# PowerShell 5+ redirects: 2> for stderr, > for stdout
& $ZoqaExe api --host $BaseUrl non_existent_e2e_route `
    2>$stderrFile 1>$stdoutFile
$stderrContent = Get-Content -Path $stderrFile -Raw -ErrorAction SilentlyContinue
if ($stderrContent -match '404') {
    Write-Host "PASS (404 reported on stderr without --quiet)"
} else {
    Write-Host "FAIL: expected '404' on stderr, got: $stderrContent"
    $script:FailedTests++
}

# Test W-26: --quiet suppresses the non-2xx status line on stderr
Write-Host ""
Write-Host "--- Test: W-26: non-2xx stderr suppressed with --quiet ---"
$stderrFileQ = Join-Path $script:LogDir "w26_stderr.log"
& $ZoqaExe api --host $BaseUrl --quiet non_existent_e2e_route `
    2>$stderrFileQ 1>$null
$stderrQ = Get-Content -Path $stderrFileQ -Raw -ErrorAction SilentlyContinue
if (-not ($stderrQ -match '404')) {
    Write-Host "PASS (--quiet suppressed 404 on stderr)"
} else {
    Write-Host "FAIL: --quiet did not suppress stderr: $stderrQ"
    $script:FailedTests++
}

# =============================================================================
# Section F — Retry and timeout knob tests
# (mirrors tests_retry_knobs.sh, full coverage)
# =============================================================================

Write-Host ""
Write-Host "==> [retry_knobs] Running retry/timeout knob tests..."

# Test W-27: OPENQA_CLI_RETRIES=0 accepted
Run-Test -Label "W-27: OPENQA_CLI_RETRIES=0 accepted" -ExpectedExit 0 -Cmd {
    $saved = $env:OPENQA_CLI_RETRIES
    $env:OPENQA_CLI_RETRIES = "0"
    try { & $ZoqaExe api --host $BaseUrl jobs/overview 2>&1 }
    finally { $env:OPENQA_CLI_RETRIES = $saved }
}

# Test W-28: OPENQA_CLI_RETRIES=abc falls back gracefully (no crash)
Run-Test -Label "W-28: OPENQA_CLI_RETRIES=abc falls back gracefully" -ExpectedExit 0 -Cmd {
    $saved = $env:OPENQA_CLI_RETRIES
    $env:OPENQA_CLI_RETRIES = "abc"
    try { & $ZoqaExe api --host $BaseUrl jobs/overview 2>&1 }
    finally { $env:OPENQA_CLI_RETRIES = $saved }
}

# Test W-29: Valid OPENQA_CLI_RETRY_SLEEP_TIME_S + OPENQA_CLI_RETRY_FACTOR accepted
Run-Test -Label "W-29: RETRY_SLEEP_TIME_S=1 RETRY_FACTOR=2.0 accepted" -ExpectedExit 0 -Cmd {
    $savedS = $env:OPENQA_CLI_RETRY_SLEEP_TIME_S
    $savedF = $env:OPENQA_CLI_RETRY_FACTOR
    $env:OPENQA_CLI_RETRY_SLEEP_TIME_S = "1"
    $env:OPENQA_CLI_RETRY_FACTOR       = "2.0"
    try { & $ZoqaExe api --host $BaseUrl jobs/overview 2>&1 }
    finally {
        $env:OPENQA_CLI_RETRY_SLEEP_TIME_S = $savedS
        $env:OPENQA_CLI_RETRY_FACTOR       = $savedF
    }
}

# Test W-30: Invalid OPENQA_CLI_RETRY_SLEEP_TIME_S + OPENQA_CLI_RETRY_FACTOR fall back gracefully
Run-Test -Label "W-30: RETRY_SLEEP_TIME_S=bad RETRY_FACTOR=bad fall back gracefully" -ExpectedExit 0 -Cmd {
    $savedS = $env:OPENQA_CLI_RETRY_SLEEP_TIME_S
    $savedF = $env:OPENQA_CLI_RETRY_FACTOR
    $env:OPENQA_CLI_RETRY_SLEEP_TIME_S = "bad"
    $env:OPENQA_CLI_RETRY_FACTOR       = "bad"
    try { & $ZoqaExe api --host $BaseUrl jobs/overview 2>&1 }
    finally {
        $env:OPENQA_CLI_RETRY_SLEEP_TIME_S = $savedS
        $env:OPENQA_CLI_RETRY_FACTOR       = $savedF
    }
}

# =============================================================================
# Summary
# =============================================================================

Write-Host ""
Write-Host "========================================"
if ($script:FailedTests -eq 0 -and $script:WarnedTests -eq 0) {
    Write-Host "==> All Windows E2E tests passed!"
} elseif ($script:FailedTests -eq 0) {
    Write-Host "==> All Windows E2E tests passed ($($script:WarnedTests) warning(s))."
} else {
    Write-Host "==> $($script:FailedTests) test(s) FAILED, $($script:WarnedTests) warning(s)." -ForegroundColor Red
}
Write-Host "========================================"

exit $script:FailedTests
