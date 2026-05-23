# NicSwitcher.psm1
#
# ドメイン駆動の3層構成:
#
#   Domain         純粋な値オブジェクトと業務ルール
#                  (Session, PriorityPolicy, PriorityDecision,
#                   Test-SystemAccountName, Resolve-PriorityDecision)
#
#   Infrastructure 外部世界へのアダプタ
#                  (quser.exe, Set-NetIPInterface, ファイル I/O)
#
#   Application    エントリポイントが呼び出すユースケース
#                  (Invoke-NicPriorityHandler)
#
# このモジュールとテストで一貫して使うユビキタス言語:
#
#   Session                  ユーザー単位のログオン。State を持つ
#   State                    'Active' | 'Disconnected'
#   PriorityUser             その出現で NIC 優先度が切り替わるユーザー
#   PriorityPolicy           設定されたルール（誰を・どの NIC を）
#   PriorityDecision         ポリシーを適用した結果
#   TriggeringUser           スケジュールタスクを発火させた Security
#                            イベントの対象ユーザー

Set-StrictMode -Version Latest


# ============================================================================
# DOMAIN
# ============================================================================

# Session 値オブジェクト。quser 出力やテスト用フィクスチャから生成する。
function New-Session {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][ValidateSet('Active', 'Disconnected')][string]$State
    )
    [pscustomobject]@{
        PSTypeName = 'NicSwitcher.Session'
        UserName   = $UserName
        State      = $State
    }
}

# PriorityPolicy 値オブジェクト。構築時に不変条件を強制するため、
# 下流のコードは値の正当性を信頼してよい。
function New-PriorityPolicy {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][int]$PriorityInterfaceIndex,
        [Parameter(Mandatory)][int]$DefaultInterfaceIndex,
        [Parameter(Mandatory)][int]$PreferredMetric,
        [Parameter(Mandatory)][int]$DemotedMetric
    )
    if ($PriorityInterfaceIndex -eq $DefaultInterfaceIndex) {
        throw 'PriorityInterfaceIndex と DefaultInterfaceIndex は異なる NIC を指定する必要があります (must differ).'
    }
    if ($PreferredMetric -ge $DemotedMetric) {
        throw "PreferredMetric ($PreferredMetric) は DemotedMetric ($DemotedMetric) より小さい必要があります (must be less)."
    }
    [pscustomobject]@{
        PSTypeName             = 'NicSwitcher.PriorityPolicy'
        Pattern                = $Pattern
        PriorityInterfaceIndex = $PriorityInterfaceIndex
        DefaultInterfaceIndex  = $DefaultInterfaceIndex
        PreferredMetric        = $PreferredMetric
        DemotedMetric          = $DemotedMetric
    }
}

# PriorityDecision 値オブジェクト。Resolve-PriorityDecision が生成し、
# Set-InterfaceMetric が消費する。Reason を含めてログを意味のあるものにする。
function New-PriorityDecision {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$PreferIndex,
        [Parameter(Mandatory)][int]$DemoteIndex,
        [Parameter(Mandatory)][int]$PreferMetric,
        [Parameter(Mandatory)][int]$DemoteMetric,
        [Parameter(Mandatory)][string]$Reason
    )
    [pscustomobject]@{
        PSTypeName   = 'NicSwitcher.PriorityDecision'
        PreferIndex  = $PreferIndex
        DemoteIndex  = $DemoteIndex
        PreferMetric = $PreferMetric
        DemoteMetric = $DemoteMetric
        Reason       = $Reason
    }
}

# ドメインルール: この名前は OS 内部アカウントで、ポリシーが無視すべきものか?
function Test-SystemAccountName {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()][AllowNull()]
        [string]$Name
    )
    if ([string]::IsNullOrWhiteSpace($Name)) { return $true }
    if ($Name -match '^(SYSTEM|LOCAL SERVICE|NETWORK SERVICE|ANONYMOUS LOGON|DWM-\d+|UMFD-\d+)$') { return $true }
    if ($Name.EndsWith('$')) { return $true }
    return $false
}

# 中核ドメイン関数。Policy と現在のセッション群から Decision を導出する。
# 純粋関数: 同じ入力に対して常に同じ出力を返す。
function Resolve-PriorityDecision {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [PSTypeName('NicSwitcher.PriorityPolicy')]
        $Policy,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Sessions
    )
    $priorityActive = $false
    foreach ($s in $Sessions) {
        if ($s.UserName -match $Policy.Pattern -and $s.State -eq 'Active') {
            $priorityActive = $true
            break
        }
    }
    if ($priorityActive) {
        New-PriorityDecision `
            -PreferIndex  $Policy.PriorityInterfaceIndex `
            -DemoteIndex  $Policy.DefaultInterfaceIndex `
            -PreferMetric $Policy.PreferredMetric `
            -DemoteMetric $Policy.DemotedMetric `
            -Reason       'priority user has active session'
    } else {
        New-PriorityDecision `
            -PreferIndex  $Policy.DefaultInterfaceIndex `
            -DemoteIndex  $Policy.PriorityInterfaceIndex `
            -PreferMetric $Policy.PreferredMetric `
            -DemoteMetric $Policy.DemotedMetric `
            -Reason       'no priority user session is active'
    }
}


