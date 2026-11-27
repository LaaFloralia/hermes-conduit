# LAA Bridge 契約・脅威・復旧設計

2026-11-02更新。§9の決定に沿って実装した端点は `bridge/README.md` のAPI表に列挙する。本書は設計・脅威・未決事項を残し、実装済みの範囲でも実接続と実機確認は別に扱う。根拠は [ROADMAP.md](ROADMAP.md) と [BASELINE.md](BASELINE.md)。依存先の機能をBridgeで再実装せず、未確認の接続・権限は実装ゲートとする。

## 1. 責務と配置

- Mac mini上のユーザー権限の**単一Bridgeプロセス**を専用launchd LaunchAgentで管理する案。HTTPは127.0.0.1の専用ポートのみで待受け、Tailscale Serveの専用HTTPSポートから転送する。番号は空きと競合を実測後に決定。Funnel・LAN直公開は禁止。Tailscale未接続・Mac未ログイン時の利用は保証しない。
- 既存8444→9119はHermes dashboard／Conduit、8443はUsage等のServe。両設定を変更・共有せず、BridgeのServeだけを追加・停止する。HTTPS証明書・経路は既存Tailscale方式を再利用し、tailnet到達性と端末認証を別に判定する。ループバックの別プロセスを信頼境界と誤認しない。
- 会話・通話・通知は現行Conduit pluginの経路を維持。Macの実体は0.69.1で、上流0.116.0のAPIを使用可能と仮定しない。Sessionの委譲は `laa-personal-agent` のcreate/status/wait/list/send/reply/stopとPaseo daemonを利用し、provider・model・effort・認証経路・停止状態を維持する。Paseo CLIにもlist/run/logs/stop/send等があるが、同等性は未実証。
- TaskはLinearが正本、週単位の習慣・禁止習慣はBridgeの `habits.json`（`bridge/docs/habits.md`。Google Calendar・Linear・Brainと分離）。Drive・Photosは既存のMac側正規Google認可のみ、Usageは既存dashboard analytics／CodexBar proxy／Console collectorの選定済み出力を読む。現状CPU・メモリ収集は未確認、欠測で返す。Archiveは整合snapshotとDrive保管のアダプターで、稼働中SQLiteの双方向同期はしない。
- 起動・停止は既存 `laa-agent-control` のゲートと監督を通し、pause・停止未確認・監査不整合を迂回しない。agent-controlのsame-UID監督は全直起動・外部操作を強制遮断する境界ではない。Bridge停止は既存の停止制御や予定を変更しない。

## 2. 脅威と端末認証

| 脅威 | 対策・残る限界 |
|---|---|
| tailnetの別端末・盗難端末 | TLSに加え端末別の鍵所持とscopeを検査。盗難は個別失効。端末全体の侵害は防げない |
| 通信の再送・応答喪失 | リクエスト署名、短期nonceと永続idempotency台帳。送信結果不明は照合まで再実行しない |
| 承認のすり替え・権限昇格 | 端末・session・request・内容hash・期限に束縛し、正規の本人判断を確認。scopeは業務の送信・削除・売買などの承認を代替しない |
| 外部writerや不正パス | vault外・symlinkを拒否。外部writerの調停未実証時はBrain書込み不可。オフライン案を保持 |
| Bridge・Mac同一UIDの侵害 | 同一UIDが鍵・状態・監査に触れ得る。監査の完全性や端末権限のOS強制を主張しない。侵害時は隔離と別経路からの検証 |

- 登録案：Macの既存の信頼済み管理経路で期限付き・1回限りの登録チャレンジを発行し、本人が対象端末と要求scopeを確認する。iOSが端末内で署名鍵を生成し公開鍵を登録、BridgeはデバイスID・公開鍵・scope・状態を保存。認証情報／登録秘密をURL・ログ・モデルへ渡さない。初回管理経路・本人確認と具体UIは未決定、実装前に脅威検証する。
- iOSの秘密鍵と必要な端末トークンはKeychainの端末限定・移行不可の保護属性で保存し、利用可能な端末保護を確認する。Bridgeは検証用公開鍵とトークンの検証情報のみを持つ。TailscaleやGoogle、Conduitの資格情報はコピーしない。
- 全要求はTLS上で端末ID・短命トークンと署名を送る。署名対象は方式・path・query・body hash・端末ID・timestamp・十分な乱数nonce・idempotency key。サーバーは許容時刻幅、署名、nonceの未使用を検証し、nonceは失効まで永続的に記録する。時計不正や記録破損時は拒否。詳細な時刻幅・容量制限は実装前に決める。トークンはヘッダーで渡し、ログ・URLには入れない。
- 管理操作で端末単位に失効し、以後の要求・stream・未実行操作を拒否する。実行中の外部処理は自動停止済みとせず状態照合。再登録は新鍵・新ID、新たな本人確認とscope付与を要する。旧IDの権限・nonceは引継がない。紛失・漏洩時は失効後、認可済み操作と結果不明を照合する。
- 状態変更は `Idempotency-Key` 必須。デバイスID＋操作種＋キーを永続保存し、正規化要求のhashと状態・結果を関連付ける。同じ内容は同じ結果／処理状態、異なる内容は409。nonceは再送ごとに新規、同じidempotency keyを維持。台帳消失・期限切れ・下流結果不明は新規実行せず照合・人手復旧。保持期間と容量は未決定、期限切れを自動実行許可にしない。

## 3. 認可と共通契約

最初の端末も全権限を自動取得しない。`read` と `write` は独立、初期値は最小の明示付与。各resourceはowner・許可範囲を追加確認し、一覧・streamでも同一条件で絞る。

| scope | 対象・制約 |
|---|---|
| `sessions:read`, `sessions:write`, `sessions:reply` | 自分に許されたproject/workspace/sessionのみ。replyは対象質問と本人判断に束縛。停止は対象sessionのみ、非常停止の代替ではない |
| `tasks:read`, `tasks:write` | Linearの許可対象のみ。ownerとexecutorを区別し、担当設定ではworkerを起動しない |
| `brain:read`, `brain:write` | 許可vault・対象範囲のみ。現行のBrain検索・禁止領域とdailyの制約を守る。writeは調停実証まで無効 |
| `brain:create` | Brainへの新規ノート作成のみ。既存ノートの変更・削除は含めない。既定付与に含めず、端末ごとに付与する |
| `calendar:read` | Google Calendarの一覧と予定詳細（参加者・説明・添付を含む）。既定付与に含めずOAuthトークンは返さない |
| `calendar:write` | 予定の作成・条件付き編集・削除。端末ごとのoperator opt-in |
| `media:write` | Driveへの写真・ファイルの分割アップロード。端末ごとのoperator opt-in |
| `media:read`, `photos:select` | Driveの既存権限内の読取、Pickerで本人が選択した写真のみ。Google資格情報を渡さない |
| `usage:read` | 選定済み集計とMac状態のみ。認証情報・生の請求データを返さない |
| `archives:read`, `archives:create`, `archives:restore` | 許可対象のsnapshot／確認／隔離復元。runtime上書きや削除は別判断、初版は自動削除しない |
| `gui:operate`, `devices:admin` | GUI操作と登録・失効は個別付与。前者は全writer排他の実証まで無効。後者は既存の信頼管理経路に限定 |

JSONはUTF-8、時刻はUTC ISO 8601。成功は `{"data":...,"requestId":"..."}`、一覧は `data.items` と `data.nextCursor`（終端null）。変更時は `Idempotency-Key` と、対象版がある場合 `If-Match` を必須にする。非同期処理は202 `data:{jobId,status:"pending"}`、`GET /v1/jobs/{id}` で `pending|running|succeeded|failed|outcome_unknown` と結果を照合。Jobは既存処理の参照でありTaskの複製ではない。

