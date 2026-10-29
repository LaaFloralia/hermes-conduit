# LAA Bridge（Mac側サービスの骨格）

`docs/laa/BRIDGE.md` の §9（親の決定）に沿った、Mac mini 上の単一 Bridge プロセスの骨格。実装済みは**端末認証・health・idempotency 台帳・起動停止・Drive（一覧／metadata／Range配信）・Project と workspace の契約・タスク読取・Session（作成／追加入力／停止／再開／イベント再接続／成果物）・Brain（一覧／取得／検索／新規作成のみ）・Usage と Mac 状態（読取のみ）**で、他の業務エンドポイントと iOS クライアントは後続タスク。

- 待受け: `127.0.0.1:9137` のみ（LAN・tailnet へ直接 bind しない）
- 公開: Tailscale Serve の専用HTTPSポート `8445` → `http://127.0.0.1:9137`（既存 8443 / 8444 は触らない）
- 状態: `~/.local/state/laa-bridge/`（`state.json`＝端末・ペアリングコードの hash・idempotency 台帳、`projects.json`、`workspaces.json`、`sessions.json`＝セッション記録と24時間のイベント journal、`brain-create/journal.jsonl`＝Brain新規作成の intent／committed 記録）
- 依存: Node.js 20.11+ の標準モジュールのみ（npm install 不要）。`laa-personal-agent`（`hq/harness/personal_agent_bridge.mjs`）と同じ ESM/Node 系に合わせ、外部依存を持たない

## 設計上の決定

