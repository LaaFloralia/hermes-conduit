# LAA Bridge（Mac側サービスの骨格）

`docs/laa/BRIDGE.md` の §9（親の決定）に沿った、Mac mini 上の単一 Bridge プロセスの骨格。実装済みは**端末認証・health・idempotency 台帳・起動停止・Drive（一覧／metadata／Range配信）・Project と workspace の契約・タスク読取・社長のLinearタスク（`/v1/linear-owner-tasks` の一覧／作成／更新／アーカイブ／復元）・Skills・routines・Calendar予定（`/v1/calendar/events`）・Session（作成／追加入力／停止／再開／イベント再接続／成果物）・Brain（一覧／取得／検索／新規作成のみ）・Usage と Mac 状態（読取のみ）・社長タスク（`/v1/owner-tasks`。保存・操作台帳・CLI・Linear からの一度限りの取込み）**で、他の業務エンドポイントと iOS クライアントは後続タスク。

- 待受け: `127.0.0.1:9137` のみ（LAN・tailnet へ直接 bind しない）
- 公開: Tailscale Serve の専用HTTPSポート `8445` → `http://127.0.0.1:9137`（既存 8443 / 8444 は触らない）
- 状態: `~/.local/state/laa-bridge/`（`state.json`＝端末・ペアリングコードの hash・idempotency 台帳、`projects.json`、`workspaces.json`、`sessions.json`＝セッション記録と24時間のイベント journal、`brain-create/journal.jsonl`＝Brain新規作成の intent／committed 記録、`owner-tasks.json`＝社長タスクと操作台帳・取込み対応表 0600）
- 依存: Node.js 20.11+ の標準モジュールのみ（npm install 不要）。`laa-personal-agent`（`hq/harness/personal_agent_bridge.mjs`）と同じ ESM/Node 系に合わせ、外部依存を持たない

## 設計上の決定

| 項目 | 決定 | 理由 |
|---|---|---|
| 認証 | 端末ごとの 256bit ランダムトークン（`Authorization: Bearer`）。保存は SHA-256 hash のみ | §9。要求ごとの署名・nonce 台帳は採らない |
| ペアリング | Mac の CLI が10分有効・1回限りのコードを発行。state には hash のみ保存し、コードは端末に一度だけ表示 | §9。コードはログ・引数・チャットへ出さない |
| scope | 初期付与は §9 の集合（`sessions:*` `tasks:*` `brain:read` `media:read` `photos:select` `usage:read` `archives:read` `archives:create`）。Studioの2権限はペアリング後に `grant-studio` で付与する。`calendar:read`・`calendar:write`・`media:write`・`brain:create`・`brain:owner` は端末ごとのopt-inで、`laa-bridge grant <device-id|prefix> --scopes <calendar:read|calendar:write|media:write|brain:create|brain:owner> --reason <理由>` で付与する。この5つ以外（`brain:write` `gui:operate` `archives:restore` `devices:admin`、scope group）はgrantで付与しない。混在要求は全体を拒否し、失効端末も拒否する | §9・BRAIN-WRITE §7 |
| 失効 | `laa-bridge revoke` は state を書き換えるだけ。稼働中サーバーは毎リクエスト state を読むため再起動不要で 401 になる | 失効の即時性 |
| idempotency | 変更系は `Idempotency-Key` 必須。端末ID＋メソッド＋path＋生body の SHA-256 で照合し、同一内容は原則として保存応答を再返却（Studioの作成・操作は現在の状態を取得）、異内容は 409、実行中は 409、7日で失効 | §2・§9。失効後の自動再実行はしない |
| 失敗時 | state が壊れていたら起動しない（端末・台帳を失ったまま稼働させない） | §7 |
| ルート追加 | 各領域は `src/routes/<area>.mjs` が `{method,path|pattern,scope,handler,headers?}` の配列を返し、`src/http.mjs` の `ROUTES` へ1行で登録する。ストリーム応答は handler が `res` を直接書き、`undefined` を返す | 並行作業の衝突を1行に閉じる |
| 版 | 変更系は `Idempotency-Key` 必須。Project の更新は加えて `If-Match`（ETag は `"<version>"`）必須。欠落は 428、不一致は 412 | §3。2台の端末が黙って上書きしない |
| 命名 | Project は `nameSource` を持つ。`owner`（人・社長の指定）の名前は自動命名で置換できない（409 `name_source_locked`）。子セッションは `parentId` を持つと表示名の先頭が「子｜」になり、指定名にも付く。Paseo 側の表示名は委譲経路が変更 API を持たないため、Bridge が記録する名前が正 | §3、`hq/tools/PASEO-HERMES.md`「会話とワークスペースの命名」 |
| 指示版 | 指示本文は Project ごとに Bridge の state（0600）へ保存し、`instructionHash` は本文そのものの SHA-256、変更ごとに `instructionVersion` と直近10版の履歴（本文・hash・版・時刻）を残す。**本文のみ**を受け付け、`instructionRef` は書き込み時に 400 `instruction_ref_unsupported`（Bridge はファイルを読まない）。イベント・ログへ本文は出さない | §9。iPhone から編集し、全セッションへ同じ版を適用する |
| workspace | 既存の repo / worktree を許可 root（既定 `~/dev`・`~/.paseo/worktrees`）から読取専用で棚卸し、branch と `git status` を返す。作成は `paseo worktree create` のみ。削除・rename・archive・force は持たない | §4。既存 worktree を壊さない |
| session | 実体は既存 `laa-personal-agent`（create/status/send/stop）。Bridge の `ses_<16hex>` は requestId から決定論的に導出し、委譲先の requestId も同じく決定論的なので、結果不明の再送は二重起動せず同じ agent に戻る。要求した profile は変更も代替もしない | §4・§9。二重実行防止を2層（Bridge の Idempotency-Key と委譲先の requestId）で持つ |
| routines | Consoleの `jobs` 読取結果から名前・予定・前回と結果だけを返す。変更操作はなく、読取失敗は503 | 認証とsessions:readが必要。未観測はnull |
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

