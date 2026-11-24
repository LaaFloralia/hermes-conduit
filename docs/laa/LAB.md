# LAB（検証基盤）

Hortensia（LAAアプリ）を、本番の判断ボード・Session・通知へ触れずにシミュレーターとMacの実窓で検証する仕組み。試験は隔離レーンで動かし、合否は試験ID単位の台帳で判定し、画面と性能は1コマンドで採る。規則の要点は `PROJECT-RULES.md`、統合前の手順は `docs/laa/SESSION-HANDOFF.md`。

| したいこと | 節 | 入口 |
| --- | --- | --- |
| 試験を本番から切り離して動かす | Lane・Adapters・Fail-closed handshake | `scripts/laa/lab/lane.mjs`、`lane-negative.mjs` |
| 統合してよいか判定する | Suites・Ratchet | `scripts/laa/lab/suite.py` |
| 全画面を見比べる | Capture | `scripts/laa/lab/capture.py` |
| iPhoneとWatchの組で確かめる | Watch | `scripts/laa/lab/watch.py` |
| 速さの退行を見つける | Performance | `scripts/laa/lab/perf.py` |
| ほかのアプリへ同じ型を入れる | 他アプリへの展開 | この文書 |

実機でしか分からないこと（APNsの実配信、端末間の通知ミラーリング、音声経路、触覚、実描画のhitch）はこの基盤の対象外で、各節の末尾に書いてある。

## Lane

統合試験は `python3 scripts/laa/lab/suite.py run integration --out <結果フォルダ>`。Work・Paseo・Studio・習慣・Usage・iPhone Useのfixtureと実Bridgeをランナーが同じレーンで起動し、UIバッチ後に停止・削除する。個別起動・ポート指定・1Passwordは不要。ビルドと実行は共有スロットを使い、終了時にシミュレーターを停止する。結果は `.xcresult` から `results.json` に採取される。レーンは `--out` の下に作るため、Unixソケットの上限に収まる短い絶対パスを使う。

レーン単体の検証には `scripts/laa/lab/lane.mjs` で実Bridgeを立てる。本番のBridge・Work・Hermesに接続せず、アプリはDebugビルドを使う。Node 20.11+、追加パッケージ不要。

```sh
lane=$(node scripts/laa/lab/lane.mjs up)       # --json: port/pid/rootのみ。--fixture work 等も指定可
trap 'node scripts/laa/lab/lane.mjs down "$lane"' EXIT
# envの出力には使い捨て端末トークンが入る。端末表示・ログ・set -xは禁止。
eval "$(node scripts/laa/lab/lane.mjs env "$lane")"
node scripts/laa/lab/lane.mjs status "$lane"
```

`up` は所有者限定の `mkdtemp`（親は `LAA_LANE_PARENT` で指定可能）に `home/`、`tmp/`、`state/`、`brain/`、`logs/`、`sink/`、`lane.json`（0600）を作る。全HTTP待受は別々に `127.0.0.1:0` へbind。Workとプロセス管理はレーン専用Unixソケット。`down` は専用管理ソケットで子の終了を待ってからルートを削除する。保存するログは先にレーン外の検証用フォルダへコピーする。保存されたPIDだけを根拠にしたkillは行わない。異常終了で管理ソケットが応答しない場合は削除せず、対象を照合してから後始末する。

統合ランナーは `TEST_RUNNER_` 付きでレーンIDとURLだけを渡し、UIテストの `launchInLab()` がアプリへ転送する。使うfixtureのURLは `LAA_BRIDGE_DEFAULT_ADDRESS` に指定し、通常のペアリング画面から登録する。実Bridgeが既定。control側も同じレーンヘッダーを照合し、固定ポートに+1せず `LAA_LANE_FIXTURE_*_CONTROL` を読む。CLIで実Bridgeに接続する場合は `lane.mjs env` の使い捨て端末資格情報を使えるが、統合ランナーはトークンをUIへ渡さない。

Work/Shellの実接続試験は本番用のopt-inを使わず、レーン内で一回限りのコードを発行して実Bridgeにペアリングする。Work制御fixtureだけにセットアップ専用の資格情報を渡し、Projectを用意する。Echoセッションの作成・送信はアプリから行う。失効試験はそのテストが登録した端末だけを対象にする。

