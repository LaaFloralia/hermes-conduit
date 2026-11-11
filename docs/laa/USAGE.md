# Usage・Mac状態のデータ契約

2026-11-11更新。UsageはAI利用量と端末・Google共有容量の自動取得値を扱う。認証情報や上流の請求データ本文は返さない。応答例は [fixtures/usage/](fixtures/usage/) にある。

## 1. 指標と取得元

| 指標 | 取得元・単位 | 欠測時 |
|---|---|---|
| 各サービスの利用枠 | CodexBar → ローカルproxy `/widget`、残り% | 数値なし |
| 自動取得可能な残高 | 同proxy、USD・クレジット | 数値なし |
| GPT API・Claude APIの残高 | 請求画面で確かめた残高（HQ `catalog.verifiedMoney`、確認日時付き）。usage-metersが `balance` として渡す。両社とも残高のAPIを公開していない（2026-11-11確認：AnthropicのAdmin API・OpenAIのCosts APIは使用額だけ、ダッシュボードの請求経路はブラウザのセッション専用） | `not_auto`・数値なし。使用額で代用しない |
| nanoGPT | 表示しない（2026-11-11に社長が解約）。proxyが行を送ってもBridgeは読まない | — |
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

`GET /v1/usage` はscope `usage:read` を要求し、`{data:{items,nextCursor,fetchedAt},requestId}` を返す。`fetchedAt` は表示中のfeedを受け取った時刻（未取得はnull）で、要求はその読み取りを待たない。個々のitemは `{id,kind,label,value,unit,source,observedAt,availability,stale,estimated,expired,nullReason?,detail?}`。欠測・期限超過・失敗・手動確認のみの項目は `availability:unavailable`、`value:null`、理由を返し、数値を含むdetailを返さない。0は正常に取得した値が0の場合だけ。

- 自動取得項目の期限 `detail.freshUntil` はproviderの `updatedAt`、feedの `fetchedAt`、受信時刻の最も早い時刻から10分以内。provider側の期限がさらに早ければそちらを採用する。期限ちょうどからBridge応答の数値はnullにする。端末の前回値は後述の表示契約に従う。時計差のため未来120秒まで許容し、期限の起点は受信時刻を超えない。時刻の欠落・120秒超の未来・不正は取得失敗とする。
- `verified` や手動確認だけの値は自動取得なしとし、数値を返さない。quotaのいずれかのresetが経過した場合も値を消す。付帯クレジットの取得時刻は別に評価する。手動reset passは返さない。
- API費用のIDは `provider.openai-api.cost-today` / `cost-month`、`provider.claude-api.cost-today` / `cost-month`。`detail.periodTimezone` は `UTC`、`detail.sourceLag` はAnthropic `typical-5m`、OpenAI `undisclosed`。反映済み時刻を推測して作らない。応答に今日（UTC）のバケットが無い場合、費用取得処理は `todayAmount` を返さず、Bridgeは `cost-today` だけ `freshness_unknown`（数値なし）、`cost-month` は返ったバケットの合計を出す。この4件は「使用額」であり、残高ではない。
- API残高のIDは `provider.openai-api.balance` / `provider.claude-api.balance`。同じprovider行の `amount`（`currency` は `USD`、無指定もUSD）が10分以内に自動取得できた時だけ `available` と数値を返す。上流行に `amount` が無い時は `not_auto`、`amount` はあるが数値でない時は `fetch_failed` とし、いずれも `value:null`・数値を含むdetailなしで返す。上流行に請求画面の確認値 `balance: {amount, confirmedAt}` がある時は、その金額（負も可）を `available`・`observedAt: confirmedAt`・`detail.sourceKind: verified` で返す。これは確認時点の値で、10分の期限の対象外だが現在値ではない。アプリは経過時間・「請求画面の確認値」と確認日時を添え、0以下は「残高なし」と示す。Costの金額をこのIDへ写さない。両社とも残高のAPIを公開していないため、自動取得の残高は無く、更新は請求画面の確認（定期確認を含む）による。
- `nullReason` は `not_configured` / `auth_required` / `not_auto` / `freshness_unknown` / `fetch_failed` / `unsupported`。原文エラー、鍵、cookieは渡さない。
- 古いBridgeの応答に `freshUntil` がない場合、アプリは観測時刻と受信時刻の早い方から10分を上限にする。同じ観測時刻を再受信しても期限は延ばさない。ただし旧Bridgeはfeedの取得時刻を渡さないため、この代用だけでfeed側の期限は再現できない。更新後のBridgeを使う。