再インストールでも、`LAA_LINEAR_PERSONAL_TOKEN_HELPER`・`LAA_LINEAR_PERSONAL_VIEWER_ID`・`LAA_GOOGLE_REMINDERS_ENABLED` の3つだけは、既に設定されていた時に限り引き継ぐ（`scripts/preserve-plist-env.py`）。それ以外の環境変数はテンプレートの値に戻るため、未設定の新規インストールで自動的に有効になることはない。plistは0600の一時ファイルへ描画し、`plutil -lint`の成功後に本番へatomic renameする（`scripts/install-plist.sh`）。既存plistが壊れていて読めない時は、値を出さずに失敗し、本番plistは変更しない。

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
laa-bridge grant-studio dev_ab12… --reason 'Owner device' # ペアリング済みの有効な端末にStudioの2 scopeだけ追加
laa-bridge grant dev_ab12… --scopes calendar:read,brain:create --reason 'Owner phone' # 指定したopt-in scopeだけ追加
```

失効後、そのトークンの要求は `401 token_revoked`。実行中の下流処理は自動停止しないので、必要なら既存の停止制御で別途止める。再登録は新しいコードと新しい端末IDになる。

音声専用端末は `laa-bridge pair --scopes voice:polish,voice:transcribe` で別に登録する。既存端末・既定scopeには追加しない。`LAA_VOICE_WORKER` に Mac mini の `saiddone-polish-worker` の絶対パスを設定した起動時だけ有効（未設定は503）。Haas-ja-v1.0 Q8_0とQwen3-4Bをprivate stdioで呼び、本文・音声はログやidempotency台帳に保存しない。同時要求は1件、処理中の追加要求は429。Bridgeの上限は通常90秒・worker初回120秒で、クライアント切断時はその要求だけを取り消す。ソースの配置と稼働への反映は別で、設定後の再起動には対象別の承認が必要。

## API（実装済み）

| method / path | 認証 | 応答 |
|---|---|---|
| `GET /v1/health` | 不要 | `{version, uptimeSeconds}` のみ |
| `POST /v1/devices/enroll` | ペアリングコード | `{deviceId, token, scopes, createdAt}`（201） |
| `GET /v1/me` | Bearer | `{deviceId, name, scopes, platform, createdAt}` |
| `POST /v1/voice/transcribe` | Bearer + `voice:transcribe` | `{pcm16,sampleRate:16000,language?:ja}` → `{text,model}`。PCM16LE mono base64、25秒まで |
| `POST /v1/voice/polish` | Bearer + `voice:polish` | `{text,language?}` → `{text,model,nothing?}`。4,000 UTF-16文字まで |
| `POST /v1/devices/self/revoke` | Bearer + voice scope | 呼出端末の資格情報だけ失効。対象指定不可 |
| `GET /v1/instructions/{agents|claude}` | Bearer + `instructions:read` | 指定された2ファイルのみ。本文と内容のSHA-256 ETag |
| `PUT /v1/instructions/{agents|claude}` | Bearer + `instructions:write` + `If-Match` | 保存前にBridge stateへ旧版をバックアップし、版不一致は412。git commitしない |
| `GET /v1/drive/files?query=&folderId=&pageSize=&cursor=` | Bearer + `media:read` | `{items,nextCursor}` |
| `GET /v1/drive/files/{id}` | Bearer + `media:read` | `{id,name,mimeType,kind,size,modifiedAt,parents,downloadable,exportFormats?}` |
| `GET|HEAD /v1/drive/files/{id}/content` | Bearer + `media:read` | bytes（200）、`Range` 部分（206）、範囲外（416）、Workspace文書（409） |
| `GET /v1/studio/snapshot`、`GET /v1/studio/requests/{id}` | Bearer + `studio:read` | Studio作品・原則・依頼一覧／依頼1件 |
| `GET /v1/studio/catalog`、`GET /v1/studio/projects/{id}` | Bearer + `studio:read` | v2の審美眼・資料／作品の版と講評。catalogは `If-None-Match` により304を返す |
| `GET /v1/studio/request-id` | Bearer + `studio:request` | Bridgeが作った依頼・講評用のUUID（送信前に下書きへ保存） |
| `POST /v1/studio/requests`、`POST /v1/studio/action` | Bearer + `studio:request` + `Idempotency-Key` | 受付202／操作200。Studio契約の衝突・受付停止の理由を返す |
| `POST /v1/studio/reviews` | Bearer + `studio:request` + `Idempotency-Key` | v2講評。初回201、同じ記録の再送200 |
| `GET|HEAD /v1/studio/media/{projectId}/{mediaKey}.{ext}` | Bearer + `studio:read` | 64桁のキーは不透明な識別子として転送する。Range 206・範囲外416。mp4・mp3は最大256 MiB、他の許可形式は最大128 MiB |
| `GET /v1/tasks` | Bearer + `tasks:read` | Linear（+ 読めるなら Kanban）のタスク一覧。`owner` / `status` / `project` / `source` / `limit` / `cursor` で絞る |
| `GET /v1/tasks/{id}` | Bearer + `tasks:read` | 1件の詳細。`linear:BUS-123`、`BUS-123`、`kanban:<id>` |
| `GET /v1/linear-owner-tasks` | Bearer + `tasks:read` | 社長本人の未完了Linear課題だけ（team BUS・owner・Todoはアカウントから解決）。`?archived=only` はアーカイブ一覧。`{items,nextCursor}` |
| `POST /v1/linear-owner-tasks` | Bearer + `tasks:write` + `Idempotency-Key` | `{id,title,description?,dueDate?,priority?}` → 201。`id` はクライアント生成のUUID v4。同じUUID・同じ内容の再送は既存課題を返す |
| `GET /v1/linear-owner-tasks/{id}` | Bearer + `tasks:read` | 1件。他人・他team・委譲済み・ゴミ箱は404 |
| `PATCH /v1/linear-owner-tasks/{id}` | Bearer + `tasks:write` + `tasks:read` + `Idempotency-Key` + `If-Match` | `{title?,description?,dueDate?,priority?}`。`If-Match` 欠落428、不一致412。アーカイブ済みは409 |
| `POST /v1/linear-owner-tasks/{id}/archive`・`/restore` | Bearer + `tasks:write` + `tasks:read` + `Idempotency-Key` + `If-Match` | `{id,archived}`。担当・状態を保ってアーカイブ／復元。旧DELETE・completed指定は受け付けない |
| `GET /v1/skills` | Bearer + `sessions:read` | `{items:[{id,name,description,source,category,summary,detail,metadataKnown}]}`。分類・日本語説明は名前別メタデータ、未登録は「その他」と元の説明。SKILL.md本文は返さない。読取失敗は503 |
| `GET /v1/routines` | Bearer + `sessions:read` | Console `jobs` の名前・予定・配信先・状態・直近実行・結果・`triggerKind`。定期実行以外は別枠。未観測はnull、読取失敗は503 |
| `GET /v1/calendar/events?start=&end=` | Bearer + `calendar:read` | RFC3339の42日以内 → `{items:[予定詳細],source,start,end}`。設定・認可・API失敗は503で、空の予定にしない |
| `POST /v1/_test/echo` | Bearer + `sessions:write` | テスト専用。`LAA_BRIDGE_TEST_ENDPOINTS=1` のときだけ存在 |
| `GET /v1/projects` | Bearer + `sessions:read` | `{items,nextCursor}`。本文は含めない。`limit`（1–100、既定50）と `cursor` |
| `POST /v1/projects` | Bearer + `sessions:write` + `Idempotency-Key` | `{name,nameSource?,instructions?}` → `{id,version,etag,instructions,instructionHash,instructionVersion,…}`（201）。`instructionRef` は 400 `instruction_ref_unsupported` |
| `GET /v1/projects/{id}` | Bearer + `sessions:read` | Project と `ETag`。`instructions`（保存済み本文）・`instructionVersion`・`instructionHash`。`instructionRef` は旧レコードのメタデータのみ。範囲外・不存在は 404 |
| `PATCH /v1/projects/{id}` | Bearer + `sessions:write` + `Idempotency-Key` + `If-Match` | 部分更新。`If-Match` 欠落 428、版不一致 412（`error.details.current` に現在の版・hash・ETag・本文）、owner 名への自動改名 409、`instructionRef` 400（`null` は旧メタデータの消去のみ） |
| `GET /v1/projects/{id}/instructions/versions` | Bearer + `sessions:read` | 直近10版の `{items:[{version,hash,body,updatedAt}]}`（新しい順） |
| `POST /v1/projects/{id}/files` | Bearer + `sessions:write` + `Idempotency-Key` | 資料 `{name,contentBase64,mimeType?}`（5 MiBまで、1件20個まで）を `project-files/` へ0600で保存（201）。表示名はそのまま、保存名だけをNFC・UTF-8バイト境界で255バイト以内に短縮する。詳細の `files` には名前・大きさ・hashだけを返し、Macのパスは返さない |
| `DELETE /v1/projects/{id}/files/{fileId}` | Bearer + `sessions:write` + `Idempotency-Key` | 資料を削除して詳細を返す |
| `GET /v1/workspaces` | Bearer + `sessions:read` | 許可 root 配下の repo / worktree。`{path,displayPath,kind,branch,head,status,projectId}` |
| `POST /v1/workspaces` | Bearer + `sessions:write` + `Idempotency-Key` | `{repoId,worktreeName,branch?,base?,projectId?}` → `paseo worktree create`（branch-off）で作成（201）、既存 branch は 409 |
| `GET /v1/workspaces/{id}` | Bearer + `sessions:read` | 1件と `ETag`。`id` は実パスから導出する `ws_<16hex>` |
| `GET /v1/session-options` | Bearer + `sessions:read` | 新規セッションの選択肢 `{profiles:[{id,label,provider,model,effort,fast}],defaultProfile,defaultMode}`。HQの `harness/models.json`（`LAA_BRIDGE_MODELS_FILE` で変更可）から読む。manual・別名は出さない。読めなければ503 |
| `GET /v1/sessions?projectId=&workspaceId=&parentId=&requestId=&phase=&archived=&scope=&limit=&cursor=` | Bearer + `sessions:read` | 新しい順の `{items,nextCursor}`。既定ではアーカイブ済みとPaseo worktree（`/.paseo/worktrees/`）のセッションを除く。`archived=only` はアーカイブ済みだけ、`scope=all` と `requestId` は除外なし。`parentId=root` は親なし |
| `POST /v1/sessions` | Bearer + `sessions:write` + `Idempotency-Key` | `{requestId,profile,prompt,workspaceId?,mode?,fast?,name?,parentId?,projectId?,purpose?,completion?,scope?,returnTo?,applyProjectInstructions?,instructions?}` → session（201）、同じ requestId の再送は既存を 200。`workspaceId` 省略か `home` はホーム（`/Users/laa`）で起動する。`mode` は `bypass`（権限確認なし。アプリが既定で送る）か `default`（省略時）、`fast` はOpusとCodexだけ。名前の省略時は依頼の1行目を仮名にし、エージェントが会話名を付けたらそれに追従する（社長が付けた名前は変えない）。`projectId` の共通指示と資料のパスを委譲プロンプト先頭のブロックとして適用し、`instructionVersion`/`instructionHash` を記録。`instructions:null` か `applyProjectInstructions:false` でその回だけ指示を省略 |
| `PATCH /v1/sessions/{id}` | Bearer + `sessions:write` + `Idempotency-Key` | `{favorite?,archived?,name?}`。Bridge側の整理だけで、Paseoの会話は止めず・アーカイブせず・改名しない |
| `GET /v1/sessions/{id}` | Bearer + `sessions:read` | session と `observation:{available,code}`。委譲先が落ちていても記録は 200 で返す |
| `GET /v1/sessions/{id}/events?cursor=&afterSeq=&wait=&limit=` | Bearer + `sessions:read` | `{items,nextCursor,oldestSeq,headSeq,resyncRequired,resyncReason}`。`wait` は最大25秒の long-poll |
| `GET /v1/sessions/{id}/artifacts` | Bearer + `sessions:read` | `{items}`。`log`（journal の JSONL）・`message`（最新の assistant 応答）・`decision`（承認待ち） |
| `POST /v1/sessions/{id}/messages` | Bearer + `sessions:write` + `Idempotency-Key` | `{message,messageId?}` → 202。実行中・承認待ち・停止中は 409 |
| `POST /v1/sessions/{id}/stop` | Bearer + `sessions:write` + `Idempotency-Key` | 停止を確認して `phase:"stopped"`。未確認は 409 `stop_unconfirmed` |
| `POST /v1/sessions/{id}/resume` | Bearer + `sessions:write` + `Idempotency-Key` | `{message,profile?,requestId?}` → 201 後継 session（`resumedFrom`）。停止確認済みのみ |
| `GET /v1/brain/files?area=&limit=&cursor=` | Bearer + `brain:read` | 許可領域の Markdown ノート一覧（`id,path,area,size,modifiedAt,contentHash,title,status,checked`）。`area` は既定外の領域を明示的に足す |
| `GET /v1/brain/files/{id}?area=` | Bearer + `brain:read` | `{id,path,text,contentHash,etag,size,status,checked}`。領域外・symlink・不存在は 404 |
| `GET /v1/brain/search?q=&k=&area=&adopted=&rerank=` | Bearer + `brain:read` | `laa-brain search` の結果を `{found,matchBasis,results[{path,section,lines,status,relevance,text}]}` で返す。常にローカルのみ。本人の全ノート閲覧には `audience=owner` と専用scope `brain:owner` が必要 |
| `POST /v1/brain/files` | Bearer + `brain:create` + `Idempotency-Key` | `{path,content,onConflict?}` → 201 新規ノート（`id,path,contentHash,size,suffixApplied`）。既存内容は変更しない |
| `GET /v1/brain/gates` | Bearer + `brain:read` | vault・git・Syncthing・空き容量の事前条件（`ok`／`code`） |
| `GET /v1/usage` | Bearer + `usage:read` | CodexBar proxy の利用枠・残高を `{items,nextCursor}` で返す。欠測は `unavailable`＋`value:null`、proxy が5秒を超えたら直前の成功値を元の `observedAt` で返す |
| `GET /v1/mac/status` | Bearer + `usage:read` | `host.cpu`・`host.memory`・`host.disk.free` の3件。CPU・メモリは Bridge 内サンプラ（10秒キャッシュ）、空き容量は storage-guard の状態ファイル |

エラーは `{"error":{"code","message","retryable"},"requestId"}`（412 のみ `error.details.current` に現在の Project を返す）。`400` 不正、`401` 未認証・失効、`403` scope・Origin、`404` 範囲外、`405` メソッド、`409` idempotency 競合・名前の固定・worktree 既存、`412` 版不一致、`413` 読取上限超過、`415` テキストでない、`423` 排他中（git同期中・master以外）、`428` `If-Match` 欠落、`429` 試行過多、`500` 内部、`503` 依存（Paseo・Syncthing・vault）停止。`enroll` は応答にトークンを含むため idempotency 台帳の対象外（コード自体が1回限り）。

失敗した要求は原則 idempotency 台帳に `in_progress` のまま残る。同じ key での再送は 60 秒は `409 idempotency_key_in_flight`、その後は `409 idempotency_outcome_unknown` になる。例外は、外部mutationの前に失敗したと実装が明示した場合（入力検証、所有・`If-Match`、Projectの版不一致、Linearの設定解決や資格情報取得など）。この場合は予約を解除し、同じkeyで修正後の再試行を許す。外部mutationを送った後の503・400・404は解除せず、二重実行を防ぐ。保存されていないと確実なStudio依頼作成の `409 studio_work_busy` と、Bridgeが送信前に検出した講評の `400 studio_payload_invalid` も解除する。

## Studio受付（タスク34）

試験端末のペアリングだけで依頼や承認ができないよう、Studio権限は明示した端末にのみ付与する。`grant-studio` は理由が必須で、対象名と付与前後のscopeを表示する。`devices --json` には管理操作の時刻・実行UID・理由と既存権限の有無を記録する（同一UIDで変更可能であり、改ざん不能な監査記録ではない）。記録済み端末への再実行は記録を更新しない。旧版ですでに付与されたscopeは自動では変更せず、記録のない端末に管理操作を行った場合は既存権限として記録する。

`src/studio/backend.mjs` が Studio の受付契約 v1（`~/dev/studio/docs/intake/README.md`）・v2（`~/dev/studio/docs/intake/v2.md`）との境界。`~/Library/Application Support/LAA Creative Studio/Remote/intake.sock` と同所の `intake.json` を同一UID・権限確認後に読み、専用BearerでHTTP/1.1を送る。TCP・Cloudflare・`control.json` は使わない。ENOENT・ECONNREFUSED・401は資格情報を読み直して1回再試行し、停止中の起動は30秒以上間隔を空けて試す。その要求で起動した直後の依頼作成が `studio_work_busy` の場合だけ、1.5秒後に同じ内容を1回再送する。応答不能は503 `studio_not_connected`。トークンはログへ出さない。`test/studio-mock.mjs` と `test/studio-v2.test.mjs` は模擬実装・模擬ソケットであり、実Studioの検証ではない。

作成はStudio側でも依頼UUIDと本文を照合する。同じBridge key・本文の作成再送はStudioに再作成せず、現在の依頼を取得して返す。作成済みでもStudio未接続なら503を返し、受理済みだが現在の状態は未確認とメッセージで伝える。状態の確認は `GET /v1/studio/requests/{id}` を使う。busyの場合は下書き・UUID・本文・Bridge keyを保持し、利用者が同じ内容で再送する。結果不明時は1件取得で照合し、404なら同じUUID・本文と新しいBridge keyで明示的に再送できる。操作の結果不明時は自動再送せず、回答は同じキー・本文、停止は新しいキーで利用者が明示的に再試行できる。Bridge台帳の実行中は409で待ち、60秒を超えて結果不明のままなら、実行済みの可能性を表示して状態確認後の入力し直しを案内する。入力し直しは新しい操作・キーになり、重複拒否はStudio側の状態確認にも依存する。`unreceived` はStudioが45秒以上受け取らなかった queued、再開APIはなく、完了後の再依頼は最新の作品版と新しいUUIDを使う。unsupportedな質問はMacで扱う。Studio本物の受付実装との接続確認は別途必要。

Bridge固有の `studio_payload_invalid` は受付契約の `invalid_request` に相当し、`studio_approval_changed` と `studio_approval_on_mac` は `studio_approval_expired` と同様に回答を受け付けない。Studioのエージェント向けCLI・MCPの `intake.action` はstopのみ、受付ソケットの `POST /api/studio/action` はanswer・stopに対応し、resumeは409。

v2はsnapshotの `contract >= 2` でのみアプリに表示する。catalogのETagは不透明な値として転送し、304は本文を返さない。Studioの初回索引待ち（最大10秒）に備え、catalogのStudioソケット待ちは20秒、アプリのBridge待ちは起動時間も含め45秒とする。作品詳細も同じ待ち時間とする。Studio契約では起動後の初回詳細は最大50件の書き出しのハッシュ計算後に返るが、計算時間の上限は定めていないため、20秒以内に完了する保証はない。講評の結果不明時はStudioのUUID重複排除を利用し、同じUUID・本文と新しいBridge keyで利用者が明示的に再送できる。Studioの同一UUID・異本文は409。Bridgeの同一keyは従来どおり生の本文バイト列を照合するため、アプリは確定した本文を保持する。メディアは `pdf` と `usdz` を含む契約形式のみをMIME・サイズ・Range検証して中継し、保存しない。

## Project と workspace（タスク13）

Project は「ジャンル＋共通指示」で、パスを持たない。workspace は repo / worktree の実体で、`projectId` は作成時に Bridge が記録するだけの任意の紐付け。同じ Project を別の workspace で使えるため、ジャンルと作業場所が混ざらない。

```sh
# Project（作成は owner 名として記録される）。共通指示は本文か ref のどちらか一方
curl -sS -H "Authorization: Bearer $TOKEN" -H 'Idempotency-Key: p1' \
  -H 'content-type: application/json' \
  -d '{"name":"Trading｜環境認識","instructions":"常に日本語で答える。根拠と反証条件を添える。"}' \
  http://127.0.0.1:9137/v1/projects

