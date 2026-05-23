# lib/NicSwitcher.psm1 の単体テスト（Pester 5 / BDD 形式）
#
# 構造:
#   Describe = Feature（機能）
#   Context  = Scenario（シナリオ）
#   It       = そのシナリオでの振る舞いの仕様
#
# 各 It の内部に Given / When / Then をインラインコメントとして書き、
# 自然言語のシナリオと実行ステップの対応が読めるようにしてある。
#
# 方針: 外部依存（quser.exe / Set-NetIPInterface / Start-Sleep）は
# すべてモックする。実マシンの状態に依存しない。
#
# テスト用フィクスチャは汎用名（alice / bob / eve / WORKSTATION）を
# 用い、実在のユーザー名やマシン名はリポジトリに残さない。

BeforeAll {
    $modulePath = Resolve-Path (Join-Path $PSScriptRoot '..\..\lib\NicSwitcher.psm1')
    Import-Module $modulePath -Force
}


# ============================================================================
# フィーチャ: ビルトイン／システムアカウントは NIC 切り替え対象から除外する
#
# ログオン関連 Security イベントは多くの内部アカウント（SYSTEM,
# LOCAL SERVICE, 仮想 DWM/UMFD アカウント, マシンアカウント自身）でも
# 発火する。これらを「ユーザー」として扱うと優先度が常時切り替わって
# しまうため、確実に除外する必要がある。
# ============================================================================

Describe 'フィーチャ: NIC 優先度の判定でシステムアカウントを無視する' {

    Context 'シナリオ: 既知のサービスアカウント名でイベントが発火する' {
        It '<name> はシステムアカウントとして分類される' -TestCases @(
            @{ name = 'SYSTEM' }
            @{ name = 'LOCAL SERVICE' }
            @{ name = 'NETWORK SERVICE' }
            @{ name = 'ANONYMOUS LOGON' }
        ) {
            param($name)
            # 前提: 既知のサービスアカウント名が渡される
            # 実行: それがシステムアカウントか問い合わせると
            $result = Test-SystemAccountName -Name $name
            # 期待: システムアカウントと判定される（後段でスキップされる）
            $result | Should -BeTrue
        }
    }

    Context 'シナリオ: ウィンドウマネージャの仮想アカウントでイベントが発火する' {
        It '<name> はシステムアカウントとして分類される' -TestCases @(
            @{ name = 'DWM-1' }
            @{ name = 'DWM-12' }
            @{ name = 'UMFD-0' }
            @{ name = 'UMFD-42' }
        ) {
            param($name)
            # 前提・実行・期待を一行で
            Test-SystemAccountName -Name $name | Should -BeTrue
        }
    }

    Context 'シナリオ: コンピュータアカウント（末尾が $）でイベントが発火する' {
        It 'コンピュータアカウントはシステムアカウントと判定される' {
            # 前提: 末尾に "$" が付くコンピュータアカウント名
            $computerAccount = 'WORKSTATION$'
            # 実行: 判定すると
            $result = Test-SystemAccountName -Name $computerAccount
            # 期待: システムアカウント扱い
            $result | Should -BeTrue
        }
    }

    Context 'シナリオ: 空文字や空白だけの名前が渡される' {
        It '空入力はシステムアカウントとして分類される' -TestCases @(
            @{ value = '' }
            @{ value = '   ' }
            @{ value = $null }
        ) {
            param($value)
            Test-SystemAccountName -Name $value | Should -BeTrue
        }
    }

    Context 'シナリオ: 実在の対話ユーザー名でイベントが発火する' {
        It '<name> はシステムアカウントではない' -TestCases @(
            @{ name = 'alice' }
            @{ name = 'user@example.com' }   # Microsoft アカウント形式
            @{ name = 'SYSTEMuser' }         # システム名のスーパーセット
        ) {
            param($name)
            # 前提: 実ユーザー名
            # 実行: 判定すると
            # 期待: スキップされない（システム扱いではない）
            Test-SystemAccountName -Name $name | Should -BeFalse
        }
    }
}