- 表示順はCodex、OpenCode、Claude、Magnific、GPT API、Claude API、Liquid AI、Venice（nanoGPTは2026-11-11に外した）。複数の枠がある時は期間を「週間」「月間」と添える。アプリはAIを先、Storageを後に、節ごとに1枚の面で表示する。題の横は最後に取得できた時刻の相対表記で、押すと更新する。行は名前・値・比率のメーター・補助1行に絞る。ウィジェットはLiquid AIを除いた上位5行までを表示し、比率だけ細いメーターを付ける。
- メーターは値に連動する。行が現れると値まで伸び、更新のたびに新しい値へ滑らかに移る（視差効果を減らす設定では即時）。利用枠とクレジットは残りを表し、残り2割未満で要確認の色にする。容量は使用量を表し、9割以上か警告水準で要確認の色にする。Magnificは付与量（`grantedAmount`、なければ `monthlyGrantedAmount`）に対する残りを描き、補助行に付与量と残りの割合を出す。分母の無い残高はメーターを描かない。WorkのUsageボタンの計器も、一覧の週間枠で最も残りが少ない値を指す。
- GPT API・Claude APIは残高だけを表示する。残高が未取得でも行を残し、「未取得」と「自動取得できる残高がありません」を出す。補助行は請求画面へのリンクを兼ねる。今日・今月の費用を残高に代用しない。App Groupに残った旧 `provider.<id>.cost-month` は描画も前回値の代用もしない。
- アプリは起動・復帰・Usageを開いた時（60秒の重複抑止）・明示更新で取得し、前面では120秒ごとにも取得する。Usage自身も表示中の取得を持ち、別の状態を持つWorkから開いても止まらない。画面を離れるかアプリが非アクティブになると画面側の取得を止める。値を取得した時刻と、更新を試みた時刻を分ける。表示の鮮度は毎分判定する。
- **表示の期限は数値の削除期限ではない。** アプリとウィジェットは、最後に正常取得した数値と元の観測時刻を保持する。10分超・取得失敗・一部欠測でも「更新待ち」に置き換えない。古い値の横には「12分前」のように経過を出す。未取得は0で埋めず「未取得」。既知の取得失敗・認証不足は理由を1行だけ添える。Bridgeが返すunavailable/nullは新たな観測値ではなく、クライアントに保存した前回値を消す指示にはしない。
- 枠のresetを過ぎた場合も前回の数値を残し、「リセット済み」と明示する。この数値はリセット前の取得値で、現在の残量ではない。100%への回復や新たなreset時刻を推測しない。次の正常な観測で数値と時刻を置き換える。
- アプリとウィジェットはApp Groupのlauncher-v1.jsonで要約を共有する。アプリの表示用項目は同Groupのusage-items-v1.jsonに保存し、再起動時も前回値を読める。これらのJSONには認証情報を入れない。ウィジェットはタイムラインの再読込時に、認証付きのGET /v1/usageを直接実行する（要求8秒、全体10秒、リダイレクトなし、ディスクキャッシュなし）。接続情報は既存App GroupのKeychainに端末限定・初回ロック解除後で共有する。端末の既存トークンとusage:readの権限判定を使い、Tailscaleを認証の代わりにはしない。
- 接続解除・接続先変更・401・403では、表示用キャッシュと共有接続情報を消す。飛行中のウィジェット取得は接続情報を読戻してから保存し、接続が変わっていたら破棄する。アプリとウィジェットの共有JSONの書込はプロセス間ロックで直列化する。Magnificの単位はAI creditsで、USDに換算しない。
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

