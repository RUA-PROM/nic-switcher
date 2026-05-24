# nic-switcher システム仕様書

## 1. 目的

nic-switcher は、Windows のログオン関連イベントを契機として、現在アクティブなユーザーセッションに応じて 2 つの NIC の優先度（InterfaceMetric）を自動切り替えする仕組みである。

主目的は次の通り。

- 優先ユーザー（例: 業務用ユーザー）がアクティブなときは業務用 NIC を優先。
- 優先ユーザーがアクティブでないときは通常 NIC を優先。
- 判定と適用の履歴を UTF-8 ログへ監査記録。

## 2. システム境界と依存

### 2.1 入力

- Security イベントログ（イベント ID: 4624, 4634, 4647, 4778, 4779）
- イベント内 TargetUserName（タスク引数 UserName として受け渡し）
- 現在のセッション一覧（quser.exe）
- ローカル設定（config.ps1）

### 2.2 出力

- NIC メトリック変更（Set-NetIPInterface）
- ログファイル追記（nic_handler.log、UTF-8）
- ログローテーション（.log.1, .log.2 ...）

### 2.3 前提条件

- install.ps1 / uninstall.ps1 は管理者権限で実行。
- 実運用時の NIC 書き換えには管理者権限が必要。
- config.ps1 が存在し、整合した値を持つこと。

## 3. アーキテクチャ

実装は Domain / Infrastructure / Application の 3 層で構成される。

```mermaid
flowchart LR
    subgraph Scheduler[Windows Task Scheduler]
      EVT[Security Event Trigger<br/>4624/4634/4647/4778/4779]
    end

    subgraph Entry[nic_handler.ps1]
      CFG[config.ps1 読み込み]
      BUILD[New-PriorityPolicy]
      APPCALL[Invoke-NicPriorityHandler]
    end

    subgraph Module[lib/NicSwitcher.psm1]
      subgraph Domain
        D1[Test-SystemAccountName]
        D2[Resolve-PriorityDecision]
      end
      subgraph Infrastructure
        I1[Get-CurrentSessions<br/>Invoke-Quser + ConvertFrom-QuserLine]
        I2[Set-InterfaceMetric<br/>Set-NetIPInterface]
        I3[Write-NicLog<br/>Invoke-LogRotation]
      end
      subgraph Application
        A1[Invoke-NicPriorityHandler]
      end
    end

    EVT --> CFG --> BUILD --> APPCALL --> A1
    A1 --> D1
    A1 --> I3
    A1 --> I1 --> D2
    D2 --> A1
    A1 --> I2
    A1 --> I3
```

## 4. コンポーネント仕様

```mermaid
flowchart LR
    subgraph EntryPoint
      EH[nic_handler.ps1]
    end

    subgraph Domain
      PP[PriorityPolicy]
      SS[Session]
      PD[PriorityDecision]
      D1[Test-SystemAccountName]
      D2[Resolve-PriorityDecision]
    end

    subgraph Application
      A1[Invoke-NicPriorityHandler]
    end

    subgraph Infrastructure
      I1[Get-CurrentSessions]
      I2[ConvertFrom-QuserLine]
      I3[Set-InterfaceMetric]
      I4[Write-NicLog]
      I5[Invoke-LogRotation]
    end

    subgraph OS[Windows OS]
      O1[Task Scheduler]
      O2[Security Event Log]
      O3[quser.exe]
      O4[Set-NetIPInterface]
      O5[File System]
    end

    EH --> PP
    EH --> A1
    A1 --> D1
    A1 --> I1 --> I2
    A1 --> D2
    D2 --> PD
    A1 --> I3 --> O4
    A1 --> I4 --> I5 --> O5
    I1 --> O3
    O2 --> O1 --> EH
    D2 --> SS
```

## 5. 実行シーケンス

### 5.1 イベント発生から NIC 切り替えまで

```mermaid
sequenceDiagram
    autonumber
    participant SEC as Security Event Log
    participant SCH as Task Scheduler
    participant ENT as nic_handler.ps1
    participant MOD as Invoke-NicPriorityHandler
    participant QUS as quser.exe
    participant NET as Set-NetIPInterface
    participant LOG as nic_handler.log

    SEC->>SCH: ログオン/ログオフ系イベント発生
    SCH->>ENT: powershell -File nic_handler.ps1 -UserName $(EventUser)
    ENT->>ENT: config.ps1 読み込み
    ENT->>ENT: New-PriorityPolicy 生成
    ENT->>MOD: Invoke-NicPriorityHandler(TriggeringUser, Policy, LogFile)

    MOD->>LOG: Triggered ログ出力
    MOD->>MOD: Test-SystemAccountName

    alt システム/サービスアカウント
      MOD->>LOG: Skipped ログ出力
      MOD-->>ENT: return
    else 対話ユーザー
      MOD->>MOD: 必要なら Start-Sleep(SettleSeconds)
      MOD->>QUS: Get-CurrentSessions
      QUS-->>MOD: Session[]
      MOD->>MOD: Resolve-PriorityDecision
      MOD->>LOG: Decision ログ出力
      MOD->>NET: Set-InterfaceMetric(Prefer/Demote)
      MOD->>LOG: Applied ログ出力
      MOD-->>ENT: complete
    end
```

### 5.2 インストール時