# 更新は ETag 必須（version 2 を期待）。古い If-Match は 412 で現在の本文を返す
curl -sS -X PATCH -H "Authorization: Bearer $TOKEN" -H 'Idempotency-Key: p2' -H 'If-Match: "1"' \
  -H 'content-type: application/json' -d '{"instructions":"常に日本語で答える。結論を先に書く。"}' \
  http://127.0.0.1:9137/v1/projects/prj_xxxxxxxxxxxx

# 版の比較・復元用（直近10版、本文つき、新しい順）
curl -sS -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:9137/v1/projects/prj_xxxxxxxxxxxx/instructions/versions

# 既存の repo / worktree の棚卸し
curl -sS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:9137/v1/workspaces

# 新規 worktree（Paseo の branch-off。既存 branch は 409）
curl -sS -H "Authorization: Bearer $TOKEN" -H 'Idempotency-Key: w1' \
  -H 'content-type: application/json' \
  -d '{"repoId":"ws_xxxxxxxxxxxxxxxx","worktreeName":"laa-example-40"}' \
  http://127.0.0.1:9137/v1/workspaces
```

- 共通指示は Project ごとに1つで、**本文のみ**（`instructions`、Bridge が保存）。`instructionRef` は受け付けず 400 `instruction_ref_unsupported`（Bridge が任意のファイルを読む経路を作らない。AGENTS.md / PROJECT-RULES.md は各エージェントが自分で読む）。本文は 32 KiB まで、`</project_instructions>` を含む本文は区切りを壊すため 400。
- `instructionHash` は本文そのものの `sha256:`。`instructionVersion` は 0（未設定）から始まり、本文が変わるたびに1つ進む。直近10版を `instructions/versions` で返す。旧レコードが持つ `instructionRef` はメタデータとして返すだけで、読まず・適用せず、`PATCH {instructionRef:null}` か本文の保存で消える。
- `POST /v1/sessions` に `projectId` を渡すと、委譲プロンプトは `<project_instructions project="…" version="…" hash="…">` ブロック＋`<user_request>` の順で構成する。セッションと `session.created` イベントには版と hash だけを記録し、本文は残さない。同じ requestId で指示が変わっていれば 409 `request_id_conflict`。`instructions:null` か `applyProjectInstructions:false` でその回だけ省略できる（inline の指示文は受け付けない）。resume は新しい試行として現在の版を適用する。
- 許可 root は `LAA_BRIDGE_WORKSPACE_ROOTS`（`:` 区切り）で差し替えられる。既定は `~/dev` と `~/.paseo/worktrees`。symlink は辿らず、realpath が root の外になる path は一覧・作成の両方で拒否する。
- 一覧は `git status --porcelain=v2 --branch`（`GIT_OPTIONAL_LOCKS=0`）を1回だけ呼び、branch・ahead/behind・staged/modified/untracked/conflicted を返す。状態は5秒キャッシュ。Paseo daemon が落ちていても一覧は動く。
- 作成は `paseo worktree create --mode branch-off` のみ。`git worktree remove`・`archive`・`--force`・rename は実装しない。Paseo が失敗したら 503 を返し、既存の worktree には触らない。作成後の path が許可 root の外なら 503（記録もしない）。
- `projectId` の紐付けは `workspaces.json` に残る。worktree を消してもこの記録は自動削除しない（削除 API を持たない方針に合わせる）。

### 検証

```sh
cd bridge
npm test    # fake adapter と fake state で契約を固定
LAA_BRIDGE_URL=http://127.0.0.1:9137 LAA_BRIDGE_TOKEN=… \
  LAA_BRIDGE_VERIFY_WORKSPACE=ws_… node scripts/verify-project-instructions.mjs
