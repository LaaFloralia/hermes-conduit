# 週単位の習慣・禁止習慣（habits）契約 v1

2026-11-14。社長の習慣（続けたいこと）と禁止習慣（減らしたいこと）を週単位で持つ。正本は Mac の Bridge。LAAアプリ（Calendar タブの「Habits」）と AI の CLI は同じ保存サービスを使う。

**この文書がアプリ・CLI・Monet のスキルの唯一の契約**。実装と食い違ったら、実装を直すか、この文書を直して親へ報告する。

## 0. 決定

1. 週は月曜 00:00 から日曜 24:00（`Asia/Tokyo`）。日付はすべて東京の暦日 `YYYY-MM-DD`。
2. 記録は「その日にしたか」の1日1回。週の目標は日数（習慣は「週N日」、禁止習慣は「週N日まで」。0 は「しない」）。
3. Google Calendar とは別物。Google の認可・API・予定を読まず、予定へ書かない。Calendar が未接続・失敗でも習慣は動く。
4. タスク（Linear・社長タスク）とも別。期限・通知・リマインダー・定期処理を持たない。Bridge から社長へ何も送らない。
5. 物理削除は無い。やめる時は保管（`archived`）で、戻せる。
6. Bridge は習慣を自分で作らない。保存前は空。
7. AI の読み書きは、社長が習慣ごとに決めた支援の範囲（`support`）に限る。`off` の習慣は AI の経路へ内容を返さず、AI から変えられない。`support` を変えられるのは社長（アプリ）だけ。
8. 変更は誰が・いつ・何を・なぜ変えたかを残し、アプリの履歴で社長が読める。

## 1. 保存

- `<stateDir>/habits.json`（既定 `~/.local/state/laa-bridge/habits.json`）。ディレクトリ 0700、ファイル 0600。`routes/state-file.mjs` の `createJsonFile`（排他ロック・tmp→fsync→rename）で読み書きする。
- 壊れたファイルを空として作り直さない（500 `state_corrupt` 系のまま返す）。
- その東京の暦日で最初の書込みの直前に、既存の `habits.json` を `<stateDir>/habits-backups/habits-<YYYY-MM-DD>.json` へ複製し、新しい順に30世代を残す。
- 形（`schema: 1`）:

```json
{
  "schema": 1,
  "habits": [],
  "checkins": { "<habitId>": ["2026-11-10", "2026-11-12"] },
  "events": [],
  "ops": { "<key>": { "habitId": "<uuid>", "at": "<ISO>" } }
}
```

`checkins` は習慣ごとの昇順・重複なしの日付。`events` は新しい順に最大2000件。`ops` は作成の重複防止で7日保持。

## 2. 習慣の形

```json
{
  "id": "e0a3b11b-3d95-4b12-ad66-8d34811f1501",
  "kind": "do",
  "title": "ランニング",
  "note": "",
  "weeklyTarget": 3,
  "minutes": 20,
  "minimum": "5分だけ走る",
  "support": "ask",
  "createdAt": "2026-11-14T10:00:00.000Z",
  "createdOn": "2026-11-14",
  "updatedAt": "2026-11-14T10:00:00.000Z",
  "archivedAt": null,
  "archivedOn": null,
  "revision": 1
}
```

| 項目 | 規則 |
|---|---|
| `kind` | `do`（習慣）か `avoid`（禁止習慣）。作成後は変えられない |
| `title` | 前後の空白を除いて 1〜80 文字。制御文字なし |
| `note` | 0〜500 文字。省略は `""` |
| `weeklyTarget` | 整数。`do` は 1〜7、`avoid` は 0〜7 |
| `minutes` | 1回の目安（分）。`null` か 1〜600 の整数 |
| `minimum` | 余力がない日の最小の形。`null` か 1〜80 文字 |
| `support` | `off`（AIに見せない）・`ask`（社長が聞いた時だけ）・`plan`（今日の一手と週の振り返りに含めてよい）。作成時の既定は `ask` |
| `revision` | 習慣ごとの版。項目の変更・保管・復帰で 1 増える。記録（チェック）では増えない |

保存だけに持つ項目: `targets: [{ "from": "<その週の月曜>", "weeklyTarget": N }]`。目標の変更は変更した週から効き、過去の週は当時の目標のまま。応答には出さない。

## 3. 週の見方

`GET /v1/habits?week=YYYY-MM-DD`（その日を含む週。省略は今週。2020-01-01 から今日の366日後まで）

```json
{
  "week": { "start": "2026-11-09", "end": "2026-11-15", "days": ["2026-11-09", "…7日"], "current": true },
  "today": "2026-11-14",
  "timeZone": "Asia/Tokyo",
  "items": [
    { "…習慣の全項目": "", "target": 3, "days": [true, false, true, false, false, false, false], "count": 2, "met": false }
  ],
  "archivedCount": 0
}
```

- 週に出る習慣: `createdOn` がその週の日曜以前で、保管されていないか `archivedOn` がその週の日曜より後。保管した週からは出ない。戻せばまた出る。
- `target` はその週の目標。`met` は `do` なら `count >= target`、`avoid` なら `count <= target`。
- 並び: `do` を先、`avoid` を後。その中は `createdAt` の古い順。

`GET /v1/habits/history?weeks=8`（1〜26、既定 8）: 今週より前の週を新しい順に返す。最も古い習慣の作成週より前は返さない。

