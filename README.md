# nic-switcher

Windows でログオンしているユーザーに応じて、イーサネットアダプターの優先度（メトリック）を自動的に切り替えるツール。

## 用途

設定した「優先ユーザー」がアクティブなセッションを持つときだけ、特定のネットワークアダプター（例：仕事用の固定IP）を最優先にする。それ以外のユーザーだけがログインしているときは通常のアダプターに戻す。

Microsoft アカウントでログオンするとイベントログ上のユーザー名がメールアドレスになるが、本ツールは `quser` の出力（ローカルセッション状態）で判定するため、ローカル名とメールアドレスのマッピングを設定せずに動作する。

## 設計方針

### ドメイン駆動の責務分離

`lib/NicSwitcher.psm1` の中で **Domain / Infrastructure / Application** の3層に責務を分けている。

| 層 | 責務 | 構成要素 |
|----|------|---------|
| **Domain** | 業務ルールと値オブジェクト。副作用なし。 | `Session`, `PriorityPolicy`, `PriorityDecision`, `Test-SystemAccountName`, `Resolve-PriorityDecision` |
| **Infrastructure** | OS・ファイルシステムへのアダプタ | `ConvertFrom-QuserLine`, `Get-CurrentSessions`, `Set-InterfaceMetric`, `Write-NicLog` |
| **Application** | ユースケースの調整 | `Invoke-NicPriorityHandler` |

Domain層は純粋関数のため、外部依存をモックせずに直接テストできる。Infrastructure層が `Set-NetIPInterface` や `quser.exe` を呼ぶ唯一の場所であり、ここを差し替えればテスト時に安全に隔離できる。

### ユビキタス言語

コードとテストで一貫して使う用語：

| 用語 | 意味 |
|------|------|
| **Session** | 1ユーザーのログオンセッション。`State`（`Active` / `Disconnected`）を持つ値オブジェクト |
| **PriorityUser** | 出現すると NIC 優先度が切り替わるユーザー |
| **PriorityPolicy** | 設定値（パターン・NIC 番号・メトリック）のまとまり |
| **PriorityDecision** | ポリシー評価の結果（どの NIC を優先するか・理由） |
| **TriggeringUser** | スケジュールタスクを発火させた Security イベントの対象ユーザー |

### その他の方針

- **設定は外部化**: 個人情報を含む値は `config.ps1` に集約、git からは除外
- **ロケール非依存**: `quser` の解析は英語固定の状態トークン（`Active` / `Disc`）のみに依存
- **ログは UTF-8**: 既定の ANSI でなく UTF-8 で書き出し、日本語が文字化けしない
- **不変条件の早期検証**: `New-PriorityPolicy` で同一 NIC 指定やメトリック逆転を構築時に弾く

## 仕組み

Windows タスクスケジューラに登録した **イベントトリガー** が Security イベントログを監視し、ログオン関連イベントが発生すると `nic_handler.ps1` を `SYSTEM` 権限で起動する。

| イベントID | 内容 |
|----------|------|
| 4624 | ログオン（コンソール / RDP / ロック解除 / キャッシュ済み） |
| 4634 | ログオフ |
| 4647 | ユーザーによるログオフ |
| 4778 | セッション再接続 |
| 4779 | セッション切断 |

## ファイル構成

| パス | 役割 | git 管理 |
|------|------|--------|
| `nic_handler.ps1` | エントリポイント（コンポジションルート）。config と module を組み立てて Application 層を呼び出す | ✅ |
| `install.ps1` | タスクスケジューラへ登録（管理者権限が必要） | ✅ |
| `uninstall.ps1` | タスクスケジューラから削除（管理者権限が必要） | ✅ |
| `config.example.ps1` | 設定テンプレート | ✅ |
| `config.ps1` | **ローカル設定**（実値） | ❌ gitignore |
| `lib/NicSwitcher.psm1` | Domain / Infrastructure / Application を含むモジュール | ✅ |
| `tests/unit/*.Tests.ps1` | 単体テスト（外部依存はモック） | ✅ |
| `tests/integration/*.Tests.ps1` | 結合テスト（実 quser / 実ファイル I/O / `-WhatIf`） | ✅ |
| `tests/Run-Tests.ps1` | テストランナー（カバレッジ計測込み） | ✅ |
| `tests/verify-on-real-machine.ps1` | 実機エンドツーエンド検証（管理者権限が必要） | ✅ |
| `tests/coverage.xml` | JaCoCo 形式のカバレッジレポート | ❌ gitignore |
| `nic_handler.log` | 実行履歴（UTF-8） | ❌ gitignore |