| 項目 | 決定 | 理由 |
|---|---|---|
| 認証 | 端末ごとの 256bit ランダムトークン（`Authorization: Bearer`）。保存は SHA-256 hash のみ | §9。要求ごとの署名・nonce 台帳は採らない |
| ペアリング | Mac の CLI が10分有効・1回限りのコードを発行。state には hash のみ保存し、コードは端末に一度だけ表示 | §9。コードはログ・引数・チャットへ出さない |
| scope | 初期付与は §9 の集合（`sessions:*` `tasks:*` `brain:read` `media:read` `photos:select` `usage:read` `archives:read` `archives:create`）。`brain:create` `brain:write` `gui:operate` `archives:restore` `devices:admin` は付与しない。`brain:create` は端末ごとの opt-in（`laa-bridge pair --scopes brain:read,brain:create`） | §9・BRAIN-WRITE §7 |
| 失効 | `laa-bridge revoke` は state を書き換えるだけ。稼働中サーバーは毎リクエスト state を読むため再起動不要で 401 になる | 失効の即時性 |
| idempotency | 変更系は `Idempotency-Key` 必須。端末ID＋メソッド＋path＋生body の SHA-256 で照合し、同一内容は保存応答を再返却、異内容は 409、実行中は 409、7日で失効 | §2・§9。失効後の自動再実行はしない |
| 失敗時 | state が壊れていたら起動しない（端末・台帳を失ったまま稼働させない） | §7 |
| ルート追加 | 各領域は `src/routes/<area>.mjs` が `{method,path|pattern,scope,handler,headers?}` の配列を返し、`src/http.mjs` の `ROUTES` へ1行で登録する。ストリーム応答は handler が `res` を直接書き、`undefined` を返す | 並行作業の衝突を1行に閉じる |
| 版 | 変更系は `Idempotency-Key` 必須。Project の更新は加えて `If-Match`（ETag は `"<version>"`）必須。欠落は 428、不一致は 412 | §3。2台の端末が黙って上書きしない |
| 命名 | Project は `nameSource` を持つ。`owner`（人・社長の指定）の名前は自動命名で置換できない（409 `name_source_locked`）。子セッションは `parentId` を持つと表示名の先頭が「子｜」になり、指定名にも付く。Paseo 側の表示名は委譲経路が変更 API を持たないため、Bridge が記録する名前が正 | §3、`hq/tools/PASEO-HERMES.md`「会話とワークスペースの命名」 |
| 指示版 | 指示本文は保存せず、`instructionRef` と本文の hash から `instructionHash` を作り、変更ごとに `instructionVersion` と履歴（20件）を残す | Brain / Drive の内容を Bridge に複製しない |
| workspace | 既存の repo / worktree を許可 root（既定 `~/dev`・`~/.paseo/worktrees`）から読取専用で棚卸し、branch と `git status` を返す。作成は `paseo worktree create` のみ。削除・rename・archive・force は持たない | §4。既存 worktree を壊さない |
| session | 実体は既存 `laa-personal-agent`（create/status/send/stop）。Bridge の `ses_<16hex>` は requestId から決定論的に導出し、委譲先の requestId も同じく決定論的なので、結果不明の再送は二重起動せず同じ agent に戻る。要求した profile は変更も代替もしない | §4・§9。二重実行防止を2層（Bridge の Idempotency-Key と委譲先の requestId）で持つ |
| session event | セッション記録と journal を同じ JSON に置き、状態変化とイベントを同時に commit する。seq は prune 後も進み、24時間を超えた cursor は 410、journal が届かない cursor も 410 | §5・§9。欠落を「新着なし」と偽らない |

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
| `GET /v1/tasks` | Bearer + `tasks:read` | Linear（+ 読めるなら Kanban）のタスク一覧。`owner` / `status` / `project` / `source` / `limit` / `cursor` で絞る |
| `GET /v1/tasks/{id}` | Bearer + `tasks:read` | 1件の詳細。`linear:BUS-123`、`BUS-123`、`kanban:<id>` |
| `POST /v1/_test/echo` | Bearer + `sessions:write` | テスト専用。`LAA_BRIDGE_TEST_ENDPOINTS=1` のときだけ存在 |
| `GET /v1/projects` | Bearer + `sessions:read` | `{items,nextCursor}`。`limit`（1–100、既定50）と `cursor` |
| `POST /v1/projects` | Bearer + `sessions:write` + `Idempotency-Key` | `{name,nameSource?,instructionRef?,instructions?}` → `{id,version,etag,instructionHash,instructionVersion,…}`（201） |
| `GET /v1/projects/{id}` | Bearer + `sessions:read` | Project と `ETag`。範囲外・不存在は 404 |
| `PATCH /v1/projects/{id}` | Bearer + `sessions:write` + `Idempotency-Key` + `If-Match` | 部分更新。`If-Match` 欠落 428、版不一致 412、owner 名への自動改名 409 |
| `GET /v1/workspaces` | Bearer + `sessions:read` | 許可 root 配下の repo / worktree。`{path,displayPath,kind,branch,head,status,projectId}` |
| `POST /v1/workspaces` | Bearer + `sessions:write` + `Idempotency-Key` | `{repoId,worktreeName,branch?,base?,projectId?}` → `paseo worktree create`（branch-off）で作成（201）、既存 branch は 409 |
| `GET /v1/workspaces/{id}` | Bearer + `sessions:read` | 1件と `ETag`。`id` は実パスから導出する `ws_<16hex>` |
| `GET /v1/sessions?projectId=&workspaceId=&parentId=&requestId=&phase=&limit=&cursor=` | Bearer + `sessions:read` | 新しい順の `{items,nextCursor}`。`parentId=root` は親なし |
| `POST /v1/sessions` | Bearer + `sessions:write` + `Idempotency-Key` | `{workspaceId,requestId,profile,prompt,name?,parentId?,projectId?,purpose?,completion?,scope?,returnTo?}` → session（201）、同じ requestId の再送は既存を 200 |
| `GET /v1/sessions/{id}` | Bearer + `sessions:read` | session と `observation:{available,code}`。委譲先が落ちていても記録は 200 で返す |
| `GET /v1/sessions/{id}/events?cursor=&afterSeq=&wait=&limit=` | Bearer + `sessions:read` | `{items,nextCursor,oldestSeq,headSeq,resyncRequired,resyncReason}`。`wait` は最大25秒の long-poll |
| `GET /v1/sessions/{id}/artifacts` | Bearer + `sessions:read` | `{items}`。`log`（journal の JSONL）・`message`（最新の assistant 応答）・`decision`（承認待ち） |
| `POST /v1/sessions/{id}/messages` | Bearer + `sessions:write` + `Idempotency-Key` | `{message,messageId?}` → 202。実行中・承認待ち・停止中は 409 |
| `POST /v1/sessions/{id}/stop` | Bearer + `sessions:write` + `Idempotency-Key` | 停止を確認して `phase:"stopped"`。未確認は 409 `stop_unconfirmed` |
| `POST /v1/sessions/{id}/resume` | Bearer + `sessions:write` + `Idempotency-Key` | `{message,profile?,requestId?}` → 201 後継 session（`resumedFrom`）。停止確認済みのみ |
| `GET /v1/brain/files?area=&limit=&cursor=` | Bearer + `brain:read` | 許可領域の Markdown ノート一覧（`id,path,area,size,modifiedAt,contentHash,title,status,checked`）。`area` は既定外の領域を明示的に足す |
| `GET /v1/brain/files/{id}?area=` | Bearer + `brain:read` | `{id,path,text,contentHash,etag,size,status,checked}`。領域外・symlink・不存在は 404 |
| `GET /v1/brain/search?q=&k=&area=&adopted=&rerank=` | Bearer + `brain:read` | `laa-brain search` の結果を `{found,matchBasis,results[{path,section,lines,status,relevance,text}]}` で返す。既定はローカルのみ（`rerank=1` で Jev 再判定） |
| `POST /v1/brain/files` | Bearer + `brain:create` + `Idempotency-Key` | `{path,content,onConflict?}` → 201 新規ノート（`id,path,contentHash,size,suffixApplied`）。既存内容は変更しない |
| `GET /v1/brain/gates` | Bearer + `brain:read` | vault・git・Syncthing・空き容量の事前条件（`ok`／`code`） |
| `GET /v1/usage` | Bearer + `usage:read` | CodexBar proxy の利用枠・残高を `{items,nextCursor}` で返す。欠測は `unavailable`＋`value:null` |
| `GET /v1/mac/status` | Bearer + `usage:read` | `host.cpu`・`host.memory`・`host.disk.free` の3件。CPU・メモリは Bridge 内サンプラ（10秒キャッシュ）、空き容量は storage-guard の状態ファイル |

