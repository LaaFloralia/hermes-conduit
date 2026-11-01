# 社長タスク（owner-tasks）契約 v1

2026-11-01 / Bridge 担当（branch `laa/owner-tasks-bridge`）/ 計画 `PLAN-TASKS.md` M1・M4

社長タスクの正本は Mac の Bridge が持つ。iPhone（iOS 担当）とエージェントの CLI は同じ保存サービスを使う。Linear はエージェント課題の正本として残し、`/v1/tasks` の読取り専用表示はそのまま。本書は新しい端点と CLI の契約だけで、既存の端点・scope・認証・`state.json` の台帳は変えない。

**この文書が iOS と CLI の唯一の契約**。実装と食い違ったら、実装を直すか、この文書を直して親へ報告する。両方を黙って変えない。

## 0. 親の決定（計画からの変更点）

1. 状態は `todo` / `doing` / `done` / `canceled` の4種。**物理削除は無い**（取消は状態）。取消から他の状態へ戻せる。
2. 同じ `Idempotency-Key`・同じ本文の再送には記録済みの結果を返す。`by-key` 照合と `abandon-unsent` の端点は作らない。結果確認は元の `POST` / `PATCH` の再送に統一する。
3. 一覧の既定の並び: 未完了（`todo`・`doing`）を先に、期限の近い順、期限なしは更新の新しい順。完了・取消は後ろ。`status` クエリで除外できる。
4. 正本なので、日次の世代バックアップと Mac 外の候補、復元手順を持つ（§11）。

## 1. 範囲

| すること | しないこと |
|---|---|
| 社長タスクの作成・一覧・詳細・部分更新・状態変更・期限解除・リンク | 物理削除、通知、繰返し、優先度、担当、プロジェクト、サイクル、ラベル、コメント、添付 |
| 端末ごとの認証と `tasks:read` / `tasks:write` の検証 | 新しい scope、新しいペアリング、権限の自動付与 |
| Linear からの一度限りの取込み（読取りのみ） | Linear への書込み（mutation）、双方向同期、旧課題の更新・削除 |

社長タスクとエージェント課題は別の一覧。`/v1/tasks`（Linear の読取り専用）はそのまま残し、社長タスクを混ぜない。移行済みの Linear 旧記録も混ぜない。

## 2. 保存と権限

- 保存先: `<stateDir>/owner-tasks.json`（既定 `~/.local/state/laa-bridge/owner-tasks.json`、`LAA_BRIDGE_STATE_DIR` で変更）。
- 同じディレクトリに初期化マーカー `owner-tasks.initialized`、ロック `owner-tasks.json.lock`、バックアップ `owner-tasks-backups/`。
- ディレクトリ 0700、ファイル 0600。**同一 macOS ユーザーのファイル操作は防げない**（改ざん不能な監査記録ではない）。
- データ（タスク・取込み対応表）と操作台帳は**同じ1ファイル**に置き、1回の `write`（tmp → fsync → rename → ディレクトリ fsync）で原子的に確定する。書込みは排他ロックの中で読み・比較・書く。
- ロックは「経過時間」だけで奪わない。ロックの持ち主 pid が生きていれば待ち、期限を超えたら 503。pid が死んでいる時だけ回収する。ロックの内容が読めない時は**書込みを止める**（運用者が確認してロックを消す）。
- データファイルが無い・壊れている・初期化マーカーと食い違う時は**空の正本として作り直さない**。503 を返し、運用者が復元する（§11）。
- 例外は「まだ一度も保存していない」状態（データもマーカーも無い）。この時 `GET` は空の一覧を返し（404 は詳細だけ）、読み取りでファイルを作らない。最初の `POST` がデータとマーカーを作る。
- 本文（題名・メモ）はログ・要求履歴・冪等記録へ複製しない。台帳が持つのは鍵と主体のハッシュ、要求指紋、対象 UUID、版、時刻、状態だけ。

## 3. 認証・scope・ヘッダー

既存の端末認証（`Authorization: Bearer <token>`）と scope をそのまま使う。

| 端点 | scope |
|---|---|
| `GET /v1/owner-tasks`、`GET /v1/owner-tasks/{id}` | `tasks:read` |
| `POST /v1/owner-tasks`、`PATCH /v1/owner-tasks/{id}` | `tasks:write` |