エラーは `{"error":{"code":"...","message":"...","retryable":false},"requestId":"..."}`。400不正、401未認証／失効、403 scope・対象拒否、404許可範囲外または不存在、409競合／同一キー別内容／結果不明、410 cursor期限切れ、412版不一致、423排他中、429制限、503依存先停止・ゲート閉鎖。ネットワーク・TLS失敗はHTTP応答がないクライアント側 `network_unreachable`／`tls_failed`、権限拒否へ変換しない。timeout後の変更は結果不明として元キーで照合し、自動新規起動しない。外部サービス側の拒否・障害も識別し、秘密や生レスポンスは返さない。

## 4. API案と受入試験

表の `{...}` はJSONの主要フィールド、`→` は `data` 内。全端点で正常・未認証・scope拒否・範囲外・依存先停止、変更系で同一キー再送／異内容409／通信断後照合を共通試験する。対象へのアクセス制御は個別にも試験する。

| method / path | 要求 → 応答・所有者 | 固有試験 |
|---|---|---|
| `GET /v1/health` | → `{state,dependencies:{name,state,observedAt}}`、機微情報なし | Bridge生存と各依存の障害・停止を区別 |
| `POST /v1/devices/enroll` | 登録チャレンジ・公開鍵・要求scope → `{deviceId,grantedScopes}`、管理経路 | 期限切れ・再使用・scope拒否・端末鍵保持 |
| `GET /v1/devices`; `POST /v1/devices/{id}/revoke` | → device状態／失効結果、管理経路 | 他端末維持・接続中stream切断・再登録は新ID |
| `GET/POST /v1/projects`; `GET/PATCH /v1/projects/{id}`; `GET /v1/projects/{id}/instructions/versions`; `POST /v1/projects/{id}/files`; `DELETE /v1/projects/{id}/files/{fileId}` | `{name,instructions,instructionVersion,instructionHash}`／資料 `{name,contentBase64,mimeType?}` → `{id,version,etag,...}`、Bridge管理（§9） | 本文のみ。`instructionRef`は400。古いversionは現在版を返す。資料は5 MiB・20件まで。表示名は保持し、保存名だけをNFC・UTF-8バイト境界で255バイト以内に短縮する |
| `POST /v1/projects/{id}/requirements`; `PATCH/DELETE /v1/projects/{id}/requirements/{requirementId}`; `PUT /v1/projects/{id}/requirements/order` | 追加 `{title,source,details?,status?,sessionIds?}`、更新 `{title?,details?,status?,sessionIds?}`、並べ替え `{ids}`、取下げは本文なし → 更新後のProject詳細 | `sessions:write`、`Idempotency-Key`、`If-Match`。出所と社長の原文は不変。別ProjectのSessionは紐付けない。 |
| `GET/POST /v1/workspaces`; `GET /v1/workspaces/{id}` | `{projectId,repoId,worktreeName}` → `{id,path,status}`、既存Paseo/worktree | 正規化・symlink・許可外repo拒否、既存worktree非破壊 |
| `GET/POST /v1/sessions`; `GET/PATCH /v1/sessions/{id}`; `GET /v1/session-options` | `{projectId,workspaceId?,parentId,requestId,profile,prompt,mode?,fast?}` → `{id,requestId,status,requested,observed,favorite,archivedAt}`、personal-agent/Paseo。`workspaceId` 省略はホーム（`/Users/laa`）、`mode` は省略時 `default`、アプリが既定で `bypass` を送る。PATCHはお気に入り・アーカイブ・改名・model・effort・fast。modelは同じprovider内でPaseoの `setAgentModel` を使い、読み戻しで確かめる（`capabilities.model`、409 `model_unsupported`／`model_rejected`／`model_not_applied`）。model・effortの変更は `requested` を変えず `ownerChanged` に残す。fastはPaseoのprovider機能（Claudeは `fast_mode`、Codexは `service_tier`）を切り替え、読み戻した値が一致しなければ409 `fast_not_applied`、providerにFastが無ければ409 `fast_unsupported`。アーカイブは子を含めてPaseoへ反映し、実行中・判断待ちを含む親子は409 `session_running` で拒否する。空になったワークスペースもPaseoでアーカイブする（worktreeは実ファイルを消すため対象外）。戻すは選んだ行だけ。Paseoの一覧から消え個別取得も404のセッションは `daemonDeletedAt` を記録し、既定一覧・`archived=only`・refsの源から外す（`scope=all` とrequestId照会では見える）。`capabilities.fast` はproviderがFastを持つと観測できた時だけtrue。選択肢はHQ `models.json` から | 同じrequest ID、親子・名称、実provider/model/effortと認証経路、作成不明の回収。bypassはagent以外の呼出し元（launchdのBridge）だけ |
| `POST /v1/sessions/{id}/messages`; `POST /v1/sessions/{id}/stop`; `POST /v1/sessions/{id}/resume` | `{message}`／`{}`／`{message}` → `{operationId,status}`、同上 | 送信不明、停止未確認、停止中再開拒否。resumeは既存のsend相当と確認できる場合のみ |
| `POST /v1/sessions/{id}/reply` | `{requestId,requestHash,answer,expiresAt}` → `{status}`、同上 | 改変・期限切れ・別session・workerの回答拒否。実際の承認消化を照合 |
| `GET /v1/sessions/{id}/events`; `GET /v1/sessions/{id}/artifacts` | cursor → event一覧／`{items:[{id,name,type}]}`、同上 | 認可・重複・欠落・ファイル範囲外・再接続を確認 |
| `GET /v1/tasks`; `GET /v1/tasks/{id}` | `{title,owner,executor,status,dependencies,sourceId,version}` → task、Linear。読取専用 | 版競合・担当変更で自動起動しない・Linearに読戻し |
| `GET/POST /v1/linear-owner-tasks`; `GET/PATCH /v1/linear-owner-tasks/{id}`; `POST /{id}/archive`・`/restore`・`/complete` | `{id,title,description,dueDate,priority,assignee?,profile?}` → 社長本人のLinear課題＋`run`。PATCH・archive/restore・completeは `If-Match` 必須 | AI担当は社長がこのAPIで作った課題だけ起動し、作成と完了に `sessions:write` も要る。指示は作成時の本文で固定。完了は判断取下げ・会話アーカイブ・Done・記録保管。`?archived=only` でアーカイブ一覧。一覧・詳細の各itemは設定がある時だけ `project:{id,name}`・`labels:[{id,name,color}]` を持つ（2026-11-11、Workのジャンル分け） |
| `GET /v1/calendar/events?start=&end=` | RFC3339の42日以内、任意の複数calendarId → `{items:[予定詳細],source,start,end}`、Google Calendar | `calendar:read` 必須。設定・認可・API失敗は503で、空の予定にしない |
| `GET/POST /v1/habits`; `PATCH /v1/habits/{id}`; `PUT /v1/habits/{id}/checkins/{date}`; `GET /v1/habits/history`・`/archived`・`/events` | 週（月曜〜日曜、東京）ごとの習慣・禁止習慣と1日1回の記録 → `{week,today,items,archivedCount}`、Bridgeの `habits.json`。契約は `bridge/docs/habits.md` | 読取りは `tasks:read`、書込みは `tasks:write` と `tasks:read` の両方。作成は `Idempotency-Key`、変更は `If-Match`。Google Calendarを呼ばない。通知・期限なし。AIはCLI `laa-bridge habits`（`--by`・`--reason` 必須、`support: off` は読めず変えられない） |
| `GET /v1/skills` | → `{items:[{id,name,description,source}]}`、Macのスキル定義 | frontmatterの2項目だけ。本文は返さない。読取失敗は503で、空一覧にしない |
| `GET /v1/routines` | Console `jobs` の名前、予定、直近実行と結果を読み取り専用で返す | 未観測はnull、読取失敗は503。既存 `sessions:read` を使用 |
| `GET /v1/brain/files`; `GET /v1/brain/files/{id}`; `GET /v1/brain/search?q=...` | → `{id,content,contentHash,version}` または一覧、Brain | 許可領域・未知Markdown・画像参照保持、path traversal拒否 |
| `PUT /v1/brain/files/{id}` | `{baseHash,content}` → `{contentHash}`、Brain | 同時writerの両版保全・中断・409。調停未実証時は拒否 |
| `GET /v1/drive/files`; `GET /v1/drive/files/{id}`; `GET /v1/drive/files/{id}/content` | 検索／metadata／`Range` → metadataまたはbytes、Drive | 206・Content-Range・MIME・長さ・seek・cancel・権限切れ・非対応、Workspace exportと区別 |
| `POST /v1/photos/picker/sessions`; `GET /v1/photos/picker/sessions/{id}`; `GET /v1/photos/picker/sessions/{id}/items`; `POST /v1/photos/picker/sessions/{id}/close` | → `{id,selectionUrl,status,expiresAt}`／選択項目、Google Photos Picker | 期限・選択前・拒否・終了・選択分のみ取込。選択URLから秘密をログしない |
| `GET /v1/usage`; `GET /v1/mac/status` | → `{items:[{value,unit,source,observedAt,availability,stale}]}`、既存collector | stale・欠測null・推計／実額／枠を区別、取得値と照合 |
| `GET/POST /v1/archives`; `GET /v1/archives/{id}`; `POST /v1/archives/{id}/verify`; `POST /v1/archives/{id}/restore` | `{sourceIds}`／`{isolatedDestination}` → archiveまたはjob、既存DB・Drive | 一貫snapshot・manifest/hash・Drive読戻し・破損・別環境復元。runtime再開は別ゲート |
| `GET /v1/jobs/{id}` | → `{status,result,error}`、Bridge台帳と依存先 | 所有者・権限、再起動後の不明／完了の照合 |
| `POST /v1/gui/leases`; `POST /v1/gui/leases/{id}/renew`; `POST /v1/gui/leases/{id}/release` | `{sessionId}` → `{leaseId,fence,expiresAt}`、排他管理 | 後述の競合・期限・クラッシュ・孤立操作を試験 |
| `GET /v1/events?cursor=...` | → stream、後述 | 認可・順序・切断後の再開と期限切れを試験 |

