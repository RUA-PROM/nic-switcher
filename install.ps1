# nic-switcher インストーラ
# ログオン関連イベントを監視して nic_handler.ps1 を発火させる
# スケジュールタスクを登録する。管理者権限が必要。

#Requires -RunAsAdministrator

# --- 設定の読み込み --------------------------------------------------------

$configPath = Join-Path $PSScriptRoot 'config.ps1'
if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Error "config.ps1 が見つかりません。config.example.ps1 をコピーして編集してください。"
    exit 1
}
. $configPath

$handlerScript = Join-Path $PSScriptRoot 'nic_handler.ps1'
if (-not (Test-Path -LiteralPath $handlerScript)) {
    Write-Error "nic_handler.ps1 が見つかりません: $handlerScript"
    exit 1
}

# --- テンプレートからタスク XML を組み立て --------------------------------

# タスクスケジューラ XML 内の $(EventUser) は値クエリ参照。
# ここでは PowerShell の here-string で展開されないようバッククォートで
# $ をエスケープする。
$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Security"&gt;&lt;Select Path="Security"&gt;*[System[(EventID=4624 or EventID=4634 or EventID=4647 or EventID=4778 or EventID=4779)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
      <ValueQueries>
        <Value name="EventUser">Event/EventData/Data[@Name="TargetUserName"]</Value>
      </ValueQueries>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>Queue</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT1M</ExecutionTimeLimit>
    <Enabled>true</Enabled>
    <StartWhenAvailable>true</StartWhenAvailable>
  </Settings>
  <Actions>
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NonInteractive -ExecutionPolicy Bypass -File "$handlerScript" -UserName "`$(EventUser)"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

$tempXml = Join-Path $env:TEMP "nic_switcher_install_$([guid]::NewGuid().ToString('N')).xml"
$xml | Out-File -FilePath $tempXml -Encoding Unicode

try {
    schtasks /Create /TN $TaskName /XML $tempXml /F
    Write-Host ""
    Write-Host "タスク '$TaskName' を登録しました。" -ForegroundColor Green
    Write-Host "ハンドラスクリプト: $handlerScript"
} finally {
    if (Test-Path -LiteralPath $tempXml) { Remove-Item -LiteralPath $tempXml -Force }
}
