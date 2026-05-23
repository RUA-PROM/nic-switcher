# nic-switcher アンインストーラ
# install.ps1 が登録したスケジュールタスクを削除する。

#Requires -RunAsAdministrator

$configPath = Join-Path $PSScriptRoot 'config.ps1'
if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Error "config.ps1 が見つかりません。"
    exit 1
}
. $configPath

schtasks /Delete /TN $TaskName /F
Write-Host "タスク '$TaskName' を削除しました。" -ForegroundColor Yellow