```mermaid
sequenceDiagram
    autonumber
    participant Admin as 管理者ユーザー
    participant INS as install.ps1
    participant CFG as config.ps1
    participant SCH as schtasks

    Admin->>INS: install.ps1 実行
    INS->>CFG: TaskName 等を読み込み
    INS->>INS: Task XML 生成(EventTrigger + ValueQueries)
    INS->>SCH: /Create /TN $TaskName /XML ... /F
    SCH-->>INS: タスク登録結果
    INS-->>Admin: 登録完了メッセージ
```

## 6. 状態遷移仕様

このシステムは「優先判定状態」と「適用状態」の 2 段階で遷移する。

```mermaid
stateDiagram-v2
    [*] --> Triggered
    Triggered --> Skipped: TriggeringUser が system/service
    Triggered --> Evaluating: TriggeringUser が対話ユーザー

    Evaluating --> PreferPriorityNIC: 優先ユーザー Active セッションあり
    Evaluating --> PreferDefaultNIC: 優先ユーザー Active セッションなし

    PreferPriorityNIC --> Applied
    PreferDefaultNIC --> Applied

    Skipped --> [*]
    Applied --> [*]
```

## 7. 判定アルゴリズム仕様

### 7.1 セッション取得と正規化

- quser.exe の各行を ConvertFrom-QuserLine で解析。
- Active または Disc を含む行のみ有効なセッション行として採用。
- Disc は内部状態 Disconnected に正規化。
- セッション行先頭の > は除去。

### 7.2 優先判定

- 条件: Session.UserName が PriorityPolicy.Pattern に正規表現一致し、かつ Session.State = Active。
- 上記を満たすセッションが 1 件でもあれば、PriorityInterfaceIndex を優先。
- 1 件もなければ、DefaultInterfaceIndex を優先。

### 7.3 NIC 適用

- 優先側 NIC: PreferredMetric を設定。
- 非優先側 NIC: DemotedMetric を設定。
- 2 回の Set-NetIPInterface 呼び出しで適用。

## 8. フローチャート

### 8.1 ハンドラ本体

```mermaid
flowchart TD
  S([Start]) --> L1[Write Triggered Log]
  L1 --> C1{TriggeringUser は<br/>system/service?}
    C1 -- Yes --> L2[Write Skipped Log]
    L2 --> E([End])
    C1 -- No --> W{SettleSeconds > 0?}
    W -- Yes --> SL[Start-Sleep]
    W -- No --> G
    SL --> G[Get-CurrentSessions]
    G --> D[Resolve-PriorityDecision]
    D --> L3[Write Decision Log]
    L3 --> N[Set-InterfaceMetric]
    N --> L4[Write Applied Log]
    L4 --> E
```

### 8.2 ログローテーション

```mermaid
flowchart TD
  A([Write-NicLog 呼び出し]) --> B{ログファイル存在かつ<br/>サイズ >= MaxBytes?}
    B -- No --> H[そのまま追記]
    B -- Yes --> C[Invoke-LogRotation]
    C --> D[.log.N を削除]
    D --> E[.log.N-1 から .log.1 を順に繰り上げ]
    E --> F[.log を .log.1 へ移動]
    F --> H
    H --> I[UTF-8 でタイムスタンプ付き追記]
    I --> J([End])
```

## 9. データ定義

### 9.1 Session

- UserName: string
- State: Active | Disconnected

### 9.2 PriorityPolicy

- Pattern: string（正規表現）
- PriorityInterfaceIndex: int
- DefaultInterfaceIndex: int
- PreferredMetric: int
- DemotedMetric: int

### 9.3 PriorityDecision

- PreferIndex: int
- DemoteIndex: int
- PreferMetric: int
- DemoteMetric: int
- Reason: string

## 10. 設定仕様（config.ps1）

- PriorityUserPattern: 優先ユーザー判定正規表現
- PriorityInterfaceIndex: 優先候補 NIC
- DefaultInterfaceIndex: 通常候補 NIC
- PreferredMetric: 優先側メトリック（小さいほど優先）
- DemotedMetric: 非優先側メトリック
- TaskName: スケジューラタスク名
- LogFile: ログ出力先
- MaxLogBytes: ローテーション閾値
- MaxLogBackups: 保持世代数

## 11. 不変条件とエラーハンドリング

- New-PriorityPolicy は次を拒否する。
  - PriorityInterfaceIndex と DefaultInterfaceIndex が同値
  - PreferredMetric >= DemotedMetric
- TriggeringUser が system/service の場合は処理スキップし副作用なし。
- Get-CurrentSessions で quser 出力が空の場合は空配列扱い。
- ローテーション失敗時も Write-NicLog 本体は継続（監査停止を回避）。

## 12. テストで検証済みの仕様範囲

- Domain: 判定ルール、不変条件、システムアカウント除外
- Infrastructure: quser 行解析、セッション取得境界、NIC 適用呼び出し、UTF-8 ログ、ローテーション
- Application: トリガー受信から判定・適用・ログ出力までのオーケストレーション
- 結合観点: 実 quser、実ファイル I/O、-WhatIf 経由の安全性確認

## 13. 制約事項

- 対象は 2 つの NIC の優先/降格切り替えモデル。
- セッション状態判定は quser の Active / Disc トークン前提。
- インストール時タスクは SYSTEM 権限で実行されるため、スクリプト改変リスク管理が必要。

## 14. 運用上の注意

- config.ps1 と nic_handler.log は機微情報を含むためリポジトリ管理対象外とする。
- モジュール更新後は install.ps1 の再実行でタスク XML の実行パスを最新化する。
- 本番反映前に tests/Run-Tests.ps1 と必要に応じて tests/verify-on-real-machine.ps1 で検証する。