```

`verify-project-instructions.mjs` は Project 作成 → 編集 → 古い `If-Match` の 412（現在の版・ETag・本文）→ 版履歴 → 実セッションへの適用 → 停止を1回で回す。`ok:true` は「セッションが同じ版/hash を記録」「応答が指示ヘッダの hash を返す（＝ブロックが委譲プロンプトに届いた）」「journal に版はあるが本文はない」の3つが揃った時だけ。どれか欠ければ終了コード1。2026-10-29 に loopback で実測: 作成 201（`instructionVersion` 1）、編集 200（2）、stale 412 の `details.current` に版2・ETag `"2"`・本文、履歴2件（本文つき）、セッションは `instructionVersion=2` と hash を記録し、DSH の応答が指示ヘッダの hash（71文字）をそのまま返した。journal に本文は入らず、版と hash だけ。検証用の端末は失効、Project・セッション・作業用 worktree は削除し、Bridge が起動した Paseo agent は `paseo archive` で退避した。

## Drive（一覧・metadata・Range配信）

`/v1/drive/files` reads the Google Drive API through `src/drive/google.mjs` and
shared runtime Google OAuth. The desktop mount adapter has been removed. Read
routes require `media:read`; uploads require opt-in `media:write`.

- My Drive, shared drives, shared-with-me, recent and starred use Google IDs,
  opaque pagination and escaped full-text/folder queries.
- Images and PDF use bounded previews; Office uses native Quick Look on iPhone.
  Google documents export to PDF. Media streams authenticated Range requests.
- Uploads use device-bound resumable sessions. `GET /v1/drive/uploads/<id>` queries
  Google's committed offset with an empty `PUT Content-Range: bytes */<size>`.
  After a lost chunk/final response the phone queries before resending, retaining
  the session so the user can resume after a connection failure.
- Reads manually follow at most three redirects to explicitly allowed Google
  content hosts. Arbitrary hosts and write redirects are refused before following.
- No File Provider mount or macOS Full Disk Access change is required. Google
  consent, device write grants and live verification remain parent actions.

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

### 社長のLinearタスク（`/v1/linear-owner-tasks`）

Workタブは社長本人のLinear課題だけを扱う。team（key BUS、name LAA）、owner id、Todoの状態はアカウントから解決し、クライアントからteam・担当・状態を受け取らない。通常一覧は未完了かつ本人担当・委譲なし、`?archived=only` は本人担当のアーカイブ一覧。`includeArchived` で取得し、どちらも `trashed:true` を除く。詳細も本人担当・委譲なし・ゴミ箱以外に限る。

作成はクライアント生成のUUID v4を `id` に使う。同じUUID・同じ内容の再送は既存課題を返す。PATCHとarchive/restoreは、最後に読んだ `updatedAt` を `If-Match` に要求する。欠落は428、不一致は412。PATCHは題名・説明・期限・優先度だけを扱い、アーカイブ済みは409を返す。

画面の削除は確認後に `POST /{id}/archive` で `issueArchive`、戻す操作は `POST /{id}/restore` で `issueUnarchive` を呼ぶ。担当・状態は変更しない。`success:true` を成功根拠とし、不明時は本人担当・ゴミ箱以外の課題を再読取して目的のアーカイブ状態と一致した場合だけ成功にする。`null`・ゴミ箱・壊れた応答を成功根拠にしない。旧DELETEとcompleted指定は受け付けない。

## 社長タスク（`/v1/owner-tasks`）

計画 `work/laa-linear-app-20261101/PLAN-TASKS.md` の M1・M4。社長タスクの正本を Bridge が持ち、iPhone と CLI が同じ保存サービスを使う。契約（端点・JSON・エラー・CLI の終了コード・取込み・バックアップと復元）は [docs/owner-tasks.md](docs/owner-tasks.md)。Linear はエージェント課題の正本として残し、`/v1/tasks` の読取り専用表示はそのまま。

| method / path | 認証 | 応答 |
|---|---|---|
| `GET /v1/owner-tasks?status=&limit=&cursor=` | `tasks:read` | `{items,nextCursor,total,counts,filter,observedAt}`。`items` は要約（本文・リンクなし） |
| `GET /v1/owner-tasks/{id}` | `tasks:read` | タスク1件 + `ETag` |
| `POST /v1/owner-tasks` | `tasks:write` + `Idempotency-Key` | 201 + タスク + `ETag` |
| `PATCH /v1/owner-tasks/{id}` | `tasks:write` + `Idempotency-Key` + `If-Match` | 200 + タスク + `ETag`。欠落 428、不一致 412（`details.current`） |

| 項目 | 決定 | 理由 |
|---|---|---|
| 状態 | `todo` / `doing` / `done` / `canceled` の4種。物理削除は無い（取消は状態）。完了チェックの往復と題名・メモ・期限のその場編集は `PATCH` だけで行う（契約 §5.5） | 親の決定。取消から戻せる。専用の端点を増やさない |
| 並び | 未完了を先に、期限の近い順、期限なしは更新の新しい順。完了・取消は後ろ。`status=open\|closed\|all\|<list>` で除外 | 親の決定。iOS は `counts` で折りたたみの件数を出す |
| 保存 | `<stateDir>/owner-tasks.json` の1ファイル（0700/0600）。タスク・操作台帳・取込み対応表を同じ1回の原子的置換（tmp → fsync → rename → ディレクトリ fsync）で確定する | データと台帳が食い違う瞬間を作らない。`state.json` の7日台帳は二重予約しない |
| 台帳 | 成功した操作だけを残す（検証拒否と 412 は何も書いていないので記録しない）。端末＋鍵＋正規化本文で照合し、同じ再送は記録済みの結果、別本文は 409。7日で tombstone に畳み、以後は 410 | 再送で二重作成しない。成功を「未送信」と判定しない |
| ロック | 持ち主の pid が生きていれば待ち、死んでいれば回収する。読めないロックでは書込みを止める | 経過時間だけで生存中の writer から奪わない |
| 消失 | データが無い・壊れている時は空で作り直さない（マーカー `owner-tasks.initialized` と 503）。まだ一度も保存していない時だけ空の一覧を返す | 正本を黙って初期化しない |
| 権限 | 既存の `tasks:read` / `tasks:write`。新しいペアリング・権限追加は要らない | 親の決定 |
| 取込み | Linear は固定の `query` だけ（mutation なし）。dry-run は manifest を 0600 で書き `contentHash` を出すだけ。実行は承認ハッシュを照合し、直前に再取得して照合し、1トランザクションで作る。同じ manifest の再実行は結果を返す | 実データの dry-run と承認は親。実装担当は fixture と模擬応答だけ |

```sh
laa-bridge tasks add --request-id r1 --input - --json <<'JSON'
{"title":"契約内容を確認する","dueDate":"2026-11-05"}
JSON
laa-bridge tasks list --status open --json
laa-bridge tasks get --id <uuid> --json
laa-bridge tasks update --id <uuid> --if-match 1 --request-id r2 --status doing
laa-bridge tasks status --json
laa-bridge tasks import-linear --dry-run --assignee <linear-user-id>
laa-bridge tasks import-linear --manifest <file> --approve <contentHash>
laa-bridge tasks backup --keep 14
laa-bridge tasks restore --from <snapshot> --to <dir>
```

長い本文は `--input -`（標準入力）で渡し、コマンド履歴・プロセス引数へ残さない。書込みは `--request-id` が必須で、再試行でも同じ値を使う。終了コードは 0 適用/再送、1 想定外、2 引数、3 対象なし、4 競合、5 入力拒否、6 保存先、7 Linear 側。

日次バックアップの launchd 追加、Mac 外の保存先の採否、実アカウントでの dry-run と取込み承認、`docs/laa/BRIDGE.md`・`FEATURE_MAP.md` への追記、Bridge の再起動は親の作業（契約 §13）。バックアップは `tasks backup` が14世代を既定で残し、`tasks restore` で別ディレクトリへ戻して件数・最大 revision・最新 updatedAt を読み戻す。

検証: `test/owner-tasks-{store,api,cli,backup,import}.test.mjs`（67 tests）。実 Linear・実データ・資格情報・シミュレーターは使わず、loopback の模擬 GraphQL と fixture だけで、送る文書が `query` のみであることも検査する。復元試験は別ディレクトリへ戻して全タスクと台帳の一致を確かめる。

## Session（`/v1/sessions`）

ROADMAP 14。実体は既存の Mac 委譲経路 `/Users/laa/.local/bin/laa-personal-agent`（= `hq/harness/personal_agent_bridge.mjs`）で、Bridge は JSON を stdin に渡して1操作ごとに1プロセス起動する（約0.5秒）。Paseo SDK を直接使わないのは、CLI 0.11.4 と daemon 0.12.0 の差（BASELINE §2）と、requestId の冪等性・実 provider/model/effort の照合・停止中や承認待ちへの送信拒否を既存ラッパーが既に持っているため。**動く経路を1本だけ使い、二重実装しない**。

### 同一性と二重実行防止

- `ses_<16hex>` は `sha256("laa-bridge|" + requestId)` の先頭16桁。委譲先の requestId も `laa-bridge-<sha256(requestId)>` で決まる。したがって、Bridge が応答を返す前に落ちても、**同じ requestId + 新しい Idempotency-Key** で再送すれば、委譲先は同じ agent を返し（`reused`）、Bridge は同じ session を 200 で返す。新しい agent は作らない。
- requestId は要求内容（profile・workspace・parent・prompt・適用した共通指示の版と hash など）に束縛する。同じ requestId で内容が違えば 409 `request_id_conflict`。同じ Idempotency-Key で内容が違えば従来どおり 409 `idempotency_key_conflict`、実行中は 409 `idempotency_key_in_flight`、60秒を超えた未完了は 409 `idempotency_outcome_unknown`（自動再実行しない）。
- 作成・送信・停止・再開はすべて `Idempotency-Key` 必須。送信の `messageId` は省略時に Idempotency-Key から導出するので、Bridge と委譲先の重複判定が一致する。

### 記録する値

`profile`（要求した名前）、`requested`（委譲先が解決した provider/model/effort）、`observed`（agent が実際に報告した値と `sources`）、`runtimeVerified`、`modelCheck`、`parentId`、`requestId`、`workspaceId`、`cwd`、`projectId`、`instructionVersion`・`instructionHash`・`instructionsApplied`（適用した共通指示の版と hash。本文は持たない）、`delegateSessionId`。**要求した model を書き換えたり、別 profile に代替したりしない**。resume で別 profile を渡すと 400 `model_change_rejected`。

Paseo の会話名（title）は `Project名｜セッション名`、Project なしならセッション名（親があれば既に「子｜」が付く）。`adapter.create` の `title` として `laa-personal-agent` へ渡し、daemon が「Origin / owner: laa-bridge」ではなく作業名を表示する。title は requestId の同一性判定（digest）に含めないので、名前の変更は新しい要求にならない。

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

本人UIの `audience=owner` は、認証済み端末にoperatorがopt-in付与した `brain:owner` が必須。値だけを指定した通常トークンは403で拒否する。本人一覧は全領域の非隠しMarkdownと競合コピーを含み、`.trash`・`.obsidian`・隠し項目・symlinkを除く。検索はモデルを使わない字句検索。通常要求の領域制限は以下のとおり維持する。

ROADMAP 25。タスク24の決定（`docs/laa/BRAIN-WRITE.md`）どおり、**既存内容の置換（`brain:write`）は提供しない**。提供するのは一覧・取得・検索と、**新規パスの作成だけ**（`brain:create`、O_EXCL、上書き経路なし）。実装は `src/routes/brain.mjs` と `src/brain/`（policy / vault / gates / journal / search）。

| 項目 | 決定 | 理由 |
|---|---|---|
| 領域 | 領域判定は `laa-brain` が読む `policy.json` をそのまま使う（既定 `/Users/laa/.local/share/laa-plugins/dev-main/laa-jev/brain/policy.json`、`LAA_BRIDGE_BRAIN_POLICY` で変更可）。既定は policy の default 領域のみで、`old`・`Inbox`・`Sources`・`Journal`・`Trading/研究資料`・`Trading/Reviews`・`Attachments`・`Templates`・未分類は `?area=` で明示した時だけ足す | 検索CLIと別の一覧を持つと、CLIが検索しないノートがアプリに出る。取り違えを二重実装しない |
| 検索 | `laa-brain search --json` を1検索1プロセスで呼び、結果を封筒へ写す。**常に `--no-jev`**（ローカルのみ）。`rerank=1` でもモデルへ送らない | 既存の検索経路を再利用する。電話からの検索が既定でBrain抜粋を外部モデルへ送る新しい経路にならないようにする。応答は `matchBasis` と `relevanceStatus` を保持し、未判定を根拠にしない |
| 取得 | `id` は `bf_` + base64url(vault相対パス)。使う時に再検証する（NFC・`..`なし・`.md`・隠し/予約名/競合コピー拒否・realpath一致）。symlinkは辿らず404 | パスを不透明IDにしても検証を省かない |
| 作成 | 本文はそのまま書き、書いたバイト列の SHA-256 を返す。`path` は作成許可prefix（既定 `Inbox/`、`LAA_BRIDGE_BRAIN_CREATE_PREFIXES`）内のみ、親フォルダは既存のみ。名前衝突は既定 `onConflict:"suffix"`（`Note 2.md` を O_EXCL で確保）で、`"reject"` なら 409 `path_exists`。rename・上書き・切詰め・削除の経路は無い | BRAIN-WRITE §7「新規pathのみ・unique name・RENAME_EXCL・journal付き」 |
| 事前条件 | 空き容量64MB以上、gitが `master` かつ `index.lock`/rebase/merge/cherry-pick 無し（423）、Syncthing folder が paused でなく `errors`/`pullErrors` が0（503）。判定は `GET /v1/brain/gates` で見える | §4-2・§5。`state` 語彙は未確定（§8）なので、新規作成では scan 中を理由に拒否しない（CAS窓が無いため） |
| journal | `~/.local/state/laa-bridge/brain-create/journal.jsonl`（0600）へ `intent` を fsync してから vault を触り、`committed`/`aborted` で閉じる。本文は残さず path・hash・size・requestId・deviceId のみ。書けない時は vault を触らず503 | §4-5。vault外に置くのでSyncthingに書き換えられない |
| scope | `brain:read` は既定付与。`brain:create` は**既定に含めない**（`laa-bridge pair --scopes brain:read,brain:create`）。§9 の初期集合を変えず、BRAIN-WRITE §7 が「安全」と言うのは作成経路だけのため | 端末ごとのopt-in。`brain:write` は引き続き未付与・未実装 |

```sh
# 一覧（既定領域）と、Inboxを明示的に足した一覧
curl -sS -H "Authorization: Bearer $TOKEN" 'http://127.0.0.1:9137/v1/brain/files?limit=20'
curl -sS -H "Authorization: Bearer $TOKEN" 'http://127.0.0.1:9137/v1/brain/files?area=inbox'

