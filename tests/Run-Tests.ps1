# Run-Tests.ps1
#
# テストランナー。Pester 5.x が必須。
#
#   -Suite Unit         単体テストのみ（モック使用）
#   -Suite Integration  結合テストのみ（quser / ファイル I/O / Set-NetIPInterface -WhatIf）
#   -Suite All          両方（既定）
#
#   -NoCoverage         カバレッジ測定を無効化（高速化）

[CmdletBinding()]
param(
    [ValidateSet('All', 'Unit', 'Integration')]
    [string]$Suite = 'All',

    [ValidateSet('Normal','Detailed','Diagnostic')]
    [string]$Output = 'Detailed',

    [switch]$NoCoverage
)

$ErrorActionPreference = 'Stop'

# --- Pester 5.x を検出 -----------------------------------------------------

$pester = Get-Module -ListAvailable -Name Pester |
    Where-Object { $_.Version.Major -ge 5 } |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $pester) {
    Write-Host "Pester 5.x が必要です。" -ForegroundColor Yellow
    Write-Host "以下でインストールしてください:" -ForegroundColor Yellow
    Write-Host "  Install-Module -Name Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck"
    exit 1
}

Import-Module $pester.Path -Force

# --- 実行対象のテストパスを決定 -------------------------------------------

$paths = switch ($Suite) {
    'Unit'        { @( (Join-Path $PSScriptRoot 'unit') ) }
    'Integration' { @( (Join-Path $PSScriptRoot 'integration') ) }
    default       { @( (Join-Path $PSScriptRoot 'unit'), (Join-Path $PSScriptRoot 'integration') ) }
}

# --- Pester 設定 -----------------------------------------------------------

$config = New-PesterConfiguration
$config.Run.Path        = $paths
$config.Output.Verbosity = $Output
$config.Run.PassThru     = $true

if (-not $NoCoverage) {
    $modulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\lib\NicSwitcher.psm1')).Path
    $config.CodeCoverage.Enabled        = $true
    $config.CodeCoverage.Path           = $modulePath
    $config.CodeCoverage.OutputFormat   = 'JaCoCo'
    $config.CodeCoverage.OutputPath     = (Join-Path $PSScriptRoot 'coverage.xml')
    $config.CodeCoverage.CoveragePercentTarget = 90
}

$result = Invoke-Pester -Configuration $config

# --- カバレッジサマリーを表示 ---------------------------------------------

if (-not $NoCoverage -and $result.CodeCoverage) {
    $cov = $result.CodeCoverage
    $covered = $cov.CommandsExecutedCount
    $total   = $cov.CommandsAnalyzedCount
    $rate    = if ($total -gt 0) { [math]::Round(($covered / $total) * 100, 2) } else { 0 }

    Write-Host ""
    Write-Host "=== コードカバレッジ ==============================================" -ForegroundColor Cyan
    Write-Host ("実行された命令: {0} / {1}" -f $covered, $total)
    Write-Host ("カバレッジ率  : {0}%" -f $rate) -ForegroundColor $(if ($rate -ge 90) { 'Green' } elseif ($rate -ge 75) { 'Yellow' } else { 'Red' })
    Write-Host ("レポート      : {0}" -f $config.CodeCoverage.OutputPath.Value)

    if ($cov.CommandsMissedCount -gt 0) {
        Write-Host ""
        Write-Host "未到達の行:" -ForegroundColor Yellow
        $cov.CommandsMissed | ForEach-Object {
            Write-Host ("  {0}:{1} {2}" -f (Split-Path $_.File -Leaf), $_.Line, $_.Command)
        }
    }
    Write-Host "==================================================================" -ForegroundColor Cyan
}

# テスト失敗時は非0で終了
if ($result.FailedCount -gt 0) { exit 1 }
