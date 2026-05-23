# nic_handler.ps1
#
# 「ログオン時に NIC 優先度を切り替える」ユースケースのコンポジションルート。
# config と module を組み立て、Application 層に委譲するだけの薄い層。

[CmdletBinding()]
param(
    [Parameter()]
    [AllowEmptyString()]
    [string]$UserName = ''
)

$ErrorActionPreference = 'Stop'

# --- 設定 ------------------------------------------------------------------

$configPath = Join-Path $PSScriptRoot 'config.ps1'
if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Error "config.ps1 が見つかりません: $configPath。config.example.ps1 をコピーして編集してください。"
    exit 1
}
. $configPath

# --- モジュール ------------------------------------------------------------

Import-Module (Join-Path $PSScriptRoot 'lib\NicSwitcher.psm1') -Force

# --- ユースケース実行 -----------------------------------------------------

$policy = New-PriorityPolicy `
    -Pattern                $PriorityUserPattern `
    -PriorityInterfaceIndex $PriorityInterfaceIndex `
    -DefaultInterfaceIndex  $DefaultInterfaceIndex `
    -PreferredMetric        $PreferredMetric `
    -DemotedMetric          $DemotedMetric

# ローテーション設定は config に書いてあれば渡す。
# 未定義の場合は Invoke-NicPriorityHandler の既定値（1MB / 3 世代）が使われる。
$handlerArgs = @{
    TriggeringUser = $UserName
    Policy         = $policy
    LogFile        = $LogFile
}
if (Test-Path Variable:\MaxLogBytes)   { $handlerArgs.MaxLogBytes   = $MaxLogBytes }
if (Test-Path Variable:\MaxLogBackups) { $handlerArgs.MaxLogBackups = $MaxLogBackups }

Invoke-NicPriorityHandler @handlerArgs
