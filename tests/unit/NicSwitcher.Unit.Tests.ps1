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
# 方針:
#   - 外部依存（quser.exe / Set-NetIPInterface / Start-Sleep）はすべて
#     モックで隔離する。実マシンの状態に依存しない。
#   - テスト用フィクスチャは汎用名（alice / bob / WORKSTATION）を用い、
#     実在のユーザー名やマシン名はリポジトリに残さない。

BeforeAll {
    $modulePath = Resolve-Path (Join-Path $PSScriptRoot '..\..\lib\NicSwitcher.psm1')
    Import-Module $modulePath -Force
}


# ============================================================================
# FEATURE: Domain 層 - システムアカウントは NIC 切り替えの対象外
#
# ログオン関連 Security イベントは多くの内部アカウント（SYSTEM,
# LOCAL SERVICE, 仮想 DWM / UMFD アカウント, マシンアカウント自身）でも
# 発火する。これらを「ユーザー」として扱うと優先度が常時切り替わって
# しまうため、確実に除外する必要がある。
# ============================================================================

Describe 'Feature: システムアカウントを NIC 切り替えの対象から除外する' {

    Context 'Scenario: 既知のサービスアカウント名でイベントが発火する' {
        It '<name> はシステムアカウントと判定される' -TestCases @(
            @{ name = 'SYSTEM' }
            @{ name = 'LOCAL SERVICE' }
            @{ name = 'NETWORK SERVICE' }
            @{ name = 'ANONYMOUS LOGON' }
        ) {
            param($name)
            # Given 既知のサービスアカウント名が渡される
            # When  Test-SystemAccountName に問い合わせると
            $result = Test-SystemAccountName -Name $name

            # Then  システムアカウントと判定される（呼び出し側でスキップされる）
            $result | Should -BeTrue
        }
    }

    Context 'Scenario: ウィンドウマネージャの仮想アカウントでイベントが発火する' {
        It '<name> はシステムアカウントと判定される' -TestCases @(
            @{ name = 'DWM-1' }
            @{ name = 'DWM-12' }
            @{ name = 'UMFD-0' }
            @{ name = 'UMFD-42' }
        ) {
            param($name)
            # Given / When / Then
            Test-SystemAccountName -Name $name | Should -BeTrue
        }
    }

    Context 'Scenario: コンピュータアカウント（末尾が $）でイベントが発火する' {
        It '末尾が $ の名前はシステムアカウントと判定される' {
            # Given 末尾に "$" が付くコンピュータアカウント名
            $computerAccount = 'WORKSTATION$'

            # When  判定すると
            $result = Test-SystemAccountName -Name $computerAccount

            # Then  システムアカウント扱い
            $result | Should -BeTrue
        }
    }

    Context 'Scenario: 空文字や空白だけの名前が渡される' {
        It '空入力はシステムアカウントと判定される' -TestCases @(
            @{ value = '' }
            @{ value = '   ' }
            @{ value = $null }
        ) {
            param($value)
            # Given 空・空白・null の入力
            # When / Then
            Test-SystemAccountName -Name $value | Should -BeTrue
        }
    }

    Context 'Scenario: 実在の対話ユーザー名でイベントが発火する' {
        It '<name> はシステムアカウントではないと判定される' -TestCases @(
            @{ name = 'alice' }
            @{ name = 'user@example.com' }   # Microsoft アカウント形式
            @{ name = 'SYSTEMuser' }         # システム名のスーパーセット
        ) {
            param($name)
            # Given 実ユーザー名
            # When  判定すると
            # Then  スキップされない
            Test-SystemAccountName -Name $name | Should -BeFalse
        }
    }
}


# ============================================================================
# FEATURE: Infrastructure 層 - quser 出力を Session 値オブジェクトに変換
#
# quser.exe は唯一の OS アダプタ。そのクセ（ロケール依存ヘッダ、
# コンソールセッション先頭の '>'、Disconnected が "Disc" と略される等）を
# ConvertFrom-QuserLine の内側に閉じ込める。
# ============================================================================