# 検索（常にローカルのみ）
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

ROADMAP 09。契約は `docs/laa/USAGE.md` §4、応答例は `docs/laa/fixtures/usage/`。実装は `src/routes/usage.mjs` と `src/usage/`（items / proxy / feed / host）。読取専用で `usage:read` だけを要求し、資格情報・請求データ・provider の URL・cookie・エラー原文は返さない。

| 項目 | 現在の契約 |
|---|---|
| 利用枠・残高 | ローカルproxy `/widget` の自動取得値を返す。手動確認のみの値は `not_auto` で数値なし |
| 背景取得 | Bridgeが定期的に取得し要求は待たない。取得結果はメモリのみで、失敗・再起動時は消える |
| 鮮度 | provider取得時刻とfeed取得時刻の古い方から最大10分。期限、reset、失敗、未来時刻では数値とdetailを返さない |
| API使用額 | Anthropic従来Cost APIとOpenAI Costs APIの今日・今月。日付はUTC、取得時刻と各社の反映遅れの説明を分ける。管理者鍵が無ければ `not_configured` |
| CPU・メモリ | Bridgeプロセス内サンプラ、10秒キャッシュ。非Darwin・失敗は数値なし |
| 空き容量 | storage-guardの状態ファイルを読むだけ。26時間超はstale、欠測は数値なし |

