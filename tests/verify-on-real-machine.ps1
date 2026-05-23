# verify-on-real-machine.ps1
#
# 実機での動作確認スクリプト。管理者 PowerShell で実行する。
#
#   1. 現在のメトリックを記録
#   2. install.ps1 を再実行してタスクを最新コードで再登録
#   3. nic_handler.ps1 を実ユーザー名で手動実行して Set-NetIPInterface まで通す
#   4. メトリックが期待通り変化したか確認
#   5. ログを表示
#   6. ログローテーションを少量データで実機検証する

#Requires -RunAsAdministrator

$root      = Split-Path $PSScriptRoot -Parent
$handler   = Join-Path $root 'nic_handler.ps1'
$installer = Join-Path $root 'install.ps1'
$config    = Join-Path $root 'config.ps1'
$module    = Join-Path $root 'lib\NicSwitcher.psm1'

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
Write-Host "=== 6. ログローテーションの実機検証 ===" -ForegroundColor Cyan
# 本番ログには手を入れず、独立した一時ログでローテーション挙動を検証する。
Import-Module $module -Force

$rotLog = Join-Path $env:TEMP "nic-switcher-rotation-verify-$([guid]::NewGuid().ToString('N')).log"
$rotMax = 200  # 200 バイトで強制的にローテーションを発生させる

try {
    Write-Host "  対象一時ログ: $rotLog"
    Write-Host "  閾値: $rotMax bytes / 世代上限: 2"

    # 1 回目: 新規作成
    Write-NicLog -Path $rotLog -Message ('A' * 300) -MaxBytes $rotMax -MaxBackups 2
    $size1 = (Get-Item $rotLog).Length
    Write-Host "    1回目書き込み後: $size1 bytes (新規ファイル)"

    # 2 回目: 閾値超過 → ローテーション
    Write-NicLog -Path $rotLog -Message 'second write' -MaxBytes $rotMax -MaxBackups 2
    $exists1 = Test-Path "$rotLog.1"
    $size2   = (Get-Item $rotLog).Length
    Write-Host "    2回目書き込み後: .log.1 存在=$exists1 / 新.log=$size2 bytes"

    # 3 回目: もう一度閾値超過 → さらにローテーション
    Write-NicLog -Path $rotLog -Message ('B' * 300) -MaxBytes $rotMax -MaxBackups 2
    Write-NicLog -Path $rotLog -Message 'third write' -MaxBytes $rotMax -MaxBackups 2
    $exists2 = Test-Path "$rotLog.2"
    Write-Host "    3回目書き込み後: .log.2 存在=$exists2"

    # 結果判定
    if ($exists1 -and $exists2) {
        Write-Host "  ローテーション動作: OK" -ForegroundColor Green
    } else {
        Write-Host "  ローテーション動作: 失敗（.log.1=$exists1 / .log.2=$exists2）" -ForegroundColor Red
    }
} finally {
    # 後始末
    Remove-Item "$rotLog*" -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "=== 期待結果 ===" -ForegroundColor Yellow
Write-Host "  優先 NIC (Index=$PriorityInterfaceIndex) のメトリック = $PreferredMetric"
Write-Host "  通常 NIC (Index=$DefaultInterfaceIndex) のメトリック = $DemotedMetric"
Write-Host "  ログ末尾に 'Applied: interface (Index=$PriorityInterfaceIndex) preferred' が含まれること"
Write-Host "  ローテーション動作 = OK と表示されていること"
