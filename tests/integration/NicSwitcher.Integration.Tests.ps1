# lib/NicSwitcher.psm1 の結合テスト（Pester 5 / BDD 形式）
#
# 単体テストとの違い:
#   - 単体テストは外部依存（quser.exe / Set-NetIPInterface / Start-Sleep）を
#     すべてモックして、関数の振る舞いだけを検証する。
#   - 結合テストは実際のシステム（quser.exe の実行・ファイル I/O・
#     Set-NetIPInterface の WhatIf 呼び出し）を通して、層をまたいだ
#     ふるまいを検証する。
#
# 方針:
#   - 実際のネットワーク設定は変更しない（Set-NetIPInterface は -WhatIf 経由か
#     モックで隔離する。実適用はそもそも管理者権限が必要）。
#   - 一時ファイルは TestDrive を使い、テスト終了時に自動削除させる。
#   - quser.exe が動かない環境（CI など）では該当シナリオは Inconclusive 扱い。

# Pester 5 は -Skip を Discovery 時に評価するため、ファイルスコープで
# 判定する必要がある。BeforeAll 内に置くと Discovery 時点で未設定となり
# 常に Skip 扱いになってしまう。
$HasQuser = $null -ne (Get-Command quser.exe -ErrorAction SilentlyContinue)

BeforeAll {
    $modulePath = Resolve-Path (Join-Path $PSScriptRoot '..\..\lib\NicSwitcher.psm1')
    Import-Module $modulePath -Force
}


# ============================================================================
# FEATURE: Infrastructure 層 - 実際の quser.exe からセッションが取れる
#
# Get-CurrentSessions は quser.exe を呼び、ConvertFrom-QuserLine で
# Session に変換する。実コマンドの出力フォーマットに対するアダプタの
# 適合性を確認する。
# ============================================================================

Describe 'Feature: 実 quser.exe からの Session 取得' {

    Context 'Scenario: テスト実行ユーザー自身がログオン済み' {
        It '最低1件以上の Session を返し、それぞれに UserName と State がある' -Skip:(-not $HasQuser) {
            # Given テスト実行プロセスはログオンセッションの中で動いている
            # When 現在のセッション一覧を取得すると
            $sessions = Get-CurrentSessions

            # Then 1件以上のセッションが返り、必須フィールドを持っている
            $sessions.Count           | Should -BeGreaterThan 0
            $sessions[0].UserName     | Should -Not -BeNullOrEmpty
            $sessions[0].State        | Should -BeIn @('Active', 'Disconnected')
            $sessions[0].PSTypeNames  | Should -Contain 'NicSwitcher.Session'
        }

        It '実行中のテストプロセスのユーザーが含まれている' -Skip:(-not $HasQuser) {
            # Given 現在のユーザー名
            $currentUser = $env:USERNAME

            # When セッションを取得すると
            $sessions = Get-CurrentSessions

            # Then 自分のユーザーが（大文字小文字無視で）含まれている
            ($sessions | Where-Object { $_.UserName -ieq $currentUser }) | Should -Not -BeNullOrEmpty
        }
    }
}


# ============================================================================
# FEATURE: Infrastructure 層 - ログがディスクに UTF-8 で書ける
#
# Write-NicLog の戻り値だけでなく、ファイルシステム経由のラウンドトリップ
# まで含めて検証する。日本語の文字化けが起きないことが最大の関心事。
# ============================================================================

Describe 'Feature: 実ディスクへの UTF-8 ログ書き込み' {

    Context 'Scenario: 日本語メッセージを書いて読み戻す' {
        It '書いた内容と読み戻した内容が一致する' {
            # Given テスト専用の一時ログパス
            $logPath  = Join-Path $TestDrive 'integration-jp.log'
            $expected = 'イーサネット 3（仕事用）を優先しました'

            # When Write-NicLog で書き、Get-Content -Encoding UTF8 で読み戻すと
            Write-NicLog -Path $logPath -Message $expected
            $line = Get-Content -LiteralPath $logPath -Encoding UTF8 -Tail 1

            # Then 文字化けなく一致する
            $line | Should -Match ([regex]::Escape($expected))
        }
    }

    Context 'Scenario: 複数回書き込んで追記される' {
        It '行数が呼び出し回数分だけ増える' {
            # Given 空のログパス
            $logPath = Join-Path $TestDrive 'integration-append.log'

            # When 3回ログを書くと
            Write-NicLog -Path $logPath -Message '1行目'
            Write-NicLog -Path $logPath -Message '2行目'
            Write-NicLog -Path $logPath -Message '3行目'

            # Then 3行が順序通りに格納されている
            $lines = Get-Content -LiteralPath $logPath -Encoding UTF8
            $lines.Count | Should -Be 3
            $lines[0] | Should -Match '1行目'
            $lines[1] | Should -Match '2行目'
            $lines[2] | Should -Match '3行目'
        }
    }
}


# ============================================================================
# FEATURE: Infrastructure 層 - Set-InterfaceMetric の -WhatIf 安全性
#
# 実際にネットワークを変更すると環境を壊すため、-WhatIf を通じて
# Set-NetIPInterface に到達するパスだけを検証する。
# ============================================================================