| ヘッダー | 必須 | 意味 |
|---|---|---|
| `Authorization: Bearer …` | 全端点 | 端末トークン |
| `Idempotency-Key` | `POST`・`PATCH` | 1–200 文字の `A-Z a-z 0-9 . _ : -`。**1要求に1つ。再試行では同じ値**。端末 ID と組で照合する |
| `If-Match` | `PATCH` | `"<revision>"`（強引用符つき）。引用符なしの数字も受け付ける。`W/"3"` は 400 |
| `content-type: application/json` | `POST`・`PATCH` | 本文は JSON オブジェクト |

応答ヘッダー:

| ヘッダー | 付く端点 | 意味 |
|---|---|---|
| `ETag: "<revision>"` | 詳細・作成・更新の 200/201 | 現在の版 |
| `Idempotency-Replayed: true` | 再送の 200/201 | 台帳の記録を返した（新規適用していない） |
| `x-request-id` | 全応答 | 既存どおり |

本文の上限は既存の 64 KiB。これを超える要求は `400 payload_too_large`。

## 4. タスクの形

```json
{
  "id": "e0a3b11b-3d95-4b12-ad66-8d34811f1501",
  "title": "契約内容を確認する",
  "memo": "確認する内容。Markdown の原文をそのまま保持する。",
  "status": "todo",
  "dueDate": null,
  "source": "owner",
  "links": ["https://example.com/reference"],
  "createdAt": "2026-11-01T00:00:00.000Z",
  "updatedAt": "2026-11-01T00:00:00.000Z",
  "revision": 1
}
```

| 項目 | 型 | 規則 |
|---|---|---|
| `id` | UUID | 作成側が送信前に予約できる。省略時は Bridge が v4 を採番。全保存先で一意 |
| `title` | string | 必須。前後の空白を除いて 1–500 文字。改行・制御文字を含まない |
| `memo` | string | 0–20,000 文字。Markdown 原文を保持し、切らない。NUL を含まない |
| `status` | string | `todo` / `doing` / `done` / `canceled`。取消から戻せる |
| `dueDate` | string \| null | `YYYY-MM-DD` の実在する日付、または `null`。時刻・通知は無い |
| `source` | string | `owner` / `agent` / `linear_import`。作成経路で決まり、更新では変えられない |
| `links` | string[] | 0–20 件。各 2,048 文字以内の絶対 `http`/`https` URL。資格情報（userinfo）を含まない |
| `createdAt` | ISO 8601 UTC | 作成時刻（ミリ秒）。表示は任意 |
| `updatedAt` | ISO 8601 UTC | 更新時刻（ミリ秒）。取込み直後は Linear の更新日時 |
| `revision` | integer | 1 から。内容が変わるたびに +1。`If-Match` と `ETag` の値 |

- 社長に見せる7項目は `title` `memo` `status` `dueDate` `source` `links` `updatedAt`。`id`・`createdAt`・`revision` は照合のための内部情報。
- **一覧の `items` は要約**（`id` `title` `status` `dueDate` `source` `createdAt` `updatedAt` `revision`）で、`memo` と `links` を含まない。本文とリンクは詳細（`GET /v1/owner-tasks/{id}`）で読む。1ページが数MBにならないようにするため。
- `source` の既定は呼出し元で決まる: HTTP `POST` は `owner`、CLI `tasks add` は `agent`。取込みは `linear_import`。
- 本文の意味は解釈しない。題名・メモの内容で並びや分類を変えない。

## 5. 端点

エラー封筒は既存と同じ `{"error":{"code","message","retryable":true|false,"details"?},"requestId"}`。成功は `{"data":…,"requestId"}`。

### 5.1 一覧 `GET /v1/owner-tasks`

クエリ:

| 名前 | 既定 | 値 |
|---|---|---|
| `status` | `all` | `all` / `open`（`todo`+`doing`）/ `closed`（`done`+`canceled`）/ 4状態のカンマ区切り（例 `todo,doing`） |
| `limit` | 50 | 1–200 |
| `cursor` | 無し | 前回の `nextCursor` |

応答 200:

