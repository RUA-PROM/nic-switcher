# nic-switcher 設定テンプレート
#
# このファイルを config.ps1 にコピーし、自分の環境に合わせて値を編集する。
# config.ps1 は gitignore 対象なので、個人設定がコミットされる心配はない。
#
# InterfaceIndex は以下で確認できる:
#   Get-NetAdapter | Select-Object Name, InterfaceIndex

# --- ユーザー識別 ----------------------------------------------------------

# 「優先ユーザー」の判定に使う正規表現。`quser` の出力に現れるローカル
# ユーザー名に対してマッチする。リテラル文字列でも正規表現として解釈
# されるので、`.` 等のメタ文字を含む名前は [regex]::Escape() で囲む。
$PriorityUserPattern = 'YOUR_USERNAME_HERE'


# --- ネットワークインターフェース -----------------------------------------

# 優先ユーザーがアクティブなときに優先する NIC（通常は仕事用・固定 IP）。
$PriorityInterfaceIndex = 0

# 優先ユーザーがアクティブでないときに優先する NIC（通常は一般用）。
$DefaultInterfaceIndex  = 0


# --- メトリック ------------------------------------------------------------

# メトリックは小さいほど優先度が高い。Windows はベースコストを加算するため、
# わずかな差で十分。
$PreferredMetric = 10
$DemotedMetric   = 100


# --- スケジュールタスク ---------------------------------------------------

$TaskName = 'SwitchNIC_Unified'


# --- ログ -----------------------------------------------------------------

# 既定ではスクリプトと同じディレクトリに出力する。プロジェクトと
# 一緒に移動でき、.gitignore で除外される。
$LogFile = Join-Path $PSScriptRoot 'nic_handler.log'

# ログローテーション設定。
# 書き込み前にファイルが $MaxLogBytes を超えていれば、.log を .log.1 に
# 押し上げ、新しい .log を開始する。世代は .log.$MaxLogBackups まで保持し、
# それ以降は破棄。これにより 1 ファイルが無限肥大化することはなくなる。
$MaxLogBytes   = 1MB
$MaxLogBackups = 3
