# AI Usage・Mac状態のデータ契約

2026-10-29。タスク05（読取専用の仕様）。実装・接続・設定変更はしていない。根拠は同日の実測（シェル、`curl`のループバック、ログ・JSONの読取り）と [BASELINE.md](BASELINE.md)・[ROADMAP.md](ROADMAP.md)・[BRIDGE.md](BRIDGE.md)。資格情報は読んでいない。数値例は [fixtures/usage/](fixtures/usage/) に置く。

## 1. 結論：指標ごとの正本は1つ

| 指標 | 正本 | 単位 | 鮮度 | 欠測・期限切れ・推計 |
|---|---|---|---|---|
| 利用枠・残量（provider別の窓） | CodexBar → `usage-proxy` `http://127.0.0.1:8081/widget`（version 1） | percent（残り%）、`resetsAt` | providerの`updatedAt`。20分超で `stale` | 窓なし・`available:false` は null。`resetsAt` 経過は期限切れ表示 |
| 残高・クレジット（金額／回数） | 同上（`kind: balance` / `unitCredits`）。`source: verified` は画面確認値 | USD・JPY・AI credits・Flow credits | `updatedAt`（自動更新なし）。期限は `expiresOnUtc` | 期限切れは `expired`。取得失敗は null＋理由 |
| 実利用（トークン・回数） | Hermes dashboard `GET /api/analytics/usage?days=` と `/api/analytics/models` | tokens（int）、sessions、api_calls | 要求時取得（ポーリングしない） | 行なしは null（0にしない） |
| 費用 | 同上。`actual_cost` と `estimated_cost` を分けて返す | USD（float） | 同上 | `actual_cost` が無い行は `estimated`。混在期間は合計を「実額」と呼ばない |
| CPU | **既存収集なし**。Bridge内サンプラ（未実装） | percent | 10秒キャッシュ | 実装まで `unavailable`（0にしない） |
| メモリ | 同上（`host_statistics64`） | bytes（total / used / available / swap） | 同上 | 同上 |
| Mac空き容量 | `laa-storage-guard` の状態ファイル `~/.local/state/laa-storage-guard/status.json` | GB（`free_gb` / `total_gb`）、`level` | `checked_at`。26時間超で `stale` | ファイル無し・不正は `unavailable` |

Console collector（`dev/inventory`）とR2のsnapshotは**正本にしない**。理由は §3。表示用の写しであり、現在は停止している。

## 2. 実測（同日・読取りのみ）

| 対象 | 実測 | 意味 |
|---|---|---|
| proxy `/widget` | HTTP 200、4,708 bytes、`version:1`、`fetchedAt 2026-10-29T04:49:24Z`、`providers` 12件 | 生きている。`updatedAt` は live が数秒前、`verified` は 10/11〜10/23 |
| 同・provider構成 | 12件中 `claude`/`codex`/`opencode-go` は quota、`jev`/`google-cloud`/`claude-api`/`fal`/`gemini` は balance、`magnific`/`google-flow` は unitCredits、`clef` は status、`liquid` は usage | 窓・残高・記録利用が同じ1本のフィードに載る |
| 同・欠測 | 17 ID中 `antigravity`/`deepseek`/`grok-bot`/`refuseless`/`venice` が今回の応答に無い（`venice` は `available:false`「残高を取得できません」） | 欠測は枠ごと落ちる。collectorは欠測IDを `unavailable`「未取得」で埋める仕様 |
| dashboard analytics | `GET http://127.0.0.1:9119/api/analytics/usage?days=7` → **401**（`/models` も401、`/health` は302） | ループバックでも無認証では読めない。Bridgeは専用の読取権限が要る |
| Console（稼働版） | release `4265754` を実行、引数に `--cloud-sync-usage` **なし**、`consoleFeatures.aiUsage: false` | AI Usageの非表示はmaster済み。**R2へのusage同期も同時に止まった** |
| 同・最終同期 | `usage-sync.json` の `lastSuccessAt 2026-10-29T04:50:20Z`、以後の更新なし（プロセス再起動 13:50:41） | R2のsnapshotは「最終同期時点」で凍結。鮮度の根拠に使えるが値の正本ではない |
| storage-guard | `status --json` は **50.7秒**（work 18.98GB等を走査）。状態ファイルは 2,979 bytes、`checked_at`・`free_gb 166.6`・`total_gb 460.4`・`level` | 要求ごとの実行は不可。状態ファイルだけを読む |
| CPU・メモリ | `dev/toolkit`・`dev/inventory` に収集コードなし。`python3` に psutil なし | 新規サンプラ以外に取得元が無い |
| `~/.config/codexbar/usage.json` | `version`・`hooks`・`providers`（`id`/`enabled`/`source`/`cookieSource`）のみ | **設定であり利用値ではない**。BASELINEの「残量」という記述は誤り。読まない |

