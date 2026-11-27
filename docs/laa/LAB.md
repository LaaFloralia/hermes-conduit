# LAB（検証基盤）

Hortensia（LAAアプリ）を、本番の判断ボード・Session・通知へ触れずに隔離レーンとMacの実窓で検証する仕組み。シミュレーター試験・撮影・計測は2026-11-27に廃止し（社長決定）、完了の判定は `laa-app-gate`（定義 `hq/harness/app-gate.json`）の1コマンドに一本化した。規則の要点は `PROJECT-RULES.md`、統合前の手順は `docs/laa/SESSION-HANDOFF.md`。

| したいこと | 節 | 入口 |
| --- | --- | --- |
| 試験を本番から切り離して動かす | Lane・Adapters・Fail-closed handshake | `scripts/laa/lab/lane.mjs`、`lane-negative.mjs` |
| 完了してよいか判定する | 完了の判定 | `laa-app-gate pre hortensia --src <作業ツリー>`／`post hortensia`（`hq/harness/app-gate.json`） |
| 既存の試験結果を台帳と照合する | Suites（廃止）・Ratchet | `scripts/laa/lab/suite.py parse`・`check` |
| Macの全画面を見比べる | Capture | `scripts/laa/lab/capture.py --platform mac`、`diff` |
| 既存の性能計測を比べる | Watch・Performance（廃止） | `scripts/laa/lab/perf.py compare` |
| ほかのアプリへ同じ型を入れる | 他アプリへの展開 | この文書 |

実機でしか分からないこと（APNsの実配信、端末間の通知ミラーリング、音声経路、触覚、実描画のhitch）はこの基盤の対象外で、各節の末尾に書いてある。

## Lane

統合試験ランナー（`suite.py run integration`）はシミュレーター試験の廃止（2026-11-27）で止めた。レーンは `lane.mjs`・`lane-smoke.mjs`・`node --test bridge/test/lane-*.test.mjs` で引き続き使う。レーンは所有者限定の一時フォルダに作るため、Unixソケットの上限に収まる短い絶対パスを使う。

隔離したWorkエンジンは導入済みの `engine`・`client` と、エンジン自身の依存（`lane.mjs` の `engineDeps`、現在は `ajv` とその依存）だけをレーンへ複製して動かす。提供元のSDKは複製しないため、レーンの中では内蔵のEcho提供元しか動かない。エンジンが新しい依存を持つとレーンは起動せず、足すべきパッケージ名を表示する（2026-11-24のエンジン更新で発生）。

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
- 試験が自分で立てるloopback fixture（撮影・性能のように実行ごとに変わるポート）は、アプリへ `LAA_BRIDGE_DEFAULT_ADDRESS` で宣言する。宣言の無いポートはポリシーが送信前に拒否し、画面は読み込まれない（統合後の撮影でWork画面が出なかった原因、2026-11-24）。例外は「Macに届かない」状態を作る `http://127.0.0.1:1` だけで、何も待ち受けないため送信は成立しない。healthの事前確認に応答が無い時は「Macに届きません」（レーン外と同じ表示）にし、応答があって照合に失敗した時だけレーン不一致にする。
- Hermesは実socket・Dashboardの音声/Kanban socket認可、native auth/OAuth、背景HTTP・ファイル、readiness/sign-outを検査する。TCP/HTTPのHermes fixtureを使う場合だけ `LAA_LANE_HERMES=http://127.0.0.1:<fixture-port>` を指定する。HermesのWebKit/ブラウザ認証と保存接続の自動復元は試験中は無効。通知relayの全request builderと直接revoke、APNs／PushKitの端末登録、Watch起動時接続、Gemini/Qwenの実プロバイダtoken発行、GPT音声のWebRTC offer、実ホストのルーム読取fixtureは試験中は無効。
- （実行停止中・コードは残す）Phone UseのUI試験は、LAA 16 Pro Maxへ レーン内の一時 `.apns` を `xcrun simctl push` で注入し、ファイルは成否にかかわらず削除していた。Debugシミュレーターの受信コードがBridge生成のペイロードから同一属性・状態でActivityKitを開始する。OSのpush-to-startやAPNs配信自体は対象外。
- （実行停止中・コードは残す）Watchペア試験は `-LAA_WATCH_LAB_SEND_CONTEXT` と合成データで通常の `WCSession.updateApplicationContext` を通していた。性能試験はレーンIDなしで実行専用のloopback Work fixtureとUUID付きKeychainサービスを使い、終了時に削除を確認していた。
- 検証は `node --test bridge/test/lane-*.test.mjs`、`node scripts/laa/lab/lane-smoke.mjs`、`LAALabLaneGuardTests`。アプリのラボ経路は `#if DEBUG` のみ（通常の戻り値・送信処理は同じ）。この仕組みはテスト経路の誤接続を防ぐもので、同じUnixユーザーがNode・アプリを改変したり、別途 `curl` を直接実行したりすることを阻止するOSサンドボックスではない。