インストール済みのWorkエンジンが `LAA_WORK_SOCKET`・`LAA_WORK_STATE`・`LAA_WORK_CONFIG` と `LAA_WORK_CATALOG` の `module:` providerを持つため、フェイクdaemonは不要。`up` は実行に必要な `engine/` と `client/` のコードだけをレーンにコピーし、既存ユーザー設定・端末情報・認証はコピーしない。レーンのモデルは外部I/Oゼロの `lab-echo` 一つ。productionの複合ルーター・Paseo・委譲CLIを経由せずUnixソケットへ直結する。ジョブなし、定期処理なし、Work側のBridge署名鍵取得なし（`bridgeUrl: null`）。このためオーナー署名の受渡し自体は別の単体試験で扱う。

## Adapters

`lane-isolation.test.mjs` は起動時のパス・外部設定拒否と、起動後の下記のHTTP拒否を実Bridgeで確認する。レーンで使わない業務は本番用コンストラクタも起動しない。`lane-smoke.mjs` は二つの実BridgeとWork、合成Work fixtureを同時に立てて確認する。

| 接続箇所 | 本番 | レーン | 実証 |
| --- | --- | --- | --- |
| 判断・Session通知、通知flush | `notify/index.mjs` → `deliver.py`、Hermes notifier、relay/APNs | `sink/notify.jsonl` に種別のみ。外部flush・通知配送の定期処理なし | 負のPOST前後で通知なし。レーンの判断一覧で `decision.new` 記録 |
| phone-use | Bridgeの状態、CLIのAPNs署名・HTTP/2 | レーンの状態と `sink/apns.jsonl`。UIでは指定シミュレーターにだけ `simctl push`、Node試験は記録のみ | `APNS_KEY_ID` 起動拒否、fixtureの本番state拒否、並列smokeで疑似端末登録と記録を確認 |
| Workの委譲・daemon・会話・モデル候補 | `laa-personal-agent`、Work router/Paseo、HQモデル表・availability CLI、命名・履歴 | 専用Workソケット＋Echo、合成モデル候補、`sink/work.jsonl`。外部の命名・初回指示探索なし | 並列smokeの作成・送信・会話・一覧・アーカイブ、Work未接続時の拒否、router/CLI/socket上書き拒否 |
| Workspace・添付・Skills | Work CLI・git・ホストrepo、オーナーのファイルと画像、Claude/Hermes skills | `home/` のみ、外部git/ファイルは拒否、画像はレーンで登録したもののみ、Skillsは空 | workspace一覧が空、外部のBrain・Skills・Workの指定を拒否 |
| Calendar・Drive・Photos | Google API、既存OAuth token/helper、予定通知 | `lane_adapter_missing`、予定通知の起動なし | Calendar/Drive HTTP拒否、reminder設定で起動拒否 |
| Linear・Kanban・タスク処理 | Linear/ Hermes Kanban、資格情報helper、成果物アップロード、task dispatch/cleanup | `lane_adapter_missing`、dispatchタイマーなし。Bridge内蔵の社長タスク・習慣はレーン状態だけ | Tasks/Linear/personal-task HTTP拒否、token helper設定で起動拒否 |
| 音声 | `LAA_VOICE_WORKER` の子プロセス | `lane_adapter_missing` | voice HTTP拒否、worker設定で起動拒否 |
| Usage・容量・Mac状態 | CodexBar feed、MacBook capacity helper、storage status、ホストサンプル | `--fixture usage` でレーンの実Bridgeが合成値を配信。それ以外は `lane_adapter_missing` | 使用率と容量、鮮度、更新、合成障害をUIで検証。外部feed・storage設定は起動拒否 |
| Brain・同期 | vault、area policy、検索CLI、Syncthing | 独立した空 `brain/`。vault/policy/検索/同期は `lane_adapter_missing` | root実パスとsymlink、検索CLI・Syncthing設定とBrain HTTP拒否 |
| Campaigns・定期処理 | campaign ledger Python、`laa-console jobs`、Work報告の配送 | `lane_adapter_missing`、報告スキャン開始なし | campaigns/routines HTTP拒否、ledger設定で起動拒否 |
| Studio・指示書 | Studioアプリ／Unixソケット、オーナーの指示ファイル | `lane_adapter_missing` | Studio/instructions HTTP拒否 |

## Fail-closed handshake