Describe 'Feature: quser 出力を Session オブジェクトに変換する' {

    Context 'Scenario: アクティブなコンソールセッション行' {
        It 'State=Active の Session を生成し、先頭の > を除去する' {
            # Given アクティブなコンソールユーザーの quser 行
            $line = '>alice                console             1  Active          .  2026/05/23 09:00'

            # When  1 行をパースすると
            $session = $line | ConvertFrom-QuserLine

            # Then  UserName="alice", State="Active" の Session が得られる
            $session.UserName | Should -Be 'alice'
            $session.State    | Should -Be 'Active'
        }
    }

    Context 'Scenario: アクティブな RDP セッション行' {
        It 'State=Active の Session を生成する' {
            # Given アクティブな RDP ユーザーの quser 行
            $line = ' alice                rdp-tcp#0           6  Active          .  2026/05/23 10:31'

            # When  パースすると
            $session = $line | ConvertFrom-QuserLine

            # Then  Active と判定される
            $session.UserName | Should -Be 'alice'
            $session.State    | Should -Be 'Active'
        }
    }

    Context 'Scenario: 切断中のセッション行（"Disc" 略記）' {
        It 'State=Disconnected の Session を生成する' {
            # Given 状態トークンが "Disc" の quser 行
            $line = ' bob                                       8  Disc           38  2026/05/23 11:47'

            # When  パースすると
            $session = $line | ConvertFrom-QuserLine

            # Then  Disconnected と判定される
            $session.UserName | Should -Be 'bob'
            $session.State    | Should -Be 'Disconnected'
        }
    }

    Context 'Scenario: 空行が混じる' {
        It '空入力からは Session を生成しない' -TestCases @(
            @{ line = '' }
            @{ line = '   ' }
        ) {
            param($line)
            # Given 空行 / When パース / Then 何も出力されない
            $line | ConvertFrom-QuserLine | Should -BeNullOrEmpty
        }
    }

    Context 'Scenario: ローカライズされたヘッダ行が混じる' {
        It '状態トークンを含まない行からは Session を生成しない' {
            # Given quser のヘッダ行（Active / Disc を含まない）
            $header = 'USERNAME              SESSIONNAME        ID  STATE   IDLE TIME  LOGON TIME'

            # When / Then 何も出力されない（ロケール非依存判定のため）
            $header | ConvertFrom-QuserLine | Should -BeNullOrEmpty
        }
    }

    Context 'Scenario: 複数行を一気にパイプする' {
        It 'データ行ごとに 1 件ずつ Session を生成し、ノイズはスキップする' {
            # Given ヘッダ・空行・Active・Disc が混在するストリーム
            $stream = @(
                'USERNAME    SESSIONNAME    ID  STATE   IDLE TIME  LOGON TIME',
                '',
                '>alice      console         1  Active   .  2026/05/23 09:00',
                '   ',
                ' bob        rdp-tcp#1       2  Disc     5  2026/05/23 08:30'
            )

            # When  パースすると
            $sessions = @($stream | ConvertFrom-QuserLine)

            # Then  順序を保って 2 件の Session が得られる
            $sessions.Count       | Should -Be 2
            $sessions[0].UserName | Should -Be 'alice'
            $sessions[0].State    | Should -Be 'Active'
            $sessions[1].UserName | Should -Be 'bob'
            $sessions[1].State    | Should -Be 'Disconnected'
        }
    }
}


# ============================================================================
# FEATURE: Domain 層 - PriorityPolicy は構築時に不変条件を強制する
#
# 不正な設定は Set-NetIPInterface 直前ではなく起動時に弾く。
# 失敗位置を早めて、運用時に気づける形にしておく。
# ============================================================================

