# LAAアプリ：引継ぎ

最初に読む入口。社長の呼び名は「AIアプリ」「LAAアプリ」。ここには現行の進め方と状態だけを置き、経緯はgit logとLinearに任せる。古くなった記述は書き足さずに置き換える。

最終更新: 2026-11-06（全社員を360度回せるようにした）

## 位置づけ

- LAAアプリ（LaaFloralia/hermes-conduit のmaster。Conduitのフォーク）は社長の主窓口。裏側はMac miniのHermes（会話・通話・通知）とLAA Bridge（`bridge/`。仕事・Brain・素材・Usage）。
- Paseo・Obsidian（Brainの表示）・Google Drive・Linear・Grok Botの操作を、道具ごとの [ROADMAP](ROADMAP.md) の移行ゲートに従ってLAAへ集約する。Paseoは実行エンジンとして継続し、画面はLAA独自のSwiftUIと既存Bridge契約へ寄せる（2026-11-03 社長判断）。実行基盤の完全自作・Paseo daemonの撤去は現在の完了条件から外す。Apache-2.0のPaseoはフォーク可能だが、既存patch・pluginを優先し、それで足りない具体的な変更が出た時にフォークを判断する。実行・履歴・承認・親子管理・復旧のLAAからの操作確認は引き続き必要。
- iPhone版（社長の端末はiPhone 16 Pro Max）とMac版（MacBook・Mac mini。Mac Catalyst、Developer ID署名・公証のDMG）を同じmasterから作る。資料作成はLAAアプリから依頼し、実行はLAA Studio（Mac専用の別アプリ）が担う。

## 始め方

1. `/Users/laa/AGENTS.md`、`/Users/laa/dev/PROJECT-RULES.md`、このrepoの [PROJECT-RULES](../../PROJECT-RULES.md) を読む。
2. Linearのプロジェクト「LAAアプリ」で、未完了の指摘と判断待ちを見る。
3. 計画と各タスクの受入条件は [ROADMAP](ROADMAP.md)、画面の仕様は [DESIGN](DESIGN.md)、Bridgeの契約は [BRIDGE](BRIDGE.md) と `bridge/README.md` を読む。

## 体制

モデル・推論・分担の正本はHQ `guide/models.md`。このrepoでの配置だけを置く。

| 役 | モデル・経路 | 担当 |
|---|---|---|
| 親 | 社長が選んだモデル（その時点の指定を維持する） | 担当端末の指摘の登録、分担、統合、検証、署名・配信（秘密を扱うため各担当の親だけ） |
| 実装・試験・調査 | 公式DSHのDeepSeek V4.1 Flash（High／Max） | 担当ごとに `git worktree` を分け、アプリ・Bridge・スクリプトの実装から単体・UI試験、CLI検証まで持つ。シミュレーターを使う作業も含む |
| デザイン | design-worker（Opus High） | 外観・Studioの視覚案 |

通常の分担は公式DSHのDeepSeekを第一候補にする（2026-11-02 社長指示）。社長が指定したモデル・提供元・推論は変えない。Terraは単純で結果を直接照合できる代替だけに使う。Claudeのサブエージェントはdesign-workerだけ。独立レビューは原則行わない（2026-11-02 社長指示）。記録の上書き・削除、認証・秘密、お金に関わる部分だけ、親が必要と判断した時に親・実装者と別系統で行う。

