# LAA Bridge（Mac側サービスの骨格）

`docs/laa/BRIDGE.md` の §9（親の決定）に沿った、Mac mini 上の単一 Bridge プロセスの骨格。実装済みは**端末認証・health・idempotency 台帳・起動停止・Drive（一覧／metadata／Range配信）**で、他の業務エンドポイント（sessions / tasks / brain …）と iOS クライアントは後続タスク。

- 待受け: `127.0.0.1:9137` のみ（LAN・tailnet へ直接 bind しない）
- 公開: Tailscale Serve の専用HTTPSポート `8445` → `http://127.0.0.1:9137`（既存 8443 / 8444 は触らない）
- 状態: `~/.local/state/laa-bridge/state.json`（端末、ペアリングコードの hash、idempotency 台帳）
- 依存: Node.js 20.11+ の標準モジュールのみ（npm install 不要）。`laa-personal-agent`（`hq/harness/personal_agent_bridge.mjs`）と同じ ESM/Node 系に合わせ、外部依存を持たない

## 設計上の決定

| 項目 | 決定 | 理由 |
|---|---|---|
| 認証 | 端末ごとの 256bit ランダムトークン（`Authorization: Bearer`）。保存は SHA-256 hash のみ | §9。要求ごとの署名・nonce 台帳は採らない |
| ペアリング | Mac の CLI が10分有効・1回限りのコードを発行。state には hash のみ保存し、コードは端末に一度だけ表示 | §9。コードはログ・引数・チャットへ出さない |
| scope | 初期付与は §9 の集合（`sessions:*` `tasks:*` `brain:read` `media:read` `photos:select` `usage:read` `archives:read` `archives:create`）。`brain:write` `gui:operate` `archives:restore` `devices:admin` は付与しない | §9 |
| 失効 | `laa-bridge revoke` は state を書き換えるだけ。稼働中サーバーは毎リクエスト state を読むため再起動不要で 401 になる | 失効の即時性 |
| idempotency | 変更系は `Idempotency-Key` 必須。端末ID＋メソッド＋path＋生body の SHA-256 で照合し、同一内容は保存応答を再返却、異内容は 409、実行中は 409、7日で失効 | §2・§9。失効後の自動再実行はしない |
| 失敗時 | state が壊れていたら起動しない（端末・台帳を失ったまま稼働させない） | §7 |
| ルート追加 | 各領域は `src/routes/<area>.mjs` が `{method,path|pattern,scope,handler}` の配列を返し、`src/http.mjs` の `ROUTES` へ1行で登録する。ストリーム応答は handler が `res` を直接書き、`undefined` を返す | 並行作業の衝突を1行に閉じる |

## 起動

```sh
# 常駐（LaunchAgent）。エージェントは agent-control のゲート経由で実行する
laa-agent-control exec --provider local --label laa-bridge-install --timeout 120 -- \
  /Users/laa/dev/hermes-conduit/bridge/scripts/install.sh

# 手元で試すだけなら
cd bridge && LAA_BRIDGE_PORT=9141 node src/main.mjs
```

install は plist を `~/Library/LaunchAgents/com.laa.bridge.plist` へ書き、`launchctl bootstrap` し、`~/.local/bin/laa-bridge` をリンクする。再実行は再インストールとして扱う。ポートが他のプロセスに使われていれば中止する。

## ペアリング（端末の追加）

```sh
laa-bridge pair                 # 10分有効・1回限りのコードを端末に表示
laa-bridge pair --name "iPhone" --scopes sessions:*,tasks:*,brain:read
laa-bridge pair --json          # エージェントが読む用（コードをログへ残さない）
```

表示されたコードをアプリのペアリング画面へ入力すると、アプリは `POST /v1/devices/enroll {"code":"XXXX-XXXX","name":"iPhone"}` を呼び、`{deviceId, token, scopes}` を一度だけ受け取る。トークンは端末の Keychain（ThisDeviceOnly）へ保存する。コードは 10 分で失効し、使用済みコードの再送は `401 pairing_code_used`、期限切れは `401 pairing_code_expired`。

## 端末の一覧・失効

```sh
laa-bridge devices              # id・状態・scope
laa-bridge revoke dev_ab12…     # 失効（4文字以上の一意な接頭辞でよい）
laa-bridge revoke dev_ab12… --reason "lost phone"
```

失効後、そのトークンの要求は `401 token_revoked`。実行中の下流処理は自動停止しないので、必要なら既存の停止制御で別途止める。再登録は新しいコードと新しい端末IDになる。

## API（実装済み）

| method / path | 認証 | 応答 |
|---|---|---|
| `GET /v1/health` | 不要 | `{version, uptimeSeconds}` のみ |
| `POST /v1/devices/enroll` | ペアリングコード | `{deviceId, token, scopes, createdAt}`（201） |
| `GET /v1/me` | Bearer | `{deviceId, name, scopes, platform, createdAt}` |
| `GET /v1/drive/files?query=&folderId=&pageSize=&cursor=` | Bearer + `media:read` | `{items,nextCursor}` |
| `GET /v1/drive/files/{id}` | Bearer + `media:read` | `{id,name,mimeType,kind,size,modifiedAt,parents,downloadable,exportFormats?}` |
| `GET|HEAD /v1/drive/files/{id}/content` | Bearer + `media:read` | bytes（200）、`Range` 部分（206）、範囲外（416）、Workspace文書（409） |
| `POST /v1/_test/echo` | Bearer + `sessions:write` | テスト専用。`LAA_BRIDGE_TEST_ENDPOINTS=1` のときだけ存在 |