Describe 'Feature: PriorityPolicy が設定の安全性を強制する' {

    Context 'Scenario: 優先 NIC と通常 NIC に同じ番号を指定する' {
        It '同一 InterfaceIndex の Policy は構築できない' {
            # Given 両方の NIC が同じ番号を指す設定
            # When  Policy を構築しようとする
            # Then  例外が投げられ、不正な Policy は外に出ない
            {
                New-PriorityPolicy `
                    -Pattern 'alice' `
                    -PriorityInterfaceIndex 6 `
                    -DefaultInterfaceIndex  6 `
                    -PreferredMetric 10 -DemotedMetric 100
            } | Should -Throw '*must differ*'
        }
    }

    Context 'Scenario: PreferredMetric が DemotedMetric 以上（優先度逆転）' {
        It '優先側が降格側より大きいメトリックの Policy は構築できない' {
            # Given 「優先」NIC のメトリックが「降格」NIC 以上
            # When  Policy を構築しようとする
            # Then  例外が投げられる（小さい値ほど優先のため）
            {
                New-PriorityPolicy `
                    -Pattern 'alice' `
                    -PriorityInterfaceIndex 6 -DefaultInterfaceIndex 3 `
                    -PreferredMetric 100 -DemotedMetric 10
            } | Should -Throw '*must be less*'
        }
    }

    Context 'Scenario: 正常な設定を与える' {
        It '与えた値をそのまま保持した Policy を返す' {
            # Given 妥当な設定値
            # When  Policy を構築すると
            $p = New-PriorityPolicy `
                -Pattern 'alice' `
                -PriorityInterfaceIndex 6 -DefaultInterfaceIndex 3 `
                -PreferredMetric 10 -DemotedMetric 100

            # Then  各プロパティから入力値が読み出せる
            $p.Pattern                | Should -Be 'alice'
            $p.PriorityInterfaceIndex | Should -Be 6
            $p.DefaultInterfaceIndex  | Should -Be 3
            $p.PreferredMetric        | Should -Be 10
            $p.DemotedMetric          | Should -Be 100
        }
    }
}


# ============================================================================
# FEATURE: Domain 層 - Policy と現在のセッションから Decision を導出する
#
# 中核ドメイン関数。決定論的で副作用なし。決定の実行は Infrastructure 層が
# 受け持つ。
# ============================================================================

Describe 'Feature: 現在のセッションから優先度判定を導出する' {

    BeforeAll {
        $script:policy = New-PriorityPolicy `
            -Pattern 'alice' `
            -PriorityInterfaceIndex 6 -DefaultInterfaceIndex 3 `
            -PreferredMetric 10 -DemotedMetric 100
    }

    Context 'Scenario: 優先ユーザーがアクティブなセッションを持つ' {
        It '優先 NIC を選び、通常 NIC を降格する' {
            # Given 優先ユーザーが現在アクティブ
            $sessions = @(
                (New-Session -UserName 'alice' -State Active)
                (New-Session -UserName 'bob'   -State Disconnected)
            )

            # When  決定を導出すると
            $d = Resolve-PriorityDecision -Policy $script:policy -Sessions $sessions

            # Then  優先 NIC が勝ち、通常 NIC が降格される
            $d.PreferIndex  | Should -Be 6
            $d.DemoteIndex  | Should -Be 3
            $d.PreferMetric | Should -Be 10
            $d.DemoteMetric | Should -Be 100
            $d.Reason       | Should -Be 'priority user has active session'
        }
    }

    Context 'Scenario: 優先ユーザーは切断中のみ' {
        It '通常 NIC に戻す' {
            # Given 優先ユーザーにアクティブなセッションがない
            $sessions = @(
                (New-Session -UserName 'alice' -State Disconnected)
                (New-Session -UserName 'bob'   -State Active)
            )

            # When  決定を導出すると
            $d = Resolve-PriorityDecision -Policy $script:policy -Sessions $sessions

            # Then  通常 NIC が勝ち、優先 NIC が降格される
            $d.PreferIndex | Should -Be 3
            $d.DemoteIndex | Should -Be 6
            $d.Reason      | Should -Be 'no priority user session is active'
        }
    }

    Context 'Scenario: パターンに一致するユーザーが存在しない' {
        It '通常 NIC に戻す' {
            # Given 優先パターンに一致するユーザーがいない
            $sessions = @(
                (New-Session -UserName 'bob' -State Active)
            )

            # When  決定を導出すると
            $d = Resolve-PriorityDecision -Policy $script:policy -Sessions $sessions

            # Then  通常 NIC が選ばれる
            $d.PreferIndex | Should -Be 3
            $d.DemoteIndex | Should -Be 6
        }
    }

    Context 'Scenario: セッションが 1 件もない' {
        It '通常 NIC に戻す' {
            # Given 空のセッション一覧
            # When  決定を導出すると
            $d = Resolve-PriorityDecision -Policy $script:policy -Sessions @()

            # Then  通常 NIC が選ばれる
            $d.PreferIndex | Should -Be 3
            $d.DemoteIndex | Should -Be 6
        }
    }

    Context 'Scenario: Policy のパターンが正規表現' {
        It 'パターンに合致する任意のユーザーを優先扱いする' {
            # Given alice または bob にマッチする Policy
            $regexPolicy = New-PriorityPolicy `
                -Pattern '^(alice|bob)$' `
                -PriorityInterfaceIndex 6 -DefaultInterfaceIndex 3 `
                -PreferredMetric 10 -DemotedMetric 100
            $sessions = @( (New-Session -UserName 'alice' -State Active) )

            # When  決定を導出すると
            $d = Resolve-PriorityDecision -Policy $regexPolicy -Sessions $sessions

            # Then  alice に対して優先 NIC が選ばれる
            $d.PreferIndex | Should -Be 6
            $d.Reason      | Should -Be 'priority user has active session'
        }
    }
}