## 3. 3系統の評価

| 系統 | 残るか | 判定 |
|---|---|---|
| CodexBar＋proxy（8081/8082） | 残る（`com.laa.ai-usage-proxy` は inventory と独立） | 利用枠・残高の正本。表示専用に射影済みの契約（version 1、`fetchedAt` 必須、未来時刻拒否、`unavailable` は null）をそのまま再利用する |
| Console collector → R2 | **usage発行は停止済み**。collector・射影・フィードはコードに残る | 正本にしない。再開は別判断（§6）。仮に再開しても1分遅れの写しで、17 ID固定・表示項目のみ |
| dashboard analytics | 残る（Hermes gateway配下） | 実利用・費用の唯一の取得元。`UsageReport.swift` が既に読む。ただし失敗を0に丸める実装（`int(nil)==0`）なので、Bridge側で null を保持する |
| `laa-storage-guard` | 残る（毎日05:30のlaunchd） | 空き容量の正本。状態ファイルの読取りのみ |

同じ値を2系統から取らない。proxyが落ちたら `unavailable` を返し、dashboardの `model.options` で補完しない（別の窓定義・別の認証で、同じ「利用枠」を名乗れないため）。

## 4. 契約（BRIDGE.md §3・§4に合わせる）

共通：UTF-8、時刻はUTC ISO 8601、成功は `{"data":..., "requestId":"..."}`、一覧は `data.items` と `data.nextCursor`（終端null）。scopeは `usage:read` のみ。認証情報・生の請求データ・providerのURL・cookie・エラー原文は返さない。

`GET /v1/usage` の `item`：

| field | 型 | 意味 |
|---|---|---|
| `id` | string | 安定ID（例 `provider.claude.quota`、`profile.laa-ciel.cost.30d`） |
| `kind` | enum | `quota` / `balance` / `usage` / `cost` |
| `label` | string | 表示名（provider名＋窓名） |
| `value` | number \| null | 値。**欠測は必ず null**（0で埋めない）。`quota` は窓のうち最も残りが少ない percent、`balance` は `amount`、`usage` は対象期間のトークン合計、`cost` は USD |
| `unit` | enum | `percent` / `usd` / `jpy` / `tokens` / `count` / `credits`（mac/statusは `bytes` / `gb`） |
| `source` | string | `codexbar-usage-proxy` / `hermes-dashboard-analytics`（mac/statusは `laa-storage-guard` / `bridge-host-sampler`） |
| `observedAt` | ISO \| null | 取得時刻（proxyはproviderの `updatedAt`、analyticsは要求時刻） |
| `availability` | enum | `available` / `unavailable`（未取得・取得失敗） |
| `stale` | boolean | 鮮度切れ（値は保持して表示） |
| `estimated` | boolean | 費用がHermesの推計（`actual_cost` 無し） |
| `expired` | boolean | 窓の `resetsAt` 経過、または `expiresOnUtc` 経過 |
| `nullReason` | string? | `availability: unavailable` の理由コード（`not_configured` / `fetch_failed` / `unsupported` / `auth_required`） |
| `detail` | object? | `quota`: `windows[{label, remainingPercent, resetsAt, windowMinutes?}]`、`balance`: `currency`・`components[]`・`expiresOnUtc?`、`usage`: `periodDays`・`models[]`、`cost`: `periodDays`・`actualUsd`・`estimatedUsd` |

`GET /v1/mac/status` の `item` は同じ形で `kind` が `host.cpu` / `host.memory` / `host.disk`。単位は `percent` / `bytes` / `gb`。`detail` に `totalBytes`・`swapUsedBytes`・`volume`・`level`・`findings` を入れる。

状態の作り方：