## セットアップ

### 1. 設定ファイルを作成

```powershell
Copy-Item config.example.ps1 config.ps1
notepad config.ps1
```

`config.ps1` の各項目を自分の環境に合わせる：

| 項目 | 説明 |
|------|------|
| `$PriorityUserPattern` | 優先したいローカルユーザー名（正規表現） |
| `$PriorityInterfaceIndex` | 優先したい NIC の `InterfaceIndex` |
| `$DefaultInterfaceIndex` | 通常時に優先する NIC の `InterfaceIndex` |
| `$PreferredMetric` / `$DemotedMetric` | メトリック値（小さいほど優先） |
| `$TaskName` | タスクスケジューラ上のタスク名 |
| `$LogFile` | ログファイルの出力先 |

`InterfaceIndex` は次で確認できる：

```powershell
Get-NetAdapter | Select-Object Name, InterfaceIndex, Status
```

### 2. （任意）`C:\Scripts` へのシンボリックリンク

タスク登録パスを安定化したい場合に作成：

```powershell
# 管理者 PowerShell
New-Item -ItemType SymbolicLink -Path "C:\Scripts" -Target "C:\Users\<you>\projects\nic-switcher"
```

### 3. タスクスケジューラに登録

```powershell
# 管理者 PowerShell
.\install.ps1
```

`install.ps1` は `config.ps1` を読み込み、`$PSScriptRoot` から現在のスクリプトパスを埋め込んだタスク XML を生成して `schtasks /Create` で登録する。

### アンインストール

```powershell
# 管理者 PowerShell
.\uninstall.ps1
```

## テスト

BDD 形式（Feature / Scenario / Given-When-Then）で書かれた Pester 5 テストを同梱している。**単体テストと結合テストを分離**し、コードカバレッジも自動計測する。

### 実行

```powershell
# 初回のみ
Install-Module -Name Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck

# 既定: 単体 + 結合 + カバレッジ
.\tests\Run-Tests.ps1

# 単体だけ
.\tests\Run-Tests.ps1 -Suite Unit

# 結合だけ
.\tests\Run-Tests.ps1 -Suite Integration

# カバレッジ計測を無効化（高速化）
.\tests\Run-Tests.ps1 -NoCoverage
```

### テスト構成

| 種別 | パス | 目的 |
|------|------|------|
| 単体 | `tests/unit/NicSwitcher.Unit.Tests.ps1` | 各関数を外部依存をモックして個別検証 |
| 結合 | `tests/integration/NicSwitcher.Integration.Tests.ps1` | 実 `quser.exe`、実ファイル I/O、`Set-NetIPInterface -WhatIf` を通したレイヤー貫通検証 |

Pester の `Describe` / `Context` / `It` をそれぞれ BDD の **Feature / Scenario / 振る舞いの仕様** に対応させている。各 `It` の中にはインラインで Given / When / Then をコメントとして書き、自然言語のシナリオと実行ステップが対応するようにしてある。

#### 単体テストの Feature 一覧（8 features / 29 scenarios）

| Feature | シナリオ数 |
|---------|----------|
| システムアカウントを NIC 切り替えの対象から除外する | 5 |
| quser 出力を Session オブジェクトに変換する | 6 |
| PriorityPolicy が設定の安全性を強制する | 3 |
| 現在のセッションから優先度判定を導出する | 5 |
| Get-CurrentSessions の境界ふるまい | 2 |
| Decision をネットワークスタックに適用する | 2 (+1 `-WhatIf`) |
| 監査ログを書き出す | 3 |
| ログオンイベントをエンドツーエンドで処理する | 3 |

#### 結合テストの Feature 一覧（4 features / 7 scenarios）

| Feature | シナリオ数 |
|---------|----------|
| 実 quser.exe からの Session 取得 | 2 |
| 実ディスクへの UTF-8 ログ書き込み | 2 |
| -WhatIf を通したネットワーク変更の安全性 | 1 |
| ハンドラのエンドツーエンド実行（ネットワークのみモック） | 2 (+1 config example) |

