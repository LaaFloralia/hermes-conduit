# LAA iPhoneアプリ 基準版（BASELINE）

2026-10-29観測。対象はLaaFloralia/hermes-conduitのLAA版（master）。本作業は読取りのみで、認証・設定・サービス・他ブランチ・稼働中workerの成果に触れていない。観測はシェル（git／ps／lsof／plutil／launchd設定・ログ・JSONの読取り）とリポジトリ内文書で行い、実機操作・画面確認は行っていない。版・パスはすべて同日の実体。

## 1. 結論（後続への要点）

- 実機ビルドの実行環境が未整備。`xcode-select -p` はCommandLineToolsを指し、`xcodebuild`・`simctl`・`devicectl` は失敗する（Xcode.appは導入済み）。04・07・11・12・32の署名済み実機検証は、開発者ディレクトリの切替（設定変更）なしには開始できない。
- 稼働版と上流の差が大きい。Conduitプラグインは実体0.69.1、上流mainは0.116.0。iPhone側アプリは2.2.0（Hermesの端末記録）で、LAAフォーク版（0.1.15）の実機導入は未確認。
- Usageは3系統が併存する。Hermes dashboard analytics（アプリの設定>Usage）、CodexBar＋usage-proxy（8081/8082）、Console collector（8081/widget）。MacのCPU・メモリ収集は存在しない。
- KanbanはConduitに実装があるが、LAA運用では使っていない（Mac mini内のみで、Paseoから見えない）。タスク正本はLinear。
- Brainは3つのwriter（Syncthing、git、Obsidian）が同じvaultを共有し、アプリ側の同時書込み調停は未検証。

## 2. 版と実体

| 対象 | 版・ID | パス | 観測方法 |
|---|---|---|---|
| Conduitリポジトリ | master 858f243c（2026-10-29 13:35 JST） | `/Users/laa/dev/hermes-conduit` | `git log -1`, `git status -sb` |
| Conduit版番号 | MARKETING 0.1.15 / build 162 | `project.yml` | `git show` |
| 上流追随 | upstream/main が master より2 commit先行 | `git rev-list --count master..upstream/main` | 同上 |
| 上流タグ | 最新 `ios/v2.2.1-build-236` | — | `git tag --sort=-creatordate` |
| iPhone/iPadアプリ | 2.2.0（両端末、Hermesのペアリング記録） | `~/.hermes/conduit-settings.json` devices | JSONの`app_version`のみ読取り |
| LAAフォーク版 | `com.laa-inc.conduit`、署名は`Apple Development`自動 | `project-personal.yml` | grep（TEAMは空、スクリプトが引数で渡す） |
| Conduitプラグイン（実体） | 0.69.1 / c2f6a19（2026-10-24, main） | `~/.hermes/plugins/conduit_push` | `plugin.yaml`, `git log`, `.install-metadata.json` |
| 同（上流main） | 0.116.0 / af9247f | GitHub kaishi00/hermes-conduit-notifier | `git ls-remote`, rawの`plugin.yaml` |
| 更新通知 | 2026-10-24〜28 毎日「plugin updates available」 | `~/.hermes/logs/gateway.log` | grep |
| Hermes | v0.22.2（2026.9.24）local d923a5eb | `~/.local/share/hermes-agent` | `hermes --version` |
| Hermes gateway | 常駐（launchd `ai.hermes.gateway`、PID稼働中） | `~/.hermes` | `ps`, launchd plist |
| Hermesプロファイル | 統合後の想定は8件（laa-monet、laa-monet-uncensored、laa-cfo、laa-cio、laa-cos、laa-cso、laa-cto、laa-argus）。実行環境への反映は親が担当 | `~/.hermes/profiles` | 切替後に確認 |
| Paseo | CLI 0.11.4 / daemon 0.12.0 | `/Applications/Paseo.app` | `paseo --version`, プラグインのエラー文 |
| Paseoプラグイン | child-session-prefix 稼働 / t3-chat-theme **failed**（daemon 0.12.0が要求範囲外） | `paseo plugin ls --json` | 同上 |
| push relay | `https://push.milim.dev`、gateway `Mac-mini.local Hermes`、E2E有効 | `~/.hermes/conduit-push.json`（credentialは読まない） | キー限定の読取り |
| CodexBar | 0.81.0 (174)、server 127.0.0.1:8080 | `/Applications/CodexBar.app` | Info.plist, lsof |
| Studio | 0.12.3 | `/Users/laa/dev/studio` | package.json, ps |