# ============================================================================
# FEATURE: Infrastructure 層 - Get-CurrentSessions の境界ふるまい
#
# Invoke-Quser ラッパをモックすることで、外部 EXE に頼らず異常パスや
# 期待出力パスを単体テスト範囲で検証できる。
# ============================================================================

Describe 'Feature: Get-CurrentSessions の境界ふるまい' {

    Context 'Scenario: quser.exe が何も出力しない（稀な異常状態）' {
        It '例外を投げず、空配列を返す' {
            # Given quser.exe が null を返す環境
            Mock -ModuleName NicSwitcher Invoke-Quser { $null }

            # When  現在セッションを取得すると
            $result = Get-CurrentSessions

            # Then  空配列が返り、例外は起きない
            $result | Should -BeNullOrEmpty
        }
    }

    Context 'Scenario: quser.exe が複数行を返す' {
        It '各データ行が Session に変換される' {
            # Given quser.exe がヘッダと 2 セッションを返す
            Mock -ModuleName NicSwitcher Invoke-Quser {
                @(
                    'USERNAME    SESSIONNAME    ID  STATE   IDLE TIME  LOGON TIME',
                    '>alice      console         1  Active   .  2026/05/23 09:00',
                    ' bob        rdp-tcp#1       2  Disc     5  2026/05/23 08:30'
                )
            }

            # When  現在セッションを取得すると
            $result = Get-CurrentSessions

            # Then  ヘッダはスキップされ、2 件の Session が得られる
            @($result).Count       | Should -Be 2
            @($result)[0].UserName | Should -Be 'alice'
            @($result)[1].State    | Should -Be 'Disconnected'
        }
    }
}


# ============================================================================
# FEATURE: Infrastructure 層 - PriorityDecision をネットワークスタックに適用
#
# Set-InterfaceMetric は Set-NetIPInterface への接続点。テストでは
# モック化することで、実ネットワーク設定には絶対に触れない。
# ============================================================================