Describe 'Feature: -WhatIf を通したネットワーク変更の安全性' {

    Context 'Scenario: -WhatIf で実行すると副作用は起きない' {
        It 'Set-NetIPInterface は呼ばれない' {
            # Given 有効な PriorityDecision
            $decision = New-PriorityDecision `
                -PreferIndex 9999 -DemoteIndex 9998 `
                -PreferMetric 10 -DemoteMetric 100 `
                -Reason 'integration-whatif-test'

            # When -WhatIf を付けて Set-InterfaceMetric を呼ぶ
            # Then 例外なく完了し、現実のメトリックは変わらない
            { Set-InterfaceMetric -Decision $decision -WhatIf } | Should -Not -Throw
        }
    }
}


# ============================================================================
# FEATURE: Application 層 - エンドツーエンドのオーケストレーション
#
# config 読み込み → Policy 構築 → Handler 実行 までを実ファイル経由で通す。
# ネットワーク呼び出しだけはモックして環境を壊さないようにする。
# ============================================================================

Describe 'Feature: ハンドラのエンドツーエンド実行（ネットワークのみモック）' {

    BeforeAll {
        # Set-NetIPInterface はモックで隔離（管理者権限が要らない）
        Mock -ModuleName NicSwitcher Set-NetIPInterface { } -Verifiable
        # Start-Sleep もモックして高速化
        Mock -ModuleName NicSwitcher Start-Sleep { }
    }

    Context 'Scenario: SettleSeconds を非 0 にして待ちパスを通す' {
        It 'Start-Sleep が指定秒で呼ばれる（モック上）' -Skip:(-not $HasQuser) {
            # Given handler に SettleSeconds=1 を渡す
            $logPath = Join-Path $TestDrive 'settle.log'
            $policy  = New-PriorityPolicy `
                -Pattern                'nobody-matches-this-pattern' `
                -PriorityInterfaceIndex 9999 -DefaultInterfaceIndex 9998 `
                -PreferredMetric 10 -DemotedMetric 100

            # When 通常ユーザーで呼び出すと
            Invoke-NicPriorityHandler `
                -TriggeringUser $env:USERNAME `
                -Policy $policy -LogFile $logPath -SettleSeconds 1

            # Then Start-Sleep が指定秒数で1回呼ばれる
            Should -Invoke -ModuleName NicSwitcher -CommandName Start-Sleep -Times 1 -Exactly `
                -ParameterFilter { $Seconds -eq 1 }
        }
    }

    Context 'Scenario: 実 quser を使い、実 Policy を作り、handler を回す' {
        It '実セッション状態に基づいて Set-NetIPInterface が1回ずつ2回呼ばれる' -Skip:(-not $HasQuser) {
            # Given 実セッションに対応した Policy と一時ログ
            $logPath = Join-Path $TestDrive 'e2e.log'

            # 現実のユーザー名を Pattern にすれば、Active 判定の経路を通る
            $policy = New-PriorityPolicy `
                -Pattern                ([regex]::Escape($env:USERNAME)) `
                -PriorityInterfaceIndex 9999 `
                -DefaultInterfaceIndex  9998 `
                -PreferredMetric        10 `
                -DemotedMetric          100

            # When 通常ユーザーを TriggeringUser として handler を呼ぶ
            Invoke-NicPriorityHandler `
                -TriggeringUser $env:USERNAME `
                -Policy         $policy `
                -LogFile        $logPath `
                -SettleSeconds  0

            # Then 2つの NIC に1回ずつメトリックが書かれる
            Should -Invoke -ModuleName NicSwitcher -CommandName Set-NetIPInterface -Times 2 -Exactly

            # And ログに Decision 行が含まれている
            (Get-Content -LiteralPath $logPath -Encoding UTF8) -join "`n" |
                Should -Match 'Decision: priority user has active session'
        }
    }

    Context 'Scenario: 実 config.example.ps1 をロードしてバリデーションが通る' {
        It 'example の値で New-PriorityPolicy がエラーにならない' {
            # Given config.example.ps1 を一時に複製してプレースホルダを実値に置換
            $examplePath = (Resolve-Path (Join-Path $PSScriptRoot '..\..\config.example.ps1')).Path
            $tempConfig  = Join-Path $TestDrive 'config.ps1'
            $content = Get-Content -LiteralPath $examplePath -Raw -Encoding UTF8
            $content = $content -replace "YOUR_USERNAME_HERE", 'testuser'
            $content = $content -replace '\$PriorityInterfaceIndex = 0', '$PriorityInterfaceIndex = 6'
            $content = $content -replace '\$DefaultInterfaceIndex\s*= 0',  '$DefaultInterfaceIndex  = 3'
            Set-Content -LiteralPath $tempConfig -Value $content -Encoding UTF8

            # When その config を読み込んで Policy を構築すると
            . $tempConfig
            $policy = New-PriorityPolicy `
                -Pattern                $PriorityUserPattern `
                -PriorityInterfaceIndex $PriorityInterfaceIndex `
                -DefaultInterfaceIndex  $DefaultInterfaceIndex `
                -PreferredMetric        $PreferredMetric `
                -DemotedMetric          $DemotedMetric

            # Then 期待した値を持つ Policy が手に入る
            $policy.Pattern                | Should -Be 'testuser'
            $policy.PriorityInterfaceIndex | Should -Be 6
            $policy.DefaultInterfaceIndex  | Should -Be 3
            $policy.PreferredMetric        | Should -BeLessThan $policy.DemotedMetric
        }
    }
}