```json
{
  "items": [ { "id": "…", "title": "…", "status": "todo", "…": "…" } ],
  "nextCursor": null,
  "total": 12,
  "counts": { "open": 10, "done": 1, "canceled": 1 },
  "filter": { "status": "all" },
  "observedAt": "2026-11-01T00:00:00.000Z"
}
```

- `total` は絞り込んだ後の件数。`counts` は絞り込み前の全件の内訳（折りたたみ表示用）。`items` は §4 の要約で、`memo`・`links` は含まない（詳細で読む）。
- `filter.status` は正規化した値を返す（`all` / `open` / `closed` / 重複を除いて並べた状態名のカンマ区切り）。まだ何も保存していない Bridge は `items: []`・`total: 0` の 200 を返す（500 にしない）。
- カーソルは不透明値で、フィルタ集合に束縛し、24時間で失効する。別のフィルタで使うと `400 cursor_filter_mismatch`、壊れていれば `400 cursor_invalid`、期限切れは `410 cursor_expired`（既存 `/v1/tasks` と同じ扱い）。ページの途中で追加・更新があっても、同じカーソルは同じ並びの続きを返す保証はしない（読み直す）。

### 5.2 詳細 `GET /v1/owner-tasks/{id}`

200 でタスク1件と `ETag`。範囲外・不存在・UUID でない id は `404 owner_task_not_found`。

### 5.3 作成 `POST /v1/owner-tasks`

```json
{
  "id": "e0a3b11b-3d95-4b12-ad66-8d34811f1501",
  "title": "契約内容を確認する",
  "memo": "",
  "status": "todo",
  "dueDate": "2026-11-05",
  "links": ["https://example.com/reference"],
  "source": "owner"
}
```

- `title` のみ必須。`id` `memo` `status` `dueDate` `links` `source` は任意（既定 `memo:""` `status:"todo"` `dueDate:null` `links:[]` `source:"owner"`）。
- 201 でタスク全体と `ETag`。同じ `id` が既にあれば `409 owner_task_exists`（`details.taskId`）。
- 未知のフィールドは `400 unsupported_field`（`details.field`）。黙って捨てない。

### 5.4 更新 `PATCH /v1/owner-tasks/{id}`

```json
{ "status": "doing", "dueDate": null }
```

- 指定した項目だけ変える。`title` `memo` `status` `dueDate` `links` が対象。`dueDate: null` は期限の解除。
- `id` `source` `revision` `createdAt` `updatedAt` は受け付けない（`400 unsupported_field`）。1つも項目が無ければ `400 patch_empty`。
- `If-Match` 必須。無ければ `428 precondition_required`、形式が不正なら `400 precondition_invalid`、現在の `revision` と違えば `412 owner_task_revision_mismatch` で `details.current` に現在のタスク全体を返す。
- 200 で更新後のタスク全体と新しい `ETag`。**値が変わらない更新は `revision` を増やさず 200**（無駄な版ずれを起こさない）。
- 更新は `status` を問わず可能（`done` → `todo`、`canceled` → `doing` を含む）。

## 6. 並び

`GET /v1/owner-tasks` の既定の並び:

1. 未完了（`todo`・`doing`）が先、完了・取消（`done`・`canceled`）が後。
2. 各群の中では `dueDate` があるものが先で、日付の昇順。
3. `dueDate` が無いものは `updatedAt` の新しい順。
4. 同値は `id` の昇順（結果を決定的にする）。

`status=open` は 1 の前半だけ、`status=closed` は後半だけを返す。iOS は `counts` で折りたたみの件数を出す。

## 7. 冪等性・競合・再送（クライアントの手順）

台帳は「成功した操作」だけを残す。検証拒否（400）と版不一致（412）は何も書いていないので記録しない。したがって**拒否された要求は、本文を直して同じ鍵で送り直してもよい**（推奨は新しい鍵）。

