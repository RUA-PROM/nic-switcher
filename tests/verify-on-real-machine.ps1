# verify-on-real-machine.ps1
#
# 実機での動作確認スクリプト。管理者 PowerShell で実行する。
#
#   1. 現在のメトリックを記録
#   2. install.ps1 を再実行してタスクを最新コードで再登録
#   3. nic_handler.ps1 を実ユーザー名で手動実行して Set-NetIPInterface まで通す
#   4. メトリックが期待通り変化したか確認
#   5. ログを表示

#Requires -RunAsAdministrator

$root      = Split-Path $PSScriptRoot -Parent
$handler   = Join-Path $root 'nic_handler.ps1'
$installer = Join-Path $root 'install.ps1'
$config    = Join-Path $root 'config.ps1'

if (-not (Test-Path $config)) {
    Write-Error "config.ps1 が見つかりません: $config"
    exit 1
}
. $config

Write-Host "=== 1. 検証前のメトリック ===" -ForegroundColor Cyan
Get-NetIPInterface -InterfaceIndex $PriorityInterfaceIndex, $DefaultInterfaceIndex |
    Select-Object InterfaceAlias, InterfaceIndex, AddressFamily, InterfaceMetric |
    Format-Table -AutoSize

Write-Host "=== 2. install.ps1 を再実行（タスク XML を最新コードで再生成） ===" -ForegroundColor Cyan
& $installer
Write-Host ""

Write-Host "=== 3. 現在ログオン中の優先ユーザーで handler を実行 ===" -ForegroundColor Cyan
# 現在ログオンしているユーザーから、優先パターンに合うものを抽出
$activeUser = (& quser.exe 2>$null | Select-Object -Skip 1 | ForEach-Object {
    if ($_ -match '\bActive\b') {
        ($_.Trim() -split '\s+', 2)[0].TrimStart('>')
    }
} | Where-Object { $_ -match $PriorityUserPattern } | Select-Object -First 1)

if (-not $activeUser) {
    Write-Warning "優先ユーザー（パターン: $PriorityUserPattern）のアクティブセッションがありません。"
    Write-Warning "ログオンし直してから再実行してください。"
    exit 1
}

Write-Host "  対象ユーザー: $activeUser"
& $handler -UserName $activeUser
Write-Host ""

Write-Host "=== 4. 検証後のメトリック ===" -ForegroundColor Cyan
Get-NetIPInterface -InterfaceIndex $PriorityInterfaceIndex, $DefaultInterfaceIndex |
    Select-Object InterfaceAlias, InterfaceIndex, AddressFamily, InterfaceMetric |
    Format-Table -AutoSize

Write-Host "=== 5. 最新ログ（末尾10行） ===" -ForegroundColor Cyan
Get-Content $LogFile -Encoding UTF8 -Tail 10

Write-Host ""
Write-Host "=== 期待結果 ===" -ForegroundColor Yellow
Write-Host "  優先 NIC (Index=$PriorityInterfaceIndex) のメトリック = $PreferredMetric"
Write-Host "  通常 NIC (Index=$DefaultInterfaceIndex) のメトリック = $DemotedMetric"
Write-Host "  ログ末尾に 'Applied: interface (Index=$PriorityInterfaceIndex) preferred' が含まれること"