各端点の実装可否は既存API・正規権限とライブラリの確認後に確定する。とくにGoogle認可、Photos Pickerの遷移と結果取得、Paseoの持続イベント、Linearの更新競合は未実測。未対応を成功応答で代用しない。

## 5. イベント・GUI排他

- `/v1/events` は認証済みHTTPS stream。`{streamId,seq,cursor,type,resourceId,version,occurredAt,payload}` を返す。Bridgeの永続journalに書けた順でstream内単調増加seqを付ける。cursorはscope・端末・stream世代に束縛した不透明値で、秘密や本文を含めない。配信は少なくとも1回、クライアントは `(streamId,seq)` で重複除去し永続cursorから再開する。payloadは許可された最小情報だけ。
- 停止中・復帰後に欠けた下流イベントをBridgeが必ず観測できるとは限らない。下流の履歴照合とsnapshotで整合できない時は `resync_required` を返し、一覧・各resourceの現在版を再取得する。cursor期限切れ／journal欠損／権限変更は410またはstream切断で全再同期、欠落なしを装わない。保持期間・容量・初回snapshotとstreamの境界を実装前に確定・試験する。
- GUIはMac全体で1 lease。owner（端末・session・実行ID）と単調増加fence、短い期限・renewを記録。操作の直前に現行fenceと起動ゲートを検証し、release／終了で返却。期限切れだけで操作中の旧processが止まる保証はない。再発行前に旧processと子孫の終了を実測し、未確認なら隔離して新規GUI操作を拒否。PID再利用やBridge再起動時も同様。期限・heartbeat値は未決定。
- 既存laa-nav、Computer Use、他会話・cron等、GUIへ到達する全経路が同じ排他とfenceを強制できるか未確認。協調lockだけでは排他を保証できない。全経路の調停・孤立process回収を独立検証するまでは `gui:operate` を無効とし、既存の画面操作へ影響させない。

## 6. Brain競合・保存と停止条件

Syncthing（sendreceive）、Git同期、Obsidian、iPhone側の未確認writer、brain-dailyが存在する。brain-dailyのlockは同処理間だけで外部editorを排他しない。Bridge内部の直列化・直前hash比較・同一filesystem上のatomic renameは必要だが、比較とrenameの間の外部変更を防げない。

書込みを有効にする条件は、**全writerを含む実効的な単一writer調停か同等の安全な条件付き更新**を選び、同期遅延・オフライン端末・別Mac・障害時を含む検証で両版保全を実証すること。単なるflock、Syncthing一時停止、事後hash検査だけでは合格しない。成立しなければread-onlyを維持する。

許可後はパス・symlinkを検査し、base hashと現行hash不一致なら409を返す。元ファイル、編集案、base版をvault外のアクセス制限された永続領域に保存し、それぞれのhashと識別子で復旧待ちとする。オフライン案はiOS側でも保持し、自動マージ・上書きしない。保存失敗、調停喪失、同期競合ファイル、外部writer未把握、状態破損、commit結果不明は当該対象の書込みを止める。日誌ledgerの喪失・破損は既存手順どおり停止し、状態だけを再生成しない。保全データの保持と削除は別途決定。

## 7. 観測・復旧・移行ゲート

- 監査は時刻・要求ID・端末ID・scope・対象の非機微ID・操作・許可／拒否・結果・依存先状態・版・経過時間を記録。トークン、鍵、本文、プロンプト、画像、個人情報、Google応答、秘密を残さない。保存容量・保持期間・アクセス権と障害時の運用は未決定。変更系は監査／idempotency記録に失敗したら新規実行を拒否し、停止・状態確認を妨げない。ローカル監査は同一UIDから改変可能であり、改ざん不能とは扱わない。
- 起動時は台帳・journal・ゲートを検査。破損時は書込み・実行を停止し、対象と未確定状態を表示。タイムアウト、クラッシュ、再起動時は既存依存先の状態と元request IDを照合し、結果不明・停止未確認を維持する。待機中の操作を勝手に再実行しない。Tailscale断は未送信案を保持し、再接続後に元キーで照合する。
- 切戻し案：Bridgeの受付を閉じて自分の未確定Job・GUI実行を照合し、専用LaunchAgentと専用Serve設定だけを停止。状態・監査・下書きを保全し、Hermes、Paseo、Linear、Syncthing、既存8443/8444とcronを止めない。切戻し後に各既存経路の稼働を別々に読戻す。Bridge停止だけでは下流の実行停止を保証しない。設定変更や削除は本草案では実施しない。
- Paseoを置換するにはROADMAPの移行ゲート（手動・Monet委譲・cron、provider/model/effort・課金、承認、停止・復帰、二重実行、再起動）を実測する。Linearは全属性・履歴・旧ID照合、単一writer、復元と正本更新が揃うまで唯一のタスク正本。Bridge稼働や画面完成だけで移行完了としない。
- 統合試験は各API固有試験に加え、二端末のscope、失効中stream、nonce再利用、同一キー並行送信、依存先切断、起動中crash、台帳破損、ディスク枯渇、時刻ずれ、Mac再起動、Bridgeのみ切戻しを行う。実機Tailscale断と復帰、GUIの旧process残存、Brain全writerの競合保全は個別に証拠を残す。検証用データを使い、実データ・稼働サービスの破壊試験はしない。

