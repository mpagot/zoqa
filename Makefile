# Makefile — openQAclient
#
# Convenience targets wrapping the standard Zig and Bash commands.
# All targets are documented below; run `make help` for a quick reference.
#
# TODO: add a `fuzz` target once the AFL++ workflow is stable enough to drive
#       from here (see tests/fuzz/README.md for the current manual workflow).

.PHONY: help zig-build-debug zig-release zig-test zig-test-discovery zig-lint e2e e2e-keep e2e-dryrun e2e-lint manual-lint fuzz-lint zig-docstring lint fuzz-build

# Default target
help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "Targets:"
	@echo "  zig-build-debug  Build the zoqa executable and static library (debug)."
	@echo "  zig-release      Build with release optimizations and strip symbols."
	@echo "  zig-test    Run all Zig unit tests."
	@echo "  zig-test-discovery  Verify every \`test\` block in src/ is actually run."
	@echo "                      Catches Zig issue #10018 (lazy-analysis silently"
	@echo "                      drops tests in unreferenced files). Runs the suite."
	@echo "  e2e         Run the full E2E suite (starts + tears down container)."
	@echo "              Requires zig-out/bin/zoqa to exist."
	@echo "              Optional: SUITES=core,auth  — run only the listed suite(s)."
	@echo "              Optional: SUITES=           — run no tests (deployment check)."
	@echo "  e2e-keep    Run E2E keeping the container alive (--keep-container)."
	@echo "              Optional: SUITES=           — deploy only, skip all tests."
	@echo "  e2e-dryrun  Simulate E2E run without starting container (--dryrun)."
	@echo "  zig-lint    Check Zig source formatting (zig fmt --check src/)."
	@echo "  e2e-lint        Run bash -n, shellcheck, and suite registry check on E2E scripts."
	@echo "  manual-lint     Run bash -n and shellcheck on manual test scripts."
	@echo "  fuzz-lint       Run bash -n and shellcheck on tests/fuzz/ scripts."
	@echo "  lint        Run all linters (zig-lint, e2e-lint, manual-lint, fuzz-lint)."
	@echo "  zig-docstring  Check /// docstring completeness for fn declarations in src/."
	@echo "                  Optional: WITH_PRIVATE=1  — also check private functions."
	@echo "  fuzz-build  Build the fuzzy app."

# -----------------------------------------------------------------------------
# Build
# -----------------------------------------------------------------------------
zig-build-debug:
	zig build

zig-release:
	zig build -Doptimize=ReleaseFast -Dstrip=true

# -----------------------------------------------------------------------------
# Fuzz
# -----------------------------------------------------------------------------
fuzz-build:
	./tests/fuzz/build.sh

# -----------------------------------------------------------------------------
# Unit Tests
# -----------------------------------------------------------------------------
zig-test:
	zig build test --summary all

# Verify every `test` block declared in src/*.zig is actually executed by the
# runner. Catches Zig's lazy-analysis silently dropping test blocks in files
# that are imported but never fully analyzed (issue #10018). Runs `zig build
# test` internally as part of the check.
zig-test-discovery:
	bash tools/check_test_count.sh .

# -----------------------------------------------------------------------------
# Near End-to-End Tests
# -----------------------------------------------------------------------------

# Internal helper: if SUITES is defined (even if empty), pass it to --suites.
# This allows 'make e2e SUITES=' to run zero tests.
E2E_SUITES_ARG := $(if $(filter-out undefined,$(origin SUITES)),--suites "$(SUITES)",)

# isotovideo storage-check keep-free ratio.
# Unset (default) = isotovideo built-in 20% keep-free check applies.
# Set to 0 to disable the check on CI hosts with low free space:
#   make e2e E2E_STORAGE_KEEP_FREE_RATIO=0
ifdef E2E_STORAGE_KEEP_FREE_RATIO
export E2E_STORAGE_KEEP_FREE_RATIO
endif

e2e:
	bash tests/e2e/run.sh $(E2E_SUITES_ARG)

e2e-keep:
	bash tests/e2e/run.sh --keep-container $(E2E_SUITES_ARG)

e2e-dryrun:
	bash tests/e2e/run.sh --dryrun $(E2E_SUITES_ARG)

