# LAAアプリ：引継ぎ

最初に読む入口。社長の呼び名は「AIアプリ」「LAAアプリ」。ここには現行の進め方と状態だけを置き、経緯はgit logとLinearに任せる。古くなった記述は書き足さずに置き換える。

最終更新: 2026-10-31（アプリのコードはmaster `21cec9ed` 時点。以降の更新は文書だけ）

## 位置づけ

- LAAアプリ（LaaFloralia/hermes-conduit のmaster。Conduitのフォーク）は社長の主窓口。裏側はMac miniのHermes（会話・通話・通知）とLAA Bridge（`bridge/`。仕事・Brain・素材・Usage）。
- Paseo・Obsidian（Brainの表示）・Google Drive・Linear・Grok Botの操作を、順にこのアプリへ集約する。置き換えは道具ごとに [ROADMAP](ROADMAP.md) の移行ゲートを満たしてから行い、満たすまで旧い道具を残す。
- iPhone版（社長の端末はiPhone 16 Pro Max）とMac版（MacBook・Mac mini。Mac Catalyst、Developer ID署名・公証のDMG）を同じmasterから作る。資料作成はLAAアプリから依頼し、実行はLAA Studio（Mac専用の別アプリ）が担う。

## 始め方

1. `/Users/laa/AGENTS.md`、`/Users/laa/dev/PROJECT-RULES.md`、このrepoの [PROJECT-RULES](../../PROJECT-RULES.md) を読む。
2. Linearのプロジェクト「LAAアプリ」で、未完了の指摘と判断待ちを見る。
3. 計画と各タスクの受入条件は [ROADMAP](ROADMAP.md)、画面の仕様は [DESIGN](DESIGN.md)、Bridgeの契約は [BRIDGE](BRIDGE.md) と `bridge/README.md` を読む。

## 体制

| 役 | モデル・経路 | 担当 |
|---|---|---|
| 親 | 社長が選んだモデル（現在 Opus 5.5） | 指摘の登録、分担、統合、検証、TestFlight（秘密を扱うため親だけ） |
| iOS実装 | GPT-6.1 Terra max（Paseo codex） | アプリとBridgeの実装・試験 |
| 独立レビュー・その他 | DeepSeek V4.1 Flash max（Paseo dsh） | レビュー、調査、文書 |
| デザイン | design-worker | Studioでの視覚案（必要な時だけ） |

Claudeのサブエージェントは使わない（design-workerだけ例外）。起動例:

```sh
# iOS実装（専用worktree）
paseo run -d --provider codex --model gpt-6.1-terra --thinking max --mode full-access \
  --title "子｜LAAアプリ｜<作業>" --new-workspace worktree --worktree-mode branch-off \
  --new-branch laa/<作業> --base master "$(cat <指示ファイル>)"
# レビュー・調査
paseo run -d --provider dsh --model '["opencode-go","deepseek-v4.1-flash"]' --thinking max \
  --title "子｜LAAアプリ｜<作業>" "$(cat <指示ファイル>)"
```

起動後は `paseo inspect <id> --json` で実際のモデル・推論を照合する。待つ時は `scripts/laa/wait-agents.sh any|all <id>…` を使う。

## 指摘の回し方

1. 社長の指摘は1件1課題でLinear「LAAアプリ」に登録する。担当なし・Todo、題名に番号を付けず、画面（会話・仕事・Brain・素材・Usage・通話・ウィジェット・設定）が分かる短い文にする。指摘はエージェントが直す作業なので、共通指示の「社長の新規タスク」とは扱いを分ける。社長の判断や本人操作が要るものだけLAA担当にする。登録は接続済みのLinear MCP（`save_issue`、team `LAA`、project `LAAアプリ`）で行う。
2. 親は同じ画面の指摘を束ね、所有ファイルが重ならない単位でTerraへ並行に渡す。指示は下の「worker共通指示」に、課題ID・対象・所有ファイル・完了条件を足す。
3. 候補は1件ずつ下のゲートを通してmasterへ入れる。まとまったら親がTestFlightへ出し、社長が実機で確かめてから課題を閉じる。

## シミュレーターとMacの負荷