- Bridge／fixtureは `X-LAA-Lane` 不足・不一致を `421 lane_mismatch` とし、レーン内の最終応答に自分のIDを付ける。実Bridgeのhealth本文は `data.lane` でも返す。通常モードのBridgeはヘッダーの値が空でも付いていれば認証・本文・保存先に触る前に拒否し、レスポンスにレーンヘッダーは付けない。`node --test` と `LAA_LANE_ID` 付きCLIは本番の既定保存先を開かない。
- Nodeは `laneClient`、Debugアプリは `LAALabNetworkPolicy` を使う。認証や書込みより先にヘッダー付き・資格情報なしのhealthで応答を照合し、実リクエストの応答も復号・デコード前に再検査する。旧版Bridgeへのread-only試験は `node scripts/laa/lab/lane-negative.mjs --live`（固定URLのhealth GETのみ、本番 `decisions.json` のSHA-256とmtimeを照合）。
- アプリの対象クライアントは `LAABridgeClient`（JSON・watch音声）、Driveのrange/export/thumbnail（Studio media含む）、個人タスクの添付アップロード。いずれもDebugブロックで検査する。`CONDUIT_UITEST=1` またはレーンIDがあれば本番のBridge／Hermesポートとloopback以外を事前拒否。レーンIDがあれば明示されたBridge／fixtureに限定する。シミュレーターではBridgeの端末情報をDebug専用Keychainサービス `com.laa.conduit.bridge.lab.<lane>.<test>` に保存する。同じテストでのアプリ再起動には残り、レーンやテストをまたいで再利用しない。ポリシー有効中は通常サービスを読取・書込・削除しない。
- Hermesは実socket・Dashboardの音声/Kanban socket認可、native auth/OAuth、背景HTTP・ファイル、readiness/sign-outを検査する。TCP/HTTPのHermes fixtureを使う場合だけ `LAA_LANE_HERMES=http://127.0.0.1:<fixture-port>` を指定する。HermesのWebKit/ブラウザ認証と保存接続の自動復元は試験中は無効。通知relayの全request builderと直接revoke、APNs／PushKitの端末登録、Watch起動時接続、Gemini/Qwenの実プロバイダtoken発行、GPT音声のWebRTC offer、実ホストのルーム読取fixtureは試験中は無効。
- Phone UseのUI試験はLAA 16 Pro Maxに レーン内の一時 `.apns` ファイルを `xcrun simctl push <UDID> com.laa-inc.laa <file>` で注入し、ファイルは成功・失敗にかかわらず削除する。`simctl push` はアプリ向け通知専用で、ActivityKit用のAPNs push type・topic・トークンを指定できない。このためBridge生成のペイロードをアプリ向け通知に包み、Debugシミュレーターの受信コードが同一属性・状態でActivityKitを開始する。iOS 27のシミュレーターがサイレント通知を拒否するため外側にテスト用alertを付け、前面ではバナーを表示しない。通知の保存だけが権限不足で拒否された場合は、そのリクエストのActivityKit登録をBridgeが確認した時に限り開始成功とする。許可・拒否・停止・期限切れは通常のActivityKitビュー、App Intent、Bridgeを通る。OSによるリモートのpush-to-startやAPNs配信自体は対象外。
- Watchペア試験のみ、Debugシミュレーターで `-LAA_WATCH_LAB_SEND_CONTEXT` と合成データを指定し、通常の `WCSession.updateApplicationContext` を通す。受信した通話・要求の処理と通知登録は無効のまま。性能試験ではレーンIDなしで、その実行専用のloopback Work fixtureとUUID付きKeychainサービスを使い、終了時に同じサービスの削除を確認する。
- 検証は `node --test bridge/test/lane-*.test.mjs`、`node scripts/laa/lab/lane-smoke.mjs`、`LAALabLaneGuardTests`。アプリのラボ経路は `#if DEBUG` のみ（通常の戻り値・送信処理は同じ）。この仕組みはテスト経路の誤接続を防ぐもので、同じUnixユーザーがNode・アプリを改変したり、別途 `curl` を直接実行したりすることを阻止するOSサンドボックスではない。

## Suites

統合前の合否は「前回と同じ失敗件数」ではなく、試験ID単位の台帳で判定する（BUS-504）。入口は `scripts/laa/lab/suite.py`、定義は `scripts/laa/lab/suites.json`、既知の失敗は `scripts/laa/lab/known-failures.json`。

| スイート | ビルド | 対象 | 役割 |
| --- | --- | --- | --- |
| `integration` | `project-laa.yml`（LAA版） | 単体の全件とUIの全クラス（`exclude_classes` に理由つきで挙げた物を除く） | 配信する製品の全試験 |
| `smoke` | `project.yml`（既定のConduit版） | `scripts/smoke-suite.json` の単体10クラスとUI 2クラス | 上流と共有するコードの早い判定 |
| `upstream` | `project.yml` | 単体の全件と、上流だけにある画面のUI 3クラス | LAA版では成立しない上流の試験（置換される文言、LAAのシェルが置き換える画面）が、成立する構成で通ることの証明 |