Describe 'Feature: Decision をネットワークスタックに適用する' {

    BeforeEach {
        Mock -ModuleName NicSwitcher Set-NetIPInterface { } -Verifiable
    }

    Context 'Scenario: 妥当な Decision を適用する' {
        It '優先 NIC に優先メトリックを書き込む' {
            # Given index 6 を優先・メトリック 10 とする Decision
            $decision = New-PriorityDecision `
                -PreferIndex 6 -DemoteIndex 3 `
                -PreferMetric 10 -DemoteMetric 100 `
                -Reason 'test'

            # When  Decision を適用すると
            Set-InterfaceMetric -Decision $decision

            # Then  Set-NetIPInterface が InterfaceIndex=6, Metric=10 で 1 回呼ばれる
            Should -Invoke -ModuleName NicSwitcher -CommandName Set-NetIPInterface `
                -Times 1 -Exactly `
                -ParameterFilter { $InterfaceIndex -eq 6 -and $InterfaceMetric -eq 10 }
        }

        It '通常 NIC に降格メトリックを書き込む' {
            # Given 同じ Decision
            $decision = New-PriorityDecision `
                -PreferIndex 6 -DemoteIndex 3 `
                -PreferMetric 10 -DemoteMetric 100 `
                -Reason 'test'

            # When  Decision を適用すると
            Set-InterfaceMetric -Decision $decision

            # Then  index 3 に降格メトリックが書かれる
            Should -Invoke -ModuleName NicSwitcher -CommandName Set-NetIPInterface `
                -Times 1 -Exactly `
                -ParameterFilter { $InterfaceIndex -eq 3 -and $InterfaceMetric -eq 100 }
        }
    }

    Context 'Scenario: -WhatIf を付けて呼び出す' {
        It 'ネットワークスタックには触れない' {
            # Given Decision オブジェクト
            $decision = New-PriorityDecision `
                -PreferIndex 6 -DemoteIndex 3 `
                -PreferMetric 10 -DemoteMetric 100 `
                -Reason 'test'

            # When  -WhatIf 付きで適用すると
            Set-InterfaceMetric -Decision $decision -WhatIf

            # Then  Set-NetIPInterface は一度も呼ばれない
            Should -Invoke -ModuleName NicSwitcher -CommandName Set-NetIPInterface -Times 0
        }
    }
}


# ============================================================================
# FEATURE: Infrastructure 層 - 監査ログを UTF-8 で書く
# ============================================================================

Describe 'Feature: 監査ログを書き出す' {

    Context 'Scenario: ASCII メッセージを書く' {
        It 'タイムスタンプ付きの 1 行が追記される' {
            # Given テスト用の一時ログパス
            $logPath = Join-Path $TestDrive 'plain.log'

            # When  メッセージを書くと
            Write-NicLog -Path $logPath -Message 'hello'

            # Then  期待する書式の 1 行が記録される
            $line = Get-Content -LiteralPath $logPath -Encoding UTF8
            $line | Should -Match '^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] hello$'
        }
    }

    Context 'Scenario: 日本語メッセージを書く' {
        It '文字化けせずラウンドトリップする' {
            # Given 日本語のメッセージ
            $logPath  = Join-Path $TestDrive 'jp.log'
            $expected = 'イーサネット 3 を優先しました'

            # When  ログに書き、UTF-8 で読み戻すと
            Write-NicLog -Path $logPath -Message $expected
            $line = Get-Content -LiteralPath $logPath -Encoding UTF8 -Tail 1

            # Then  同じ文字列が得られる
            $line | Should -Match ([regex]::Escape($expected))
        }
    }

    Context 'Scenario: 既存ログに追記する' {
        It '上書きせず追記する' {
            # Given 1 件のエントリが入ったログ
            $logPath = Join-Path $TestDrive 'append.log'
            Write-NicLog -Path $logPath -Message 'first'

            # When  2 件目を追加すると
            Write-NicLog -Path $logPath -Message 'second'

            # Then  2 件が順序通りに残っている
            $lines = Get-Content -LiteralPath $logPath -Encoding UTF8
            $lines.Count | Should -Be 2
            $lines[0] | Should -Match 'first'
            $lines[1] | Should -Match 'second'
        }
    }
}


# ============================================================================
# FEATURE: Application 層 - ユースケースのエンドツーエンドな組み立て
#
# Invoke-NicPriorityHandler は各層を組み立てる。Infrastructure 境界
# （Get-CurrentSessions / Set-InterfaceMetric / Start-Sleep）をモック化し、
# 管理者権限もネットワーク I/O もなしでパイプラインを動かす。
# ============================================================================

Describe 'Feature: ログオンイベントをエンドツーエンドで処理する' {

    BeforeEach {
        $script:logPath = Join-Path $TestDrive 'handler.log'
        $script:policy  = New-PriorityPolicy `
            -Pattern 'alice' `
            -PriorityInterfaceIndex 6 -DefaultInterfaceIndex 3 `
            -PreferredMetric 10 -DemotedMetric 100

        Mock -ModuleName NicSwitcher Set-NetIPInterface { } -Verifiable
        Mock -ModuleName NicSwitcher Start-Sleep { }   # テストでは絶対に sleep しない
    }

    Context 'Scenario: 発火ユーザーが SYSTEM アカウント' {
        It 'スキップをログに残し、ネットワーク変更は行わない' {
            # Given SYSTEM がイベントを発火した
            Mock -ModuleName NicSwitcher Get-CurrentSessions { @() }

            # When  ハンドラを実行すると
            Invoke-NicPriorityHandler `
                -TriggeringUser 'SYSTEM' `
                -Policy $script:policy `
                -LogFile $script:logPath `
                -SettleSeconds 0

            # Then  NIC 変更は実行されない
            Should -Invoke -ModuleName NicSwitcher -CommandName Set-NetIPInterface -Times 0

            # And   ログにスキップ理由が記録される
            (Get-Content -LiteralPath $script:logPath -Encoding UTF8) -join "`n" |
                Should -Match 'Skipped \(system or service account'
        }
    }

    Context 'Scenario: イベント時点で優先ユーザーがアクティブ' {
        It '優先 NIC を優先メトリックに切り替える' {
            # Given 優先ユーザーが実機でアクティブ
            Mock -ModuleName NicSwitcher Get-CurrentSessions {
                @( (New-Session -UserName 'alice' -State Active) )
            }

            # When  別ユーザー発火でハンドラを実行すると
            Invoke-NicPriorityHandler `
                -TriggeringUser 'someone@example.com' `
                -Policy $script:policy `
                -LogFile $script:logPath `
                -SettleSeconds 0

            # Then  優先 NIC が優先メトリックに設定される
            Should -Invoke -ModuleName NicSwitcher -CommandName Set-NetIPInterface `
                -Times 1 -Exactly `
                -ParameterFilter { $InterfaceIndex -eq 6 -and $InterfaceMetric -eq 10 }
        }
    }

    Context 'Scenario: 非優先ユーザーしか存在しない' {
        It '通常 NIC を優先メトリックに戻す' {
            # Given 非優先ユーザーだけが実機にいる
            Mock -ModuleName NicSwitcher Get-CurrentSessions {
                @( (New-Session -UserName 'bob' -State Active) )
            }

            # When  ハンドラを実行すると
            Invoke-NicPriorityHandler `
                -TriggeringUser 'bob' `
                -Policy $script:policy `
                -LogFile $script:logPath `
                -SettleSeconds 0

            # Then  通常 NIC に優先メトリックが書かれる
            Should -Invoke -ModuleName NicSwitcher -CommandName Set-NetIPInterface `
                -Times 1 -Exactly `
                -ParameterFilter { $InterfaceIndex -eq 3 -and $InterfaceMetric -eq 10 }

            # And   理由がログに残る
            (Get-Content -LiteralPath $script:logPath -Encoding UTF8) -join "`n" |
                Should -Match 'no priority user session is active'
        }
    }
}