## 8. 親の判断・実装前の未決事項

1. 初回登録の本人確認と管理経路、端末scopeの初期セット、登録／失効の操作主体。端末鍵・署名方式とKeychain属性の実機検証。
2. 専用ポート・launchd設定・Serveの設置と撤去、nonce／台帳／streamの保持期間・容量・復旧手順。既存Serveを保護して試験する。
3. GUIの全経路を実際に強制調停できるか。不可ならBridge経由のGUIを提供しない。
4. Brain全writerの実体と安全な調停方法。未実証なら書込み・習慣チェックは提供しない。
5. Usageの3系統から画面ごとの採用元、取得不能時の表示、CPU・メモリ取得方法。BASELINEの観測値とHQ文書の鮮度差を解消する。
6. Google既存認可・Picker・Drive Range、Paseoの履歴／cursor・resume、Linearの条件付き更新、snapshotの実装可能性と権限の確認。
7. 機微データを含む下書き・競合保全・監査・archiveの保存先、暗号化、保持・削除、障害時の責任者。自動削除や課金・送信等の許可はこの設計から生じない。

## 9. 親の決定（2026-10-29）

本書の案を次の点で簡素化して採用する。ここに書いた内容が上の節と食い違う場合はこの節を優先する。

- Scheduling (2026-11-13): the LaunchAgent runs as `ProcessType = Interactive`. As `Background` it ran at the lowest priority; with the Mac at load 45–118 and swap nearly full it got about 1% CPU, was paged out, stopped answering from 20:06 JST and could not finish starting for over ten minutes. Authentication, the listener and Serve are unchanged.
- Decision board (2026-11-08): shell agents post through `laa-bridge decide add` with an `--impact` starting with `【必ず社長：<kind>】` or `【任せられる】`; unmarked filings are refused (`decision_category_required`). Only owner-only items generate a push. The Bridge owns bounded decision records in a locked, atomic 0600 `decisions.json`, retaining closed history for 30 days. `/v1/decisions` merges open records, failed or waiting deliveries, active proxy answers the owner can change, and native pending sessions. Reading requires `sessions:read`; answer/retry require `sessions:write` (the existing native reply scope), a device request ID and `Idempotency-Key`. Answers resume the source agent through the existing daemon `send` with stable per-attempt IDs, then read the agent back before reporting delivery. A conversation that is still working refuses a second foreground turn (`session_busy`); that answer is not a failure (2026-11-13): it stays `pending` with `waiting: true` (`waitingSince`, `holds`), is listed on the board, keeps its `J` number and message id, and the Bridge delivers it when the turn ends — checked at startup and every 15 s for ten minutes, then every minute, for at most 24 hours or 50 refused sends, tolerating five minutes of an unreachable Paseo. Each send is claimed in the store first, so a Bridge that stops mid-send never repeats it (the record becomes `delivery_unconfirmed`). Answers an earlier Bridge filed as `failed`/`session_busy` are picked up the same way. Only an archived or missing conversation, a stopped Paseo, an unconfirmed send or an expired wait (`delivery_wait_expired`) is a failure: those preserve the answer and require explicit retry; only owner-only items can notify once per attempt. `laa-bridge decide answer <id|ref> (--option <1-based>|--note <text>) --by monet --reason <one line>` records and delivers a proxy answer (idempotent for matching input, refused for owner-only items). The owner can replace a proxy answer in LAA; both answers are kept and only the owner’s replacement remains current. Sources without a Paseo agent read stored answers by CLI. `decide stats --json` returns the counts, and `decide list --monet-log --json` returns the subject, chosen option, reason and time of each proxy answer; both accept `--since <ISO>` to filter answer events. Native questions and approvals are `unmarked`, produce no decision push, and retain the existing decision/reply endpoints. Existing five-second sync detects CLI posts and suppresses `session.finished` while their session has an open board decision. References are resolved at read time through the shared registry: decision `J` and source session `S` (see §9); standalone services without that dependency return null. API/CLI details: `bridge/README.md`. Production restart and iPhone notification acceptance remain parent-owned gates.

- Decision images (D-17): `decide add --image /absolute/path` attaches up to six ordered general images; `--option 'label::detail::image=/absolute/path'` attaches one to an option (detail is optional). The Bridge stores private copies, not paths, and adds `images: [{id,width,height,option?}]` only when non-empty. The option index is zero-based in recommended-first order. `GET /v1/decisions/<decId>/images/<imgId>` (`?size=thumb` for the thumbnail) requires `sessions:read`, returns base64 in the standard JSON envelope, and supports ETag/304. Sync removes copies seven days after answer or withdrawal and reclaims orphan/staging dirs after one hour; expired images return 410, unknown images 404. See `bridge/README.md` for formats, limits and error codes.

- 判断ボードの自由回答と選択肢への補足は、どちらも `note` で8,000 Unicodeコードポイントまで受け付ける。改行・絵文字を含め、保存と会話への配達に同じ本文を使う。超過は400 `decision_note_too_long`「回答は8000文字以内で入力してください。」で、未回答のまま。通知のクイック返信は従来どおり選択肢だけを送信し、通知にも回答本文を含めない。