`integration` と `smoke` は別のビルド・別の試験集合で、片方の結果をもう片方の根拠にしない。

```sh
python3 scripts/laa/lab/suite.py run integration --out <結果フォルダ>     # 生成→ビルド→列挙→単体→UI
python3 scripts/laa/lab/suite.py check integration <結果フォルダ>         # 台帳と照合。0以外は統合しない
python3 scripts/laa/lab/suite.py run smoke --out <結果フォルダ> && python3 scripts/laa/lab/suite.py check smoke <結果フォルダ>
python3 scripts/laa/lab/suite.py run upstream --out <結果フォルダ> && python3 scripts/laa/lab/suite.py check upstream <結果フォルダ>
```

- 一部だけ流す時は `--phase build|unit|ui` と `--only <Target>/<Class>[/<test>]`、照合は `check … --partial`（走らせた範囲だけを見る。統合の根拠にはしない）。
- 既定版とLAA版は生成されるプロジェクトが違うため、同じチェックアウトで交互に流さない。ランナーはチェックアウトごとに排他を取り、2本目は待つ。既定版は別のworktreeで流す。
- ランナーは `LAA_UI_TEST_REAL_BRIDGE`・`LAA_REAL_BRIDGE_TEST` を環境から外す。試験の各段（単体、UIの各バッチ）は共有ビルド枠の中で `LAA 16 Pro Max` を消去し、言語と地域を英語（米国）にして読み戻してから始める。シミュレーターはほかの会話と共有で、枠の合間に残った保存済み接続が初回ログイン画面を飛ばした（2026-11-24）。`--no-erase` は絞り込みの再実行用で、統合の根拠にしない。
- 1件も走らずに終わった段（試験ランナーの起動失敗）は1回だけやり直す。最初の結果は `<段>.xcresult.attempt1` に残る。
- 台帳で説明できない失敗は、対象ごとに10件までを単独でもう一度流す（`rerun-unit`・`rerun-ui`）。そこでだけ通った試験は `results.json` に最初の失敗と指紋を残し、`check` が `PASSED ONLY ON RERUN` として毎回表示する。合格にはなるが、統合の報告に書き、繰り返すなら直す。`--no-rerun` で止められる。
- `xcodebuild` は1本ずつ共有ビルド枠の中で動き、シミュレーターは同じ枠の中で起動・停止する。ビルドだけの段はシミュレーターを起動しない。

## Ratchet

`run` はビルド済みの試験バンドルから試験IDを列挙し（`inventory-<Target>.json`）、`.xcresult` から試験ごとの結果・失敗メッセージ・指紋を `results.json` へ書く。指紋は失敗メッセージからアドレス・パス・数値・空白の揺れを除いたSHA-1の先頭12桁で、同じ失敗は実行をまたいで同じ値になる。

`check` は次のどれか1つで不合格（終了コード1）にする。

| 不合格の条件 | 意味 |
| --- | --- |
| 台帳に無い失敗・スキップ | 新しい退行 |
| 台帳と指紋が違う | 同じ試験が別の理由で落ちている（古い失敗の陰に新しい失敗が隠れている） |
| 台帳にあるのに成功した | 直った。台帳から消すまで統合しない（歯止めを締める） |
| 台帳にあるのに走らなかった | 試験が消えた・名前が変わった・選ばれなかった |
| 列挙されたのに走らなかった | 途中で落ちた・実行から漏れた |
| 台帳が無い・読めない | 試験ランナーが起動せず、列挙がバンドル名だけを返した（終了コードは0になる） |
| 理由の無い除外クラス | 黙って外された試験 |

台帳の1行は `"<Target>/<Class>/<test>": {"result", "fingerprint", "class", "reason"}`。`class` は次の4つだけ。

| 分類 | 使う時 | 行を残せる条件 |
| --- | --- | --- |
| `stale-expectation` | 製品の挙動は意図どおりで、試験の期待値が古い | 原則残さず試験を直す |
| `environment` | シミュレーター・負荷・権限など実行環境が原因 | 環境側で直せない理由を書く |
| `real-bug` | 製品の不具合 | この場で直せない理由と、社長から見える影響を書く |
| `not-applicable` | その構成では成立しない試験（上流の文言・画面をLAA版が置き換えている等） | 成立する構成で通ることを別のスイートで示す |

失敗を直したら同じ変更で台帳の行を消す。新しい行を足すのは、分類・理由・証拠を書ける時だけにする。件数の比較（「masterと同じ◯件」）は根拠にしない。

## Capture