## Suites（2026-11-27に廃止）

シミュレーター試験は社長決定で廃止した。`suite.py run`（ワーカーを含む）と `seed` は、シミュレーター・ビルド枠・MacBookに触れる前に終了コード64で止まり、代わりの `laa-app-gate pre hortensia --src <作業ツリー>` を示す。完了の判定はこの1コマンド（定義は `hq/harness/app-gate.json`）だけにする。読取専用の `suite.py parse <結果フォルダ>` と `suite.py check <suite> <結果フォルダ> [--partial]` は、既存の `.xcresult`・`results.json` の分析用に残す。定義 `suites.json`（`integration`・`smoke`・`upstream`）、`known-failures.json` と試験のソースは、再開に備えて消さない。


## Ratchet

廃止前の `run` はビルド済みの試験バンドルから試験IDを列挙し（`inventory-<Target>.json`）、`.xcresult` から試験ごとの結果・失敗メッセージ・指紋を `results.json` へ書く。指紋は失敗メッセージからアドレス・パス・数値・空白の揺れを除いたSHA-1の先頭12桁で、同じ失敗は実行をまたいで同じ値になる。

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

Hortensia の主要画面を、本番の Bridge・Hermes ではなく同梱の見本データで、別の `macdev` ビルドの実窓（900×600、1280×820、1680×1050 pt）に撮る。Mac の UI テストは起動しない。iPhoneシミュレーター撮影は2026-11-27に廃止し、`--platform` に `iphone` を含むと終了コード64で止まる（部分的にも撮らない）。iPhoneの画面は実機（`laa-phone`、`laa-app-gate post hortensia`）で確かめる。

```sh
python3 scripts/laa/lab/capture.py --out <新規ディレクトリ>        # 既定 --platform mac
python3 scripts/laa/lab/capture.py --out <別の新規ディレクトリ> --variants light --screens work-tasks
python3 scripts/laa/lab/capture.py diff <変更前> <変更後>
```

`index.html` を開くと画面×条件の一覧をオフラインで見比べられる。`index.json` には PNG のパス・SHA-256・寸法・ソースのコミット・撮影時刻と外観の実測を残す。撮影元はコミットしてから実行する。`diff` の `changed_pixel_ratio` は sRGB に揃えた画素の変化率で、寸法が違うときは片方にしかない画素も数える。日時やアニメーションの差も含むため、変更率だけを UI の合否にはしない。

- Mac の既定条件: `light`、`dark`、`long-japanese` を各3サイズ。導入済みのアプリ・ペアリングを使わず、ショットごとに見本の窓を閉じる。SwiftUIの外観とWindowServerの窓枠寸法を検証し、PNGにはタイトルバーを含む。
- 画面の追加: `scripts/laa/lab/capture-screens.json` に ID・題名・経路・見本と `mac` の起動先を登録する。不足・重複・設定の不一致があれば失敗し、完成版の索引は出さない。
- 連続比較でビルドを温存する場合だけ `--keep-build` を使う。既定は DerivedData を消し、PNG・索引・検証ログを残す。Mac 12画面×3条件×3サイズ＝108枚・22.6 MiB、初回から最終撮影まで9分34秒（Mac mini、ビルド別）。


## Watch・Performance（2026-11-27に廃止）

