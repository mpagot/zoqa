# run_windows.ps1 — Windows E2E orchestrator for zoqa.
#
# Coordinates the full Windows end-to-end flow:
#
#   1. Verifies that zig-out\bin\zoqa.exe exists (build it yourself first).
#   2. Starts the openQA container in WSL (run_container.sh --expose-ports).
#   3. Reads the PowerShell env file written by run_container.sh.
#   4. Resolves the WSL IP so tests reach the container on port 8080.
#   5. Runs run_tests.ps1 (native Windows, zoqa.exe only).
#   6. Signals run_container.sh to begin teardown (sentinel file).
#   7. Waits for teardown to complete.
#   8. Exits with the test result code.
#
# Prerequisites:
#   - zoqa.exe built natively: zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe
#   - WSL2 installed with a Linux distro that has Podman available.
#   - PowerShell 5.1+ or pwsh 7+ on Windows.
#
# Usage:
#   pwsh tests\e2e\run_windows.ps1 [OPTIONS]
#
# OPTIONS:
#   -WslDistro <name>  WSL distro to use (e.g. "Ubuntu-22.04", "openSUSE-Tumbleweed").
#                      Defaults to the system WSL default (wsl --set-default).
#                      Run 'wsl --list' to see available distros.
#   -CollectLogs       Pass --collect-logs to run_container.sh.
#   -DryRun            Pass --dryrun to run_container.sh (no container started).
#   -Help              Show this help message and exit.
#
# NOTES:
#   The script assumes it is run from the repository root, i.e. the directory
#   that contains build.zig.  It converts Windows paths to WSL paths as needed
#   using 'wsl wslpath'.