Hortensia の主要画面を、本番の Bridge・Hermes ではなく同梱の見本データで撮影する。iPhone は `LAA 16 Pro Max`（440×956 pt、PNG は 1320×2868 px）、Mac は別の `macdev` ビルドの実窓（900×600、1280×820、1680×1050 pt）。Mac の UI テストは起動しない。

```sh
python3 scripts/laa/lab/capture.py --out <新規ディレクトリ> --platform iphone,mac
python3 scripts/laa/lab/capture.py --out <別の新規ディレクトリ> --platform iphone \
  --variants light,text-max --screens work-tasks,work-task-detail
python3 scripts/laa/lab/capture.py diff <変更前> <変更後>
```

`index.html` を開くと画面×条件の一覧をオフラインで見比べられる。`index.json` には PNG のパス・SHA-256・寸法・ソースのコミット・端末・撮影時刻とアクセシビリティ設定の実測を残す。撮影元はコミットしてから実行する。`diff` の `changed_pixel_ratio` は sRGB に揃えた画素の変化率で、寸法が違うときは片方にしかない画素も数える。日時やアニメーションの差も含むため、変更率だけを UI の合否にはしない。

- iPhone の既定条件: `light`、`dark`、`long-japanese`、`text-mid`（アクセシビリティの中）、`text-max`（最大）、`reduce-motion`、`reduce-transparency`、`increase-contrast`。ダーク以外はライト。各起動で SwiftUI と UIKit の実効値を読み、シミュレーターの設定は撮影前に戻してから停止する。
- Mac の既定条件: `light`、`dark`、`long-japanese` を各3サイズ。導入済みのアプリ・ペアリングを使わず、ショットごとに見本の窓を閉じる。SwiftUIの外観とWindowServerの窓枠寸法を検証する。
- 画面の追加: `scripts/laa/lab/capture-screens.json` に ID・題名・経路・見本を登録し、iPhone は `ConduitUITests/LAALabCaptureUITests.swift` で安定したアクセシビリティ識別子から開いて同じ ID を添付する。Mac 対象なら `mac` の起動先を登録する。不足・重複・設定の不一致があれば失敗し、完成版の索引は出さない。
- 連続比較でビルドを温存する場合だけ `--keep-build` を使う。既定は DerivedData と xcresult を消し、PNG・索引・検証ログを残す。共有ビルド枠の待機は画面撮影時間と区別して読む。

既定の撮影表は iPhone 31画面・248枚、Mac 12画面・108枚、計356枚。Mac mini上でiPhoneの社員一覧を8条件で撮ると約7分51秒、計3.9 MiB（ビルドと枠待ち別、起動・設定復元と書き出し込み）。PNGは1320×2868 px。ビルド済みのMac版は108枚で約9分20秒、PNG計22.6 MiB（ビルドと枠待ち別）。900×600等の指定は撮影時に窓枠の実寸も検証し、PNGにはタイトルバーを含む。iPhone全条件を含む実測は撮影完了後に追記する。

## Watch

```sh
python3 scripts/laa/lab/watch.py pair-check --out /absolute/work/watch/pair-check
python3 scripts/laa/lab/watch.py test --out /absolute/work/watch/test
```

`LAA 16 Pro Max`（iOS 27.0）と `LAA Watch S11 46`（watchOS 27.2）を名前から一意に特定する。共有ビルド枠内だけ両方を起動し、`simctl list pairs` の `active, connected` と両方の `Booted` を確認する。終了時は両端末の `Shutdown` を読み戻す。既に起動中の端末は引き取らない。このMacでは未起動のWatchを含む初回のペア確認に枠内64.9秒かかり、ランタイムの追加は不要だった。

ペアがないときは `xcrun simctl list devices` で上の2名称と対応するランタイムを確認する。端末自体が消えていた場合だけ、既存ランタイムを使い `xcrun simctl create '<上の名称>' <device-type-id> <runtime-id>` を実行する（`com.apple.CoreSimulator.SimDeviceType.` 以下は `iPhone-16-Pro-Max`／`Apple-Watch-Series-11-46mm`。`com.apple.CoreSimulator.SimRuntime.` 以下は `iOS-27-0`／`watchOS-27-2`）。取得したIDで `xcrun simctl pair <Watch ID> <iPhone ID>`、必要なら `xcrun simctl pair_activate <新しいペアID>`。同名端末の重複、既存ペアの削除、新規ランタイムの追加はしない。