各管理者キーの設定とサービス再起動は統合担当が行う。設定後、AnthropicとOpenAIの実APIを各1回確認し、使用ゼロの日のバケット（`results` が空で返るか、バケット自体が無いか）、最終ページの `has_more: false` と `next_page`（値または欠落）、UTC日付と金額を照合する。OpenAIは§1の期間で確認済み。Anthropic従来Cost APIの空バケットは未確認で、鍵の保存後に同じ観測を行う。WidgetKitのタイムラインは期限を過ぎた値を過去の取得値として表示し、数値と取得時刻を残す。iOSの背景更新は実行時刻を保証しない。ウィジェットはアプリを開かずに再取得できるが、OSによる遅延中は最後の値と経過を示す。アプリ配信・実機での切替は別途確認する。

SwiftBarは毎分feedの期限を判定するが、MacのスリープやSwiftBar停止中は最後の描画が残りうる。ウィジェットは、更新前に置いた上流Workspaceの2種が更新後も古い表示のままタップしても開かず、旧ウィジェットの削除とLAA Employeeへの置き換えが必要。systemSmallはChatとCall、systemMediumはUsageを開く経路を確認し、ロック画面用の円形・長方形は通知センターの画面からLAAを開いて未接続案内まで確認した。実際にロックされた状態での遷移は未確認。

### 旧クライアントの移行

端末に残った旧クライアントはrepoの置き換えでは消えない。統合時に次を行う。

- iPhone: Scriptableの旧スクリプト（feedを端末へ保存していた版）を削除する。残す場合は、案内用の `LAA Usage.js` に置き換える。旧スクリプトは保存済みの古い値を出し得る。
- Mac: SwiftBarのプラグインフォルダから旧 `laa-usage.2m.py` を外し、新しい `laa-usage.1m.py` に切り替える。切替は統合担当が行う。

## 7. 検証

proxyはfixtureで10分境界、失敗・部分ページ・手動値・金額とページング、今日バケットの欠落、空応答、疎な日次バケット、`next_page` の無い最終ページを検証する。API残高は、`amount` の無い上流行が `not_auto` になり費用を写さないこと、残高と使用額が同じ行に共存すること、10分経過・手入力・JPYで数値を出さないことを検証する。Bridgeは `npm test` で期限とreset、数値の欠落（今日だけ状態行・月は金額）、背景取得、再起動、認証、HTTP応答を検証する。アプリ側は、旧snapshotの `cost-month` を描画も前回値の代用もせず残高を未取得にすること、正式な残高の正常値、残高と費用の共存、10分・期限・失敗を `LAAUsageWidgetTests` で検証する。`python3 scripts/laa/test-widget-bundle-registration.py` はLAA版と上流版の登録を検証する。実接続・鍵権限・iOS実機の表示はfixture試験と区別する。

## 容量

`/v1/usage` に `kind: capacity`、`unit: bytes`、`value: 使用済みbytes` を追加する。IDは `capacity.mac-mini.memory`、`capacity.mac-mini.ssd`、`capacity.google-drive`、`capacity.macbook.memory`、`capacity.macbook.ssd`、`capacity.icloud`。iCloudは取得経路がなく `unavailable` / `unsupported`。MacBookの接続失敗時はメモリとSSDを両方 `unavailable` / `fetch_failed` とする。

各利用可能項目の `detail` は `totalBytes`、`availableBytes`、`freshUntil`、`deviceLabel`、`resourceType`、`status`、`warningFreeBytes`、`criticalFreeBytes` を持つ。閾値未設定時はnull、statusはunknown。

SSDは空きが80 GiB未満でwarning、40 GiB未満でcritical、その他normal。Google共有容量は使用率90%以上でwarning、98%以上でcritical。メモリは圧力を取得しないためunknown。

