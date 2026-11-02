# LAAアプリ：引継ぎ

最初に読む入口。社長の呼び名は「AIアプリ」「LAAアプリ」。ここには現行の進め方と状態だけを置き、経緯はgit logとLinearに任せる。古くなった記述は書き足さずに置き換える。

最終更新: 2026-11-03（統合1102のゲート。master `156c096d` と同一smokeクラスで比較し、UI試験は `LAA 16 Pro Max` で実施）

## 位置づけ

- LAAアプリ（LaaFloralia/hermes-conduit のmaster。Conduitのフォーク）は社長の主窓口。裏側はMac miniのHermes（会話・通話・通知）とLAA Bridge（`bridge/`。仕事・Brain・素材・Usage）。
- Paseo・Obsidian（Brainの表示）・Google Drive・Linear・Grok Botの操作を、順にこのアプリへ集約する。置き換えは道具ごとに [ROADMAP](ROADMAP.md) の移行ゲートを満たしてから行い、満たすまで旧い道具を残す。
- iPhone版（社長の端末はiPhone 16 Pro Max）とMac版（MacBook・Mac mini。Mac Catalyst、Developer ID署名・公証のDMG）を同じmasterから作る。資料作成はLAAアプリから依頼し、実行はLAA Studio（Mac専用の別アプリ）が担う。

## 始め方

1. `/Users/laa/AGENTS.md`、`/Users/laa/dev/PROJECT-RULES.md`、このrepoの [PROJECT-RULES](../../PROJECT-RULES.md) を読む。
2. Linearのプロジェクト「LAAアプリ」で、未完了の指摘と判断待ちを見る。
3. 計画と各タスクの受入条件は [ROADMAP](ROADMAP.md)、画面の仕様は [DESIGN](DESIGN.md)、Bridgeの契約は [BRIDGE](BRIDGE.md) と `bridge/README.md` を読む。

## 体制

モデル・推論・分担の正本はHQ `guide/models.md`。このrepoでの配置だけを置く。

| 役 | モデル・経路 | 担当 |
|---|---|---|
| 親 | 社長が選んだモデル（その時点の指定を維持する） | 指摘の登録、分担、統合、検証、TestFlightとMac版の署名・公証（秘密を扱うため親だけ） |
| 実装・試験・調査 | 公式DSHのDeepSeek V4.1 Flash（High／Max） | 担当ごとに `git worktree` を分け、アプリ・Bridge・スクリプトの実装から単体・UI試験、CLI検証まで持つ。シミュレーターを使う作業も含む |
| デザイン | design-worker（Opus High） | 外観・Studioの視覚案 |

通常の分担は公式DSHのDeepSeekを第一候補にする（2026-11-02 社長指示）。社長が指定したモデル・提供元・推論は変えない。Terraは単純で結果を直接照合できる代替だけに使う。Claudeのサブエージェントはdesign-workerだけ。独立レビューは原則行わない（2026-11-02 社長指示）。記録の上書き・削除、認証・秘密、お金に関わる部分だけ、親が必要と判断した時に親・実装者と別系統で行う。

担当は再委譲しない。起動はHQ `tools/PASEO-HERMES.md` の「サブエージェントの統一起動」に従い、親のIDを保ったまま同じワークスペースのサブエージェントへ置く。子専用ワークスペース・detach・画面に出ない独立CLI workerは使わない。作業ファイルだけを `git worktree add` で分ける。起動例:

```sh
# 担当は /Users/laa/work/<作業>-<日付> に branch laa/<作業> のworktreeを作る
paseo run --background --json --provider dsh --model '["opencode-go","deepseek-v4.1-flash"]' --thinking high \
  --title "子｜LAAアプリ｜<作業>" --cwd /Users/laa "$(cat <指示ファイル>)"
```

起動後は `paseo inspect <id> --json` で実際のモデル・推論・親IDを照合する。待つ時は `scripts/laa/wait-agents.sh any|all <id>…` を使う。

## 指摘の回し方

1. 社長の指摘は1件1課題でLinear「LAAアプリ」に登録する。担当なし・Todo、題名に番号を付けず、画面（会話・仕事・Brain・素材・Usage・通話・ウィジェット・設定）が分かる短い文にする。指摘はエージェントが直す作業なので、共通指示の「社長の新規タスク」とは扱いを分ける。社長の判断や本人操作が要るものだけLAA担当にする。登録は接続済みのLinear MCP（`save_issue`、team `LAA`、project `LAAアプリ`）で行う。
2. 親は同じ画面の指摘を束ね、所有ファイルが重ならない単位で担当へ並行に渡す。指示は下の「worker共通指示」に、課題ID・対象・所有ファイル・完了条件を足す。
3. 候補は1件ずつ下のゲートを通してmasterへ入れる。親は統合のたびにTestFlightへ出し（まとめて待たない。社長の指摘 2026-11-01）、社長が実機で確かめてから課題を閉じる。

## シミュレーターとMacの負荷

