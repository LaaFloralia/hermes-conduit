# AI Usage・Mac状態のデータ契約

2026-11-02更新。AI Usageは自動取得した現在の値だけを扱う。認証情報や上流の請求データ本文は返さない。応答例は [fixtures/usage/](fixtures/usage/) にある。

## 1. 指標と取得元

| 指標 | 取得元・単位 | 欠測時 |
|---|---|---|
| 各サービスの利用枠 | CodexBar → ローカルproxy `/widget`、残り% | 数値なし |
| 自動取得可能な残高 | 同proxy、USD・クレジット | 数値なし |
| Venice | 自動取得したUSD残高と補助残高 | 数値なし |
| Liquid AIの記録済み使用 | ローカル台帳に記録された呼出しのトークン・費用 | 数値なし。全利用分とは限らない |
| Claude API使用額 | Anthropic従来Cost API、今日・今月のUSD | Admin key未設定・認証失敗・取得失敗を区別 |
| GPT API使用額 | OpenAI Costs API、今日・今月のUSD | 同上 |
| Jev・Google Cloud・Google Flow | 取得も表示もしない（2026-11-01に廃止。古い保存値は表示しない） | — |
| CPU・メモリ | Bridge内サンプラ、percent・bytes、10秒キャッシュ | nullと理由 |
| Mac空き容量 | `laa-storage-guard` 状態ファイルのGB、`checked_at` | 読取失敗はnull。26時間超はstale |