## 3. Conduitアプリの機能実体

- `docs/FEATURE_MAP.md` は3,383行・92エントリ。各エントリが Siblings / Code / Rulings / Open gaps / Checked を持ち、CIの`scripts/check-feature-map.py`が形・パス実在・PR記載を検査する。変更時は兄弟画面（音声モード、通話の場所、チャット面、設定の説明文）を同時に計画する規約。LAA版のPRでも同じ照合が要る。
- ウィジェット（`docs/WIDGETS.md`、`ConduitWidgets/`）はNativeとConduit-chanの2種、mediumのみ。App Groupは `group.com.milim.relay.launcher`、拡張のApp IDは `com.milim.relay.widgets`。文書の記録ではTestFlight 0.1.18 build 200（2026-10-14）まで署名・アップロード済みだが、**WidgetKitギャラリー描画はシミュレータのAppIntentヘルパー不具合で未確認**、実機タップも未確認。
- Kanbanは `Conduit/Views/Kanban`（12ファイル）ほか全35 Swiftファイル。状態遷移は `docs/KANBAN_LIFECYCLE_MATRIX.md` が上流NousResearch/hermes-agentの `VALID_STATUSES`・`LOCKED_COLUMNS`・plugin_apiに突き合わせて確定（scheduled/running/reviewはユーザー移動不可）。
- アプリ内Usage（設定>Usage、`Conduit/Models/UsageReport.swift`）はdashboardの `/api/analytics/usage`・`/api/analytics/models` と `model.options` を読むだけで、自前収集を持たない。Roadmap 05/09の「既存取得」候補の一つ。

## 4. HQ正本と現状の差分

- `hq/tools/PASEO-HERMES.md`：pluginの記述は「2026-10-24に0.66.1の保存版＝読込み版、restart_needed=false」。実体は0.69.1で上流0.116.0。**文書が実体より古い**。plugin更新は `hermes plugins update conduit_push` → Conduit正規再起動 → loaded_version/restart_needed読戻し、と手順は明記。
- 同：Conduit接続先は `https://mac-mini.tailc9b8e7.ts.net:8444`（→ 127.0.0.1:9119）、Tailscale内限定。Kanbanは「Mac mini内だけでPaseo等から見えないため現在は使わない」。
- `hq/tools/AI-OPERATING-MODEL.md`：Mac側の共通入口は`laa-personal-agent`。モデル自動切替・新ジョブ基盤を作らない。request ID・ownerの再利用、`awaiting_review`は完了でない、通知を実行命令にしない、を規定。
- `hq/tools/LINEAR.md`：タスク・判断待ち・実行進捗の正本はLinear。担当LAAへのアサインは実行許可ではない。Brainへ同じタスク状態を複製しない。

## 5. laa-personal-agent

- 入口 `/Users/laa/.local/bin/laa-personal-agent` → 実体 `/Users/laa/hq/harness/personal_agent_bridge.mjs`（24,938 bytes、2026-10-25更新、hqはmaster clean）。
- 操作は create / status / wait / list / send / reply / stop。waitは最大55秒（Monet側）、`creation_outcome_unknown` は新IDで再試行しない。Paseoの永続idempotency必須。
- Hermes Monetの `laa_personal_agent` だけがorigin `hermes-conduit` 固定で呼ぶ。他7役はterminal・Mac委譲を持たない。

## 6. Usage・Mac監視の既存経路