1. 下書きに UUID を予約し、`Idempotency-Key` を1つ作る。端末の保護領域へ「元の UUID・本文・鍵」を保存してから送る。
2. 応答が無い・タイムアウト・通信断 → **同じ UUID・同じ本文・同じ鍵**で再送する。適用済みなら台帳の記録が返り（`Idempotency-Replayed: true`）、未適用ならそこで初めて適用される。どちらも二重作成しない。
3. `409 owner_task_key_conflict` → その鍵は別の本文で既に成功している。現在のタスク（`details.taskId`）を読み、新しい鍵で作り直す。
4. `409 owner_task_exists` → 予約した UUID は既にある。`GET` で読む（最初の送信が適用された可能性が高い）。
5. `412` → `details.current` と自分の入力を並べて利用者に選ばせ、現在の `revision` で新しい鍵の `PATCH` を送る。
6. `410 owner_task_operation_compacted` → 7日を超えて台帳を畳んだ。`details.targetId` を `GET` して現在値を読む。**再作成しない**。
7. `503 owner_tasks_store_unavailable` → 保存先が使えない。要求と鍵を保持して再試行する。Linear へ代替作成しない。

- 台帳の鍵は `sha256(端末ID + "\n" + Idempotency-Key)`。要求指紋は `sha256(method, path, 端末ID, If-Match, 生body)`。
- 成功した操作の記録は7日後に tombstone（鍵ハッシュ・主体ハッシュ・対象 UUID・版・時刻・結果）へ畳む。tombstone は消さない。畳んだ後の再送は 410 で、成功を「未送信」と判定しない。
- 台帳が満杯（20,000件）・欠落・破損の時は新しい書込みを止める（503）。空の台帳として作り直さない。

## 8. エラー

| HTTP | code | 意味 | iOS の扱い |
|---|---|---|---|
| 400 | `payload_invalid` | JSON でない・オブジェクトでない | 実装の誤り。下書きは保持 |
| 400 | `payload_too_large` | 64 KiB 超 | 入力を分ける |
| 400 | `idempotency_key_required` / `idempotency_key_invalid` | 鍵の欠落・形式 | 実装の誤り |
| 400 | `precondition_invalid` | `If-Match` の形式 | 現在値を読み直す |
| 400 | `field_invalid` | 値が不正（`details.field`） | 該当項目を直す |
| 400 | `unsupported_field` | 未知の項目（`details.field`） | 実装の誤り |
| 400 | `patch_empty` | 更新項目が無い | 実装の誤り |
| 401 | `unauthenticated` / `invalid_token` / `token_revoked` | 既存 | 再ペアリング |
| 403 | `insufficient_scope` | `tasks:write` が無い | 読取り専用として扱う |
| 404 | `owner_task_not_found` | 不明な id | 一覧を読み直す |
| 409 | `owner_task_exists` | 予約 UUID が既存 | 詳細を読む |
| 409 | `owner_task_key_conflict` | 同じ鍵で別の要求 | 新しい鍵 |
| 409 | `owner_task_operation_target_missing` | 台帳の対象が保存先に無い（復元後の不整合） | 親へ報告 |
| 410 | `owner_task_operation_compacted` | 台帳を畳んだ後の再送 | 詳細を読む |
| 412 | `owner_task_revision_mismatch` | 版の食い違い（`details.current`） | 選択してから再送 |
| 428 | `precondition_required` | `If-Match` 欠落 | 実装の誤り |
| 503 | `owner_tasks_store_unavailable` | 保存先が無い・壊れている・ロック中・容量不足（`details.reason`） | 保留にして再試行 |

`details.reason` は `missing`（初期化済みなのにデータが無い）/ `corrupt` / `locked` / `io_error` / `ledger_full`。
未知の code は「確定していない」として保留にし、成功表示にしない。

## 9. CLI

```
laa-bridge tasks add   --request-id <id> (--title <text> | --input <file|->) [--memo <text>]
                       [--status todo|doing|done|canceled] [--due YYYY-MM-DD] [--link <url>]…
                       [--source owner|agent] [--id <uuid>] [--json]
laa-bridge tasks list  [--status all|open|closed|<list>] [--limit N] [--cursor C] [--json]
laa-bridge tasks get   --id <uuid> [--json]
laa-bridge tasks update --id <uuid> --if-match <revision> --request-id <id>
                       [--title <text>] [--memo <text>] [--status <state>]
                       [--due YYYY-MM-DD | --clear-due] [--link <url>]… | --input <file|->
                       [--json]
laa-bridge tasks status [--json]
laa-bridge tasks import-linear --dry-run [--assignee <linear-user-id>] [--include-closed]
                       [--out <file>] [--json]
laa-bridge tasks import-linear --manifest <file> --approve <content-hash> [--json]
laa-bridge tasks backup [--keep N] [--out <dir>] [--json]
laa-bridge tasks restore --from <snapshot> --to <dir> [--allow-live] [--force] [--json]
```