Mac miniのメモリは `/v1/mac/status` と同じホストサンプラーを使う。SSDは `/` のstatfs（利用可能領域bavail、使用済みはtotal−available）から得る。

Google Driveは既存のGoogle認証接続で `about.storageQuota` とアカウントを確認する。`resourceType: google-storage` はGoogle全サービスの共有容量を表し、分子は `usage`、Drive内訳は `detail.driveUsageBytes`（取得不能ならnull）に `usageInDrive` を入れる。組織のプール容量では `limit` と `usage` は組織全体の値となる。上限なしで `limit` が返らない場合は取得不能とする。根拠: [Google Drive API About](https://developers.google.com/workspace/drive/api/reference/rest/v3/about)。数値のない項目はnullと理由を返す。

MacBookは既存SSH認証ラッパーで固定の読み取り専用コマンドを一度実行し、`vm_stat` と `hw.memsize` からMac miniと同じ式でメモリを、`df -k /System/Volumes/Data` からSSDの合計・利用可能量を得る。片方でも取得・解析できなければ両方を破棄する。

`/v1/usage` への要求時に、Mac miniは10秒、MacBookとGoogleは5分を更新間隔として独立にバックグラウンド取得する。重複する取得は1回にまとめる。容量の取得元には常駐タイマーを設けない。最新の取得失敗時は値を破棄する。応答は外部取得を待たず、取得時刻から10分以上経った値はstale、未来の観測時刻は拒否する。AI feedの `fetchedAt` は容量の取得時刻ではなく、各容量の `observedAt` / `freshUntil` を参照する。

## 更新の組合せ（2026-11-11）

| 経路 | 採用と動作 | 制約 |
|---|---|---|
| タイムライン | 次回取得を15分後に要求。最初の1時間は5分ごと、以降24時間まで1時間ごとの表示エントリと期限・reset境界を渡す | 取得機会と描画時刻はWidgetKitが決める。数値を予測するエントリは作らない |
| ウィジェットの通信 | OSがタイムラインを要求するたびBridgeを直接読む | オフライン・タイムアウトは最後の値を保持 |
| アプリの前面取得 | 既存の起動・復帰・120秒タイマー・手動更新で保存し、差分があればreloadTimelines | 前面の定期取得はアプリ稼働中だけ |
| BGAppRefreshTask | 15分以降でOSに要求。保存後にreloadTimelines。通常のKeychainがロック中ならウィジェット用経路で取得 | 実行の保証なし。省電力・利用状況に依存 |
| 通常のプッシュ | 既存のphone.changes経路は端末設定同期用。Usage取得は現時点では呼ばない | 対応にはConduitApp.swiftの受信処理への追加が必要 |
| iOS 26のWidgetKit push | 今回は未接続。通常タイムラインと同じ取得処理を起動できる | WidgetPushHandler、拡張のAPNs entitlement、専用トークンの登録・送信経路が必要。既存の会話通知トークンと混用しない |

[Appleの更新予算](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)は利用状況に応じて決まり、日常的に見るウィジェットでも1日40〜70回が目安で、15分後の指定は保証ではない。[拡張からの通信](https://developer.apple.com/documentation/widgetkit/making-network-requests-in-a-widget-extension)はタイムライン提供時に行える。[WidgetKit push](https://developer.apple.com/documentation/widgetkit/updating-widgets-with-widgetkit-push-notifications)も更新予算の管理を受けるため、プッシュだけに依存しない。Context7ではAppleのライブラリが削除済みだったため、Appleの現行一次文書を直接確認した。

Mac側はCodexBarの取得を120秒、proxyの再取得を60秒、Bridgeのfeed再取得を60秒とする。各タイマーは独立しており、取得にかかった時間と位相差が加わる。provider固有のキャッシュ（Magnificの300秒等）は別に残る。proxyとBridgeは上流を待たず保存済みの表示データを返す。上流feedの期限・手動値・不正値の棄却は維持し、古い数値の保持はクライアントの履歴として扱う。