現在の担当（2026-11-03 社長訂正）: Astraの引継ぎセッションはiPhoneの指摘修正とTestFlight配信を最優先にする。MacBook・PC版のLAAは別セッションのOpusが担当し、Macの操作・導入確認をiPhone配信の待ち条件にしない。共有コードとxcodebuild枠だけを両親で調整する。

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
- Mac版の署名と公証は親だけが `scripts/laa/mac-release.sh` で行う。Developer ID証明書（G2、期限2027-11-30）は1PasswordのAgents「LAA Developer ID Application」、テンプレートは `~/.config/laa/mac-release.env.tpl`。できたら親が `/Applications` へ入れて起動を確かめ、Mac miniのDockへ追加する（重複させず、既存の項目は動かさない）。更新時は通常終了後のプロセス消滅を待ってから入れ替える。画面の再取得はアプリを起動することがあるため、終了の判定には使わない。
- Bridgeは `/Users/laa/dev/hermes-conduit/bridge` から直接動く。`bridge/` を変えた候補をmasterへ入れたら、親が `launchctl kickstart -k gui/$(id -u)/com.laa.bridge` で再起動し、`/v1/health` の起動時間で反映を確かめる。
- TestFlightは親だけが出す: `cd /Users/laa/dev/hermes-conduit && /Users/laa/.config/laa/op-run-batch.sh /Users/laa/.config/laa/asc.env.tpl scripts/laa/testflight.sh`。配信済みの最新は **2611060152**（コードのmaster `3590f6ee`、2026-11-06にアップロード、`VALID`・`IN_BETA_TESTING`・LAA Internalを確認）。その前は **2611052350**（master `83e24164`）、**2611051644**（master `a252ae24`）、**2611051513**（master `f450d90c`）、**2611051323**（master `12287615`）、**2611031110**（master `740f7014`、2026-11-03 20:29 JSTにアップロード、`VALID`・`IN_BETA_TESTING`・`LAA Internal` を確認。ウィジェットのproviderフィルタにnanoGPTを追加し、GPT API・Claude APIの行を残高から今月の使用額へ変え、画面の残高「未取得」行を請求ページの注記に置き換えた）。**2611031024**（master `5b29f95b`）は画面だけnanoGPTが出てウィジェットに出なかった。**2611030952**（master `0a42f336`）は画面側の固定リストにnanoGPTが無く表示されなかった。前の **2611030910**（master `4c4c34ba`）と **2611030011**（master `d787a4ba`）はそのまま残る。署名用秘密はxcodebuildへ引き継がず、終了時にDerivedDataと一時署名ファイルを清掃する。

## 現在の状態（2026-11-06）

- iPhone指摘修正をコードmaster `3590f6ee`へ統合し、Bridgeを再起動してhealthを確認した。Chat遷移・引用・一覧の負荷、定期実行の取得状態、DocのMarkdown編集、Work詳細の題名・画像・設定表示・末尾表示、社員ウィジェットを修正。Bridge **625/625**、LAA統合 **365/365**、既定schemeのunit **1685/1685**・UI再試験 **8/8**、personal Releaseが成功。既定schemeの初回UIはランナー起動待ちで中断したため再試験した。保存ログは `work/laa-app-fixes-20261106/`。実機の日本語入力・ウィジェット・Chatの体感速度と、修正後の定期通知到達は未確認（BUS-357、363〜371）。COS・CTOは配送待ちを30分に延長したが、過去の配送未達4件は再送していない。11/6のメール確認1件は3回失敗しproviderの詳細理由は未確定。次のCOS・CTO定期実行は11/7 03:00。

- 社員の見た目を独自の9体のマスコットへ替えた。Cielは青い白鳥、Argusは孔雀。全員、通話と社員の詳細で指で360度回せる（`Conduit/LAA/Staff/StaffMascotView.swift`。Klingの周回動画から作った60コマで、3Dモデルではない）。チャット上部は54ptで名前のガラスの外へ出し、通話の円と外周リングは外した。処理中の行や一覧もHermesの画像ではなく同梱のマスコットを使う（`profileAvatarURL`）。制作手順は `docs/laa/DESIGN.md`、素材は `docs/laa/assets/staff/README.md`。実機の回り心地は社長の確認待ち。
- Workの詳細は見出しを名前だけのLiquid Glassにし、中断を `ぁあ` の左へ移した。LAAアプリ発の本人の会話は `plainPrompt` で入力文だけを届け、一覧の名前はPaseoがワークスペースへ付けた題名へ追従する（本人の命名は保持）。AI UsageはGPT API・Claude APIを使用額ではなく残量で表示する。各社は残高APIを公開していないため、値はHQ `catalog.verifiedMoney` の請求画面確認値で、確認日時を出す（自動更新なし。請求画面を確認したら台帳を更新する）。見出しの `Weekly` を外し、単独枠はカード内の枠名も出さず、複数枠は `週間` と表示する。表示順はVeniceを最後へ移した。
- Workのアーカイブは親子ごとPaseoへ反映する（master `12287615`）。実行中・判断待ちを含む親子は `session_running` で拒否する（Paseoのアーカイブは実行中のターンを中断し、ラベル付きの子も閉じるため）。空になったワークスペースもPaseoでアーカイブするが、worktreeは実ファイルを消すので対象外。戻すは選んだ行だけで、子はアーカイブに残す。LAAだけでアーカイブされていた14件と空のワークスペース2件は、Paseo実機へ反映済み（戻す→再アーカイブの往復も確認）。プロジェクトのアーカイブはBridge内だけで、属するセッションは変えない。子エージェントは親の下に畳み、隠れた判断待ちは親へ出す。Bridge 613/613、LAA単体・UI 31/31＋追加UI 2/2、スモーク695/695（masterも同数成功）、personal Release成功。実機とMac版への配信は未了。