エラーは `{"error":{"code","message","retryable"},"requestId"}`。`400` 不正、`401` 未認証・失効、`403` scope・Origin、`404` 範囲外、`405` メソッド、`409` idempotency 競合・名前の固定・worktree 既存、`412` 版不一致、`413` 読取上限超過、`415` テキストでない、`423` 排他中（git同期中・master以外）、`428` `If-Match` 欠落、`429` 試行過多、`500` 内部、`503` 依存（Paseo・Syncthing・vault）停止。`enroll` は応答にトークンを含むため idempotency 台帳の対象外（コード自体が1回限り）。

失敗した要求（4xx）は idempotency 台帳に `in_progress` のまま残る。同じ key での再送は 60 秒は `409 idempotency_key_in_flight`、その後は `409 idempotency_outcome_unknown` になるので、内容を直してやり直すときは**新しい key** を使う（成功の再送だけが保存応答を返す）。

## Project と workspace（タスク13）

Project は「ジャンル＋共通指示」で、パスを持たない。workspace は repo / worktree の実体で、`projectId` は作成時に Bridge が記録するだけの任意の紐付け。同じ Project を別の workspace で使えるため、ジャンルと作業場所が混ざらない。

```sh
# Project（作成は owner 名として記録される）
curl -sS -H "Authorization: Bearer $TOKEN" -H 'Idempotency-Key: p1' \
  -H 'content-type: application/json' \
  -d '{"name":"Trading｜環境認識","instructionRef":"Brain/Context/aesthetic.md"}' \
  http://127.0.0.1:9137/v1/projects

# 更新は ETag 必須（version 2 を期待）
curl -sS -X PATCH -H "Authorization: Bearer $TOKEN" -H 'Idempotency-Key: p2' -H 'If-Match: "1"' \
  -H 'content-type: application/json' -d '{"name":"Trading｜環境認識 v2"}' \
  http://127.0.0.1:9137/v1/projects/prj_xxxxxxxxxxxx

# 既存の repo / worktree の棚卸し
curl -sS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:9137/v1/workspaces

# 新規 worktree（Paseo の branch-off。既存 branch は 409）
curl -sS -H "Authorization: Bearer $TOKEN" -H 'Idempotency-Key: w1' \
  -H 'content-type: application/json' \
  -d '{"repoId":"ws_xxxxxxxxxxxxxxxx","worktreeName":"laa-example-40"}' \
  http://127.0.0.1:9137/v1/workspaces
```

- 許可 root は `LAA_BRIDGE_WORKSPACE_ROOTS`（`:` 区切り）で差し替えられる。既定は `~/dev` と `~/.paseo/worktrees`。symlink は辿らず、realpath が root の外になる path は一覧・作成の両方で拒否する。
- 一覧は `git status --porcelain=v2 --branch`（`GIT_OPTIONAL_LOCKS=0`）を1回だけ呼び、branch・ahead/behind・staged/modified/untracked/conflicted を返す。状態は5秒キャッシュ。Paseo daemon が落ちていても一覧は動く。
- 作成は `paseo worktree create --mode branch-off` のみ。`git worktree remove`・`archive`・`--force`・rename は実装しない。Paseo が失敗したら 503 を返し、既存の worktree には触らない。作成後の path が許可 root の外なら 503（記録もしない）。
- `projectId` の紐付けは `workspaces.json` に残る。worktree を消してもこの記録は自動削除しない（削除 API を持たない方針に合わせる）。

## Drive（一覧・metadata・Range配信）

`/v1/drive/files` は Google Drive API v3 を直接呼び、`files.list`・`files.get`・`files.get?alt=media` へクライアントの `Range` をそのまま中継する（`src/drive/google-api.mjs`、外部依存なし）。Driveデスクトップの同期フォルダ（`~/Library/CloudStorage`）は**読まない**。macOSのTCCがnodeプロセスへDrive管理ファイル全体の読取りを求め、許可するとnodeで動く全スクリプトに権限が広がること、オンライン専用ファイルは丸ごと取得しないと読めずRange再生に合わないことが理由（launchd配下では実際に `readdir` が許可待ちで停止した）。