| 系統 | 実体 | 取得元・単位 | 鮮度・欠測 |
|---|---|---|---|
| アプリ設定>Usage | `UsageReport.swift` | Hermes dashboard `/api/analytics/usage`・`/api/analytics/models`・`model.options`（トークン、推定/実コスト、利用枠） | 画面を開いた時と更新時のみ。未取得の表現は実装依存で未確認 |
| CodexBar＋proxy | CodexBar 0.81.0 (server :8080)、`usage-proxy.py`（:8081 `/widget`、:8082 auday） | 各providerの残量・利用枠、`~/.config/codexbar/usage.json` | 120秒更新。`com.laa.ai-usage-server` のログにDeepSeek balance **HTTP 401** が継続（2026-10-25） |
| Console | `dev/inventory` collector（`USAGE_FEED_URL = http://127.0.0.1:8081/widget`） | proxyのwidget JSON。`fetchedAt`必須・未来時刻は拒否、`unavailable`はnull | 1分間隔でR2へ同期。表示はConsole `:4318`／Tailscale 8443 `/overview` |
| Mac容量 | `laa-storage-guard status` | 空き167.5GB/460.4GB、work・cacheの内訳 | 毎日05:30のlaunchd。**CPU・メモリの収集はどの経路にも無い** |

Tailscale Serveの実体：8443 → `/`=8081、`/auday`=8082、`/overview`=4318。8444 → 9119（Hermes dashboard、Conduitの接続先）。

## 7. Studio

- `/Users/laa/dev/studio` 0.12.3（Electron、`dist-mobile` にPWA資産、`src/main/mobile.ts`）。MCP `creative_studio` と `bin/studio` が同じ版検査・Undo付き操作を使う。
- 稼働中の実体が**2つ**：`/Users/laa/dev/studio/release/Studio.app`（現行、`--user-data-dir=.../LAA Creative Studio`）と `/Users/laa/dev/creative-studio/release/Studio.app`（旧パス、`studio-mcp.js` を実行）。どちらがMCPの正規窓口かは未確認。03（iPhone Lab視覚案）はこの重複を解消しないまま作業を始めると版が混ざる。
- `/Users/laa/Studio` は空ディレクトリ（作品データはアプリ側のユーザーディレクトリ）。

## 8. Brain同期writer

| writer | 実体 | 挙動 |
|---|---|---|
| Syncthing | launchd `sh.brew.syncthing`（KeepAlive）、`~/Library/Application Support/Syncthing/config.xml` | `brain`→`/Users/laa/Brain`、`hq`→`/Users/laa/hq` を sendreceive。rescan 3600秒＋fsWatcher 10秒。device定義10件（自分含む） |
| git | `/Users/laa/Brain` remote `LaaFloralia/Brain`、launchd `com.laa.vault-git-sync`（10分ごと） | master clean・origin一致。iPhone側のgit writer有無は未確認 |
| Obsidian | `/Applications/Obsidian.app`、vault登録 `/Users/laa/Brain`（開）と `/Users/laa/hq` | 直接書込み。file recovery設定は未確認 |
| iPhone | SyncTrain等のクライアント | **未確認**（MacにSyncTrain.appは無い） |

同時書込みは3系統が同一ファイルへ到達し得る。原子上書きだけでは外部writerとのcheck→rename競合を防げない（Roadmap 24の主題）。

## 9. 稼働サービス・定期処理

- `crontab` は空（`crontab: no crontab for laa`）。`~/Library/LaunchAgents` は29件、うちLAA系は hermes-gateway / hermes-personal / hermes-personal-voice / hermes-scheduler（停止） / usage-meters / ai-usage-server / ai-usage-proxy / inventory-overview / vault-git-sync / storage-guard / harness-control-local・relay / jev-gateway / gemini-tts / work-apps / slack-company（停止） / mt5系 / trade-journal系。
- `laa-console jobs` は30件を返す。主な予定：app-updates 金04:30、technology-audit 土03:00、brain-daily 毎日00:05（毎時補完）、daily 平日09:00・18:00、weekly 土07:00、storage-guard 毎日05:30。在庫系（inventory-overview）はcommit固定release `3ab440a` を `:4318` で常駐配信。
- 注意：`com.laa.usage-meters` は収集ではなく、ログイン時にCodexBar・SwiftBar・Activity Monitorを開くだけ（`ProgramArguments = /usr/bin/open`）。