- Workの一覧で行を左へスワイプすると詳細も開いていた（BUS-358）を直した（master `4c4c34ba`）。行のタップをスワイプ行のジェスチャーへ移し、ドラッグを優先、部分スワイプはピン、通常のタップは詳細、縦スクロールは一覧、を維持する。VoiceOverは1行をボタンとして読み、ピン・アーカイブをアクションに持つ。シミュレーター（LAA 16 Pro Max・iOS 27.0）で `LAAPaseoUITests` 7件と `LAAShellNavigationUITests` 4件が成功。既定スキームのsmokeはmasterと候補が同じ5件（`ConnectionSetupUITests`）だけ失敗し、unit **687/687**、personal iOS Releaseも成功した。詳細から戻った後の下部タブ欠落（BUS-360）はシミュレーターでは再現せず、詳細の戻る・左端スワイプの戻る・スクロール後の戻るの3経路でタブが戻ることを確認した。左スワイプで詳細が開く経路自体を消した。配信後の実機受入は社長が行う（エージェント側の実機確認は行わない）。
- 11/3の候補をmaster `d787a4ba`へ統合した。通知の会話名・本文、人物別未読件数、担当者別の定期実行と次回時刻、Work内のAI Usage、ピン留め上段・左スワイプ、Paseoの固定との同期、Brain索引、Date弱リンクの修正を含む。Bridge **556/556**、LAA単体 **180/180**、personal iOS Release、配信アーカイブの本体・拡張・Watch **6本のDate検査**が成功。master比較スモークは2437件中2432件成功、既知5件から新規失敗なし。FEATURE_MAPは106節/1673パス。UI初回93件は66成功・5失敗・22除外、失敗5件の再試験で3件成功。Shellは画面外ボタンのタップで2回失敗し、効果のなかった471f0d5cは未統合。見えているWork項目を順に選ぶ試験へ置き換え、該当1件が成功（build/test exit 0、xcresult 1成功・0失敗・0除外）。アプリ本体の変更はない。日誌はシート表示後の入力フォーカス失敗で実機確認を残す。高負荷の影響が有力だが合格扱いにはしない。
- Workのタスクは Linear の一覧・本人受信箱・作成/変更・コメント・添付・アーカイブ復元を実装済み。Bridgeへ既存のLinear helperと期待する本人viewer IDを設定し、本番設定から本人受信箱を読めることを確認した。Mac版から既存課題BUS-322の本文を保存し、Linear側の更新を読戻した。iPhoneの操作・通知配送は別の受入確認とする。
- Driveは Studio タブの「Drive」から既存の Assets 画面（Drive/Studio切替）へ入る。5タブは変えていない。設定は全タブで右上の同じ位置（作成系は左上）。
- Mac版 **2611030214**（master e45b71d0。Mac向けのサイドバー・一覧・詳細の全面刷新に、サインイン後のページ残り修正を加えた版）はApple Silicon／Intel両対応で、アプリとDMGのDeveloper ID署名・公証・staple・Gatekeeperと、Foundationの `Date <=`/`>=` 弱リンクが0件であること（`scripts/laa/check-weak-date-ops.sh`。`mac-release.sh`・`testflight.sh` が書出し前に自動実行）を確認した。Macでは、サインインのページが分割表示の詳細列に積まれ、接続後も会話一覧の上に残っていた（戻るで消える）。`LoginFlowModel` が接続前にこのページを閉じる（Mac Catalystのみ）。macdev版で実際にサインインし、ページが残らないことを確認した（macdev版の認証情報は、保存の成否も残存も未確認）。Mac miniの `/Applications/LAA.app` を2611030214へ入れ替え、既存接続の保持・Dock登録・Spotlight索引を確認した（Spotlight画面での検索は未確認）。DMGは本体チェックアウトの `build/laa/mac/2611030214/`。MacBookも2611030214へ更新済み（旧版はMacBookの `~/laa-backup-20261103/` にzip）。Mac miniの `https://mac-mini.tailc9b8e7.ts.net:8444` へのサインインを保ち、RPC応答・Dock登録を確認した。MacBookの操作は、1Password Agentsの「MacBook」で画面共有とSSH（パスワード認証、SSH_ASKPASSで実行時に渡す）を使う。社長の使用中は画面に触らない（BUS-322）。登録済み端末を作り直さない。
- AI Usageは収集元の応答が30秒を超えることがあるため、表示サービスの取得待機を65秒へ調整した（devのusage-meters、関連45試験成功）。社長の承認後に表示サービスだけ再起動し、04:08 JSTに8提供元の新しいfeedとMac版の利用枠・API月次値・取得時刻を確認。指標ごとの取得不能は数値を出さない。
- Bridgeの遅い読み取り（routines/Studio/usage）は前回成功値と `fetchedAt` を返し、期限切れはアプリが「最新ではない可能性」を表示する。Googleのカレンダー通知は初回有効化時刻を台帳に残し、有効化前の過去分をまとめて送らない（以後の失敗・再起動の追送と重複抑止は維持）。
- 本番BridgeとLAA通知リレーは、社長の対象別承認に従って2026-11-03 09:11 JSTに各1回再起動し、新PIDとhealthを確認した。既存の本人端末の `brain:owner`・`calendar:write`・`media:write` とGoogle通知の初回時刻を保持。既存notifierの自己宛て受入通知は配送成功を返したが、iPhoneの表示・タップ先は未確認。再起動は追加承認なしに繰り返さない。
- iPhoneは05:41 JSTにTestFlightでLAA **2611021926**・音声 **2026110301** が「開く」表示で、更新済みを確認した。LAAの5タブ、Todayの11/3「文化の日」、Driveの実動画一覧・サムネイル・再生の進行・10秒送り・PiP表示を実機確認。動画は初回の読み込みが長く、pause/play後に進行した。続きから再開・PiP復帰・AirPlay・音声は未確認（BUS-338）。Brain・HQのSyncTrain移行とiPhoneのObsidian削除はHQ台帳の別作業で確認済みのため、フォルダ選択や削除を重ねて行わない。Brainの編集・復元、Linearの実書込み・通知、PaseoのIME/音声、WidgetKit、通話と音楽の受入は未完了。旧アプリの削除やStudio Webの撤去を配信成功だけで進めない。 09:31には旧2611021926でCielとの2回目のチャット中に入力不能となり、process-exit watchdog（5秒）で終了した。終了時はSwiftUIのレイアウト処理中だが、最初の入力停止原因は未確定（BUS-359）。Chat/Composerの該当実装は最新版と共通のため、配信だけで修正済みとは扱わない。社長が別タスクでiPhoneを使用中のため、実機操作は中断してコード調査を進める。