[CmdletBinding()]
param(
    # WSL distro name to use.  Empty string = WSL default distro.
    # Example: -WslDistro "openSUSE-Tumbleweed"
    # List available distros: wsl --list --verbose
    [string] $WslDistro   = "",
    [switch] $CollectLogs,
    [switch] $DryRun,
    [switch] $Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Ensure WSL UTF-8 output is not garbled by the console's default code page.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
if ($Help) {
    Get-Help $MyInvocation.MyCommand.Path -Full
    exit 0
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step([string]$Msg) {
    Write-Host ""
    Write-Host "==> $Msg"
}

# Invoke-Wsl — run a command inside the chosen WSL distro.
#
# When $WslDistro is non-empty, passes -d <distro> to wsl.exe so that the
# correct distro is used regardless of the system default.
# When $WslDistro is empty, relies on the WSL default (wsl --set-default).
#
# Usage:
#   Invoke-Wsl "hostname" "-I"          # positional string args
#   Invoke-Wsl @("wslpath", "-u", $p)   # array of args
function Invoke-Wsl {
    param([string[]]$WslArgs)
    if ($WslDistro -ne "") {
        $result = wsl -d $WslDistro @WslArgs 2>&1 | Out-String
    } else {
        $result = wsl @WslArgs 2>&1 | Out-String
    }
    return $result.Trim()
}

# Start-WslProcess — launch a WSL command in the background (via Start-Job).
# Returns the job object.
function Start-WslProcess {
    param([string[]]$WslArgs)
    if ($WslDistro -ne "") {
        return Start-Job -ScriptBlock {
            param($distro, $WslArguments)
            wsl -d $distro @WslArguments
        } -ArgumentList $WslDistro, (, $WslArgs)
    } else {
        return Start-Job -ScriptBlock {
            param($WslArguments)
            wsl @WslArguments
        } -ArgumentList (, $WslArgs)
    }
}

# Signal-WslSentinel — touch a file inside WSL (used to trigger teardown).
function Signal-WslSentinel {
    param([string]$Path)
    if ($WslDistro -ne "") {
        wsl -d $WslDistro -- touch $Path
    } else {
        wsl -- touch $Path
    }
}

# Resolve the repo root (the directory containing build.zig).
$repoRoot = $PSScriptRoot | Split-Path -Parent | Split-Path -Parent
if (-not (Test-Path (Join-Path $repoRoot "build.zig"))) {
    # Fallback: assume we're already at the repo root.
    $repoRoot = Get-Location
}
Write-Step "Repository root: $repoRoot"
Set-Location $repoRoot

# Show which WSL distro will be used so the user can detect mismatches early.
if ($WslDistro -ne "") {
    Write-Host "    WSL distro: $WslDistro (explicit -WslDistro)"
} else {
    $defaultDistro = Invoke-Wsl @("--exec", "bash", "-c", 'echo $WSL_DISTRO_NAME')
    Write-Host "    WSL distro: $defaultDistro (system default — use -WslDistro to override)"
}

# ---------------------------------------------------------------------------
# Preflight — verify zoqa.exe exists (user must build it natively beforehand)
# ---------------------------------------------------------------------------
$zoqaExe = Join-Path $repoRoot "zig-out\bin\zoqa.exe"

if (-not (Test-Path $zoqaExe)) {
    Write-Host "ERROR: zoqa.exe not found at '$zoqaExe'." -ForegroundColor Red
    Write-Host "       Build it first with:" -ForegroundColor Red
    Write-Host "         zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe" -ForegroundColor Red
    exit 1
}
Write-Host "    zoqa.exe: $zoqaExe"

# Print MD5 and last-modified date of zoqa.exe.
# Get-FileHash is available in PowerShell 4+ (always present on Win 8.1+).
# (Get-Item) is always available.  Both are optional — errors are silently
# swallowed so a missing tool never aborts the run.
# Runs unconditionally (including -DryRun) as long as the binary exists.
try {
    $hash = (Get-FileHash -Algorithm MD5 -Path $zoqaExe -ErrorAction Stop).Hash
    Write-Host "    zoqa.exe md5   : $hash"
} catch {}
try {
    $mtime = (Get-Item $zoqaExe -ErrorAction Stop).LastWriteTime
    Write-Host "    zoqa.exe mtime : $mtime"
} catch {}

# ---------------------------------------------------------------------------
# Start the container in WSL (background job)
# ---------------------------------------------------------------------------
Write-Step "Starting openQA container in WSL (run_container.sh)..."

$wslRepoRoot = Invoke-Wsl @("wslpath", "-u", ($repoRoot -replace '\\', '\\\\'))

# Compute the env file path before launching the container so we can pass it
# to run_container.sh.  Use $env:TEMP (a real NTFS path) instead of /tmp inside
# WSL so that dot-sourcing the file is not blocked by PowerShell's execution
# policy (UNC paths like \\wsl.localhost\... are treated as untrusted network
# locations and cannot be dot-sourced).
$psEnvFile  = Join-Path $env:TEMP "openqa_e2e_env.ps1"
$wslEnvFile = Invoke-Wsl @("wslpath", "-u", ($psEnvFile -replace '\\', '\\\\'))
Write-Host "    Env file (Windows): $psEnvFile"
Write-Host "    Env file (WSL):     $wslEnvFile"

# Build argument list for run_container.sh.
# We use bash -c "cd ... && bash ..." so the script runs from the repo root
# regardless of what directory WSL defaults to on launch.
$containerCmdLine = "cd '$wslRepoRoot' && bash tests/e2e/run_container.sh --env-file '$wslEnvFile'"
if ($CollectLogs) { $containerCmdLine += " --collect-logs" }
if ($DryRun)      { $containerCmdLine += " --dryrun" }

$containerCmdArgs = @("--", "bash", "-c", $containerCmdLine)
$containerJob = Start-WslProcess -WslArgs $containerCmdArgs

Write-Host "    Container job started (job ID: $($containerJob.Id))"
Write-Host "    WSL command: bash -c `"$containerCmdLine`""

# Give the job a moment to start, then check it hasn't immediately failed.
Start-Sleep -Seconds 3
if ($containerJob.State -eq 'Failed' -or $containerJob.State -eq 'Stopped') {
    Write-Host "ERROR: Container job failed immediately after launch." -ForegroundColor Red
    Receive-Job -Job $containerJob | Write-Host
    exit 1
}
Write-Host "    Container job state after 3s: $($containerJob.State)"

# ---------------------------------------------------------------------------
# Wait for the env file to appear (run_container.sh writes it after seeding)
# ---------------------------------------------------------------------------
# Write the env file into the native Windows TEMP directory (a real NTFS path)
# rather than /tmp inside WSL.  UNC paths (\\wsl.localhost\...) are treated as
# untrusted network locations by PowerShell's execution policy and cannot be
# dot-sourced.  We pass the WSL equivalent of $env:TEMP to run_container.sh so
# it knows where to write the file.
$psEnvFile  = Join-Path $env:TEMP "openqa_e2e_env.ps1"
$wslEnvFile = Invoke-Wsl @("wslpath", "-u", ($psEnvFile -replace '\\', '\\\\'))
Write-Host "    Env file (Windows): $psEnvFile"
Write-Host "    Env file (WSL):     $wslEnvFile"

Write-Step "Waiting for container to finish bootstrap and seeding..."
Write-Host "    Polling for: $psEnvFile"

$timeout  = 1200   # 20 minutes
$interval = 10     # poll every 10s
$elapsed  = 0

while (-not (Test-Path $psEnvFile)) {
    if ($elapsed -ge $timeout) {
        Write-Host "ERROR: Timed out after ${timeout}s waiting for $psEnvFile" -ForegroundColor Red
        Write-Host "--- Container job output so far ---" -ForegroundColor Yellow
        Receive-Job -Job $containerJob | Write-Host
        # Signal teardown anyway
        Signal-WslSentinel -Path "/tmp/openqa_e2e_done"
        exit 1
    }
    # Check if the container job died unexpectedly
    if ($containerJob.State -eq 'Failed' -or $containerJob.State -eq 'Stopped') {
        Write-Host "ERROR: Container job ended prematurely (state: $($containerJob.State))." -ForegroundColor Red
        Write-Host "--- Container job output ---" -ForegroundColor Yellow
        Receive-Job -Job $containerJob | Write-Host
        exit 1
    }
    # Every 30s print job state and flush any new output from the WSL job
    if ($elapsed -gt 0 -and $elapsed % 30 -eq 0) {
        Write-Host "    ... still waiting (${elapsed}s elapsed, job state: $($containerJob.State)) ..."
        $jobOutput = Receive-Job -Job $containerJob
        if ($jobOutput) {
            Write-Host "--- WSL output ---" -ForegroundColor Cyan
            $jobOutput | Write-Host
            Write-Host "--- end WSL output ---" -ForegroundColor Cyan
        }
    } else {
        Write-Host "    ... still waiting (${elapsed}s elapsed) ..."
    }
    Start-Sleep -Seconds $interval
    $elapsed += $interval
}

Write-Host "    Env file ready after ${elapsed}s."

# ---------------------------------------------------------------------------
# Source the env file
# ---------------------------------------------------------------------------
Write-Step "Loading credentials and seeded IDs from $psEnvFile ..."
# The file is in $env:TEMP (a real NTFS path), so dot-sourcing works without
# execution policy issues.
. $psEnvFile

# Verify the host is reachable (quick smoke test before running tests)
if (-not $DryRun) {
    Write-Host "    E2E host: $env:OPENQA_E2E_HOST"
    # Give a few seconds for any last network initialisation
    Start-Sleep -Seconds 3
    try {
        $resp = Invoke-WebRequest -Uri "$env:OPENQA_E2E_HOST/api/v1/jobs/overview" `
            -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        Write-Host "    Host reachable — HTTP $($resp.StatusCode)"
    } catch {
        Write-Host "    WARNING: preflight GET failed: $_" -ForegroundColor Yellow
        Write-Host "    Tests will still run; individual failures will be reported."
    }
}