- シミュレーターは同時に1台だけ起動する。workerは起動前に親へ使用枠を求め、終わったら停止を報告する。親は `scripts/laa/sim-turn.sh <id> "<枠を渡す文>"` で空きを待ってから渡す。
- 検証用の端末は2台。`LAA 16 Pro Max`（iOS 27.0、`DFFD3966-F54E-4C7A-A161-59201C7EA105`、社長の端末と同じ画面）と `iPhone Duo`（iOS 27.1、`228F6BE7-98B2-4AF6-861F-F76BC8CA0DE7`）。作業用に端末を増やしたら、終了時に削除する。
- xcodebuildは同時3本・各 `-jobs 4` まで、空き容量は80 GiB以上を保つ。作業後はDerivedData・xcresult・一時端末を消す。

## マージとTestFlight

- GitHub CIはmasterへのpushで動いていない（BUS-323）。直るまでは次の代替ゲートを使う。
  1. 候補へ最新のorigin/masterを通常mergeしてpushする。
  2. `python3 scripts/plan-tests.py smoke --repo-root . --suite scripts/smoke-suite.json --changed-from <mergeしたmasterのSHA> --out <file>` で選ばれたunit・UIクラスを、既定のConduit scheme（`project.yml`。LAA版ではない）で流す。端末は言語と地域を英語（米国）に設定して読み戻したものを使う（`-AppleLanguages` だけでは効かなかった）。同じクラスをmasterでも流し、候補だけの失敗が0であること。
  3. `xcodegen generate --spec project-personal.yml` の後、`xcodebuild build -quiet -project Conduit.xcodeproj -scheme Conduit -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO` が成功すること。生成したprojectはcommitしない。
  4. masterをfast-forwardしてpushし、branchを消し、local/remoteのSHA一致を確かめる。
- 既知の基準（master `21cec9ed`）: `LAA 16 Pro Max` では既知の失敗なし。`iPhone Duo` では `ConnectionSetupUITests` 5件と `ProfilePickerUITests` 1件が既知の失敗。
- Mac版の署名と公証は親だけが行う。Developer ID証明書（G2、期限2027-11-30）は1PasswordのAgents「LAA Developer ID Application」、テンプレートは `~/.config/laa/mac-release.env.tpl`。
- TestFlightは親だけが出す: `cd /Users/laa/dev/hermes-conduit && /Users/laa/.config/laa/op-run-batch.sh /Users/laa/.config/laa/asc.env.tpl scripts/laa/testflight.sh`。配信済みはビルド6（2610300121、LAA Internal）。ビルド7はXcode 27.2（27B52）をApp Store Connectが拒否して止まっている（BUS-320）。

## 現在の状態（2026-10-31）

- 完了: ROADMAP 01–14・24・25・28、デザインv2、W3の仕上げ（プラグイン更新表示の撤去、社員呼出しボタンの表示条件）。
- 残り: 15–18 Paseo移行、19–22 Linear移行、23 PC幅プレビュー、26–27 Brain編集・ギャラリー（方式が判断待ち）、29 写真の取込、30 会話の保管、31 Mac画面の配信、32 実機での総合検証、33 Mac版（branch `laa/mac-catalyst` で実装中）、34 Studio依頼（アプリとBridgeは模擬のStudioで先に作り、LAA Studioのローカル受付APIができたら接続）。
- Driveの閲覧・再生は実装済み。認可がないため、Bridgeは `503 drive_not_configured` を返す（BUS-318）。
- 再生画面の再生ボタンとシークバーは素の部品のままで、デザインの手直しが要る。
- Bridgeで有効な端末は社長のiPhone 1台だけ。試験用の端末はすべて失効済み。

## 判断待ちと未解決（Linear「LAAアプリ」）