# ============================================================================
# フィーチャ: quser.exe 出力を Session 値オブジェクトに変換する
#
# quser.exe は唯一の OS アダプタ。そのクセ（ロケール依存ヘッダ、
# コンソールセッションの先頭 '>'、Disconnected が "Disc" と略される等）を
# ConvertFrom-QuserLine の内側に閉じ込める。
# ============================================================================

Describe 'フィーチャ: quser 出力を Session オブジェクトへ変換する' {

    Context 'シナリオ: アクティブなコンソールセッション行' {
        It 'State=Active の Session が生成され、先頭の > が除去される' {
            # 前提: アクティブなコンソールユーザーの quser 行
            $line = '>alice                console             1  Active          .  2026/05/23 09:00'
            # 実行: 1行をパースすると
            $session = $line | ConvertFrom-QuserLine
            # 期待: Session(UserName='alice', State='Active') が生成される
            $session.UserName | Should -Be 'alice'
            $session.State    | Should -Be 'Active'
        }
    }

    Context 'シナリオ: アクティブな RDP セッション行' {
        It 'State=Active の Session が生成される' {
            # 前提: アクティブな RDP ユーザーの quser 行
            $line = ' alice                rdp-tcp#0           6  Active          .  2026/05/23 10:31'
            # 実行
            $session = $line | ConvertFrom-QuserLine
            # 期待: Active と判定される
            $session.UserName | Should -Be 'alice'
            $session.State    | Should -Be 'Active'
        }
    }

    Context 'シナリオ: 切断中のセッション行（"Disc" 略記）' {
        It 'State=Disconnected の Session が生成される' {
            # 前提: 状態トークンが "Disc" の quser 行
            $line = ' bob                                       8  Disc           38  2026/05/23 11:47'
            # 実行
            $session = $line | ConvertFrom-QuserLine
            # 期待: Disconnected と判定される
            $session.UserName | Should -Be 'bob'
            $session.State    | Should -Be 'Disconnected'
        }
    }

    Context 'シナリオ: 空行が混じる' {
        It '空入力は Session を生成しない' -TestCases @(
            @{ line = '' }
            @{ line = '   ' }
        ) {
            param($line)
            # 前提・実行・期待: 空行からは何も出力されない
            $line | ConvertFrom-QuserLine | Should -BeNullOrEmpty
        }
    }

    Context 'シナリオ: ローカライズされたヘッダ行が混じる' {
        It '状態トークンを含まない行は Session を生成しない' {
            # 前提: quser のヘッダ行（Active/Disc を含まない）
            $header = 'USERNAME              SESSIONNAME        ID  STATE   IDLE TIME  LOGON TIME'
            # 実行・期待: 何も出力されない（ロケール非依存判定）
            $header | ConvertFrom-QuserLine | Should -BeNullOrEmpty
        }
    }

    Context 'シナリオ: 複数行を一気にパイプする' {
        It 'データ行ごとに1件ずつ Session を生成し、ノイズはスキップする' {
            # 前提: ヘッダ・空行・Active・Disc が混在するストリーム
            $stream = @(
                'USERNAME    SESSIONNAME    ID  STATE   IDLE TIME  LOGON TIME',
                '',
                '>alice      console         1  Active   .  2026/05/23 09:00',
                '   ',
                ' bob        rdp-tcp#1       2  Disc     5  2026/05/23 08:30'
            )
            # 実行
            $sessions = @($stream | ConvertFrom-QuserLine)
            # 期待: 順序を保って2件の Session が生成される
            $sessions.Count       | Should -Be 2
            $sessions[0].UserName | Should -Be 'alice'
            $sessions[0].State    | Should -Be 'Active'
            $sessions[1].UserName | Should -Be 'bob'
            $sessions[1].State    | Should -Be 'Disconnected'
        }
    }
}


# ============================================================================
# フィーチャ: PriorityPolicy は自身の不変条件を構築時に守る
#
# 不正な設定は Set-NetIPInterface 直前にではなく、起動時に弾く。
# 失敗位置を早めて、運用時に気づける形にしておく。
# ============================================================================