- CLI は HTTP を通らず、Bridge と同じ保存サービス（検証・競合制御・台帳・ロック）を直接使う。主体は固定の `cli`。**`--request-id` は書込みで必須**で、再試行でも同じ値を使う。
- 長い本文は `--input -`（標準入力の JSON）か `--input <file>` で渡す。コマンド履歴・プロセス引数へ本文を残さない。`--json` のとき stdout は1行の JSON だけ。
- `--json` の成功形は `{"ok":true,…}`。失敗形は `{"ok":false,"error":{"code","message","details"?}}` を stdout に出し、`laa-bridge: <code>: <message>` を stderr にも出す（`--json` なしでは stderr だけ）。
- `get` は1件を本文・リンクつきで返す（一覧は要約だけなので、書いた本文を読み戻す経路）。
- `list` の既定出力は1行1件の読みやすい形（`<revision>  <status>  <due|->  <id>  <title>`）。`--json` は HTTP の一覧と同じ形。
- `--input` を使った `add` でも `source` の既定は `agent`（JSON に `source` があればそれに従う）。

終了コード:

| code | 意味 |
|---|---|
| 0 | 適用した、または記録済みの結果を返した |
| 1 | 想定外の失敗（バグ・I/O の想定外） |
| 2 | 引数の誤り（必須の欠落・未知のフラグ・`--if-match` 無し） |
| 3 | 対象が無い（`owner_task_not_found`） |
| 4 | 競合（版不一致、鍵の衝突、取込み manifest の不一致・陳腐化） |
| 5 | 入力の拒否（検証エラー、上限超過） |
| 6 | 保存先が使えない（ロック中・欠落・破損・容量不足） |
| 7 | 取込み元が使えない（Linear の資格情報・到達性・応答不正・ページ欠落） |

## 10. Linear からの一度限りの取込み

読取り専用。既存のエージェント用資格情報（`~/.config/laa/linear-agent-token.sh`）を実行時だけ使い、**GraphQL の mutation を送らない**。固定の `query` 文だけを送り、`mutation`・`subscription` を含む文書は送信前に拒否する。

### 10.1 dry-run

```
laa-bridge tasks import-linear --dry-run --assignee <linear user id> [--include-closed] [--out <file>]
```

`--assignee` は環境変数 `LAA_OWNER_TASKS_LINEAR_ASSIGNEE` でも渡せる（引数履歴に残したくない時）。

1. 指定した assignee ID の課題を、状態を問わず**全ページ**取得する（既定は未完了のみ。`--include-closed` で完了・取消も候補に含める）。担当名の文字列一致やチーム決め打ちはしない。ページ欠落・ループ・権限不足・応答不正は全体を失敗にする（部分的な候補で続けない）。
2. 候補ごとに次を出す: `linearId`（UUID）、`identifier`、`title`、`memo`（description 原文）、提案 `status`、`dueDate`、`url`、`linearUpdatedAt`、`linearState`、除外理由、`taskId`（決定的に導出した予約 UUID）、移行しない情報の印（コメント・添付・プロジェクト・ラベルがある場合）。
3. 状態の提案: `backlog` / `unstarted` → `todo`、`started` → `doing`、`completed` → `done`、`canceled` → `canceled`。判別できない種別は `state_undecided` として**除外**し、親が決める（自動分類しない）。
4. 除外理由: `assignee_mismatch`、`missing_title`、`state_undecided`、`memo_too_large`、`title_too_large`、`due_date_invalid`、`url_invalid`（Linear の URL が https でない）、`already_imported`、`task_id_conflict`。
5. manifest（下記）を 0600 で保存し、`contentHash`（manifest のうち `generatedAt` と `contentHash` を除いた正規化 JSON の SHA-256）と件数を表示する。**作成・更新はしない**。`generatedAt` を除くので、同じ Linear データなら dry-run をやり直しても同じハッシュになり、承認をやり直さずに済む。