- 端末認証：要求ごとの署名・nonce台帳は採らない。Tailscale Serve のTLS、tailnetのACL（社長の端末のみ）、端末ごとの256bitランダムトークン（iOS Keychain、ThisDeviceOnly）、変更系の `Idempotency-Key` で足りる。単一利用者の閉じたtailnetで、署名の追加コストに見合う脅威がないため。トークンはBridgeにhashだけを保存する。
- 登録と失効：Mac側のCLI（`laa-bridge pair` / `revoke`）が10分有効・1回限りのペアリングコードを出し、アプリで入力またはQR読取する。CLIはエージェントも実行してよく、コードはチャット・ログへ出さず、Mac画面かアプリへの直接表示だけにする。
- 初期scope：社長の端末には `sessions:*`、`tasks:*`、`brain:read`、`media:read`、`photos:select`、`usage:read`、`archives:read`、`archives:create` を付与する。`brain:write`、`gui:operate`、`archives:restore`、`devices:admin` は各ゲートを満たすまで付与しない。
- 追加付与（2026-11-02）：`calendar:read`・`calendar:write`・`media:write`・`brain:create`・`brain:owner`・`voice:transcribe` は既定に含めない。有効な端末へ `laa-bridge grant <device-id|prefix> --scopes <comma-list> --reason <理由>` で付与する。付与できるのはこの6つだけで、`brain:write`・`gui:operate`・`archives:restore`・`devices:admin` やscope groupを含む要求は、一部だけを適用せず全体を拒否する。失効端末は拒否し、既に付与済みなら `alreadyGranted` を返して監査記録を重複させない。監査は端末ごとの `scopeGrants` に理由・時刻・実行UID・対象scopeを残す。同一UIDで変更できるため、改ざん不能な監査ではない。
- 音声入力（2026-11-03）：`voice:transcribe` と `voice:polish` は既定に含めず、原則LAA Voice専用のペアリングに付与する。例外としてWatchの音声入力のため社長のLAAアプリ端末1台へ `voice:transcribe` のみ理由付きで明示付与する。自己失効は音声scopeを1つ以上持ち、それ以外のscopeを持たないVoice専用端末に限り、一般scopeを併せ持つLAAアプリ端末は拒否する。他のLAA機能のscopeは付与しない。Haasの日本語音声認識とQwenの文章整理は固定モデル・入力上限付きで提供し、本文・音声を台帳やログに保存しない。APIとworker起動条件は `bridge/README.md` に従う。
- scopeを足す・付与する時は、そのscopeを参照する他のAPI（例 `/v1/devices/self/revoke`）まで確認する（2026-11-08、`voice:transcribe`の付与で自己失効の副作用を見落としかけた）。
- Studio受付（2026-10-31、タスク34）：新規ペアリングの初期scopeには含めず、ペアリング済みの有効な端末へ管理者が `laa-bridge grant-studio <device-id> --reason <理由>` で `studio:read`（一覧・1件・資材・v2 catalog）と `studio:request`（依頼作成・回答・停止・v2講評）を付与する。承認も同じ端末権限であり、別の認証要素ではない。既存端末は再ペアリングしない。Bridgeは同じMacのStudio受付契約v1・v2にUnixソケットで接続する。v2はsnapshotの `contract >= 2` のとき表示する。契約と実装の稼働は別に確認する。
- Studio依頼の `studio_work_busy` は保存なしの契約により台帳の予約を解除し、同じ依頼ID・本文・keyの明示的な再送を許可する。その要求内でStudioを起動した直後だけ、1.5秒後に1回自動再送する。起動間隔は30秒以上。
- 保持：idempotency台帳は7日、event cursorは24時間。期限切れのcursorは410を返し、アプリは全件を再取得する。
- Workの提供元切替（2026-11-14）：`PATCH /v1/sessions/{id}` に `{provider,model,effort}` を渡す。同じ提供元は既存のモデル変更、別の提供元は同じworkspace・親IDの新しい実行エージェントへ引き継ぐ。会話IDと参照番号、名前、ピン、プロジェクト、判断とLinearの紐づけは維持する。選択はHQのactive/manual Work入口と完全一致するswitchProfilesだけ。従来のprofilesと自動既定は別に保つ。別提供元での起動はHigh以上・Bypass・Fast無効。社長の操作だけで起こり、自動の代替・課金経路・認証情報のコピーは追加しない。
  - 切替中は `modelSwitch:{phase,target}` と `capabilities.providerSwitch` を返す。旧履歴は `delegateHistory`、新しい実行先は `delegate` に保存する。会話表示は履歴を連結し、内部の引継ぎ入力は表示しない。引継ぎには目的、決定・変更・検証・残件の原文と、元の会話記録を保存した0600のsnapshotの場所を含める。
  - 新側は確認なし（bypass）で起動するため、提供元の切替は元の会話が `mode: bypass` の時だけ受ける。確認ありの会話（`default`、記録なしを含む）は409 `model_unsupported` で断り、`capabilities.providerSwitch` もfalseにする。切替で権限を広げない（2026-11-14）。
  - 新側の実モデル・effortと最初の応答を読み戻した後だけ旧側を単独で保管する。失敗時は旧側へ戻す。途中再起動で残った準備状態も同期時に戻し、新側の保管が未確認なら状態を残して追加送信を断る。実行中は409 `model_switch_busy`、子孫の実行・判断待ちは `model_switch_children_busy`、準備・後始末待ちは `model_switch_pending`、作業先不明は `model_switch_workspace`、確認失敗は `model_switch_failed`、選択肢外は400 `model_choice_invalid`。判断ボードに未回答がある場合も切替を断る。
  - `requested` は開始時のまま、`ownerChanged:{provider,model,effort}` と `modelLog` のowner印に「社長の切替」を記録する。旧アプリは同じ提供元の従来PATCHを使える。
### Projects and requirements

Project reads use `sessions:read`; writes use `sessions:write` and `Idempotency-Key`. The list adds `progressNote` (string or null) and `requirementSummary: {completed,total,rate}` (`rate` is 0–1 or `null` if total is zero). Create and patch accept `progressNote` (2 KiB; null clears it). `GET /v1/projects/{id}` also returns `instructions`, `files`, `requirements` and the first page of `sessions`. The JSON `etag` versions the project document for `If-Match` on writes. Detail responses also send a weak HTTP `ETag` covering the actual detail, including the displayed Session observations. Repeat the same query with that header value in `If-None-Match`: an unchanged detail returns 304 with the tag and no body. The GET tag is also accepted by writes using its document version.

```json
{
  "requirementSummary": {"completed": 1, "total": 1, "rate": 1},
  "progressNote": null,
  "requirements": [{"id":"req_0123456789ab","title":"結果を照合","details":null,"status":"completed","source":"owner","sessionIds":["ses_0123456789abcdef"],"order":0,"updatedAt":"2026-01-01T00:00:00.000Z","verifiedAt":"2026-01-01T00:00:00.000Z","verifiedBy":"monet","note":"試験で確認","requestId":"request-1"}],
  "requirementDenominatorLog": [{"at":"2026-01-01T00:00:00.000Z","delta":1,"reason":"要件を追加"}],
  "sessions": [{"id":"ses_0123456789abcdef","name":"Release｜Verify","status":"waiting","model":"model-id","updatedAt":"2026-01-01T00:00:00.000Z","parentId":null,"archivedAt":null}],
  "sessionCounts": {"active": 1, "archived": 0, "running": 1, "awaitingDecision": 0, "waiting": 0},
  "nextSessionsCursor": null
}
```

- Requirement states: `not_started` (default), `in_progress`, `awaiting_decision`, `completed`; `source` is `owner` or `ai`. An owner title is stored verbatim and can't be replaced. Updates use the notes or state; withdrawal hides the row and retains the record. `ids` is a permutation of all current requirement IDs. The store migrates in place to schema 3 (0600); limits are 200 records including withdrawals per project, 600 UTF-8 bytes per title, 8 KiB each for `details` and internal `evidence`, and 30 distinct Session IDs per requirement. Writes use the current project ETag (428 if absent, 412 if stale).
- An agent's `projects rpc` add/patch to `completed` requires `verifiedBy` (`monet` or `ses_<16 hex>`) and a nonempty one-line Japanese `note` (≤200 code points), or returns 422. Bridge stamps `verifiedAt`; an owner can manually set the status without verification from a paired device. The optional `requestId` groups one owner request. `evidence` is available to the internal project RPC only and is not sent to paired devices. The `requirementDenominatorLog` keeps 20 add/withdraw changes with `{at,delta,reason}`. Session status never affects these counts.
- Session statuses are `running`, `waiting`, `awaiting_decision`, and `completed` (closed or archived). `waiting` includes an idle turn awaiting Monet's review; it never completes a requirement. A linked Session's pending decision is reflected without changing the requirement status. Routine and deleted Sessions are not shown or counted. `sessions` defaults to unarchived only, newest update first (ties by ID). `?sessions=all` includes archived Sessions. `sessionsLimit` is 1–200 (default 200); use `sessionsCursor` for the same project and filter with `nextSessionsCursor`, which is null at the end. `sessionCounts` reports both totals before filtering or paging; `active` is every unarchived Session, and `running`, `awaitingDecision` and `waiting` split it by status (the rest are closed but unarchived), so the app never shows the unarchived total as Sessions at work (BUS-508).
- A Session belongs to one Project independent of its workspace. `POST /v1/sessions` without `projectId` stays compatible: a child inherits its parent's project, other Sessions use the reserved `未分類` project. Legacy unassigned records are backfilled, and CLI-created roots appear there unless assigned. `PATCH /v1/sessions/{id}` with only `{ "projectId":"prj_0123456789ab" }` moves it and its descendants without reapplying instructions. Linked requirements must be unlinked first; a child cannot be moved away from its parent. Locally, `laa-bridge projects assign <project-name-or-id> <Work-agent-UUID-or-Bridge-id>` uses the same assignment logic.
- Monet labels its new Work Session with the validated project before it starts and waits for the Bridge import. A requirement linked on launch moves from `not_started` to `in_progress`; an existing decision or verified state is not overwritten. Recover a failed attachment with the original request ID without starting another Session. Only the owner-side launcher may make a new root; Work children keep their existing scoped entry.