`test` は `project-laa.yml` の LAA Debug 版を両方に導入し、`ConduitWatchLab` を Watch Simulator 宛てに実行する。電話側は合成UUID付きの2種類の `WatchPhoneContext` を通常の `WCSession.updateApplicationContext` で順に送る。Watch側は受け取ったUUIDとAI社員の通話ボタンの非表示→表示を同じ試験内で照合する。ボタンは押さず、実資格・本番Bridge・Hermes・音声を使わない。失敗・スキップ・未実行・欠けた添付はいずれも終了コード非0。

`watch/<variant>/<screen>.png` と `index.json` を出力する。watchOS 27.2では `simctl ui appearance` が未対応で、SwiftUIが受け取った `dark` のみ実測した。最大文字サイズはDebugシミュレーター限定で `.accessibility5` を注入し、OS設定の確認とは区別する。長い日本語名はスクリーンショット上では1行省略されるが、アクセシビリティラベルに全文があることを確認した。このMacでの初回全工程は共有枠内279.68秒、3試験・PNG4枚。

このレーンの対象はアプリ画面・レイアウトと試験したWatchConnectivity経路まで。文字・画像の合成通知はシミュレーターへ直接投入できても、端末間の実通知ミラーリング・APNs、文字盤やSmart Stackの実環境での更新、マイク／音声ルーティング・通話継続、触覚品質はこの試験では確認しない。試験していない転送種別（`sendMessage`、`transferUserInfo`、`transferFile`）を合格扱いしない。

## Performance

```sh
python3 scripts/laa/lab/perf.py run --out /absolute/work/perf/first --runs 5
python3 scripts/laa/lab/perf.py run --out /absolute/work/perf/second --runs 5 --reuse-build
python3 scripts/laa/lab/perf.py compare /absolute/work/perf/first/perf.json /absolute/work/perf/second/perf.json
```

本番BridgeやHermesには接続しない。LAA 16 Pro Maxで、`project-laa.yml` のDebug fixtureを残し、Swift `-O`（incremental）・C `-O2`、iOS Simulator向けにビルドする。App StoreのRelease/archiveと同一ではない。Work／Today／Usageは `scripts/laa/work-ui-fixture.mjs`（loopbackのみ）、Hermesは無通信スタブ、Docは45段落のローカルfixture、Chatは120件の合成会話を使う。`--reuse-build` は直前と同じコミット、設定、SDK、バイナリの場合だけ使える。

冷起動はプロセス終了から `XCTApplicationLaunchMetric(waitUntilResponsive: true)` が測る応答可能な初フレームまで。OSファイルキャッシュは消さない。温起動は同一プロセスの再前面化からWorkの操作要素まで。画面遷移は操作から表示確認までを単調時計で測るため、UI自動化の送受信・確認待ちを含む。Chat・Work・Today・Doc・Usageの方向付き20通り。iPhoneのUsageはWorkから開くため、他タブとの組み合わせにはWork経由の操作を含む。文書とWork履歴はタイトルではなく本文が開くまで測る。

### Simulatorのスクロール計測