```sh
curl -sS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:9137/v1/usage
curl -sS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:9137/v1/mac/status
```

`items[]` は `{id,kind,label,value,unit,source,observedAt,availability,stale,estimated,expired,nullReason?,detail?}`。`availability:"unavailable"` の時だけ `value:null`・`nullReason` が付き、`observedAt` は null になる。`availability:"available"` は `value` が数値（0 も実値）。`detail` は quota=`{windows[{label,remainingPercent,resetsAt,windowMinutes?}]}`、balance=`{currency,components[]?,expiresOnUtc?}`、credits=`{renewsAt?,grantedAmount?,monthlyGrantedAmount?,dailyRemaining?,dailyGrantedAmount?}`、usage=`{periodDays,models[{model,inputTokens,outputTokens}]}`、CPU=`{windowSeconds,userPercent,systemPercent}`、メモリ=`{totalBytes,availableBytes,swapUsedBytes?}`、disk=`{volume,totalGb,level?,findings[]}`。

検証: `npm test` はHTTP認証、取得失敗、期限、背景取得と射影をfixtureで確認する。実接続は別途 `node bridge/scripts/verify-usage.mjs` で確認する。

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
cd bridge && npm test        # node --test "test/**/*.test.mjs"（405 tests、約18秒。Drive・sessions・brain・usage・Linear owner tasks・社長タスクはfakeアダプタで検証）
```

CI は `.github/workflows/laa-bridge.yml`（ubuntu-latest、Node 24、依存導入なし）が `bridge/**` の変更時に実行する。macOS ランナーは使わない。

## セキュリティ境界と限界

- ループバックの別プロセスを信頼境界とみなさない。同一 UID は state・監査に触れ得る。
- Tailscale の到達性は認証ではない。ACL とトークンの両方で絞る。TLS は Serve が終端する。
- ログは requestId・method・path・status・deviceId・エラーコードのみ。トークン・コード・body は残さない。
- 実装していない: レート制限の永続化（メモリ内・enroll のみ）、監査ファイル、全体 `/v1/events` stream、GUI 排他、Brain の既存内容の書換え（`brain:write`）。Brainは新規作成のみで、削除・rename・移動・フォルダ作成を持たない。git の未解決競合は `index.lock`/rebase/merge/cherry-pick のマーカーで判定し、マーカーの無い未解決indexまでは見ない。
- `/v1/tasks` は Linear の全非アーカイブ課題を 1 リクエスト最大 500 件まで読み、フィルタとページングは Bridge 側で行う。500 件を超えると `sources[].truncated = true`。
- Drive: マウントを読取専用で扱い、ルート外とシンボリックリンクを拒否する。macOS権限と実データでの再生は未確認。書き出し・共有設定・削除は扱わない。
- workspace の一覧は root 配下を毎回 walk する（深さ3、4000 entry、status 5秒キャッシュ）。巨大な root を許可すると遅くなるので、`LAA_BRIDGE_WORKSPACE_ROOTS` は用途の狭いディレクトリにする。

## 未対応（後続タスク）

iOS クライアント、`/v1/sessions/{id}/reply`（承認・質問への回答はタスク15）、`/v1/events`（セッション横断）、`/v1/jobs`、GUI lease、Brain の既存ノート編集（`brain:write`。§9未決4の実証まで提供しない）、DriveのWorkspace文書export、Linearの一般課題への書込み（実装済みは社長本人の `/v1/linear-owner-tasks` の作成・更新・アーカイブ・復元だけ）。Kanban の読取は親が認証済みラッパーを承認するまで無効。社長タスクの日次バックアップの定刻実行と Mac 外の保管は親が決める。

Project 側の残り: 端末をまたぐ「どの端末がどの Project を見られるか」の個別付与（今は `sessions:read/write` の範囲内で全 Project）、自動命名の生成器そのもの（Bridge は `nameSource` の規則だけを持つ）。共通指示は本文の保存・版管理・適用まで実装済みで、外部ファイル参照は持たない。

指示ファイルAPIは独立レビューまで既定で無効（ルート未登録）。アプリの編集画面も `LAA_INSTRUCTION_EDITOR` が未定義のため無効。専用scopeは自動付与しない。対象端末を確認して `laa-bridge grant-instructions <device-id> --reason <reason>` で明示付与する。保存は最終再照合後のatomic renameだが、ロック非参加の外部編集がその間に書いた場合の競合は完全に防げない。バックアップはBridge stateの `instruction-backups/`（0600）に残る。

### Google Drive and Calendar

Both adapters share `src/google/connection.mjs`, including one in-memory refresh
and the existing runtime credential helper. Helper JSON remains `client_id`,
`client_secret`, `refresh_token`, optional `calendar_id`. Nothing is logged or
returned from helper output; tokens never reach the phone. Missing credentials
and authorization errors remain distinct from an empty result.

Drive now uses its API, independent of the desktop mount's macOS permission.
`GET /v1/drive/files?view=my|shared|sharedWithMe|recent|starred` retains existing
paging, metadata, thumbnail, export and Range contracts. Search in My Drive spans
all accessible files rather than only the root. Google documents export to PDF
(up to Google's 10 MB limit); binary content streams without whole-file buffering.
`POST /v1/drive/uploads` and `PUT /v1/drive/uploads/<id>/chunks/<offset>` require
opt-in `media:write` and idempotency keys. Upload sessions are device-bound,
expire after one hour and accept at most 4 MiB per chunk. Status queries reconcile
lost acknowledgements before resending; completed status remains available until expiry.

Calendar list and event/detail reads require `calendar:read`. Day/week/month/agenda
ranges span up to 42 days. Create/PATCH/DELETE require separate `calendar:write`;
etags protect edits and deletes, and Bridge idempotency protects retries. Expanded
instances and a recurring master have different IDs. The editor confirms attendee
notifications before saving. No device gains these writes by default.

The parent provisions additional consent for `drive.readonly`, `drive.file`,
`calendar.events`, and `calendar.calendarlist.readonly` under
`https://www.googleapis.com/auth/`. `drive.file` may not permit uploads to an
existing folder until it has been authorized for this app; root uploads remain
available. Do not reuse another connector's OAuth credentials.

Popup reminders use Google defaults/overrides, a 30-second non-overlapping poll
and shared `notifyOwner`; email reminders stay with Google. A 24-hour catch-up window
recovers unsent reminders after restart, sleep or upstream errors. Enable polling only
after parent setup (`LAA_GOOGLE_REMINDERS_ENABLED=1`). Delivery dedupes on calendar,
instance, start and reminder offset, persisting only successful deliveries.
Notification links are `laa://today/events/<id>?calendar=<calendarId>`.