Describe 'フィーチャ: PriorityPolicy が設定の安全性を強制する' {

    Context 'シナリオ: 優先 NIC と通常 NIC が同じ番号' {
        It '同一 InterfaceIndex の Policy は構築できない' {
            # 前提: 両方の NIC が同じ番号を指す設定
            # 実行: Policy を構築しようとする
            # 期待: 例外が投げられ、不正な Policy が外に出ない
            {
                New-PriorityPolicy `
                    -Pattern 'alice' `
                    -PriorityInterfaceIndex 6 `
                    -DefaultInterfaceIndex  6 `
                    -PreferredMetric 10 -DemotedMetric 100
            } | Should -Throw '*must differ*'
        }
    }

    Context 'シナリオ: PreferredMetric が DemotedMetric 以上（優先度が逆転）' {
        It '優先より大きいメトリックは構築できない' {
            # 前提: 「優先」NIC のメトリックが「降格」NIC のメトリック以上
            # 実行: Policy を構築しようとする
            # 期待: 例外が投げられる（小さい値ほど優先のため）
            {
                New-PriorityPolicy `
                    -Pattern 'alice' `
                    -PriorityInterfaceIndex 6 -DefaultInterfaceIndex 3 `
                    -PreferredMetric 100 -DemotedMetric 10
            } | Should -Throw '*must be less*'
        }
    }

    Context 'シナリオ: 正常な設定を与える' {
        It '与えた値をそのまま保持した Policy が返る' {
            # 前提: 妥当な設定値
            # 実行: Policy を構築すると
            $p = New-PriorityPolicy `
                -Pattern 'alice' `
                -PriorityInterfaceIndex 6 -DefaultInterfaceIndex 3 `
                -PreferredMetric 10 -DemotedMetric 100
            # 期待: 値が読み出せる
            $p.Pattern                | Should -Be 'alice'
            $p.PriorityInterfaceIndex | Should -Be 6
            $p.DefaultInterfaceIndex  | Should -Be 3
            $p.PreferredMetric        | Should -Be 10
            $p.DemotedMetric          | Should -Be 100
        }
    }
}


# ============================================================================
# フィーチャ: Policy と現在のセッションから PriorityDecision を導く
#
# 中核ドメイン関数。決定論的・副作用なし。決定の実行は Infrastructure 層が
# 受け持つ。
# ============================================================================

Describe 'フィーチャ: 現在のセッションから優先度判定を導出する' {

    BeforeAll {
        $script:policy = New-PriorityPolicy `
            -Pattern 'alice' `
            -PriorityInterfaceIndex 6 -DefaultInterfaceIndex 3 `
            -PreferredMetric 10 -DemotedMetric 100
    }

    Context 'シナリオ: 優先ユーザーがアクティブなセッションを持つ' {
        It '優先 NIC を選ぶ' {
            # 前提: 優先ユーザーが現在アクティブ
            $sessions = @(
                (New-Session -UserName 'alice' -State Active)
                (New-Session -UserName 'bob'   -State Disconnected)
            )
            # 実行: 決定を導出すると
            $d = Resolve-PriorityDecision -Policy $script:policy -Sessions $sessions
            # 期待: 優先 NIC が勝ち、通常 NIC が降格される
            $d.PreferIndex  | Should -Be 6
            $d.DemoteIndex  | Should -Be 3
            $d.PreferMetric | Should -Be 10
            $d.DemoteMetric | Should -Be 100
            $d.Reason       | Should -Be 'priority user has active session'
        }
    }

    Context 'シナリオ: 優先ユーザーは切断中のみ' {
        It '通常 NIC に戻す' {
            # 前提: 優先ユーザーにアクティブなセッションがない
            $sessions = @(
                (New-Session -UserName 'alice' -State Disconnected)
                (New-Session -UserName 'bob'   -State Active)
            )
            # 実行
            $d = Resolve-PriorityDecision -Policy $script:policy -Sessions $sessions
            # 期待: 通常 NIC が勝ち、優先 NIC が降格される
            $d.PreferIndex | Should -Be 3
            $d.DemoteIndex | Should -Be 6
            $d.Reason      | Should -Be 'no priority user session is active'
        }
    }

    Context 'シナリオ: パターンに一致するユーザーが存在しない' {
        It '通常 NIC に戻す' {
            # 前提: 優先パターンに一致するユーザーがいない
            $sessions = @(
                (New-Session -UserName 'bob' -State Active)
            )
            # 実行
            $d = Resolve-PriorityDecision -Policy $script:policy -Sessions $sessions
            # 期待: 通常 NIC が選ばれる
            $d.PreferIndex | Should -Be 3
            $d.DemoteIndex | Should -Be 6
        }
    }

    Context 'シナリオ: セッションが1件もない' {
        It '通常 NIC に戻す' {
            # 前提: 空のセッション一覧
            # 実行
            $d = Resolve-PriorityDecision -Policy $script:policy -Sessions @()
            # 期待: 通常 NIC が選ばれる
            $d.PreferIndex | Should -Be 3
            $d.DemoteIndex | Should -Be 6
        }
    }

    Context 'シナリオ: Policy のパターンが正規表現' {
        It 'パターンに合致するユーザーを優先扱いする' {
            # 前提: alice または bob にマッチする Policy
            $regexPolicy = New-PriorityPolicy `
                -Pattern '^(alice|bob)$' `
                -PriorityInterfaceIndex 6 -DefaultInterfaceIndex 3 `
                -PreferredMetric 10 -DemotedMetric 100
            $sessions = @( (New-Session -UserName 'alice' -State Active) )

            # 実行
            $d = Resolve-PriorityDecision -Policy $regexPolicy -Sessions $sessions

            # 期待: alice に対して優先 NIC が選ばれる
            $d.PreferIndex | Should -Be 6
            $d.Reason      | Should -Be 'priority user has active session'
        }
    }
}