### Monet completion reports

- `laa-bridge projects report <project-id> --request-id <id>` calls `POST /v1/monet/completion-report`. After independent verification, the trusted top-level Monet runner is the only caller. Bridge reads the authoritative project, requirements and current decision state; archived projects, empty request checklists, unverified rows and project decisions still open prevent a report. The report carries the project/request and `laa://work/projects/<id>`, never the checklist notes or raw evidence.
- Bridge uses a separate 32-byte random base64url bearer (`LAA_BRIDGE_MONET_TOKEN` in the trusted runner only; Bridge receives its hex SHA-256 as `LAA_BRIDGE_MONET_TOKEN_SHA256`). Do not inherit it into Work sessions, briefs, tools or logs; it is not a pairing scope. Without separate provisioning the routes deny every call. The lane takes only an injected hash and notifier; it never inherits production authorization or uses the production egress. Configuration and live push receipt require separate verification.
- Agent-authored project/session names, requirement notes, and decision title/summary/options are validated at the write boundary; agent notification title/body are checked before enqueue. Whole-string product labels are allowed; otherwise Japanese script is required, and `RESULT:` and `{` prefixes are refused. Errors are 422 `owner_surface_language` with the field name. Paired owner input and internal logs/evidence remain verbatim. Legacy imports without title provenance are not rewritten; unvetted legacy names are not copied into alert titles.

### Existing project defaults and related decisions