manifest:

```json
{
  "format": "laa-owner-tasks-import",
  "version": 1,
  "generatedAt": "2026-11-01T00:00:00.000Z",
  "assigneeId": "…",
  "includeClosed": false,
  "candidates": [
    {
      "linearId": "…", "identifier": "BUS-123", "title": "…", "memo": "…",
      "status": "todo", "dueDate": null, "url": "https://linear.app/…",
      "linearUpdatedAt": "2026-10-30T00:00:00.000Z",
      "linearState": { "name": "Todo", "type": "unstarted" },
      "taskId": "…", "excluded": null,
      "notes": ["comments_not_migrated"]
    }
  ],
  "counts": { "fetched": 12, "selected": 10, "excluded": 2, "undecided": 0 },
  "contentHash": "sha256:…"
}
```

### 10.2 承認と実行

```
laa-bridge tasks import-linear --manifest <file> --approve <contentHash>
```

1. manifest の形式・版・`contentHash` を検証する。`--approve` が `contentHash` と違えば実行しない（終了コード 4）。**コマンドの実行指定だけを承認と見なさない**。
2. 実行直前に候補全体を再取得し、対象 ID の集合と、各候補の `title`・`memo` のハッシュ・状態・期限・`url`・`linearUpdatedAt`・移行しない情報の印を manifest と照合する（保存先に依存する `already_imported` / `task_id_conflict` は比べない）。1つでも違えば**何も書かずに**失敗する（終了コード 4、新しい dry-run が必要）。
3. 選択済み（`excluded: null`）の候補を**1トランザクション**で作る。元 Linear の URL を `links` に入れ、`source` は `linear_import`、`memo` は原文、`dueDate` は元の期限、`updatedAt` は Linear の更新日時。Linear issue ID → タスク UUID の対応を同じ保存単位に残す。
4. 同じ manifest の再実行は記録済みの結果を返し、二重作成しない。別の manifest で既に取り込んだ課題は飛ばし、`alreadyImported` として数える。
5. 旧 Linear の課題は更新・削除しない。コメント・添付・プロジェクト・ラベルは移さない（候補に印を出す）。

## 11. バックアップと復元（提案）

**提案**であり、保存先の採否は親が決める。日次ジョブの導入（launchd の追加）は統合時に親が行う。Bridge の再起動・本番設定はこの branch では変えない。

### 11.1 方式

- `laa-bridge tasks backup` が `<stateDir>/owner-tasks-backups/owner-tasks-<UTC>.json` を書く。スナップショットは `{format,version,createdAt,counts,stateSha256,state}` で、`stateSha256` は `state` の正規化 JSON の SHA-256。
- 取得はロック内の一貫した読み。書込みは tmp → fsync → rename で、書いた後に読み戻してハッシュを検証する。失敗は成功扱いにしない。
- 世代は既定14（日次1回 × 14日）。`--keep` で変更。削除するのは自分の命名規則と `format` に一致するファイルだけ。
- 取込みの実行前にもう1世代取る（親の手順）。まだ何も保存していない Bridge では「保存なし」を返し、成功したふりをしない（終了コード 0、`skipped`）。初期化済みなのにデータが無い時は失敗する（終了コード 6）。
- 実測（2026-11-01、`owner-tasks-store.test.mjs`）: tombstone 2万件で 5,280,180 バイト（5.04 MiB）。1件あたり約 264 バイトで、上限 20,000 件でも単一 JSON として扱える大きさ。
- ローカルの権限は 0700 / 0600。**同一ユーザーからは守れない**。Mac 外へ出す時は必ず暗号化する（`age` など。鍵は 1Password Agents に置き、repo・引数・ログへ出さない）。平文のタスク本文をクラウドへ置かない。

### 11.2 復元手順

```
laa-bridge tasks restore --from <snapshot> --to <dir> [--allow-live] [--force]
```