# ============================================================================
# フィーチャ: Get-CurrentSessions の境界ふるまい
#
# Invoke-Quser ラッパをモック化することで、外部 EXE に頼らず例外パスを
# 検証できる。
# ============================================================================

Describe 'フィーチャ: 現在セッション取得の境界ふるまい' {

    Context 'シナリオ: quser.exe が何も出力しない（稀な異常状態）' {
        It '例外を投げず、空配列を返す' {
            # 前提: quser.exe が null を返す環境
            Mock -ModuleName NicSwitcher Invoke-Quser { $null }
            # 実行: 現在セッションを取得すると
            $result = Get-CurrentSessions
            # 期待: 空配列が返り、例外にはならない
            $result | Should -BeNullOrEmpty
        }
    }

    Context 'シナリオ: quser.exe が複数行を返す' {
        It '各行が Session に変換される' {
            # 前提: quser.exe が2件のセッションを返す
            Mock -ModuleName NicSwitcher Invoke-Quser {
                @(
                    'USERNAME    SESSIONNAME    ID  STATE   IDLE TIME  LOGON TIME',
                    '>alice      console         1  Active   .  2026/05/23 09:00',
                    ' bob        rdp-tcp#1       2  Disc     5  2026/05/23 08:30'
                )
            }
            # 実行
            $result = Get-CurrentSessions
            # 期待: ヘッダはスキップされ、2件の Session が得られる
            @($result).Count       | Should -Be 2
            @($result)[0].UserName | Should -Be 'alice'
            @($result)[1].State    | Should -Be 'Disconnected'
        }
    }
}


# ============================================================================
# フィーチャ: PriorityDecision をネットワークスタックに適用する
#
# Set-InterfaceMetric は Set-NetIPInterface への接続点。テストでは
# モック化することで、実ネットワーク設定には絶対に触れない。
# ============================================================================