# -----------------------------------------------------------------------------
# Linting — bash syntax check + shellcheck on all E2E scripts
# -----------------------------------------------------------------------------
E2E_SCRIPTS := \
	tests/e2e/run.sh \
	tests/e2e/tests.sh \
	tests/e2e/setup.sh \
	tests/e2e/teardown.sh \
	tests/e2e/seed_fixtures.sh \
	tests/e2e/lib.sh \
	tests/e2e/tests_archive.sh \
	tests/e2e/tests_auth.sh \
	tests/e2e/tests_core.sh \
	tests/e2e/tests_data.sh \
	tests/e2e/tests_output.sh \
	tests/e2e/tests_retry_knobs.sh \
	tests/e2e/tests_robustness.sh \
	tests/e2e/tests_monitor.sh \
	tests/e2e/tests_schedule.sh \
	tests/e2e/tests_clone_job.sh \
	tests/e2e/tests_help.sh \
	tests/e2e/tests_perf.sh \
	tests/e2e/tests_stress.sh \
	tests/e2e/check_suite_registry.sh

e2e-lint:
	@echo "==> bash -n syntax check"
	@for f in $(E2E_SCRIPTS); do \
		bash -n "$$f" && echo "  OK  $$f" || echo "  FAIL $$f"; \
	done
	@echo "==> shellcheck"
	@shellcheck $(E2E_SCRIPTS)
	@echo "==> suite registry check"
	@bash tests/e2e/check_suite_registry.sh
	@echo "==> e2e-lint passed"

# -----------------------------------------------------------------------------
# Linting — bash syntax check + shellcheck on manual test scripts
# -----------------------------------------------------------------------------
MANUAL_SCRIPTS := \
	tests/manual/lib.sh \
	tests/manual/test_api.sh \
	tests/manual/test_archive.sh \
	tests/manual/test_schedule_monitor.sh

manual-lint:
	@echo "==> bash -n syntax check"
	@for f in $(MANUAL_SCRIPTS); do \
		bash -n "$$f" && echo "  OK  $$f" || echo "  FAIL $$f"; \
	done
	@echo "==> shellcheck"
	@shellcheck -x $(MANUAL_SCRIPTS)
	@echo "==> manual-lint passed"

# -----------------------------------------------------------------------------
# Linting — bash syntax check + shellcheck on fuzz harness scripts
# -----------------------------------------------------------------------------
FUZZ_SCRIPTS := \
	tests/fuzz/build.sh \
	tests/fuzz/cmin.sh \
	tests/fuzz/coverage.sh \
	tests/fuzz/distill.sh \
	tests/fuzz/run.sh

fuzz-lint:
	@echo "==> bash -n syntax check"
	@for f in $(FUZZ_SCRIPTS); do \
		bash -n "$$f" && echo "  OK  $$f" || echo "  FAIL $$f"; \
	done
	@echo "==> shellcheck"
	@shellcheck $(FUZZ_SCRIPTS)
	@echo "==> fuzz-lint passed"

# -----------------------------------------------------------------------------
# Linting — Zig source formatting check
# -----------------------------------------------------------------------------
zig-lint:
	@echo "==> zig fmt --check src/"
	@zig fmt --check src/
	@echo "==> zig-lint passed"

# -----------------------------------------------------------------------------
# Docstring completeness check
# -----------------------------------------------------------------------------
# Check that every pub/export fn declaration in src/*.zig has a complete /// doc
# comment (summary, Arguments:, Returns:, Errors: as appropriate).
# Optional: pass WITH_PRIVATE=1 to also check private functions.
#   make zig-docstring
#   make zig-docstring WITH_PRIVATE=1
DOCSTRING_FLAGS := $(if $(WITH_PRIVATE),--with-private,)

zig-docstring:
	@echo "==> docstring completeness check"
	@python3 tools/check_docstrings.py $(DOCSTRING_FLAGS) .
	@echo "==> zig-docstring passed"

# -----------------------------------------------------------------------------
# Aggregate lint target
# -----------------------------------------------------------------------------
lint: zig-lint e2e-lint manual-lint fuzz-lint
	@echo "==> all linters passed"