# ---------------------------------------------------------------------------
# Run the Windows test suite
# ---------------------------------------------------------------------------
Write-Step "Running Windows E2E tests (run_tests.ps1)..."

$testScript = Join-Path $repoRoot "tests\e2e\run_tests.ps1"
& $testScript `
    -ZoqaExe  $zoqaExe `
    -BaseUrl  $env:OPENQA_E2E_HOST `
    -ApiKey   $env:OPENQA_API_KEY `
    -ApiSecret $env:OPENQA_API_SECRET `
    -JobId    $env:JOB_ID `
    -GroupId  $env:GROUP_ID

$testResult = $LASTEXITCODE

# ---------------------------------------------------------------------------
# Signal teardown
# ---------------------------------------------------------------------------
Write-Step "Signalling teardown (touching /tmp/openqa_e2e_done in WSL)..."
Signal-WslSentinel -Path "/tmp/openqa_e2e_done"

# ---------------------------------------------------------------------------
# Wait for container job to finish teardown
# ---------------------------------------------------------------------------
Write-Step "Waiting for container teardown to complete..."
$containerJob | Wait-Job -Timeout 120 | Out-Null
if ($containerJob.State -eq 'Running') {
    Write-Host "    WARNING: container job did not finish within 120s; stopping it." -ForegroundColor Yellow
    Stop-Job -Job $containerJob
}
$containerJob | Receive-Job
Remove-Job -Job $containerJob -Force

# Clean up the PS env file
Remove-Item -Path $psEnvFile -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Exit with test result
# ---------------------------------------------------------------------------
Write-Host ""
if ($testResult -eq 0) {
    Write-Host "==> Windows E2E suite: ALL TESTS PASSED" -ForegroundColor Green
} else {
    Write-Host "==> Windows E2E suite: $testResult TEST(S) FAILED" -ForegroundColor Red
}

exit $testResult