Describe 'フィーチャ: 決定をネットワークスタックに適用する' {

    BeforeEach {
        Mock -ModuleName NicSwitcher Set-NetIPInterface { } -Verifiable
    }

    Context 'シナリオ: 妥当な決定を適用する' {
        It '優先 NIC に優先メトリックが書き込まれる' {
            # 前提: index 6 を優先・メトリック 10 とする決定
            $decision = New-PriorityDecision `
                -PreferIndex 6 -DemoteIndex 3 `
                -PreferMetric 10 -DemoteMetric 100 `
                -Reason 'test'

            # 実行
            Set-InterfaceMetric -Decision $decision

            # 期待: Set-NetIPInterface が InterfaceIndex=6, Metric=10 で1回呼ばれる
            Should -Invoke -ModuleName NicSwitcher -CommandName Set-NetIPInterface `
                -Times 1 -Exactly `
                -ParameterFilter { $InterfaceIndex -eq 6 -and $InterfaceMetric -eq 10 }
        }

        It '通常 NIC に降格メトリックが書き込まれる' {
            # 前提: 同じ決定
            $decision = New-PriorityDecision `
                -PreferIndex 6 -DemoteIndex 3 `
                -PreferMetric 10 -DemoteMetric 100 `
                -Reason 'test'

            # 実行
            Set-InterfaceMetric -Decision $decision

            # 期待: index 3 に降格メトリックが書かれる
            Should -Invoke -ModuleName NicSwitcher -CommandName Set-NetIPInterface `
                -Times 1 -Exactly `
                -ParameterFilter { $InterfaceIndex -eq 3 -and $InterfaceMetric -eq 100 }
        }
    }

    Context 'シナリオ: -WhatIf を付けて呼び出す' {
        It 'ネットワークスタックに触れない' {
            # 前提: 決定オブジェクト
            $decision = New-PriorityDecision `
                -PreferIndex 6 -DemoteIndex 3 `
                -PreferMetric 10 -DemoteMetric 100 `
                -Reason 'test'

            # 実行: -WhatIf 付きで呼ぶ
            Set-InterfaceMetric -Decision $decision -WhatIf

            # 期待: Set-NetIPInterface は1度も呼ばれない
            Should -Invoke -ModuleName NicSwitcher -CommandName Set-NetIPInterface -Times 0
        }
    }
}


# ============================================================================
# フィーチャ: 監査ログを UTF-8 で書き、日本語が文字化けしない
# ============================================================================

Describe 'フィーチャ: 監査ログの書き込み' {

    Context 'シナリオ: ASCII メッセージを書く' {
        It 'タイムスタンプ付きの1行が追記される' {
            # 前提: テスト用の一時ログパス
            $logPath = Join-Path $TestDrive 'plain.log'
            # 実行: メッセージを書く
            Write-NicLog -Path $logPath -Message 'hello'
            # 期待: 期待した書式の1行が記録される
            $line = Get-Content -LiteralPath $logPath -Encoding UTF8
            $line | Should -Match '^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] hello$'
        }
    }

    Context 'シナリオ: 日本語メッセージを書く' {
        It '文字化けせずにラウンドトリップする' {
            # 前提: 日本語のメッセージ
            $logPath  = Join-Path $TestDrive 'jp.log'
            $expected = 'イーサネット 3 を優先しました'
            # 実行
            Write-NicLog -Path $logPath -Message $expected
            # 期待: UTF-8 で読み戻すと同じ文字列が得られる
            $line = Get-Content -LiteralPath $logPath -Encoding UTF8 -Tail 1
            $line | Should -Match ([regex]::Escape($expected))
        }
    }

    Context 'シナリオ: 既存ログに追記する' {
        It '上書きせず追記される' {
            # 前提: 1件入りのログ
            $logPath = Join-Path $TestDrive 'append.log'
            Write-NicLog -Path $logPath -Message 'first'
            # 実行: 2件目を追加
            Write-NicLog -Path $logPath -Message 'second'
            # 期待: 2件が順序通りに残っている
            $lines = Get-Content -LiteralPath $logPath -Encoding UTF8
            $lines.Count | Should -Be 2
            $lines[0] | Should -Match 'first'
            $lines[1] | Should -Match 'second'
        }
    }
}


# ============================================================================
# フィーチャ: ユースケースのエンドツーエンドなオーケストレーション
#
# Invoke-NicPriorityHandler は各層を組み立てる。テストでは
# Infrastructure 境界（Get-CurrentSessions・Set-InterfaceMetric・Start-Sleep）を
# モック化し、管理者権限もネットワーク I/O もなしでパイプラインを動かす。
# ============================================================================

Describe 'フィーチャ: ログオンイベントのエンドツーエンド処理' {

    BeforeEach {
        $script:logPath = Join-Path $TestDrive 'handler.log'
        $script:policy  = New-PriorityPolicy `
            -Pattern 'alice' `
            -PriorityInterfaceIndex 6 -DefaultInterfaceIndex 3 `
            -PreferredMetric 10 -DemotedMetric 100

        Mock -ModuleName NicSwitcher Set-NetIPInterface { } -Verifiable
        Mock -ModuleName NicSwitcher Start-Sleep { }   # テストでは絶対に sleep しない
    }

    Context 'シナリオ: 発火ユーザーが SYSTEM アカウント' {
        It 'スキップをログに残し、ネットワーク変更は行わない' {
            # 前提: SYSTEM がイベントを発火した
            Mock -ModuleName NicSwitcher Get-CurrentSessions { @() }

            # 実行: ハンドラを動かすと
            Invoke-NicPriorityHandler `
                -TriggeringUser 'SYSTEM' `
                -Policy $script:policy `
                -LogFile $script:logPath `
                -SettleSeconds 0

            # 期待: NIC 変更は実行されない
            Should -Invoke -ModuleName NicSwitcher -CommandName Set-NetIPInterface -Times 0
            # かつ ログにスキップが記録される
            (Get-Content -LiteralPath $script:logPath -Encoding UTF8) -join "`n" |
                Should -Match 'Skipped \(system or service account'
        }
    }

    Context 'シナリオ: イベント時点で優先ユーザーがアクティブ' {
        It '優先 NIC を優先メトリックに切り替える' {
            # 前提: 優先ユーザーが実機でアクティブ
            Mock -ModuleName NicSwitcher Get-CurrentSessions {
                @( (New-Session -UserName 'alice' -State Active) )
            }

            # 実行: 別ユーザー発火でハンドラを動かす
            Invoke-NicPriorityHandler `
                -TriggeringUser 'someone@example.com' `
                -Policy $script:policy `
                -LogFile $script:logPath `
                -SettleSeconds 0

            # 期待: 優先 NIC が優先メトリックに設定される
            Should -Invoke -ModuleName NicSwitcher -CommandName Set-NetIPInterface `
                -Times 1 -Exactly `
                -ParameterFilter { $InterfaceIndex -eq 6 -and $InterfaceMetric -eq 10 }
        }
    }

    Context 'シナリオ: 非優先ユーザーしか存在しない' {
        It '通常 NIC を優先メトリックに戻す' {
            # 前提: 非優先ユーザーだけが実機にいる
            Mock -ModuleName NicSwitcher Get-CurrentSessions {
                @( (New-Session -UserName 'bob' -State Active) )
            }

            # 実行
            Invoke-NicPriorityHandler `
                -TriggeringUser 'bob' `
                -Policy $script:policy `
                -LogFile $script:logPath `
                -SettleSeconds 0

            # 期待: 通常 NIC に優先メトリックが書かれる
            Should -Invoke -ModuleName NicSwitcher -CommandName Set-NetIPInterface `
                -Times 1 -Exactly `
                -ParameterFilter { $InterfaceIndex -eq 3 -and $InterfaceMetric -eq 10 }
            # かつ 理由がログに残る
            (Get-Content -LiteralPath $script:logPath -Encoding UTF8) -join "`n" |
                Should -Match 'no priority user session is active'
        }
    }
}