1. `format`・`version`・`schema` と `stateSha256` を検証する。1バイトでも違えば拒否する。
2. 復元先は明示した `--to` だけ。稼働中の state ディレクトリへ戻すには `--allow-live` が要る。既にデータがある場所へは `--force` が要る。
3. 書込みは tmp → fsync → rename。`owner-tasks.initialized` も同時に置く。書いた後に読み戻し、件数・最大 `revision`・最新 `updatedAt` を表示する。
4. 復元後は Bridge を再起動せずに読める（毎回ファイルを読むため）。**切替後の全体巻戻しは自動でしない**（後に作られたタスクを失う）。問題時は新規書込みを止め、現状とバックアップを保全して親が差分を判断する。

### 11.3 Mac 外の候補

| 候補 | 費用 | 長所 | 短所・残るリスク |
|---|---|---|---|
| 同じ tailnet の MacBook へ `laa-bridge tasks backup` の出力を rsync（既存の Tailscale） | 0円 | 新しい契約・資格情報が不要。すぐ試せる | MacBook が起動していないと失敗する。世代は MacBook 側にも必要 |
| Google Drive（floralia@laa-inc.com）へ暗号化スナップショットを置く | 既存契約内 | 既に使っている保管先 | Drive の OAuth が未認可（BUS-318）。暗号化と鍵の管理が要る |
| Backblaze B2 + restic（または `age` + `rclone`） | 約 $0.006/GB/月（数十 MB なら実質 0円） | 世代・暗号化・遠隔地 | 新しい資格情報とツールの導入が要る。親の承認が要る |
| 外付け SSD へ Time Machine 併用 | 実費（SSD） | オフライン・ランサムウェアに強い | 同じ場所にある。持ち出し運用が要る |

推奨: まずローカル14世代＋MacBook への rsync（新規契約なし）。クラウドは BUS-318 の認可後、暗号化したスナップショットだけを置く。どれも「Mac が動いている間に取り、失敗を成功扱いにしない」を守る。

### 11.4 接続断・失敗時

- 日次ジョブが失敗しても直前の成功世代を消さない。`laa-bridge tasks status` が最終成功時刻・最終スナップショット・件数を出す。
- 保存先の空き容量不足・書込み失敗は成功扱いにせず、終了コード 6 で返す。

## 12. 試験

`cd bridge && npm test`。新しい試験は実 Linear・実データ・資格情報・シミュレーターを使わない（fixture と模擬応答だけ）。

- 保存: 初期化マーカー、欠落・破損・未初期化の拒否、ロックの待ちと死んだ持ち主の回収、読めないロックでの停止、原子的な置換、0700/0600。
- 台帳: 同じ鍵・同じ本文の再送、同じ鍵・別本文の 409、7日後の tombstone、37日後の再送が未送信にならないこと、満杯での停止、tombstone 2万件のサイズ実測。
- API: 作成・一覧の既定の並び・状態と期限の絞り込み・詳細・部分更新・期限解除・状態の往復・版不一致（412 の現在値）・`If-Match` 欠落・未知の項目・上限・scope・失効・64 KiB・カーソル・同時送信。
- CLI: 同じ保存サービスを直接使うこと、`--request-id` 必須、終了コードの区別、HTTP との相互読戻し。
- 取込み: 複数ページ・500件超・所有者混在・未確定分類・期限なし・本文超過・ページ途中の失敗・ループ・承認なし・ハッシュ不一致・承認後の変更・新規課題の混入・同じ manifest の再実行・mutation を送らないこと。
- バックアップ: 世代の保持、別ディレクトリへの復元一致、改ざんの拒否、稼働先への復元の拒否。

## 13. 残件（親の作業）

- 日次バックアップの launchd 追加と実行確認、Mac 外の保存先の採否（§11）。
- 実アカウントでの `import-linear --dry-run`、候補の分類（社長タスク／委譲課題）、実取込みの別承認。最初の dry-run では、未完了の絞り込み（`state.type` の `nin`）と取得件数が Linear の画面と一致するかを確認する。
- `docs/laa/BRIDGE.md`・`docs/FEATURE_MAP.md` への追記（共有ファイルのため親の統合順で行う）。
- Bridge の再起動（`launchctl kickstart -k gui/$(id -u)/com.laa.bridge`）と実機確認。
- 切替時の正本の更新（`hq/AGENTS.md`・`hq/tools/LINEAR.md` などの「社長タスクを Linear に作る」記述）。