## 10. 並行作業の状態（読取りのみ）

| 作業 | 実体 | 状態 |
|---|---|---|
| 署名／TestFlight | branch `laa/testflight-signing` = c4923d8a（worktree `/Users/laa/.paseo/worktrees/3jx6tqiv/laa-testflight-signing`） | masterに対し**新規commit 0**（1 behind）。成果はまだbranchに無い |
| CallKit発信 | branch `laa/callkit-outgoing` = 0b1e26f8 | masterから2 commit、17ファイル +1050/−233。未マージ |
| Console AI Usage非表示 | `dev` branch `console/hide-ai-usage` = 745bdcb | dev masterと同一（差分0）。作業中か完了済みかは未確認 |
| 設計・Studio iPhone Lab | gitに痕跡なし（Studio側） | 状態不明。07/03の前提 |

## 11. 未確認

実機のビルド種別（App Store 2.2.0かLAAフォーク0.1.15か）とIME・通話・ウィジェットの実挙動。WidgetKitの描画とタップ。Conduit LAAフォークの署名・7日失効の運用実績。pluginのloaded_versionとrestart_needed（文書は0.66.1、実体0.69.1）。Kanbanの上流バックエンドがこのMacで稼働しているか。StudioのMCPがどちらのbuildを指すか。iPhone側Brain同期クライアントとObsidianのfile recovery。Drive Range再生・Photos Pickerの認可。MacのCPU・メモリ収集経路（存在しない可能性が高い）。Paseo移行ゲートの実測記録（16・17・18）。

## 12. 後続タスクへの影響

- 02（Bridge契約）：認可の材料はTailscale Serve 8443/8444の実体、relay `push.milim.dev`、`conduit-push.json`のgateway_id。pluginの版差（0.69.1 vs 0.116.0）を前提に、Bridgeはplugin APIの現行版へ依存させない。
- 04（実機基準）：まず開発者ディレクトリの切替が必要。署名branchにcommitが無いため、TestFlight側の成果物は未提供。
- 05・09・19（Usage・Mac）：3系統のどれを正本にするかを先に決める。アプリは既にdashboard analyticsを読むため、Usageタブはその再利用が最短。CPU・メモリは新規収集が要る。DeepSeek 401は「欠測」表示の実例になる。
- 03・07・11・12（デザイン・実機）：Studioの二重稼働を解消しないとLab候補の版が混ざる。ウィジェットはExtension追加とApp Group（`group.com.milim.relay.launcher`）の再取得が要る。
- 13–18（Session・Paseo）：`laa-personal-agent` の create/status/wait/send/reply/stop とrequestId契約をそのままアダプター化できる。Local Live・GPT-Live・CallKitの3経路を混同しない。
- 20–22（タスク移行）：KanbanはLAAで未使用のため、移行対象はLinearのまま。Kanban書込（21）は上流バックエンドの稼働確認が前提。
- 24–27（Brain）：writerが3系統ある現状を前提に、CASだけで安全と主張しない。iPhone側writerの実体確認が先。
- 28–31（Drive・写真・保管・画面配信）：既存の認可・保存先の実測が未了。30のsnapshotは、稼働中SQLiteをDrive同期しない原則を維持。


## 13. 操作性能の計測（BUS-392、2026-11-11）

Release・専用「LAA 16 Pro Max」で5回ずつ採り、中央値と全サンプルを保存する。
再計測はrepoルートの絶対パスを指定して次の1コマンド。実Bridgeは読取専用の一時端末をペアリングし、終了時にその端末だけ失効、ペーストボードを空にしてシミュレーターを停止する。既存端末やTestFlightは変更しない。

```sh
python3 /absolute/path/to/repo/scripts/laa/perf/run.py --output /absolute/local/work/perf-after
```