エラーは `{"error":{"code","message","retryable"},"requestId"}`。`400` 不正、`401` 未認証・失効、`403` scope・Origin、`404` 範囲外、`405` メソッド、`409` idempotency 競合、`429` 試行過多、`500` 内部。`enroll` は応答にトークンを含むため idempotency 台帳の対象外（コード自体が1回限り）。

## Drive（一覧・metadata・Range配信）

既存のGoogle認可はMacの**Driveデスクトップ**（floralia@laa-inc.com）。`~/Library/CloudStorage/GoogleDrive-floralia@laa-inc.com` にツリーを出し、各項目のDrive IDを `com.google.drivefs.item-id#S` xattr に持つ。Bridgeはこの既存経路を**読取専用**で使い、OAuth付与・APIキー・アカウントを追加せず、Driveクライアントの資格情報も取り出さない（`src/drive/drivefs.mjs`）。

- 一覧の対象はDriveデスクトップが見せる範囲（マイドライブ・共有ドライブ）。「共有アイテム」の未追加分とゴミ箱は含まない。索引は初回に構築して60秒キャッシュする（実測: 約700項目で0.3秒）。
- `?query=` は索引全体の名前検索、`?folderId=` はそのフォルダ直下、どちらも無い場合はDriveルート（ブラウズの入口）。
- `content` は単一の `Range` をローカルファイルの部分読みへ中継する（206・`Content-Range`・`Content-Length`・MIME・`Accept-Ranges`・ETag）。複数rangeは無視して200で全体を返し、範囲外は `416` と `Content-Range: bytes */size`。クライアントが切ると読み取りを中止する。
- Workspace文書（.gdoc/.gsheet/.gslides）はディスク上はリンク情報だけなので、`409 export_required` と書き出し候補形式を返す。Bridgeは書き出しを行わない。

実測（2026-10-29、ループバック、実ファイル、テスト用の一時端末）:

| 項目 | 結果 |
|---|---|
| 初回バイト（未キャッシュの9.6MB mp4、`bytes=0-65535`） | 206、2,674ms |
| 中間seek（同ファイル、`bytes=4830429-5092572`） | 206、1,615ms |
| キャッシュ済みファイルの先頭・中間 | 206、1–2ms |
| 中断（1チャンク読後に切断） | 読み取り停止、以後のリクエストは正常 |
| 範囲外 | 416 `range_not_satisfiable` |
| Workspace文書 | 409 `export_required`（pdf/docx/txt） |
| 未知のID | 404 `not_found` |
| Driveクライアント無し | 503 `drive_unavailable`（retryable） |

制約: 初回バイトはDriveデスクトップの取得待ちで秒単位になる。Drive API（`files.get?alt=media` + `Range`）を直接使う経路は未認可で、速さと全ファイル到達性が要るなら親がOAuthクライアント（`drive.readonly`）を用意する。

## 停止・再起動・クラッシュ復帰

```sh
launchctl kickstart -k gui/$(id -u)/com.laa.bridge     # 再起動
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.laa.bridge.plist   # 停止
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.laa.bridge.plist # 開始
```

`KeepAlive` により `kill -9` 後も launchd が再起動する（`ThrottleInterval` 10 秒）。端末・台帳は state に残るため、再起動後も同じトークンと idempotency key が有効。

## Tailscale で公開する

```sh
bridge/scripts/tailscale-serve-add.sh      # 8445 を追加（8443/8444 は前後比較で不変を検査）
bridge/scripts/tailscale-serve-remove.sh   # 8445 だけを削除
bridge/scripts/verify.sh                   # 読み取りのみの受入確認
```

`serve-guard.py` が前後の `serve status --json` を比較し、8443（Console/Usage）と 8444（Hermes dashboard/Conduit）に差分が出たら追加を取り消す。`tailscale serve reset` は使わない。Funnel は使わない。

## ロールバック（1コマンド）

```sh
bridge/scripts/rollback.sh
```

Bridge の Serve エントリ削除 → LaunchAgent の停止・解除 → `127.0.0.1:9137` が閉じたことと 8443/8444 が残っていることの確認、まで行う。state は残す（`uninstall.sh --purge-state` で明示的に削除）。Hermes・Paseo・Linear・Syncthing・cron・既存 Serve は止めない。

## テスト

```sh
cd bridge && npm test        # node --test "test/**/*.test.mjs"（51 tests、約0.6秒。DriveFSのxattrテストはmacOSのみ）
```

CI は `.github/workflows/laa-bridge.yml`（ubuntu-latest、Node 24、依存導入なし）が `bridge/**` の変更時に実行する。macOS ランナーは使わない。

## セキュリティ境界と限界

- ループバックの別プロセスを信頼境界とみなさない。同一 UID は state・監査に触れ得る。
- Tailscale の到達性は認証ではない。ACL とトークンの両方で絞る。TLS は Serve が終端する。
- ログは requestId・method・path・status・deviceId・エラーコードのみ。トークン・コード・body は残さない。
- 実装していない: レート制限の永続化（メモリ内・enroll のみ）、監査ファイル、event stream、GUI 排他、Brain 書込み。
- Drive: 索引はメモリ内で、Driveデスクトップが同期していない項目は見えない。Drive APIの書き出し・共有設定・削除は扱わない（読取専用）。

## 未対応（後続タスク）

iOS クライアント、`/v1/sessions` 以降の業務端点、`/v1/events`、`/v1/jobs`、GUI lease、Brain 書込み、Usage/Mac 状態、DriveのWorkspace文書export。§9 の未決3・4（GUI・Brain書込み）は実証まで提供しない。