| 課題 | 内容 |
|---|---|
| BUS-318 | Google Driveの読取認可（GCPのOAuthクライアント作成と同意） |
| BUS-319 | HermesのChatGPT再ログイン（GPT-Liveの通話） |
| BUS-320 | TestFlight用のXcode（27.1を併設するか27.2正式版を待つか）と自動更新 |
| BUS-321 | Brainの既存ノートを編集する方式 |
| BUS-322 | Mac版をMacBook・Mac miniで使えるようにする（実装中。最後に社長がMacBookへ導入してペアリング） |
| BUS-317 | CallKit発信の実機確認（登録・署名・配信は済み） |
| BUS-323 | GitHub CIがmasterへのpushで動かない原因の調査（エージェントが進める。それまでは代替ゲート） |

## 環境の注意

- `xcode-select` はCommandLineToolsを指している。xcrun・simctl・xcodebuildには `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` を付ける。
- Claude Codeのサンドボックス内ではsimctlが止まる。サンドボックスの外で実行する。
- App Storeの自動更新でXcodeが変わることがある。27.2では `xcodebuild -runFirstLaunch`（`laa-admin` 経由）とMetal Toolchainの追加が必要だった。
- push relay（launchd `com.laa.conduit-relay-laa`）は本体チェックアウトの `scripts/laa/relay-run.sh` から動く。worktreeから入れない。
- Brainの既存ノートの上書きはv1では無効（[BRAIN-WRITE](BRAIN-WRITE.md)）。できるのは閲覧・検索・新規作成だけ。
- 秘密は親だけが1Password Agents経由で扱い、workerへ渡さない。workerにBrainを読ませない。
- Conduitプラグインの更新は、HQの定期処理（`hq/tools/CONDUIT-UPDATE.md`）が判断する。

## worker共通指示（各指示の先頭に貼る）

```text
plan_id=<受付時のD1計画ID>
Repo: LaaFloralia/hermes-conduit（master = LAA版）。最初に /Users/laa/AGENTS.md、/Users/laa/dev/PROJECT-RULES.md、repoの PROJECT-RULES.md と docs/laa/SESSION-HANDOFF.md を読んで従う。iOS作業は自分で行い、再委譲しない。
仕様: docs/laa/ROADMAP.md（担当タスクの行）、docs/laa/DESIGN.md（v2。Liquid Glass、ナビゲーションと操作ラベルはLAACopyの英語、本文は日本語可）、docs/laa/BRIDGE.md（§9「親の決定」を優先）、bridge/README.md、CONTRIBUTING.md（FEATURE_MAP）。
コード: LAA版だけを変える。Conduit/LAA/<担当領域>/ に置き、LAA_BUILD で囲む。色・余白・角丸・文字は LAATokens から取る。既存のBridgeクライアント、ペアリングとKeychain、エラー対応を再利用し、2つ目のクライアントを作らない。共有ファイル（タブ、project、Localizable）は登録に要る最小行だけ変える。サーバーにない機能は作らず、理由付きで無効表示にする。
ビルド: `xcodegen generate --spec project-laa.yml`。xcrun・xcodebuild・simctl には DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer を付ける。シミュレーター用はad-hoc署名（CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=）。SwiftPMがログインKeychainで止まる時は -packageAuthorizationProvider netrc と GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false を使う。Keychainのダイアログには答えず、回避もしない。
検証: 新しいロジックのunit test、主な流れのUI test（LAA 16 Pro Max）、新しい画面ごとに440×956のライト・ダークのsnapshot（PNGは指示されたフォルダへ）。必要な時は実Bridgeで確かめる（laa-bridge pair で試験端末を作り、終了時に失効させる）。通常・空・エラー・オフライン・未ペアリングを含める。docs/FEATURE_MAP.md を更新し、社長が実機で確かめる項目を挙げる。
シミュレーター: 起動前に親へ使用枠を求め、使い終えたらすぐ停止して報告する。
マージ: origin/masterから分岐する。親が順番を渡したら最新のorigin/masterを通常mergeし、SESSION-HANDOFFのゲートを通す。fast-forward後にbranchを消し、local/remoteのSHA一致を確かめる。
衛生: プロセス一覧は pgrep -x <name> か ps -o pid,ppid,comm だけ。Brainを読まない。laa-console integrity は走らせない。秘密を出力しない。自分のビルドキャッシュと一時端末は終了時に消す。親への返答は短い日本語で、結果・SHA・検証・実機確認項目・未解決点。
```