- Project既定モデル（2026-11-14）：`defaultProfile` はHQのprofile IDかnull。Projectの作成・更新・一覧・詳細に含み、更新には従来どおりIf-Matchが必要。本文の版とは別にProjectの版を進め、412の現在側にも返す。nullで共通既定へ戻す。新規会話の `profile` が省略されるとProject既定を使い、明示値があればその値を使う。既定が選択肢から消えた時は409 `project_default_unavailable` とし、自動で別モデルへ送らない。
- Project共通指示（2026-10-29、タスク13b）：Projectごとの指示本文はBridgeのstate（0600、既存state dir配下）に保存する。`instructionVersion`（整数）、`instructionHash`（本文のSHA-256）、ETagを持ち、直近10版（本文・hash・版・時刻）を比較・復元用に保持する。`GET /v1/projects/{id}` は `instructions`（本文）と版・hashを返し、一覧は本文を省略する。`POST` は `instructions` を受け付け、`PATCH` は `If-Match` で置換する（欠落428、不一致412では現在の版・hash・ETag・本文を返し、自動マージしない）。`GET /v1/projects/{id}/instructions/versions` は保持中の版を本文つきで返す。指示は**本文のみ**で、`instructionRef`（外部ファイル参照）は受け付けない（400 `instruction_ref_unsupported`）。Bridgeが任意のファイルを読む経路は作らず、AGENTS.md／PROJECT-RULES.mdは各エージェントが自分で読む。判断前に書かれた旧レコードがrefを持つ場合はメタデータとして返すだけで、読まず・適用せず、`PATCH {instructionRef:null}`または本文の保存で消える。`POST /v1/sessions` に `projectId` を渡すと、委譲プロンプトを区切った指示ブロック（版とhashをヘッダ行に含む）＋利用者のプロンプトとして構成し、セッションに `projectId`・`instructionVersion`・`instructionHash` を記録、requestIdの束縛にも含める（指示が変わった再送は409）。作成時に `instructions: null` または `applyProjectInstructions: false` を明示すれば適用しない（社長の明示指定を優先）。イベントは版とhashのみで本文を含めない。委譲先には会話名として `title`（Project名｜セッション名、Projectなしはセッション名）を渡し、requestIdの同一性判定には含めない。旧来の「本文を保存せずhashだけ」「指示は外部ファイル参照でよい」の記述はこの項で置き換える。Projectの資料（2026-11-02）：`POST /v1/projects/{id}/files` で受け取ったファイル（5 MiB・20件まで）をstate dir配下の `project-files/` に0600で保存し、そのProjectのセッションには資料のパスだけを区切ったブロックで渡す（本文はプロンプトへ入れず、エージェントが必要な時に読む）。端末へはMacのパスを返さない。
- 社長のLinearタスク（2026-11-02）：`/v1/linear-owner-tasks` は本人担当・委譲なしの課題だけを扱う。team（BUS）・owner・Todoはアカウントから解決する。作成はクライアント生成UUID、PATCHとarchive/restoreは `If-Match` 必須。画面の削除は確認後の `issueArchive`、戻すは `issueUnarchive`。担当・状態を変えず、旧DELETE・completed指定は受け付けない。`includeArchived` の結果は `trashed` を除き、`?archived=only` でアーカイブを取得する。書込みの `success:true`、または本人担当・ゴミ箱以外の再読取が目的のアーカイブ状態と一致した場合だけ成功とする。`null`・ゴミ箱・壊れた応答を成功根拠にしない。
- Linear BUSはLAAアプリとMonetの社長タスクの正本。ローカルCLIの `laa-bridge tasks list --source linear --limit 10 --json` はアプリと同じ認証済み一覧を読む。提案の状態は `task-proposals.json` に課題UUID単位で保持する。`laa-bridge tasks proposals --pending --sync-linear --json` はLinearで直接作った課題も取り込み、明示的なAI社員割当を除外する。Monetの10分監視は `digest` の変化で提案の候補を拾う。`tasks proposals mark` は提案済み・見送りを記録する。CLIの出力と再試行手順は [owner-tasks.md](../../bridge/docs/owner-tasks.md#9-cli) を参照。
- 監視を有効にするときは、HQの `harness/task_proposals_monitor.py` をMonetのHermesプロファイルの `scripts/` に配置し、`task-proposals` の `monitor_script` にファイル名を指定する。Hermesは初回の正常な出力を基準として保存する。空の一覧からは提案を送らない。
- `laa-bridge projects sessions --json` はWorkのUUIDごとの最新のProject所属を読み出す。`data.items` の各行は `agentId`、`sessionId`、`projectId` を含み、アーカイブ済みの会話も対象とする。
- タスクの取得と完了（2026-11-09）：ペアリング済み端末から社長が作成した課題を `task-runs.json`（0600・atomic replace＋lock）に記録し、AI担当（monet/argus/cfo/cio/cos/cso/cto）だけMonetの代理会話へ渡す。Linearの担当は社長のまま。Linearの担当付けや記録のない課題では起動しない。モデルはsession-optionsのprofileを保持し、HOME・bypass・固定requestIdと初回の依頼文で作成直後／30秒ごとに取得する。再試行は1分→5分→15分→60分、継続できない失敗はfailed。各itemのrunに担当・状態・S/J番号・600字以内の報告を返し、会話または子の未回答判断を判断待ちとして扱う。`laa-bridge tasks report <uuid|T#|BUS-ID> --summary '<結果・検証・残件>'` は紐づく会話かその子から受け付ける（ローカル管理者はagent指定なしで保存可能）。`POST /{id}/complete` はIf-MatchとIdempotency-Keyを要求し、会話ツリーが実行中なら409で変更しない。未回答判断の取下げ→既存サービスによる親子・空のワークスペースのアーカイブ（ピン・S番号解放）→S番号・会話名・担当・モデル・報告の完了コメント→completed型の状態→T番号解放→非同期の `laa-agent cleanup --done-only` の順で進める。段階台帳と固定コメントUUIDで途中失敗から再送できる。課題と全コメントの保管先はHQ `logs/linear/<ID>-<hash>.json/.md`（Git・非公開GitHub）。cleanup失敗でもDoneを保ち、週次の整理へ残す。社長担当・旧課題は会話なしで完了できる。実行記録は完了から30日保持し、壊れた保存内容は503で読み書きを止める。
- 予定・スキル・定期実行（2026-11-02）：`GET /v1/calendar/events` は `calendar:read`、`GET /v1/skills` と `GET /v1/routines` は `sessions:read` を要求する読取専用の端点。Calendarの範囲は42日以内で、設定・認可・APIの失敗は空の予定にせず503を返す。Skillsはfrontmatterの `name`・`description` に、名前別の分類・日本語要約・詳細を加える。未登録は「その他」と元の説明。SKILL.md本文は返さず保存しない。RoutinesはConsoleの観測値と構造化された `triggerKind` を投影する。アプリは時刻つきの定期実行を通常一覧、常駐・手動・未確認を一覧末尾の「常時」帯、`state: "paused"` を一覧の下の「停止中」折りたたみ（既定は閉）に表示し（2026-11-23 社長）、未観測はnull、読取失敗は503とする。
- 遅い読み取りのキャッシュ（2026-11-02）：`GET /v1/routines` は成功値を60秒鮮度で保持し、期限切れは古い値と `fetchedAt` を即返して裏で1本だけ更新する（`laa-console jobs` のtimeoutは60秒。値が一度も取れていない間だけ503）。`GET /v1/studio/snapshot` と `/v1/studio/catalog` も同じ方式で、Studioが応答しない時は前回の成功値に `stale:true` と `fetchedAt` を付けて返し（snapshotは届いていないので `online:false`）、読取はStudioの起動を待たずに503する。`GET /v1/usage` は背景feed読み取りのままで、`fetchedAt` にfeedの受信時刻を返す。既存の応答形式・認可・エラーコードは変えず、追加フィールドだけを足す。
- 未決の3（GUI）と4（Brain書込み）は本書の案どおり、実証まで提供しない。5（Usage）はタスク05の結果で決める。

- iPhone Use permission (2026-11-12): `laa-phone unlock` finding the iPhone open runs `laa-bridge phone-use ask` under 1Password (the LAA APNs key, `~/.config/laa/hortensia-relay.env.tpl`, for that run only). The CLI writes the request to the 0600 `phone-use.json` and starts the `LAAPhoneUseAttributes` Live Activity by push-to-start (`input-push-token: 1`), then waits for the answer (default 90 s). The phone registers its push-to-start token (`PUT /v1/phone-use/start-token`) and each activity's update token (`PUT /v1/phone-use/requests/{id}/activity-token`), and posts Allow, Don't Allow or Stop (`POST /v1/phone-use/requests/{id}/answer`), all with `sessions:write`; only the device that registered the start token can answer. `phone-use end` closes the request and ends the activity with an end push; iOS may not hand over the update token for a pushed activity, so `end` then wakes the app with a background push (`laa_phone_use`, to the app push token sent as `wakeToken` with the start token), and the phone reads its request (`GET /v1/phone-use/requests/{id}`) whenever the app runs and ends an activity whose request closed. A dropped APNs connection with no answer is retried once. One open request at a time; pending requests expire at their answer time and allowed ones at the session limit. A session that began from a locked iPhone asks nobody: its guard runs `laa-bridge phone-use begin` (2026-11-13), which opens the request already `allowed` (`unasked: true`) and starts the activity in `operating` with Stop, so the owner who picks the phone up sees it and can stop it; `status`, the answer route (Stop only) and `end` treat it like any allowed request.

Allow and Don't Allow stay in the bottom permission row. While operating, Stop sits beside the status in the upper trailing area on both the expanded Dynamic Island and the Lock Screen; it must never replace the permission row, so a repeated tap at Allow cannot stop the operation (owner, 2026-11-15).

### 番号（refs）（2026-11-08）

社長が「T12をやって」のように短い番号でタスク・セッション・プロジェクト・定期実行・スキルを指せるようにする。番号は既存の識別子（Linear課題ID、session id、project id、routine id、スキル名）を置き換えず、追加の別名として持つ。

- 接頭辞は task `T`、session `S`、project `P`、routine `R`、skill `K`（同じスキルがClaudeとHermesにあっても1つ）。
- 判断ボードの判断は decision `J`（2026-11-08追加。`D` はD1と紛れるため避けた）。保持するのは未回答と「届いていません」の間だけで、配達済み・取下げで解放する。同期は60秒ごとと判断ボードの同期（新しい判断の通知の前）で、通知の題に `判断 J3: …` と出す。依頼元のS番号は判断へ写さず、表示時にsession keyから引く（`sourceRef`）。
- 保存は `<state dir>/refs.json` の1ファイル（0600、schema付き、atomic replace + lock）。レコードは `{ref,kind,n,key,title,external,assignedAt,releasedAt}` で、`title` は200文字までの題名だけ。説明・プロンプト・スキル本文は保存しない。壊れたファイルは黙って作り直さず、読み書きを拒否してエラーにする（`ref:null` で一覧は返す）。
- 割当は「そのキーが以前持っていた番号が空いていれば戻す」、なければ「保持されておらず、別のキーが24時間以内に解放していない最小の番号」。解放済みの履歴は30日残す。初回の一括割当は種類ごとに古い順（taskは `BUS-12` が `BUS-130` より先、session/projectは `createdAt`、routineは `id`、skillは名前）。
- 解放は、Bridge経由のアーカイブ・削除・完了・取消・再割当の即時と、その種類の**完全で成功した**読み取りから消えた時だけ。失敗・部分・ページ途中の読み取りでは解放しない。一度も成功していない種類のレコードは触らない。
- 一覧・詳細の応答は各itemに `"ref": "T12" | null` を足す（`/v1/linear-owner-tasks` のアーカイブ一覧は常にnull）。`GET /v1/refs?kind=` は保持中の番号、`GET /v1/refs/<ref>` は `{ref,kind,status,holder,previous}` を返す。解決の入力はNFKC・空白/`-`/`_`除去・大文字化の後に `^([TSPRKJ])0*([1-9][0-9]{0,4})$` で、`t12`・`Ｔ１２`・`T-12`・`T 12` を受け付ける。未知で履歴もなければ404 `ref_unknown`、解放済みは200で `status:"released"` と30日以内の `previous`。
- 認可はデータに合わせる。taskは `tasks:read`、他は `sessions:read`。読めない種類だけを明示要求した場合は403。
- 同期は、session・project・skill・decisionを60秒ごとのローカル読み取り、routineを既存のroutinesキャッシュ、taskを5分ごとの既存owner-task一覧キャッシュ（全ページ読めた時だけ完全）で行う。同期は一覧応答を待たせず、失敗してもその応答を失敗させない。
- CLIは `laa-bridge ref <ref> [--json]` と `laa-bridge refs [--kind <kind>] [--json]`。`refs.json` を直接読むだけで、サーバー停止中も動き、書き込まない。`--json` の `ref` は、社長の依頼文へそのまま貼れる1行の `brief` を足す。


Paseoセッションのアプリ置換（2026-11-02）:

- 実稼働起動はdaemonの全メタデータを取り込み、Bridge由来でない会話にも安定したses IDを付ける。`delegateSessionId`はPaseoのagent IDを保持する。アプリは`scope=all`でアーカイブを含めてリンク先を解決する。
- 会話は要求時だけprojected timelineから取得する。reasoning・ツール入出力は返さず、ツール名と実行状態を要約する。
- `GET /v1/sessions/{id}/initial-instruction`（`sessions:read`）は保存した初回指示・日時・経路を返す。Bridge作成時の全文を保持し、Work経由は履歴かローカルの初回控えから一度回収する。提供元切替前にも保存し、一覧・イベントに本文を含めない。取得不能は`instruction: null`。
- `POST /v1/sessions/{id}/interrupt`は現在の手番を中断し、同じ会話への追加指示を許す。従来の`stop`の契約は保つ。`GET .../decision`が発行した5分ticketとpending hashを`POST .../reply`で照合し、回答の消化を再読取する。
- 追加指示は安定したmessage IDとsteerを使う。画像は最大4枚・合計4 MiBをstate内の0600ファイルへ保存する。既存Paseo画像の参照は公開履歴にないため、表示はLAAから送った分に限る。
- 返答中のMac上の画像（`![x](file:///…)`・`![x](/Users/laa/…)`・画像の `::preview{file="…"}`）は、Paseoの添付フォルダか、下の所有者ファイルの境界を通る8 MiB以下の画像だけをその会話の `images` に登録し、本文から外す。通らない物は「（画像を表示できません）」を残す。コードブロックと引用行は例として触らない。
- `GET /v1/sessions/{id}/files?path=<絶対パス>`（`sessions:read`）は、返答が名指したファイル（リンク・HTMLやPDFの `::preview`）を `{name,mimeType,size,data}`（base64）で返す。その会話の本文に出たパスだけを読み、出ていないパスは境界内でも404。ホームの隠しフォルダ・隠しファイルは `.hermes/profiles/*/images` と `.local/state/laa-muse` だけ。読めるのはホーム配下の単一リンクの通常ファイル16 MiBまでで、書いたパスと実体の両方がホーム内（シンボリックリンクで外へ出ない）、`.ssh`・`.config`・`.git`・`.aws`等と `~/Library`（Keychainを含む）・Bridgeのstate、`*.env`・鍵・`credential`・`secret`・`auth.json` の名前を拒否する。最後の名前はsymlinkを辿らずに開き、開いた記述子と実体の一致を確かめてから読む。境界外・不在はどれも404 `not_found`（`bridge/src/sessions/owner-files.mjs`）。
- `notifyOwner`は既存Hermesプラグインの暗号化配送を使う。未達は永続化して30秒ごとに再試行し、同時配送は2件までとする。実通知・実会話書込・実機性能は親が最終確認する。
- Notification actions: all kinds carry `v:1,k` in the base64url JSON suffix of `session_id` (`laa-bridge:<deepLink>#<meta>`, ≤512 UTF-8 bytes). Board metadata adds `id,o,d?`; sessions add `sid` plus `h,o` for one supported question with 2–6 choices, or `h,a:1` for one tool approval whose whole request fits the body (name + compact one-line JSON input, ≤140 characters, only printable ASCII and plain Japanese characters (allowlist), nothing secret-shaped; otherwise generic body, no buttons, and `quick-reply` answers `allow` with `quick_reply_unsupported`). `h` equals the decision ticket's `requestHash`; retries preserve the encoded value. Labels shorten evenly, then `o` is removed, then the legacy link is used if needed.
- Notification preferences: `GET|PUT /v1/notifications/preferences` use `sessions:read|write` (PUT is idempotent). `{kinds:{...},updatedAt}` exposes eight categories; only stored overrides persist in locked 0600 state. Default is alert except `finished=off`. A legacy `finished: quiet` without an owner marker was indistinguishable from the materialized old default; it migrates once to off, preserving explicit owner-marked quiet and other stored values. New owner changes are marked. Quiet adds `lv:"p"`; off skips delivery and retries, but decision/question/approval cannot be off. Child completions, `agent-notification` and `monet.proposal` never enqueue a push. Invalid updates return `notification_preferences_invalid` (400). `monet.report:<projectId>:<requestId>` has a separate persistent dedupe ledger which fails closed at capacity rather than evicting prior keys.
- Quick answers: optional boolean `quick:true` on board answer rejects expired deadlines (`decision_expired`, 409) after request-ID replay and closed-state checks. `POST /v1/sessions/<id>/quick-reply` accepts `{requestHash,choice:"allow"|"deny"|{optionIndex}}` with `sessions:write` and Idempotency-Key; it requires one unchanged pending request and reuses the existing ticket/reply/readback path. Unsupported formats return `quick_reply_unsupported`; changed or consumed requests return `pending_request_changed` (409). Full contract: `bridge/README.md`.

### Google API追加（BUS-338・BUS-318）

Google接続は `bridge/src/google/connection.mjs` に共通化し、既存helperのJSON形式を維持する。追加OAuth scopeは `drive.readonly`、`drive.file`、`calendar.events`、`calendar.calendarlist.readonly`（すべて`https://www.googleapis.com/auth/`配下）。親が同意と端末の追加grantを行うまで書込みは使えない。

- `GET /v1/calendar/calendars`、`GET /v1/calendar/events/<id>?calendarId=`: `calendar:read`。予定IDは招待・ICSの`@`も安全にエンコードして扱う。一覧は不正な予定だけを除外し`skippedCount`を返す。削除済み404、競合409を再試行可能な503へ変換しない。
- `POST /v1/calendar/events`、`PATCH|DELETE /v1/calendar/events/<id>`: `calendar:write`とIdempotency-Key。編集・削除はbodyのetag必須。Googleの条件付き更新失敗は409。参加者への通知を伴う保存・削除はアプリで確認する。
- `POST /v1/drive/uploads`: `media:write`とIdempotency-Key。name/mimeType/sizeと任意folderIdを渡す。
- `PUT /v1/drive/uploads/<opaque-id>/chunks/<offset>`: 同scopeとIdempotency-Key、最大4MiBのバイナリ。Googleのresumable URLやtokenを端末へ渡さず端末IDに束縛する。再起動で未完了uploadは失効する。任意フォルダへの追加にはGoogle側でdrive.fileの対象となる権限が必要で、拒否時はマイドライブへ保存する。
- `GET /v1/drive/uploads/<opaque-id>`: `media:write`。空PUTでGoogleの受信位置を照会し、応答喪失後も再送前に照会する。完了応答もセッション期限まで保持する。端末画面を閉じた後やBridge再起動をまたぐ再開は未対応。Driveのメディア302はHTTPSの許可Googleホストだけへ最大3回追従する。
- Calendar通知は`LAA_GOOGLE_REMINDERS_ENABLED=1`で有効化する。直近24時間の未配信を起動・復帰時にも追送し、永続dedupeKeyで重複を避ける。Googleのpopup設定に従い、共通notifyOwnerへ送る。deepLinkは`laa://today/events/<id>?calendar=<calendarId>`。親が通知経路を統合し、本人の端末で到着と遷移を確かめる。