- `fetchedAt` が未来（+60秒超）の応答は捨てて `unavailable`（collectorと同じ判定）。
- proxyの `source: verified` は「画面確認値・自動更新なし」。鮮度では `stale` にせず、`observedAt` と期限だけ示す（collectorの既存表示に合わせる）。
- `live`/`local` は `updatedAt` と `fetchedAt` の古い方から20分で `stale`（`USAGE_AUTO_STALE_MS`）。
- analytics は要求時取得なので `stale` にしない。取得失敗は `unavailable`＋`auth_required`（401）と `fetch_failed` を区別する。
- storage-guard は `checked_at` が26時間超で `stale`、ファイル欠落・JSON不正で `unavailable`。**Bridgeから `laa-storage-guard status` を起動しない**（50.7秒の全走査）。
- CPU・メモリは実装まで `availability: unavailable`、`nullReason: unsupported`。値を0にしない。

## 5. 認証境界

| 経路 | 方式 | 禁止 |
|---|---|---|
| iPhone → Bridge | BRIDGE.md §9の端末トークン、scope `usage:read` | Conduitのペアリング券・dashboard券を渡さない |
| Bridge → proxy 8081 | ループバックのみ、資格情報なし。collectorと同じ射影（表示項目だけ通す） | providerのURL・cookie・エラー原文をアプリへ返さない |
| Bridge → dashboard 9119 | **未決**。401を実測。Hermes側の読取専用チケットを Bridge 専用に発行し、起動時に取得・メモリ保持 | Conduitの `DashboardTicketBridge` の券を流用しない。券をログ・応答・URLへ出さない |
| Bridge → storage-guard | 状態ファイルの読取りのみ（同一UID） | 走査の起動、`prune`/`--apply` |
| Bridge → R2 / Cloudflare | 使わない | `cf` の資格情報、R2のキーを読まない |

Tailscaleは輸送の前提で、認証の代替にしない（BRIDGE.md §1）。

## 6. 未取得・未決（親の判断が要る）

1. **dashboard analyticsの読取権限**：ループバックでも401を実測（`/health` は302）。Bridge専用の読取専用チケットの発行方法（Hermes側の設定か、既存CLIか）を決める必要がある。決まらない場合、費用・トークンは「アプリが現行どおり直接dashboardを読む」経路に残し、`/v1/usage` からは外す。
2. **CPU・メモリの実装**：Bridge内サンプラ（Darwin `host_processor_info`／`host_statistics64`、10秒キャッシュ）を新設するか、収集自体を09で見送るか。新しい常駐は増やさない前提。
3. **R2 usage同期の再開**：Consoleの非表示で `--cloud-sync-usage` と `aiUsage` が落ち、snapshotは 2026-10-29T04:50:20Z で止まった。iPhone向けにR2経由の履歴が要るなら別作業で再開を決める（本仕様は依存しない）。
4. **保持期間**：`/v1/usage` は現在値を返すのみ。履歴・日次系列を返すかは未決（analyticsの `daily` をそのまま返す案がある）。

### 親の決定（2026-10-29）

1. 費用・トークンはv1では `/v1/usage` に含めず、アプリが現行どおりdashboardを直接読む。新しい資格情報を増やさないため。
2. CPU・メモリはBridgeプロセス内のサンプラ（10秒キャッシュ）で返す。常駐は増やさない。
3. R2のusage同期は再開しない（社長指示でConsoleのAI Usageは停止）。
4. v1は現在値のみ返す。日次系列はdashboardの `daily` をアプリが直接表示する。

## 7. 受入（09での照合）

- `/v1/usage` の quota/balance 項目を `curl 127.0.0.1:8081/widget` の `providers[].windows[].remaining`・`resetsAt` と1件ずつ照合する。欠測IDが `unavailable` で、値が null であることを確認する。
- 費用・トークンを dashboard の `totals`・`daily`・`models` と照合し、`actual_cost` の無い行が `estimated: true` になることを確認する。
- `host.disk` を `~/.local/state/laa-storage-guard/status.json` の `free_gb`/`total_gb`/`checked_at` と照合する。`checked_at` を26時間進めた複製で `stale` になることを確認する。
- `host.cpu`・`host.memory` が `unavailable`（null）で、0や前回値の使い回しにならないことを確認する。
- fixtureは [fixtures/usage/](fixtures/usage/) の4件をそのまま応答として返し、アプリ側で欠測・古い・推計・期限切れの表示が分かれることを確認する。
- 認証：`usage:read` 無しで403、失効トークンで401、proxy停止中でも Bridge が 200 で `unavailable` を返すことを確認する。