Watchシミュレーターのペア確認・試験（`watch.py pair-check|test`）とシミュレーター性能計測（`perf.py run`）は社長決定で廃止し、呼ぶと終了コード64で代わりの手順を返す。Watchとウィジェットは `laa-app-gate pre hortensia` の実機向けビルド（`Conduit` が `ConduitWatch`・`ConduitWatchWidgets` を含む）で確かめる。既存の計測同士の比較 `python3 scripts/laa/lab/perf.py compare <基準perf.json> <新perf.json>` だけ残す（同じ手順・設定・ランタイム・単位が条件、一方でも `unavailable` なら `NOT COMPARABLE`、悪化方向の中央値差が両方の幅の大きい方を超えたら退行）。基準は `scripts/laa/lab/perf-baseline.json`。計測方法・初回基準の記述と試験のソースは、再開に備えてgit履歴とrepoに残す。


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
| 撮影 | 画面と状態を一覧ファイルで宣言し、1コマンドでMac実窓の全外観を撮る。撮影用の試験は挙動の試験と混ぜない。iPhoneは実機（`laa-phone`） | `scripts/laa/lab/capture.py --platform mac`、`capture-screens.json` |
| 完了の判定 | ビルド・検査・配信の読戻しを1コマンドで判定し、規則はその入口を指すだけにする | `laa-app-gate`（`hq/harness/app-gate.json`） |
| 共有資源 | `xcodebuild` は `/Users/laa/hq/harness/build-slot.sh` の下で1本ずつ | `laa-app-gate pre` が1枠でまとめて実行 |

アプリ本体に入れる試験用の分岐は `#if DEBUG`（シミュレーター専用なら `targetEnvironment(simulator)` も）で囲み、`laa-app-gate pre` のRelease実機向けビルドで不在を確かめる。

### 新しいアプリで書く物

1. **境界の棚卸し**：外へ出る接続を全て挙げ、それぞれ「レーンの差し替え」か「レーンでは拒否」を決める（LAB「Adapters」の表と同じ形）。
2. **起動の歯止め**：試験用の起動引数・環境変数が付いたら、本番のURL・保存先・Keychainを読まない経路に入る。付いていない試験は走らせない。
3. **負の試験**：本番の保存物を1つ選び、試験の前後でSHA-256と更新時刻が同じであることを確かめる。
4. **試験の定義**：`suites.json` に相当する1ファイルへ、ビルド仕様・対象の試験・除外するクラスと理由を書く。`suite.py` は `REPO`・スキーム名・UDIDを差し替えれば流用できる。
5. **初回の基準**：macOSで動く試験（`swift test`、Node・Python等）を全件走らせ、失敗とスキップを1件ずつ分類する（期待値が古い／環境／実バグ／対象外）。シミュレーターは使わない（2026-11-27廃止）。
6. **画面の一覧**：主要な画面と状態を一覧ファイルに書き、撮影コマンドへ渡す。

### アプリごとの入口

| アプリ | 場所 | 既にある入口 | 足す物 |
| --- | --- | --- | --- |
| Voice（キーボード） | `dev/voice-input`（`iOS/project.yml`、スキーム `LAAVoice`、単体 `LAAVoiceTests`） | `scripts/test.sh`、マイクとUIを使わない `scripts/e2e.sh`、`iOS/Tests` の入力評価、`laa-app-gate pre campanula` | 入力欄だけのDebugホスト画面と録音済み音声の注入は、シミュレーターでなくmacOSで動く試験か実機確認（`laa-phone`）で書く。変換モデルと辞書は使い捨ての保存先、Mac連携は合成の相手 |
| Journal | `dev/journal`（Webは `npm test`＝vitest、Appleは `apple/project.yml`） | 合成の取引データ `scripts/ui-fixture.ts`、画面検証 `scripts/verify-ui.ts`、撮影 `scripts/design-shots.ts`、Mac実窓 `apple/scripts/mac-capture.sh`、`laa-app-gate pre triteleia` | Webは使い捨てのDBと認証秘密で起動し、本番のDB・ストレージ・MT5取込へ届かないことを負の試験で示す。取引の研究・記録データは使わず合成データだけ。Appleは合成のAPI相手へ向け、Mac実窓で撮る |
| Academy | `dev/laa-academy`（`apple/scripts/xc.sh -scheme LAAAcademy`、教材の検査 `tests/test_academy.py`、`AcademyKit` の `swift test`） | `xc.sh` が共有枠・容量・負荷の開始判定を持つ。`laa-app-gate pre primula` | 教材パックは同梱の見本だけを読み、進捗は使い捨ての保存先へ書く。UI試験 `LAAAcademyUITests` はソースだけ残し実行しない |

各repoのPROJECT-RULESが優先する。この節は型の説明で、他repoの手順を置き換えない。