Xcode 27.2（27B52）の `XCTMetric.h` は `scrollingAndDecelerationMetric` を “The XCTMetric object covering both the scroll and deceleration animations” と記述し、animation signpostには “hitch time ratio (ms per s)” 等を列挙する。[AppleのAPI文書](https://developer.apple.com/documentation/xctest/xctossignpostmetric/scrollinganddecelerationmetric) に明記されている非報告環境は “In a compatible iPad or iPhone app running in visionOS, the system doesn’t report hitch- or animation-related metrics that occur during scrolling.”。[`XCTHitchMetric`](https://developer.apple.com/documentation/xctest/xcthitchmetric) の説明は “A metric to measure the number of hitches your UI encounters in a performance test.”。これらと[27.2のリリースノート](https://developer.apple.com/documentation/xcode-release-notes/xcode-27_2-release-notes)からiOS Simulatorでのhitch出力可否を一般化できない。このMacのiOS 27.0／Xcode 27.2では、両APIを併用した5回ともスクロール区間長のみが出力され、hitch・frame指標は出なかった（`perf/baseline-04/run-*/metrics.json`）。区間長をhitchとして使わない。

代わりに、Debug Simulator版へ明示した起動引数を渡し、XCTestが `CADisplayLink` の記録を開始・停止する。記録中は確保済みバッファへの数値書込みだけで、UI更新・ファイル書出し・JSON化は停止後。開始・停止のタップ時間を除き、同じ単調時計上のスクロール操作と自動化の減速待ち区間を集計する。[Appleの`CADisplayLink`文書](https://developer.apple.com/documentation/quartzcore/cadisplaylink) の “To calculate the actual frame duration, use `targetTimestamp` - `timestamp`.” に従い、この差を次の間隔の予算とする。各コールバックの実測間隔について、予算超過のうち操作区間内に入る時間を足して区間長で割る（ms/s）。[AppleのTech Talk](https://developer.apple.com/videos/play/tech-talks/10855/) が定義する “Hitch time ratio is the total hitch time in an interval divided by its duration.” と同じ比率だが、測定対象は実表示フレームでなくSimulatorのメインループへのコールバック。予算の1.5倍・2倍を超過した回数、最長間隔、予定／実測Hzも記録する。**このMac上での前後比較用の代替指標であり、実機の絶対性能やAppleの評価閾値には当てはめない。** 製品ビルドに記録経路はない。

### 静穏判定と比較

共有枠を取得した秒を起動ログに記録する。先行ジョブが起動したiPhoneは最大30秒だけ停止を待ち、停止しなければ引き継がない。各試行の前に1分負荷平均（このMacでは上限6.0）、ほかの `xcodebuild` と稼働中シミュレーターの有無を確認する。最大2分で揃わない、または試行中に別のビルド・端末を検知した回は除外する。短時間の負荷スパイクは完全には除けない。

`perf.json`／`perf.md` に5回以上有効な値が揃った指標の中央値・最小・最大・幅を保存する。欠測は理由付きの `unavailable` とし、ゼロにしない。静穏な試行が規定回数に足りないか、採用済み基準で測れていた指標が測れなければ終了コード1。`run-*/frames-{chat,work}.json` は各フレーム間隔の監査用ログ。基準は `scripts/laa/lab/perf-baseline.json`。

比較は同じ計測手順・設定・ランタイム・ツールチェーン・単位・取得元が条件。一方でも `unavailable` なら `NOT COMPARABLE`。悪化方向の中央値差が `max(基準の最大−最小, 新計測の最大−最小)` を超えたとき退行とする。実測Hzは低下が悪化、予定Hzは参考値。環境が異なるときは基準を採り直す。

### 初回基準

`e1a7278042af3c4e910d8507513a1bb1bc52f5d9` のビルドで静穏5回（開始時load 3.500–5.915）、4試験×5合格、38指標を採用。XCTestのネイティブhitch比率2件だけ `unavailable`。冷起動2.730秒、温起動1.243秒、長文Doc 1.827秒、Work長履歴2.886秒。

| スクロールの代替指標（5回中央値） | Chat | Work |
|---|---:|---:|
| 予算超過比率 | 28.30 ms/s | 39.25 ms/s |
| 1.5倍超／2倍超 | 6／3回 | 4／2回 |
| 試行内の最長間隔 | 41.68 ms | 49.09 ms |
| 予定／実測コールバックHz | 60.00／58.33 | 60.00／57.65 |

HO-28の優先候補はDoc→Usage 5.057秒、Today→Usage 4.924秒、Chat→Usage 4.912秒、Usage→Chat 3.980秒、Usage→Today 3.835秒。いずれもWork経由と自動化の確認時間を含むので、最適化前にUsage描画と経由の操作を切り分ける。生ログと幅は `perf/slot-retry-05/{perf.json,verification.log,run-*/frames-*.json}`。

## 他アプリへの展開

この検証基盤は「アプリ固有の部品」と「どのアプリでも同じ型」に分かれる。新しいアプリでは型をそのまま使い、固有の部品だけを書く。Voice・Journal・Academyの順で足す時の最小手順を示す。

### どのアプリでも同じ型

| 型 | 守ること | Hortensiaでの実物 |
| --- | --- | --- |
| 隔離レーン | 1回の実行ごとに使い捨てのHOME・状態・ポートを作り、終了時に消す。固定ポート・既定の保存先・既存ログインを使わない | `scripts/laa/lab/lane.mjs`、`bridge/src/lane/` |
| 失敗時に閉じる照合 | 試験側は全リクエストにレーンIDを付け、応答のレーンIDを照合してから読む。本番側はレーンID付きの要求を認証・保存より先に拒否する。起動時に本番のパス・ポート・外部設定を見つけたら起動しない | `X-LAA-Lane`、`bridge/src/lane/guard.mjs`、`LAALabNetworkPolicy.swift` |
| 負の試験 | 「試験が本番へ届かない」ことを、本番の保存物のSHA-256と更新時刻が変わらない形で毎回示す。本番へ送ってよいのは読取専用の生存確認1本だけ | `scripts/laa/lab/lane-negative.mjs --live`、`bridge/test/lane-isolation.test.mjs` |
| 差し替え口 | 外へ出る接続（通知、他サービス、音声、課金のあるモデル）は全て注入する。差し替えが無い接続はレーンで `lane_adapter_missing` を返し、黙って本番へ出ない | LAB「Adapters」の表 |
| 試験の台帳と歯止め | 実行前にビルド済みバンドルから試験IDを列挙し、結果を試験ID単位で記録する。既知の失敗は「試験ID・結果・指紋・分類・理由」で持ち、件数で比べない。新しい失敗、指紋の変化、直ったのに台帳に残る行、列挙されたのに走らなかった試験は全て不合格 | `scripts/laa/lab/suite.py`、`known-failures.json` |
| 撮影 | 画面と状態を一覧ファイルで宣言し、1コマンドで全外観（明・暗、長い日本語、大きい文字、視差・透明度の低減）を撮る。設定は撮影後に元へ戻す。撮影用の試験は挙動の試験と混ぜない | `scripts/laa/lab/capture.py`、`capture-screens.json` |
| 性能 | 静かな状態で5回以上測り、中央値を基準にする。測れない指標は `unavailable` と記録し、合格にしない | `scripts/laa/lab/perf.py` |
| 共有資源 | `xcodebuild` は `/Users/laa/hq/harness/build-slot.sh` の下で1本ずつ。シミュレーターは枠の中で起動し、同じ枠の中で停止する。実行先は機種名でなくUDIDで指定する | `suite.py` の `xcodebuild()` |

アプリ本体に入れる試験用の分岐は `#if DEBUG`（シミュレーター専用なら `targetEnvironment(simulator)` も）で囲み、Releaseビルドが通ることを毎回確かめる。

### 新しいアプリで書く物

1. **境界の棚卸し**：外へ出る接続を全て挙げ、それぞれ「レーンの差し替え」か「レーンでは拒否」を決める（LAB「Adapters」の表と同じ形）。
2. **起動の歯止め**：試験用の起動引数・環境変数が付いたら、本番のURL・保存先・Keychainを読まない経路に入る。付いていない試験は走らせない。
3. **負の試験**：本番の保存物を1つ選び、試験の前後でSHA-256と更新時刻が同じであることを確かめる。
4. **試験の定義**：`suites.json` に相当する1ファイルへ、ビルド仕様・対象の試験・除外するクラスと理由を書く。`suite.py` は `REPO`・スキーム名・UDIDを差し替えれば流用できる。
5. **初回の基準**：消去済みのシミュレーターで全件を走らせ、失敗とスキップを1件ずつ分類する（期待値が古い／環境／実バグ／対象外）。対象外は「どの構成なら通るか」を別の実行で示す。
6. **画面の一覧**：主要な画面と状態を一覧ファイルに書き、撮影コマンドへ渡す。

### アプリごとの入口

| アプリ | 場所 | 既にある入口 | 足す物 |
| --- | --- | --- | --- |
| Voice（キーボード） | `dev/voice-input`（iOSは `iOS/project.yml`、スキーム `LAAVoice`、単体 `LAAVoiceTests`、シミュレーター `LAA Voice Keyboard Test`） | `scripts/test.sh`、マイクとUIを使わない `scripts/e2e.sh`、`iOS/Tests` の入力評価 | キーボード拡張は単独で起動できないため、入力欄だけを持つホスト画面をDebugに用意し、そこへUI試験から文字を打たせる。音声は録音済みファイルを注入し、変換モデルと辞書は使い捨ての保存先に置く。Mac連携は合成の相手に差し替える |
| Journal | `dev/journal`（Webは `npm test`＝vitest、Appleは `apple/project.yml`、スキーム `LAAJournalLoginSmoke`・UI試験 `LAAJournalUITests`） | 合成の取引データ `scripts/ui-fixture.ts`、画面検証 `scripts/verify-ui.ts`、撮影 `scripts/design-shots.ts`、Mac実窓 `apple/scripts/mac-capture.sh` | Webは使い捨てのDBと認証秘密で起動し、本番のDB・ストレージ・MT5取込へ届かないことを負の試験で示す。取引の研究・記録データは試験に使わず、合成データだけを使う。Appleは合成のAPI相手へ向け、同じ画面一覧で撮る |
| Academy | `dev/laa-academy`（`apple/scripts/xc.sh -scheme LAAAcademy`、UI試験 `LAAAcademyUITests`、教材の検査 `tests/test_academy.py`） | `xc.sh` が共有枠・容量・負荷の開始判定を持つ | 教材パックは同梱の見本だけを読み、進捗は使い捨ての保存先へ書く。画面一覧と台帳を足す |

各repoのPROJECT-RULESが優先する。この節は型の説明で、他repoの手順を置き換えない。