### カバレッジ

| 指標 | 値 |
|------|-----|
| 単体 + 結合 合計テスト数（TestCases 展開後） | **49** |
| `lib/NicSwitcher.psm1` 命令カバレッジ | **100%** (78 / 78 命令) |

カバレッジレポートは `tests/coverage.xml` に JaCoCo 形式で出力される（SonarQube・Coverage Gutters 等で読める）。

すべての自動テストは `Set-NetIPInterface` のモック化／`-WhatIf` 隔離によって、**管理者権限なし・ネットワークに影響なし** で完結する。

### 実機での最終確認

自動テストはあくまで `Set-NetIPInterface` をモックしているため、「実機で本当にメトリックが書き換わる」ことは別途確認が必要。`tests/verify-on-real-machine.ps1` がその一連の手順を自動化する。

```powershell
# 管理者 PowerShell
.\tests\verify-on-real-machine.ps1
```

このスクリプトは以下を順に実行する：

1. 検証前の `Get-NetIPInterface` を表示
2. `install.ps1` を再実行して、最新コードのパスでタスク XML を再生成
3. 現在ログオンしている優先ユーザーで `nic_handler.ps1` を実呼び出し
   （`Set-NetIPInterface` まで実際に到達する）
4. 検証後の `Get-NetIPInterface` を表示し、メトリックが期待値になっていることを目視確認
5. 監査ログの末尾を表示

期待結果は `config.ps1` の値から自動で表示される。

## 動作確認

```powershell
# 現在のメトリック
Get-NetIPInterface | Format-Table InterfaceAlias, InterfaceIndex, InterfaceMetric -AutoSize

# 実行履歴（UTF-8）
. .\config.ps1
Get-Content $LogFile -Encoding UTF8 -Tail 30

# 手動でテスト（管理者権限が必要）
powershell -ExecutionPolicy Bypass -File .\nic_handler.ps1 -UserName "your_username"
```

## セキュリティ考慮事項

公開リポジトリとして共有する／他人の環境で動かす場合に注意すべき点。

### 必ず守ること

- **`config.ps1` を絶対にコミットしない**: ユーザー名・パス・社内ネットワーク構成などの個人／組織情報が含まれる。`.gitignore` 済みだが、`git add -f` 等で誤コミットしないこと
- **`nic_handler.log` をコミットしない**: アクティブセッションのユーザー名・接続元（RDP クライアント名など）が記録される（PII 相当）
- **`install.ps1` を実行する前に必ず差分レビュー**: スケジュールタスクは `SYSTEM` 権限で動作する。本リポジトリの改ざんはマシン全体の侵害と等価
- **管理者 PowerShell の利用は最小限に**: `install.ps1` / `uninstall.ps1` 以外で管理者権限を要求しない設計

### 想定する脅威モデルと対策

| 脅威 | 対策 |
|------|------|
| `config.ps1` の漏洩 | `.gitignore` で除外。クラウドストレージ同期対象からも外す |
| `nic_handler.ps1` への悪意ある書き換え | プロジェクトディレクトリは ACL で本人＋Administrators のみ書き込み可とすること |
| `$PriorityUserPattern` の正規表現誤設定 | 文字列リテラルでも正規表現として解釈される。`.` 等のメタ文字を含むユーザー名は `[regex]::Escape()` で囲む |
| ログファイルの肥大化 | イベントは頻繁に発火する。定期的なローテーション運用を推奨 |
| 不正な Policy 構築 | `New-PriorityPolicy` が同一 NIC 指定 / メトリック逆転を構築時に拒否 |
| 予期せぬ副作用 | `Set-InterfaceMetric` は `SupportsShouldProcess`。`-WhatIf` でドライランできる |

### 推奨運用

- `nic_handler.log` を週次でローテーション
- `config.ps1` をパスワードマネージャや暗号化ボールトに別途バックアップ
- `lib/NicSwitcher.psm1` 変更時は `tests/Run-Tests.ps1` を必ず実行してから `install.ps1` し直す
- `install.ps1` の生成 XML を `schtasks /Query /TN <TaskName> /XML` で定期的に確認

## ライセンス

未定。私用利用を想定。