Claude・GPTの費用は日単位で、今日・今月の区切りをUTC、取得時刻を日本時間で示す。`observedAt` は取得時刻であり、上流の反映済み時刻ではない。Anthropicの従来Cost APIは現在も提供され、`amount` は米セント、反映は通常5分程度だが、個々の反映済み時刻や最大遅延は示されない。新規統合に推奨されるAnalytics APIは通常4時間、最大24時間の遅れなので、鮮度を優先して従来APIを使う。従来APIが停止すれば `fetch_failed` となり、保存済みの古い金額は表示しない。Analyticsへの移行は、遅延を受け入れる判断か上流の鮮度改善を条件とし、`data_refreshed_at` を基準にする。根拠: [Anthropic従来API](https://platform.claude.com/docs/en/manage-claude/usage-cost-api)、[Anthropic Analytics API](https://platform.claude.com/docs/en/manage-claude/usage-cost-analytics-api)。

OpenAI Costs APIの `amount.value` は返された通貨単位（USDならドル）で、反映遅延の上限は確認できない。両社の費用とも取得から10分未満に限るが、取得の鮮度は上流への反映完了を保証しない。費用は返った日次バケットだけを数え、欠けた日を0で補わない。今日（UTC）の金額は、応答に今日のバケットがあるときだけ出す。無ければ今日の項目だけ `freshness_unknown`（数値なし）とする。今月（UTC）は返ったバケットの合計で、今日のバケットが無くても過去のバケットがあれば金額を出す。バケットが1件も無い応答は確認できた金額が無いため `freshness_unknown` とし、0を出さない。使用ゼロの日が `results` の空のバケットとして返り、それが今日なら0を出す。Priority Tier費用は従来Cost APIに含まれない。

[OpenAI Costs API](https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage/methods/costs)は空の日の扱いを公式に明記していない。2026-10-22〜11-01の実応答では、使用ゼロの日も `results` が空のバケットとして毎日返り、最終ページは `has_more: false`・`next_page: null` だった。全ページの終端と日付範囲・昇順・重複なしを確認する。これはその期間の観測であり、公式保証ではない。

Anthropicの従来Cost API（`/v1/organizations/cost_report`）が使用ゼロの日を空バケットで返すかは、[従来Cost APIの資料](https://platform.claude.com/docs/en/manage-claude/usage-cost-api)からは確認できていない。そのためOpenAIと同じく返ったバケットだけを数え、月初から当日までの全日が揃うことを要求しない。実応答は§6で確認する。

CodexBar 0.74.0の `serve` はproviderごとのエラーを返す場合があり、proxyは `error` を持つ行を無効にする。一方、同一アカウントの一部失敗では、CodexBarがエラー行を最後の正常行そのもので置き換えるため、エラーは見えず `usage.updatedAt` もその行の時刻のままになる。proxyはその時刻を使い10分で消す。各providerの内部取得経路すべてが元の観測時刻を正しく保持することまでは未確認。値が同じことだけでは期限切れにしない。根拠: [CodexBar 0.74.0のserve実装](https://github.com/steipete/CodexBar/blob/v0.74.0/Sources/CodexBarCLI/CLIServeCommand.swift)。

以前の `clef` は自動取得の数値ではなく、ローカルhealthからの「主系／予備／一時停止」という文字の接続状態だった。Usageの数値一覧には該当する表示項目がないため、今回のfeedには含めない。

## 2. 実装前の実測

2026-10-29のproxyとConsoleの状態、dashboard analyticsの401、storage-guardの走査約50秒という調査結果は、当時の状態であり現在の稼働確認ではない。Consoleの古いsnapshotを値の正本にしない。再起動・実環境確認は統合担当が行う。

## 3. 取得と保存

proxyとBridgeはバックグラウンドで取得し、要求時に上流を待たない。Bridgeは一度に一つだけ取得し、表示用payloadをメモリに保持する。取得失敗時は消し、再起動時も新しい取得を待つ。以前の `usage-feed.json` は読まず、更新もしない。proxyの `/health` は最終成功時刻、表示可能なprovider数、feedの期限状態を返す。

## 4. 契約

`GET /v1/usage` はscope `usage:read` を要求し、`{data:{items,nextCursor},requestId}` を返す。個々のitemは `{id,kind,label,value,unit,source,observedAt,availability,stale,estimated,expired,nullReason?,detail?}`。欠測・期限超過・失敗・手動確認のみの項目は `availability:unavailable`、`value:null`、理由を返し、数値を含むdetailを返さない。0は正常に取得した値が0の場合だけ。

- 自動取得項目の期限 `detail.freshUntil` はproviderの `updatedAt`、feedの `fetchedAt`、受信時刻の最も早い時刻から10分以内。provider側の期限がさらに早ければそちらを採用する。期限ちょうどから値を消す。時計差のため未来120秒まで許容し、期限の起点は受信時刻を超えない。時刻の欠落・120秒超の未来・不正は取得失敗とする。
- `verified` や手動確認だけの値は自動取得なしとし、数値を返さない。quotaのいずれかのresetが経過した場合も値を消す。付帯クレジットの取得時刻は別に評価する。手動reset passは返さない。
- API費用のIDは `provider.openai-api.cost-today` / `cost-month`、`provider.claude-api.cost-today` / `cost-month`。`detail.periodTimezone` は `UTC`、`detail.sourceLag` はAnthropic `typical-5m`、OpenAI `undisclosed`。反映済み時刻を推測して作らない。応答に今日（UTC）のバケットが無い場合、費用取得処理は `todayAmount` を返さず、Bridgeは `cost-today` だけ `freshness_unknown`（数値なし）、`cost-month` は返ったバケットの合計を出す。
- `nullReason` は `not_configured` / `auth_required` / `not_auto` / `freshness_unknown` / `fetch_failed` / `unsupported`。原文エラー、鍵、cookieは渡さない。
- 古いBridgeの応答に `freshUntil` がない場合、アプリは観測時刻と受信時刻の早い方から10分を上限にする。同じ観測時刻を再受信しても期限は延ばさない。ただし旧Bridgeはfeedの取得時刻を渡さないため、この代用だけでfeed側の期限は再現できない。更新後のBridgeを使う。

- 表示順と表記は、アプリ内のAI usage画面もウィジェットも同じ: Codex Weekly、OpenCode Weekly、Claude Weekly、Venice、Magnific、GPT API、Claude API、Liquid AI。7日の枠は全言語で「Weekly」に統一し、`D1` とは書かない。ウィジェットはこの順で入る分を並べ、最後に取得できた値と「HH:mm時点」を表示する。行ごとの取得時刻が異なる場合は最古の時刻、別日は日付も示す。保存値のない項目だけを未取得にする。
- アプリは開いた時と明示更新で取得する。表示中はshellの自動取得を抑止し、鮮度・期限の判定も最終取得時点に固定する。ウィジェットはApp Groupのlauncher-v1.jsonを読み、Bridgeへ直接通信しない。アプリが/v1/usageを取得して保存する。期限超過・通信失敗・一部行の欠測では、保存済みの値と元の取得時刻を保持する。接続解除・接続先変更・アクセス拒否では消去する。Magnificの単位はAI creditsで、USDに換算しない。
- Jev・Google Cloud・Google Flow は取得も表示もしない（2026-11-01に廃止）。端末に古い保存値が残っていても落ちず、描画しない。

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

各管理者キーの設定とサービス再起動は統合担当が行う。設定後、AnthropicとOpenAIの実APIを各1回確認し、使用ゼロの日のバケット（`results` が空で返るか、バケット自体が無いか）、最終ページの `has_more: false` と `next_page`（値または欠落）、UTC日付と金額を照合する。OpenAIは§1の期間で確認済み。Anthropic従来Cost APIの空バケットは未確認で、鍵の保存後に同じ観測を行う。WidgetKitのタイムラインは期限を過ぎた値を過去の取得値として表示し、数値と取得時刻を残す。iOSの背景更新は実行時刻を保証しないため、現在値への更新にはアプリでの再取得が必要になる場合がある。アプリ配信・実機での切替は別途確認する。

SwiftBarは毎分feedの期限を判定するが、MacのスリープやSwiftBar停止中は最後の描画が残りうる。ウィジェットは、更新前に置いた上流Workspaceの2種が更新後も古い表示のままタップしても開かず、旧ウィジェットの削除とLAA Employeeへの置き換えが必要。systemSmallはChatとCall、systemMediumはUsageを開く経路を確認し、ロック画面用の円形・長方形は通知センターの画面からLAAを開いて未接続案内まで確認した。実際にロックされた状態での遷移は未確認。

### 旧クライアントの移行

端末に残った旧クライアントはrepoの置き換えでは消えない。統合時に次を行う。

- iPhone: Scriptableの旧スクリプト（feedを端末へ保存していた版）を削除する。残す場合は、案内用の `LAA Usage.js` に置き換える。旧スクリプトは保存済みの古い値を出し得る。
- Mac: SwiftBarのプラグインフォルダから旧 `laa-usage.2m.py` を外し、新しい `laa-usage.1m.py` に切り替える。切替は統合担当が行う。

## 7. 検証

proxyはfixtureで10分境界、失敗・部分ページ・手動値・金額とページング、今日バケットの欠落、空応答、疎な日次バケット、`next_page` の無い最終ページを検証する。Bridgeは `npm test` で期限とreset、数値の欠落（今日だけ状態行・月は金額）、背景取得、再起動、認証、HTTP応答を検証する。`python3 scripts/laa/test-widget-bundle-registration.py` はLAA版と上流版の登録を検証する。実接続・鍵権限・iOS実機の表示はfixture試験と区別する。
