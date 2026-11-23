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

Work/Shellの実接続試験は本番用のopt-inを使わず、レーン内で一回限りのコードを発行して実Bridgeにペアリングする。Work制御fixtureだけにセットアップ専用の資格情報を渡し、ProjectやEchoセッションを用意する。失効試験はそのテストが登録した端末だけを対象にする。

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
- Phone UseのUI試験はLAA 16 Pro Maxに レーン内の一時 `.apns` ファイルを `xcrun simctl push <UDID> com.laa-inc.laa <file>` で注入し、ファイルは成功・失敗にかかわらず削除する。`simctl push` はアプリ向け通知専用で、ActivityKit用のAPNs push type・topic・トークンを指定できない。このためBridge生成のペイロードをアプリ向け通知に包み、Debugシミュレーターの受信コードが同一属性・状態でActivityKitを開始する。許可・拒否・停止・期限切れは通常のActivityKitビュー、App Intent、Bridgeを通る。OSによるリモートのpush-to-startやAPNs配信自体は対象外。
- 検証は `node --test bridge/test/lane-*.test.mjs`、`node scripts/laa/lab/lane-smoke.mjs`、`LAALabLaneGuardTests`。アプリのラボ経路は `#if DEBUG` のみ（通常の戻り値・送信処理は同じ）。この仕組みはテスト経路の誤接続を防ぐもので、同じUnixユーザーがNode・アプリを改変したり、別途 `curl` を直接実行したりすることを阻止するOSサンドボックスではない。