- このプロジェクトの端末は同時に1台だけ起動する。他の作業（音声入力など）の端末には触れない。workerは起動前に親へ使用枠を求め、終わったら停止を報告する。親は `scripts/laa/sim-turn.sh <id> "<枠を渡す文>"` で端末の停止を待ってから渡す。
- 検証用の端末は `LAA 16 Pro Max`（iOS 27.0、`DFFD3966-F54E-4C7A-A161-59201C7EA105`、社長の端末と同じ画面）の1台だけ（iPhone Duoは社長の指示で使わない）。作業用に端末を増やしたら、終了時に削除する。
- xcodebuildは共有の `build-slot.sh` 経由で同時1本・`-jobs 4`（2026-11-02、Mac miniのメモリ24GBを共有しているため max=1）。容量では試験を止めない（社長、2026-11-01）。空きが80 GiBを切ったら、試験を続けたまま親が不要物の削除・Driveへの退避を並行して進める。30 GiBを切った時だけ新しいビルドを始めずに親へ知らせる。作業後はDerivedData・xcresult・一時端末を消し、80 GiB以上へ戻す。親はゲートが終わるたびに `LAA 16 Pro Max` を `simctl erase` で初期化し、起動して `defaults write -g AppleLanguages -array en-US` と `AppleLocale en_US` を書いて読み戻してから停止する（試験のたびに端末のデータが増え、2時間で約2 GB増えた）。

## マージとTestFlight

- GitHub CIはmasterへのpushで動いていない（BUS-323）。直るまでは次の代替ゲートを使う。
  1. 候補へ最新のorigin/masterを通常mergeしてpushする。
  2. `python3 scripts/plan-tests.py smoke --repo-root . --suite scripts/smoke-suite.json --changed-from <mergeしたmasterのSHA> --out <file>` で選ばれたunit・UIクラスを、既定のConduit scheme（`project.yml`。LAA版ではない）で流す。端末は言語と地域を英語（米国）に設定して読み戻したものを使う（`-AppleLanguages` だけでは効かなかった）。同じクラスをmasterでも流し、候補だけの失敗が0であること。
  3. `xcodegen generate --spec project-personal.yml` の後、`xcodebuild build -quiet -project Conduit.xcodeproj -scheme Conduit -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO` が成功すること。生成したprojectはcommitしない。
  4. masterをfast-forwardしてpushし、branchを消し、local/remoteのSHA一致を確かめる。
- 既知の失敗: `LAA 16 Pro Max`（英語（米国））の `ConnectionSetupUITests` 5件。master `156c096d` と候補の同一smokeで両方同じ5件だけが失敗し、`ProfilePickerUITests` は候補・masterとも3件成功（統合1102で確認）。
- Mac版の署名と公証は親だけが行う。Developer ID証明書（G2、期限2027-11-30）は1PasswordのAgents「LAA Developer ID Application」、テンプレートは `~/.config/laa/mac-release.env.tpl`。できたら親が `/Applications` へ入れて起動を確かめ、Mac miniのDockへ追加する（重複させず、既存の項目は動かさない）。
- Bridgeは `/Users/laa/dev/hermes-conduit/bridge` から直接動く。`bridge/` を変えた候補をmasterへ入れたら、親が `launchctl kickstart -k gui/$(id -u)/com.laa.bridge` で再起動し、`/v1/health` の起動時間で反映を確かめる。
- TestFlightは親だけが出す: `cd /Users/laa/dev/hermes-conduit && /Users/laa/.config/laa/op-run-batch.sh /Users/laa/.config/laa/asc.env.tpl scripts/laa/testflight.sh`。配信済みは 2611020818（2026-11-02、master 628b4c93、統合1102b：Liquid Glassの全体調整と横長ウィジェットの簡素化、Workのタスク（チェックボックス廃止・確認付き削除＝Linearアーカイブ・戻す）、スキルの分類と日本語説明・詳細、定期実行のtriggerKind表示、LAA Internal）。終わったら `build/laa/DerivedData` を消す。

## 現在の状態（2026-11-03）

- 統合1102で Google（Drive/Calendar）・Brain・Paseo・Linear・fixes・bridge-speed を master へ統合した（`laa/integrate-1102`）。Bridgeは全521試験、翻訳6546箇所、FEATURE_MAP 104節/1616パスが通る。
- Workのタスクは Linear の一覧・受信箱・作成/変更・コメント・添付・アーカイブ復元までをアプリで行える。受信箱の既読は端末側で保持する。
- Driveは Studio タブの「Drive」から既存の Assets 画面（Drive/Studio切替）へ入る。5タブは変えていない。設定は全タブで右上の同じ位置（作成系は左上）。
- Bridgeの遅い読み取り（routines/Studio/usage）は前回成功値と `fetchedAt` を返し、期限切れはアプリが「最新ではない可能性」を表示する。Googleのカレンダー通知は初回有効化時刻を台帳に残し、有効化前の過去分をまとめて送らない（以後の失敗・再起動の追送と重複抑止は維持）。
- 残り: 15–18 Paseo移行、19–22 Linear移行、23 PC幅プレビュー、26–27 Brain編集・ギャラリー（方式が判断待ち）、29 写真の取込、30 会話の保管、31 Mac画面の配信、32 実機での総合検証、33 Mac版（`laa/mac-catalyst` 系で進行）、34 Studio依頼の仕上げ。
- 実機確認は未了（TestFlight後）。Drive/Calendarの実データ、Linearの実書き込み、Paseoの通知・IME/音声、WidgetKitの表示は親と社長が実機で確かめる。

## 判断待ちと未解決（Linear「LAAアプリ」）

| 課題 | 内容 |
|---|---|
| BUS-318 | 旧OAuth案は取り下げ。Google DriveマウントのmacOS権限を親が判断し、課題状態を更新 |
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
- StudioのUI試験（`LAAStudioUITests`）は `scripts/laa/studio-ui-fixture.mjs`（api 19582／control 19583）を先に起動し、アプリへ `LAA_BRIDGE_DEFAULT_ADDRESS=http://127.0.0.1:19582` を渡す（DEBUGのみ有効。simulatorのhttpは127.0.0.1だけ許可）。
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