認可はまだ無い。`LAA_DRIVE_CLIENT_ID`・`LAA_DRIVE_CLIENT_SECRET`・`LAA_DRIVE_REFRESH_TOKEN` の3つが揃った時だけ有効になり、無ければ全端点が `503 drive_not_configured` を返す（上流へ何も試さない）。必要な認可は OAuthクライアント（Desktop）と `https://www.googleapis.com/auth/drive.readonly` のrefresh token。

- 一覧は `corpora=allDrives`・`supportsAllDrives=true`・`trashed = false`。`?query=` は `name contains`、`?folderId=` は `'<id>' in parents`、どちらも無ければルート一覧。cursorは上流の `nextPageToken` を不透明化して24時間有効（期限切れは410）。
- `content` は `files.get?alt=media` へRangeを中継し、Driveの 206・`Content-Range`・`Content-Length`・MIME・ETag をそのまま返す。416は `Content-Range: bytes */size` 付きで返し、クライアント切断時は上流のfetchをabortする。HEADはmetadataから計算し、media endpointを開かない。
- Workspace文書（Docs/Sheets/Slides）は `409 export_required` と書き出し候補形式を返す。Bridgeは書き出しを行わない。

検証状況（2026-10-29）: 認可が無いため実ファイルでの再生・seek・中断は**未実施**。ローカルのfake Drive API（Range→206/416、pageToken、401/404/500）とHTTP契約テスト（206/416/HEAD/中断/409/404/503）で検証した。実機確認は認可後に `scripts/verify-drive.mjs` で行う。

## タスク読取（`/v1/tasks`）

ROADMAP 19。**読取専用**で、担当の設定も worker の起動もしない。実装は `src/routes/tasks.mjs`（HTTP）と `src/tasks/`（Linear / Kanban アダプター）。Linear は現行の正本で、Mac の既存ラッパー `/Users/laa/.config/laa/linear-agent-token.sh`（1Password Agents の既存認証を実行時だけ取得）を再利用する。新しい API キー・OAuth は追加していない。

各項目は `{id, source, sourceId, title, owner, executor, status, dependencies, result, project, labels, url, updatedAt, version}`。**owner と executor を分ける**のが要点:

| フィールド | 意味 |
|---|---|
| `owner.kind` | `owner`（社長の担当）/ `agent`（エージェントの担当）/ `unassigned` |
| `executor` | 実行するエージェント（Linear の `delegate`、なければエージェント担当者）。社長担当なら `null` |
| `status` | Linear の状態名・type・`open`/`done`/`closed` |
| `dependencies` | `blockedBy` / `blocks`（issue identifier）と `complete`（relation を全ページ読めたか） |
| `result` | `none` / `reported`（最新の `[laa-agent]` コメント）/ `completed` / `canceled`。詳細では `summary` と `commentId` も返す |
| `version` | Linear の `updatedAt`（将来の書込で `If-Match` に使う版） |

- 一覧は `{items, nextCursor, total, sources, suppressedDuplicates}`。`sources` は取得元ごとの `available` / `unavailable` と理由で、取得できないことを空一覧にしない。Linear 自体が失敗したときは 503（`linear_credential_unavailable` など）。
- `cursor` は件数オフセットをフィルタ集合に束縛した不透明値（24時間で失効）。別フィルタで使うと 400 `cursor_filter_mismatch`、壊れていれば 400 `cursor_invalid`、期限切れは 410 `cursor_expired`。
- 詳細は `{task, comments, links}`。`task.description` を含み、コメントは 4,000 文字で切り詰めて `truncated` を付ける。添付は `links`。
- **Kanban** は `source: "kanban"` の別ソース。Conduit は Hermes dashboard の `/api/plugins/kanban/*` を読むが、その API は loopback でも 401 で、Bridge が使える認証済みラッパーがまだ無い。よって現在は `sources[].state = "unavailable"`（`kanban_wrapper_not_authorized`）を返し、項目は 0 件。Linear の identifier を持つ Kanban 項目は重複として落とし、`suppressedDuplicates.kanban` に数える（社長タスクを複製しない）。ラッパーが用意できたら `createKanbanTaskSource({ baseUrl, request })` を差し込むだけで有効になる。
- 読み取り専用の担保: Linear アダプターは `query` 以外の GraphQL 文書を拒否し（`linear_read_only_guard`）、mutation を定義しない。Kanban アダプターは `/dispatch` や reassign を呼ばない。ルートは GET のみ。
- 照合: 2026-10-25 に Linear を直接読んだ結果と 57 件を突き合わせ、件数・title・状態・owner/executor・依存・project・updatedAt が一致（差分 0）。詳細 3 件もコメント・添付・依存が一致。再実行は `node scripts/verify-tasks.mjs`。