```json
{ "weeks": [ { "start": "2026-11-02", "end": "2026-11-08", "items": [ { "id": "…", "kind": "do", "title": "ランニング", "target": 3, "count": 2, "met": false } ] } ] }
```

`GET /v1/habits/archived`: `{ "items": [習慣] }`（保管済み、保管の新しい順）。

`GET /v1/habits/events?limit=50&cursor=`（1〜100）: 変更の記録を新しい順に返す。`{ "items": [event], "nextCursor": "…"|null }`。

```json
{
  "id": "<uuid>", "at": "<ISO>", "actor": "owner", "agent": null,
  "type": "habit.updated", "habitId": "<uuid>", "title": "ランニング",
  "changes": { "weeklyTarget": { "from": 3, "to": 2 } },
  "date": null, "reason": null
}
```

- `type`: `habit.created`・`habit.updated`・`habit.archived`・`habit.restored`・`checkin.set`・`checkin.cleared`。
- `actor`: `owner`（アプリ＝HTTP）か `agent`（CLI）。`agent` の時は `agent`（名前）と `reason` が必須。
- `title` は記録時点の名前。`changes` は変えた項目の前後（`note` は長さだけ `{ "fromLength", "toLength" }`）。記録の `date` はチェックの日付。

## 4. 書込み（HTTP＝社長）

認証は既存の端末トークン。scope は新設しない: 読取り `tasks:read`、書込み `tasks:write`（習慣は社長の計画データでタスクと同じ区分。新しい scope は全端末の付け直しが要る）。

| 端点 | 本文・ヘッダー | 応答 |
|---|---|---|
| `POST /v1/habits` | `Idempotency-Key` 必須（形式は owner-tasks と同じ）。`{kind,title,weeklyTarget,note?,minutes?,minimum?,support?}` | 201 習慣。同じ鍵・同じ端末の再送は 200 と `Idempotency-Replayed: true` で同じ習慣 |
| `PATCH /v1/habits/{id}` | `If-Match: "<revision>"` 必須（引用符なしも可）。変える項目だけ。`archived: true/false` で保管・復帰。`kind` は不可 | 200 習慣と `ETag`。変化なしは版を上げず 200 |
| `PUT /v1/habits/{id}/checkins/{date}` | `{ "done": true|false }` | 200 `{ habitId, date, done, week: { start, count, target, met } }`。同じ値の再送は何も書かない |

エラー（本文は既存の `{ok:false,error:{code,message}}`）:

| 状態 | code | 時 |
|---|---|---|
| 400 | `habit_invalid` | 項目の規則違反・未知の項目（`details.field`） |
| 400 | `habit_week_invalid` / `habit_date_invalid` | 日付の形・範囲 |
| 400 | `habit_date_future` | 今日（東京）より後の日への記録 |
| 400 | `habit_date_before_start` | 作成した週の月曜より前への記録 |
| 400 | `idempotency_key_required` / `idempotency_key_invalid` | 作成の鍵 |
| 404 | `habit_not_found` | 無い ID |
| 409 | `habit_archived` | 保管中の習慣への記録・項目変更（復帰は可） |
| 412 | `habit_revision_mismatch` | `If-Match` が現在の版と違う（`details.revision` に現在値） |
| 428 | `habit_if_match_required` | `If-Match` 無し |
| 403 | `habit_support_owner_only` | AI の経路から `support` を指定 |
| 403 | `habit_support_off` | AI の経路から `off` の習慣を読む・変える |

## 5. CLI（AI の経路）

`laa-bridge habits …`。HTTP と同じサービスを直接呼ぶ。CLI の書込みは常に `actor: agent` で、`--by <名前>`（例 `Monet`）と `--reason <社長の依頼の要約、1〜200文字>` が必須。

```
laa-bridge habits week    [--week YYYY-MM-DD] [--json]
laa-bridge habits history [--weeks N] [--json]
laa-bridge habits events  [--limit N] [--json]
laa-bridge habits add     --by <name> --reason <text> --request-id <id>
                          --kind do|avoid --title <text> --target N
                          [--minutes N] [--minimum <text>] [--note <text>] [--json]
laa-bridge habits update  --id <uuid> --if-match <revision> --by <name> --reason <text>
                          [--title <text>] [--target N] [--minutes N | --clear-minutes]
                          [--minimum <text> | --clear-minimum] [--note <text>] [--json]
laa-bridge habits archive --id <uuid> --if-match <revision> --by <name> --reason <text> [--json]
laa-bridge habits restore --id <uuid> --if-match <revision> --by <name> --reason <text> [--json]
laa-bridge habits check   --id <uuid> --date <YYYY-MM-DD|today> --by <name> --reason <text> [--json]
laa-bridge habits uncheck --id <uuid> --date <YYYY-MM-DD|today> --by <name> --reason <text> [--json]
```

- 読取り（`week`・`history`・`events`）は `support: off` の習慣を除き、`withheld`（除いた件数）だけを返す。`events` も `off` の習慣の記録を除く。
- `add` の `support` は常に `ask`。CLI に `--support` は無い。
- `off` の習慣への書込みは `habit_support_off`。
- `--json` は `{ "ok": true, … }` か `{ "ok": false, "error": { code, message } }`。終了コード: 0 成功、1 想定外、2 使い方、3 見つからない、4 競合・保管中・支援の範囲外、5 入力の規則違反、6 保存先が使えない。

## 6. しないこと

通知・リマインダー・定期実行、期限、連続日数や点数の表示、未達の警告、Google Calendar・Linear・Brain への複製や同期、1日に複数回の記録、物理削除。