## 判断待ちと未解決（Linear「LAAアプリ」）

現在の作業・本人判断はLinear「LAAアプリ」を正本とする。接続（BUS-318・342）、BrainのSyncTrain受入（BUS-321）、Mac版（BUS-322）、通話（BUS-317・319）、CI（BUS-323）と各画面の課題を参照し、ここへ課題状態を複製しない。Xcodeの配信拒否（BUS-320）は解決済み。GitHubはフォークのActions利用規模を理由に停止中で、再有効化の判断までは上のローカル代替ゲートを使う。

## 環境の注意

- `xcode-select` はCommandLineToolsを指している。xcrun・simctl・xcodebuildには `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` を付ける。
- Claude Codeのサンドボックス内ではsimctlが止まる。サンドボックスの外で実行する。
- App Storeの自動更新でXcodeが変わることがある。27.2では `xcodebuild -runFirstLaunch`（`laa-admin` 経由）とMetal Toolchainの追加が必要だった。
- push relay（launchd `com.laa.conduit-relay-laa`）は本体チェックアウトの `scripts/laa/relay-run.sh` から動く。worktreeから入れない。
- Bridgeの `brain:write`（既存ノートの上書き）は無効を維持する。iPhoneのSyncTrainとLAAは「このiPhone内/LAA」のBrain・HQへ結び付け済み（HQ台帳96101d7）。オフライン編集・移動・.trash・競合検出・保存履歴はこの端末内の経路で、Bridgeの上書きとは区別する。[BRAIN-WRITE §10](BRAIN-WRITE.md#10-iphoneローカルのノート管理と下書き2026-11-02) を参照する。
- Mac CatalystのTextEditorでは、AXの値だけの書換えがSwiftUIの保存内容へ反映されなかった。通常入力の選択範囲を確認して保存し、Linearから本文を読戻す。送信成功だけで入力の一致を確定しない。
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