## Session（`/v1/sessions`）

ROADMAP 14。実体は既存の Mac 委譲経路 `/Users/laa/.local/bin/laa-personal-agent`（= `hq/harness/personal_agent_bridge.mjs`）で、Bridge は JSON を stdin に渡して1操作ごとに1プロセス起動する（約0.5秒）。Paseo SDK を直接使わないのは、CLI 0.11.4 と daemon 0.12.0 の差（BASELINE §2）と、requestId の冪等性・実 provider/model/effort の照合・停止中や承認待ちへの送信拒否を既存ラッパーが既に持っているため。**動く経路を1本だけ使い、二重実装しない**。

### 同一性と二重実行防止

- `ses_<16hex>` は `sha256("laa-bridge|" + requestId)` の先頭16桁。委譲先の requestId も `laa-bridge-<sha256(requestId)>` で決まる。したがって、Bridge が応答を返す前に落ちても、**同じ requestId + 新しい Idempotency-Key** で再送すれば、委譲先は同じ agent を返し（`reused`）、Bridge は同じ session を 200 で返す。新しい agent は作らない。
- requestId は要求内容（profile・workspace・parent・prompt など）に束縛する。同じ requestId で内容が違えば 409 `request_id_conflict`。同じ Idempotency-Key で内容が違えば従来どおり 409 `idempotency_key_conflict`、実行中は 409 `idempotency_key_in_flight`、60秒を超えた未完了は 409 `idempotency_outcome_unknown`（自動再実行しない）。
- 作成・送信・停止・再開はすべて `Idempotency-Key` 必須。送信の `messageId` は省略時に Idempotency-Key から導出するので、Bridge と委譲先の重複判定が一致する。

### 記録する値

`profile`（要求した名前）、`requested`（委譲先が解決した provider/model/effort）、`observed`（agent が実際に報告した値と `sources`）、`runtimeVerified`、`modelCheck`、`parentId`、`requestId`、`workspaceId`、`cwd`、`projectId`、`delegateSessionId`。**要求した model を書き換えたり、別 profile に代替したりしない**。resume で別 profile を渡すと 400 `model_change_rejected`。

### イベントと再接続

`GET /{id}/events` は long-poll（`wait` 0–25秒、既定0）。cursor は `{sessionId,seq,issuedAt}` の不透明値で、作成・一覧・詳細の `events.cursor` から始め、応答の `nextCursor` で進める。

- セッション記録と journal は同じ JSON ファイルに置き、観測した状態変化（phase・承認待ち・最新応答）とイベントを同じロックで commit する。イベントは `session.created` / `session.phase` / `session.pending` / `session.result` / `session.message.sent` / `session.stopped` / `session.stop_unconfirmed` / `session.resumed`。
- journal は24時間（§9）。seq は prune 後も進むので、期限切れ cursor は 410 `cursor_expired`、保持範囲より古い cursor は 410 `event_history_gap`。どちらも「新着なし」ではなく、クライアントは詳細と成果物を読み直す。
- 委譲先を観測できないときは 200 のまま `resyncRequired:true` と `resyncReason` を返し、journal にある分だけ渡す。空一覧で隠さない。
- イベントの payload に prompt・メッセージ本文・秘密は入れない（件数・種別・文字数・hash のみ）。

### 停止と再開

`stop` は委譲先の停止確認が取れたときだけ `phase:"stopped"`。取れなければ 409 `stop_unconfirmed` とし、状態を stopped と偽らない。`laa-personal-agent` は停止後に `send` を拒否し（`session_stopped`）、resume 操作を持たないため、`resume` は**同じ profile・workspace で後継セッションを作る**（`resumedFrom` / `resumedTo` で相互リンク、元 session に `session.resumed` イベント）。停止した agent をラッパーの外から再開しない。会話履歴は引き継がないので、resume には続きの指示（`message`）が要る。

### 成果物（ログ回収）

`/{id}/artifacts` は次の3種を返す。

| type | 内容 |
|---|---|
| `log` | Bridge が観測したイベント journal の JSONL（保持24時間、64KBで切詰め） |
| `message` | 最新の assistant 応答本文（委譲先 `status.result`） |
| `decision` | 承認待ち・質問の配列（委譲先が伏字化済みのもの） |

Paseo の生タイムラインは取得しない。`paseo logs --json` は JSON を返さず（表示用テキスト）、daemon の非公開 SDK に依存すると版差の影響を受けるため。Bridge の journal と委譲先 `status` が、再起動後も再現できる範囲のログになる。