# ============================================================================
# INFRASTRUCTURE
# ============================================================================

# 腐敗防止アダプタ: quser.exe の1行を Session に変換する。
# 純粋な変換関数。quser.exe を実行せずにテストできる。
function ConvertFrom-QuserLine {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()][AllowNull()]
        [string]$Line
    )
    process {
        if ([string]::IsNullOrWhiteSpace($Line)) { return }
        $clean = $Line.Trim()
        # セッション行は必ず "Active" または "Disc" を含む
        # （Windows は表示言語を問わずこの英略を使う）。
        # それ以外（ローカライズされたヘッダ行など）はセッションではない。
        if ($clean -notmatch '\b(Active|Disc)\b') { return }
        $user  = ($clean -split '\s+', 2)[0].TrimStart('>')
        $state = if ($clean -match '\bActive\b') { 'Active' } else { 'Disconnected' }
        New-Session -UserName $user -State $state
    }
}

# Infrastructure: quser.exe 呼び出しを薄くラップする。
# 外部 EXE は直接モックできないため、この関数経由にすることで
# テストが quser 不在パスや異常出力パスを検証できるようにする。
function Invoke-Quser {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    & quser.exe 2>$null
}

# Infrastructure: OS から現在のセッションを取得する。
function Get-CurrentSessions {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    $raw = Invoke-Quser
    if (-not $raw) { return @() }
    , @($raw | ConvertFrom-QuserLine)
}

# Infrastructure: PriorityDecision をネットワークスタックに適用する。
function Set-InterfaceMetric {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [PSTypeName('NicSwitcher.PriorityDecision')]
        $Decision
    )
    $target = "Interface $($Decision.PreferIndex) / $($Decision.DemoteIndex)"
    $action = "Set metric $($Decision.PreferMetric) / $($Decision.DemoteMetric)"
    if ($PSCmdlet.ShouldProcess($target, $action)) {
        Set-NetIPInterface -InterfaceIndex $Decision.PreferIndex `
                           -AutomaticMetric Disabled `
                           -InterfaceMetric $Decision.PreferMetric
        Set-NetIPInterface -InterfaceIndex $Decision.DemoteIndex `
                           -AutomaticMetric Disabled `
                           -InterfaceMetric $Decision.DemoteMetric
    }
}

# Infrastructure: UTF-8 でタイムスタンプ付きのログ行を追記する。
# UTF-8 が重要 - Windows PowerShell の既定 ANSI コードページは
# 日本語を文字化けさせる。
function Write-NicLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}


# ============================================================================
# APPLICATION
# ============================================================================

# ユースケース: 「ログオン関連 Security イベントが発生したとき、設定された
# 優先ポリシーを現在のセッションに適用し、結果の Decision をネットワーク
# スタックに反映する」
function Invoke-NicPriorityHandler {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$TriggeringUser,

        [Parameter(Mandatory)]
        [PSTypeName('NicSwitcher.PriorityPolicy')]
        $Policy,

        [Parameter(Mandatory)][string]$LogFile,

        # イベント直後のセッションテーブル安定化を待つ秒数。
        # テストでは 0 を渡して高速化する。
        [int]$SettleSeconds = 2
    )

    Write-NicLog -Path $LogFile -Message "Triggered with UserName='$TriggeringUser'"

    if (Test-SystemAccountName -Name $TriggeringUser) {
        Write-NicLog -Path $LogFile -Message "Skipped (system or service account: '$TriggeringUser')"
        return
    }

    if ($SettleSeconds -gt 0) {
        Start-Sleep -Seconds $SettleSeconds
    }

    $sessions = Get-CurrentSessions
    $decision = Resolve-PriorityDecision -Policy $Policy -Sessions $sessions

    Write-NicLog -Path $LogFile -Message (
        "Decision: {0} (PreferIndex={1}, DemoteIndex={2})" -f `
            $decision.Reason, $decision.PreferIndex, $decision.DemoteIndex
    )

    Set-InterfaceMetric -Decision $decision

    Write-NicLog -Path $LogFile -Message (
        "Applied: interface (Index={0}) preferred" -f $decision.PreferIndex
    )
}


Export-ModuleMember -Function `
    New-Session, `
    New-PriorityPolicy, `
    New-PriorityDecision, `
    Test-SystemAccountName, `
    Resolve-PriorityDecision, `
    ConvertFrom-QuserLine, `
    Invoke-Quser, `
    Get-CurrentSessions, `
    Set-InterfaceMetric, `
    Write-NicLog, `
    Invoke-NicPriorityHandler
