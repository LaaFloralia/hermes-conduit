# AI Usage・Mac状態のデータ契約

2026-11-01更新。AI Usageは自動取得した現在の値だけを扱う。認証情報や上流の請求データ本文は返さない。応答例は [fixtures/usage/](fixtures/usage/) にある。

## 1. 指標と取得元

| 指標 | 取得元・単位 | 欠測時 |
|---|---|---|
| 各サービスの利用枠 | CodexBar → ローカルproxy `/widget`、残り% | 数値なし |
| 自動取得可能な残高 | 同proxy、USD・クレジット | 数値なし |
| Liquid D1の記録済み使用 | ローカル台帳に記録された呼出しのトークン・費用 | 数値なし。全利用分とは限らない |
| Claude API使用額 | Anthropic従来Cost API、今日・今月のUSD | Admin key未設定・認証失敗・取得失敗を区別 |
| GPT API使用額 | OpenAI Costs API、今日・今月のUSD | 同上 |
| 自動取得できないGoogle Cloud・Flow・Jev | 固定の管理画面へのリンク | 数値なし、自動取得なし |
| CPU・メモリ | Bridge内サンプラ、percent・bytes、10秒キャッシュ | nullと理由 |
| Mac空き容量 | `laa-storage-guard` 状態ファイルのGB、`checked_at` | 読取失敗はnull。26時間超はstale |

Claude・GPTの費用は日単位APIで取得し、区切りはUTCと明記する。`observedAt` は取得時刻であり、上流の反映済み時刻ではない。Anthropicは通常5分程度の遅れを公表、OpenAIは反映の遅れを公表していない。両者とも取得から10分未満の値だけ表示する。AnthropicのPriority Tier費用はCost APIに含まれない。根拠: [Anthropic Usage and Cost API](https://platform.claude.com/docs/en/manage-claude/usage-cost-api)、[OpenAI Costs API](https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage/methods/costs)。

## 2. 実装前の実測

2026-10-29のproxyとConsoleの状態、dashboard analyticsの401、storage-guardの走査約50秒という調査結果は、当時の状態であり現在の稼働確認ではない。Consoleの古いsnapshotを値の正本にしない。再起動・実環境確認は統合担当が行う。

## 3. 取得と保存

proxyとBridgeはバックグラウンドで取得し、要求時に上流を待たない。Bridgeは一度に一つだけ取得し、成功した表示用payloadをメモリと `usage-feed.json`（0600）に保存する。失敗すればメモリを消し、ファイルも消す。再起動時は以前のファイルを読み戻さず、新しい取得の結果を待つ。期限を超えた値や失敗した値を、現在値または前回値として返さない。

## 4. 契約

`GET /v1/usage` はscope `usage:read` を要求し、`{data:{items,nextCursor},requestId}` を返す。個々のitemは `{id,kind,label,value,unit,source,observedAt,availability,stale,estimated,expired,nullReason?,detail?}`。欠測・期限超過・失敗・手動確認のみの項目は `availability:unavailable`、`value:null`、理由を返し、数値を含むdetailを返さない。0は正常に取得した値が0の場合だけ。

- 自動取得項目の期限 `detail.freshUntil` はproviderの `updatedAt` とfeedの `fetchedAt` の古い方から10分以内。provider側の期限がさらに早ければそちらを採用する。期限ちょうどから値を消す。時刻の欠落・未来・不正も取得失敗とする。
- `verified` や手動確認だけの値は自動取得なしとし、数値を返さない。quotaのいずれかのresetが経過した場合も値を消す。付帯クレジットの取得時刻は別に評価する。手動reset passは返さない。
- API費用のIDは `provider.openai-api.cost-today` / `cost-month`、`provider.claude-api.cost-today` / `cost-month`。`detail.periodTimezone` は `UTC`、`detail.sourceLag` はAnthropic `typical-5m`、OpenAI `undisclosed`。反映済み時刻を推測して作らない。
- `nullReason` は `not_configured` / `auth_required` / `not_auto` / `freshness_unknown` / `fetch_failed` / `unsupported`。原文エラー、鍵、cookieは渡さない。
- 古いBridgeの応答に `freshUntil` がない場合、アプリは `observedAt + 10分` を上限にする。ただし旧Bridgeはfeedの取得時刻を渡さないため、この代用だけでfeed側の期限は再現できない。更新後のBridgeを使う。

`GET /v1/mac/status` は従来どおり `host.cpu`・`host.memory`・`host.disk` を返す。usageと別のホスト状態であり、diskの26時間判定を変更しない。

## 5. 認証境界

| 経路 | 方式 |
|---|---|
| iPhone → Bridge | 端末トークン、`usage:read` |
| Bridge → proxy | ループバックのみ。表示用データのみ |
| proxy → provider | 各providerに必要な鍵を実行時のみ注入。鍵や認証先の応答本文はアプリへ渡さない |
| Bridge → storage-guard | 状態ファイルを読むだけ。走査・削除は起動しない |

Tailscaleは輸送であり認証の代替ではない。

## 6. 統合時の確認事項

各管理者キーの設定とサービス再起動は統合担当が行う。falの鍵権限とVenice実環境の失敗原因は別途確認中。WidgetKitのタイムラインは期限に数値なしへ切り替えるよう指定するが、実際の切替時刻はOSに管理される。アプリ配信・実機での切替は別途確認する。

## 7. 検証

proxyはfixtureで10分境界、失敗・部分ページ・手動値・金額とページングを検証する。Bridgeは `npm test` で期限とreset、数値の欠落、背景取得、再起動、認証、HTTP応答を検証する。実接続・鍵権限・iOS実機の表示はfixture試験と区別する。