### 検証

```sh
cd bridge
npm test                                    # fake adapter で契約を固定（13 tests）
LAA_BRIDGE_URL=http://127.0.0.1:9137 LAA_BRIDGE_TOKEN=… \
  LAA_BRIDGE_VERIFY_WORKSPACE=ws_… node scripts/verify-sessions.mjs
```

`verify-sessions.mjs` は実 DSH（`deepseek-flash-high`）で create → cursor からの再接続 → 同一 requestId の重複作成 → 追加入力 → 停止 → artifacts を1回で回す。2026-10-29 に実測: create 201（`requested` = dsh / `["opencode-go","deepseek-v4.1-flash"]` / high、`observed` は `sources.model=runtime`）、重複 200 で同一 `ses_`、send 202、stop 200（`daemonStatus=idle`）、artifacts に log 2,035 bytes と結果 "second"、cursor から `session.stopped` を受信。

## Brain（`/v1/brain`）

ROADMAP 25。タスク24の決定（`docs/laa/BRAIN-WRITE.md`）どおり、**既存内容の置換（`brain:write`）は提供しない**。提供するのは一覧・取得・検索と、**新規パスの作成だけ**（`brain:create`、O_EXCL、上書き経路なし）。実装は `src/routes/brain.mjs` と `src/brain/`（policy / vault / gates / journal / search）。

| 項目 | 決定 | 理由 |
|---|---|---|
| 領域 | 領域判定は `laa-brain` が読む `policy.json` をそのまま使う（既定 `/Users/laa/.local/share/laa-plugins/dev-main/laa-jev/brain/policy.json`、`LAA_BRIDGE_BRAIN_POLICY` で変更可）。既定は policy の default 領域のみで、`old`・`Inbox`・`Sources`・`Journal`・`Trading/研究資料`・`Trading/Reviews`・`Attachments`・`Templates`・未分類は `?area=` で明示した時だけ足す | 検索CLIと別の一覧を持つと、CLIが検索しないノートがアプリに出る。取り違えを二重実装しない |
| 検索 | `laa-brain search --json` を1検索1プロセスで呼び、結果を封筒へ写す。**既定は `--no-jev`**（ローカルのみ）。`rerank=1` の時だけCLI本来のJev再判定を通す | 既存の検索経路を再利用する。電話からの検索が既定でBrain抜粋を外部モデルへ送る新しい経路にならないようにする（Jev経由はCLI単体では承認済みだが、Bridgeからの自動送信は社長の明示時だけ）。応答は `matchBasis` と `relevanceStatus` を保持し、未判定を根拠にしない |
| 取得 | `id` は `bf_` + base64url(vault相対パス)。使う時に再検証する（NFC・`..`なし・`.md`・隠し/予約名/競合コピー拒否・realpath一致）。symlinkは辿らず404 | パスを不透明IDにしても検証を省かない |
| 作成 | 本文はそのまま書き、書いたバイト列の SHA-256 を返す。`path` は作成許可prefix（既定 `Inbox/`、`LAA_BRIDGE_BRAIN_CREATE_PREFIXES`）内のみ、親フォルダは既存のみ。名前衝突は既定 `onConflict:"suffix"`（`Note 2.md` を O_EXCL で確保）で、`"reject"` なら 409 `path_exists`。rename・上書き・切詰め・削除の経路は無い | BRAIN-WRITE §7「新規pathのみ・unique name・RENAME_EXCL・journal付き」 |
| 事前条件 | 空き容量64MB以上、gitが `master` かつ `index.lock`/rebase/merge/cherry-pick 無し（423）、Syncthing folder が paused でなく `errors`/`pullErrors` が0（503）。判定は `GET /v1/brain/gates` で見える | §4-2・§5。`state` 語彙は未確定（§8）なので、新規作成では scan 中を理由に拒否しない（CAS窓が無いため） |
| journal | `~/.local/state/laa-bridge/brain-create/journal.jsonl`（0600）へ `intent` を fsync してから vault を触り、`committed`/`aborted` で閉じる。本文は残さず path・hash・size・requestId・deviceId のみ。書けない時は vault を触らず503 | §4-5。vault外に置くのでSyncthingに書き換えられない |
| scope | `brain:read` は既定付与。`brain:create` は**既定に含めない**（`laa-bridge pair --scopes brain:read,brain:create`）。§9 の初期集合を変えず、BRAIN-WRITE §7 が「安全」と言うのは作成経路だけのため | 端末ごとのopt-in。`brain:write` は引き続き未付与・未実装 |

