# Makefile — openQAclient
#
# Convenience targets wrapping the standard Zig and Bash commands.
# All targets are documented below; run `make help` for a quick reference.
#
# TODO: add a `fuzz` target once the AFL++ workflow is stable enough to drive
#       from here (see tests/fuzz/README.md for the current manual workflow).

.PHONY: help build release test e2e e2e-keep e2e-lint fuzz-build

# Default target
help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "Targets:"
	@echo "  build       Build the zoqa executable and static library."
	@echo "  release     Build with release optimizations."
	@echo "  test        Run all Zig unit tests."
	@echo "  e2e         Build, then run the full E2E suite (starts + tears down container)."
	@echo "              Optional: SUITES=core,auth  — run only the listed suite(s)."
	@echo "  e2e-keep    Build, then run E2E keeping the container alive (--keep-container)."
	@echo "  e2e-lint        Run bash -n syntax check and shellcheck on all E2E scripts."
	@echo "  fuzz-build  Build the fuzzy app."

# -----------------------------------------------------------------------------
# Build
# -----------------------------------------------------------------------------
build:
	zig build

release:
	zig build -Doptimize=ReleaseFast

# -----------------------------------------------------------------------------
# Fuzz
# -----------------------------------------------------------------------------
fuzz-build:
	./tests/fuzz/build.sh

# -----------------------------------------------------------------------------
# Unit Tests
# -----------------------------------------------------------------------------
test:
	zig build test --summary all

# -----------------------------------------------------------------------------
# Near End-to-End Tests
# -----------------------------------------------------------------------------
e2e: build
	bash tests/e2e/run.sh $(if $(SUITES),--suites $(SUITES),)

e2e-keep: build
	bash tests/e2e/run.sh --keep-container $(if $(SUITES),--suites $(SUITES),)

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
	tests/e2e/tests_perf.sh

e2e-lint:
	@echo "==> bash -n syntax check"
	@for f in $(E2E_SCRIPTS); do \
		bash -n "$$f" && echo "  OK  $$f" || echo "  FAIL $$f"; \
	done
	@echo "==> shellcheck"
	@shellcheck $(E2E_SCRIPTS)
	@echo "==> e2e-lint passed"
