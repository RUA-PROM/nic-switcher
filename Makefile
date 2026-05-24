SHELL := /bin/bash

# Override if needed, e.g.:
# make POWERSHELL=pwsh test
# make POWERSHELL='powershell.exe' test
POWERSHELL ?= powershell.exe
PSFLAGS := -NoProfile -ExecutionPolicy Bypass
TEST_RUNNER := ./tests/Run-Tests.ps1

.PHONY: help test test-unit test-integration test-fast test-ci

help:
	@echo "Available targets:"
	@echo "  make test              # Unit + Integration + coverage (default target behavior)"
	@echo "  make test-unit         # Unit tests only"
	@echo "  make test-integration  # Integration tests only"
	@echo "  make test-fast         # Unit + Integration without coverage"
	@echo "  make test-ci           # Unit + Integration with 100% coverage target"
	@echo ""
	@echo "Options:"
	@echo "  POWERSHELL=...         # Default: powershell.exe"

test:
	$(POWERSHELL) $(PSFLAGS) -File "$(TEST_RUNNER)" -Suite All -Output Detailed

test-unit:
	$(POWERSHELL) $(PSFLAGS) -File "$(TEST_RUNNER)" -Suite Unit -Output Detailed

test-integration:
	$(POWERSHELL) $(PSFLAGS) -File "$(TEST_RUNNER)" -Suite Integration -Output Detailed

test-fast:
	$(POWERSHELL) $(PSFLAGS) -File "$(TEST_RUNNER)" -Suite All -Output Normal -NoCoverage

test-ci:
	$(POWERSHELL) $(PSFLAGS) -File "$(TEST_RUNNER)" -Suite All -Output Detailed -CoveragePercentTarget 100