```sh
# 一覧（既定領域）と、Inboxを明示的に足した一覧
curl -sS -H "Authorization: Bearer $TOKEN" 'http://127.0.0.1:9137/v1/brain/files?limit=20'
curl -sS -H "Authorization: Bearer $TOKEN" 'http://127.0.0.1:9137/v1/brain/files?area=inbox'

# 検索（ローカルのみ。Jev再判定は rerank=1）
curl -sS -H "Authorization: Bearer $TOKEN" 'http://127.0.0.1:9137/v1/brain/search?q=デザイン&k=3'

# 新規作成（上書きしない。衝突時は "Note 2.md" になる）
curl -sS -H "Authorization: Bearer $TOKEN" -H 'Idempotency-Key: b1' \
  -H 'content-type: application/json' \
  -d '{"path":"Inbox/買い物.md","content":"# 買い物\n\n- 牛乳\n"}' \
  http://127.0.0.1:9137/v1/brain/files
```

本文の上限は48KB（`content_too_large`）。HTTPの封筒自体は64KBなので、エスケープの多い本文は封筒側で `payload_too_large` になる。読取は256KBまで（`file_too_large`）で、それを超えるノートは一覧に `contentHash:null` と `unreadable` 付きで残り、一覧全体を落とさない。`baseHash`・`overwrite` など置換を示すフィールドは 400 `unsupported_field` で拒否する。

事前条件の充足は `GET /v1/brain/gates` で確認する。作成の拒否理由は `brain_vault_unavailable`／`brain_vault_no_space`／`brain_git_busy`／`brain_git_branch`／`brain_sync_paused`／`brain_sync_error`／`brain_sync_unavailable`／`brain_journal_unavailable`／`brain_create_area_forbidden`／`path_parent_missing`／`path_exists` で区別する。

検証（2026-10-29、実vault）: `scripts/verify-brain.mjs` で一覧64件・gates ok・検索1件・`Inbox/_bridge-create-verify-*.md` の作成201・読戻し本文一致・hash一致・同名再作成409を確認し、その試験ノートは vault の既定（Obsidian のシステムTrash）に合わせて `~/.Trash/` へ移動した（削除APIは持たない。vaultに `.trash` は無く `trashOption` も未設定のため）。`npm test` の `test/brain.test.mjs` は fake vault・fake search・fake gates で同じ契約を固定する（実 vault・実 Syncthing は触らない）。

## Usage と Mac 状態（`/v1/usage`・`/v1/mac/status`）

ROADMAP 09。契約は `docs/laa/USAGE.md` §4、応答例は `docs/laa/fixtures/usage/`。実装は `src/routes/usage.mjs` と `src/usage/`（items / proxy / host）。読取専用で `usage:read` だけを要求し、資格情報・請求データ・provider の URL・cookie・エラー原文は返さない。

| 項目 | 決定 | 理由 |
|---|---|---|
| 利用枠・残高 | `http://127.0.0.1:8081/widget`（version 1）を読む。`provider.<id>.quota` / `.balance` / `.credits` / `.usage` の16件を固定順で返す | USAGE.md §1。Console collector と同じ表示射影（code-owned の id・ラベル・単位）で、provider 側の任意テキストは通さない |
| 欠測 | フィードに無い provider も `unavailable`＋`value:null`＋`nullReason:"fetch_failed"` で並べる。proxy 停止・タイムアウト（既定5秒、`LAA_BRIDGE_USAGE_FEED_TIMEOUT_MS`）・不正 JSON・`fetchedAt` が60秒超未来、は全件 unavailable の **200** | §4。0 で埋めない。Bridge の障害と「値が無い」を混ぜない |
| 鮮度 | `live`/`local`/`codexbar-cli` は provider `updatedAt` と `fetchedAt` の古い方から20分（`LAA_BRIDGE_USAGE_AUTO_STALE_MS`）で `stale`。`source:"verified"` は画面確認値なので stale にしない | §4。verified は `observedAt` と期限で鮮度を示す |
| 期限切れ | quota は `value` を決めた窓の `resetsAt` 経過、balance は `expiresOnUtc` 経過（日付は当日UTC末まで有効）または残高のある component が全期限切れ、で `expired:true`。値は保持する | §4。`claude-api` のような「一部だけ期限到来」は期限切れと呼ばない |
| 費用・トークン | v1 には含めない（`profile.*` の item を作らない）。アプリは現行どおり dashboard を直接読む | USAGE.md §6 親の決定1。新しい読取チケットを増やさない。dashboard は実測401で、Bridge専用の認可が未決のため |
| CPU・メモリ | Bridge プロセス内のサンプラ。CPU は `os.cpus()` のtick差分、メモリは `vm_stat` のページ数と `sysctl vm.swapusage`（`host_statistics64` と同じカーネル値）。10秒キャッシュで、常駐は増やさない | §6 親の決定2。`os.freemem()` だけだと reclaim 可能なキャッシュを「使用中」に見せる。非Darwin・取得失敗は `unsupported`／`fetch_failed` で null |
| 空き容量 | `~/.local/state/laa-storage-guard/status.json` を読むだけ（`LAA_BRIDGE_STORAGE_STATUS`）。`checked_at` が26時間超で `stale`、ファイル無しは `not_configured`、JSON不正は `fetch_failed` | §4。`laa-storage-guard status` は約50秒かかるので起動しない |
| 対象外 | proxy の `clef`（kind `status`＝テキスト）と `codex` の `credits` は v1 の4種類の item に載せない。`antigravity` の `extraWindows` は `windows` に合算して最小値を採る | 値の意味を変えて見せない。追加はアプリ側の表示要件が決まってから |

