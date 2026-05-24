SHELL := /bin/bash

# 必要に応じて上書き可能:
# make POWERSHELL=pwsh test
# make POWERSHELL='powershell.exe' test
POWERSHELL ?= powershell.exe
PSFLAGS := -NoProfile -ExecutionPolicy Bypass
TEST_RUNNER := ./tests/Run-Tests.ps1

.PHONY: help security fmt test test-unit test-integration test-fast test-ci

help:
	@echo "利用可能なターゲット:"
	@echo "  make security         # PowerShell セキュリティ診断"
	@echo "  make fmt              # PowerShell ファイルの整形チェック"
	@echo "  make test             # security + fmt + 単体/結合テスト + カバレッジ"
	@echo "  make test-unit        # 単体テストのみ"
	@echo "  make test-integration # 結合テストのみ"
	@echo "  make test-fast        # security + fmt + 単体/結合テスト（カバレッジなし）"
	@echo "  make test-ci          # security + fmt + 単体/結合テスト + カバレッジ 100%"
	@echo ""
	@echo "オプション:"
	@echo "  POWERSHELL=...         # 既定: powershell.exe"

security:
	$(POWERSHELL) $(PSFLAGS) -File "./tests/Invoke-SecurityCheck.ps1"

fmt:
	$(POWERSHELL) $(PSFLAGS) -File "./tests/Invoke-FormatCheck.ps1"

test:
	$(MAKE) security
	$(MAKE) fmt
	$(POWERSHELL) $(PSFLAGS) -File "$(TEST_RUNNER)" -Suite All -Output Detailed

test-unit:
	$(POWERSHELL) $(PSFLAGS) -File "$(TEST_RUNNER)" -Suite Unit -Output Detailed

test-integration:
	$(POWERSHELL) $(PSFLAGS) -File "$(TEST_RUNNER)" -Suite Integration -Output Detailed

test-fast:
	$(MAKE) security
	$(MAKE) fmt
	$(POWERSHELL) $(PSFLAGS) -File "$(TEST_RUNNER)" -Suite All -Output Normal -NoCoverage

test-ci:
	$(MAKE) security
	$(MAKE) fmt
	$(POWERSHELL) $(PSFLAGS) -File "$(TEST_RUNNER)" -Suite All -Output Detailed -CoveragePercentTarget 100