同じ外部ビルド領域を使う場合は `--build-root /absolute/build/run`。再ビルド不要の同じ成果物の計測には `--skip-build`。共有ビルド枠を必ず使い、Releaseのテスト用importには `ENABLE_TESTABILITY=YES` を指定する。UIの経過時間にはXCTestの操作・待機コストが含まれ、フレーム時間ではない。各タブは選択/マウント、一覧の詳細は本文readyを別指標にする。端末再起動・アプリ再インストールを伴うOSキャッシュ消去はせず、ここでのcoldはプロセス終了後の再起動。

出力は `build.log`、`test.log`、`results.xcresult`、`summary.json`。取得不能・権限外の項目は `unavailable` とし、0msや成功に換算しない。初回/空キャッシュと保存済みの状態、OS・Revision・Release最適化、試行数を照合して比較する。長い会話は合成120メッセージのキャッシュ読込みも5回測る。実会話の送信→表示は未承認の送信を行わず未計測とする。

サーバー側の読取専用計測（URL/応答本文は出力しない）:

```sh
python3 /absolute/path/to/repo/scripts/laa/perf/probe.py --endpoint dashboard=http://127.0.0.1:9119/api/status --endpoint proxy=https://YOUR_PROXY/api/status --output /absolute/local/work/network.json
```

CPU・Hangs・SwiftUI・signpostはUI試験中に `profile.py --output /absolute/local/work/navigation.trace`（既定30秒、最大60秒）。`EmployeeConversationOpen` がタップ後の接続待ち全体、`EmployeeCachedTranscript` が保存済み会話の読込み/行生成。trace/xcresultには画面の私的な内容が入り得るためrepoへ置かず、必要な数値を抽出後に削除する。

### 前後の実測

親の02:32指示で変更前の再ビルドを省略。既存実機証拠は `shots/device-before/`、TestFlight 2611092249。02:16の社員チャットは40秒超「開いています」のまま、同時刻9119 statusは8秒超（親による実測、5回の中央値ではない）。修正後の表は検証後に追記する。02:34前後の9119/8444再読込・合成11試験の切断/5xxはサービス側イベントとして分け、アプリの回帰に数えない。

### 遅延原因と候補10件

| 順位 | 場所 | 原因・根拠 | 対処/見込み効果 | 所有 |
|---|---|---|---|---|
| 1 | AppState+WidgetLaunch / employeeChat | profile接続・catalog完了まで保存済み本文を出さない。実機40秒超 | 別読込モデルで即表示、8秒期限。表示接続はCHATへ | PERF+CHAT |
| 2 | OfflineChatCache | 同期Data読込・JSON decode・表示行生成が接続状態に従属 | 専用の読取インスタンスをdetached taskへ。メインのI/O待ちを除く | PERF |
| 3 | LAAWorkSessionCache.save | 同一poll応答でも全draft storeを同期JSON保存 | sorted encodingで同一内容は保存しない。周期I/Oと通知を除く | PERF |
| 4 | StaffMascotTurner.drag | 初回HEICコンテナとフレーム数をmainで読む | decoder queueへ移す。最初の指追従のI/Oを除く | PERF |
| 5 | StaffAvatarView.still/assets | body評価で画像file読込と4種fileExists | async縮小decode＋上限付き画像cache。静的確認、効果未実測 | CHAT |
| 6 | LAAWorkSessionDetail.refreshSnapshot | 同一session/historyでも代入し、全rows再評価 | 変更時だけ代入。静的確認、効果未実測 | WORK |
| 7 | LAAWorkSessionDetailのrows加工 | filter・speaker計算・enumerated配列をbody更新ごとに再生成 | messages変化時の派生値へ。静的確認、長文のO(n)を減らす | WORK |
| 8 | LAAAppShellのAppState監視 | 多数のpublished値を持つ親をタブの外枠が購読 | 子へ狭い値を渡し非表示タブのbody数を測る。候補、未実測 | SYS |
| 9 | 9119 status._bounded_health_probe | future.result(timeout=1)後もExecutorのwith終了が未完了workerを待つ | 絶対期限を持つ共有pool/probeへ。02:16との因果は未確定 | ①B |
| 10 | 9119 get_status | topology/cache lock・DB・health等のthreadpool待ちを直列合算 | 各phaseの待ち/実行を別計測し期限内の旧値を返す。候補 | ①B |