```sh
curl -sS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:9137/v1/usage
curl -sS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:9137/v1/mac/status
```

`items[]` は `{id,kind,label,value,unit,source,observedAt,availability,stale,estimated,expired,nullReason?,detail?}`。`availability:"unavailable"` の時だけ `value:null`・`nullReason` が付き、`observedAt` は null になる。`availability:"available"` は `value` が数値（0 も実値）。`detail` は quota=`{windows[{label,remainingPercent,resetsAt,windowMinutes?}]}`、balance=`{currency,components[]?,expiresOnUtc?}`、credits=`{renewsAt?,grantedAmount?,monthlyGrantedAmount?,dailyRemaining?,dailyGrantedAmount?}`、usage=`{periodDays,models[{model,inputTokens,outputTokens}]}`、CPU=`{windowSeconds,userPercent,systemPercent}`、メモリ=`{totalBytes,availableBytes,swapUsedBytes?}`、disk=`{volume,totalGb,level?,findings[]}`。

検証: `npm test` の `test/usage.test.mjs` は HTTP 経由で fixture と同じ読みを1件ずつ照合し、`test/usage-sources.test.mjs` は射影・鮮度・期限・サニタイズ・10秒キャッシュ・状態ファイルの異常を固定する。実機は `node bridge/scripts/verify-usage.mjs`（proxy と状態ファイルを直接読み、独立計算と突き合わせる。資格情報なし）。

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
cd bridge && npm test        # node --test "test/**/*.test.mjs"（153 tests、約2秒。Drive・sessions・brain・usageはfakeアダプタで検証）
```

CI は `.github/workflows/laa-bridge.yml`（ubuntu-latest、Node 24、依存導入なし）が `bridge/**` の変更時に実行する。macOS ランナーは使わない。

## セキュリティ境界と限界

- ループバックの別プロセスを信頼境界とみなさない。同一 UID は state・監査に触れ得る。
- Tailscale の到達性は認証ではない。ACL とトークンの両方で絞る。TLS は Serve が終端する。
- ログは requestId・method・path・status・deviceId・エラーコードのみ。トークン・コード・body は残さない。
- 実装していない: レート制限の永続化（メモリ内・enroll のみ）、監査ファイル、全体 `/v1/events` stream、GUI 排他、Brain の既存内容の書換え（`brain:write`）。Brainは新規作成のみで、削除・rename・移動・フォルダ作成を持たない。git の未解決競合は `index.lock`/rebase/merge/cherry-pick のマーカーで判定し、マーカーの無い未解決indexまでは見ない。
- `/v1/tasks` は Linear の全非アーカイブ課題を 1 リクエスト最大 500 件まで読み、フィルタとページングは Bridge 側で行う。500 件を超えると `sources[].truncated = true`。
- Drive: 認可が無いため実Driveへは未接続（503 `drive_not_configured`）。`~/Library/CloudStorage` は読まない。書き出し・共有設定・削除は扱わない（読取専用）。認可情報は環境変数のみで受け取り、ログ・URL・応答へ出さない。
- workspace の一覧は root 配下を毎回 walk する（深さ3、4000 entry、status 5秒キャッシュ）。巨大な root を許可すると遅くなるので、`LAA_BRIDGE_WORKSPACE_ROOTS` は用途の狭いディレクトリにする。

## 未対応（後続タスク）

iOS クライアント、`/v1/sessions/{id}/reply`（承認・質問への回答はタスク15）、`/v1/events`（セッション横断）、`/v1/jobs`、GUI lease、Brain の既存ノート編集（`brain:write`。§9未決4の実証まで提供しない）、DriveのWorkspace文書export、タスクの書込（`tasks:write`）。Kanban の読取は親が認証済みラッパーを承認するまで無効。

Project 側の残り: 端末をまたぐ「どの端末がどの Project を見られるか」の個別付与（今は `sessions:read/write` の範囲内で全 Project）、自動命名の生成器そのもの（Bridge は `nameSource` の規則だけを持つ）、Project と指示文書の実体（Brain/Drive）の存在確認。
