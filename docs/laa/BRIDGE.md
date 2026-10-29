# LAA Bridge 契約・脅威・復旧設計

2026-10-29。実装・接続・権限変更は未実施。仕様の提案であり、採用や安全性の実証ではない。根拠は [ROADMAP.md](ROADMAP.md) と [BASELINE.md](BASELINE.md)。依存先の機能をBridgeで再実装せず、未確認の接続・権限は実装ゲートとする。

## 1. 責務と配置

- Mac mini上のユーザー権限の**単一Bridgeプロセス**を専用launchd LaunchAgentで管理する案。HTTPは127.0.0.1の専用ポートのみで待受け、Tailscale Serveの専用HTTPSポートから転送する。番号は空きと競合を実測後に決定。Funnel・LAN直公開は禁止。Tailscale未接続・Mac未ログイン時の利用は保証しない。
- 既存8444→9119はHermes dashboard／Conduit、8443はUsage等のServe。両設定を変更・共有せず、BridgeのServeだけを追加・停止する。HTTPS証明書・経路は既存Tailscale方式を再利用し、tailnet到達性と端末認証を別に判定する。ループバックの別プロセスを信頼境界と誤認しない。
- 会話・通話・通知は現行Conduit pluginの経路を維持。Macの実体は0.69.1で、上流0.116.0のAPIを使用可能と仮定しない。Sessionの委譲は `laa-personal-agent` のcreate/status/wait/list/send/reply/stopとPaseo daemonを利用し、provider・model・effort・認証経路・停止状態を維持する。Paseo CLIにもlist/run/logs/stop/send等があるが、同等性は未実証。
- TaskはLinearが正本、習慣はBrain daily。Drive・Photosは既存のMac側正規Google認可のみ、Usageは既存dashboard analytics／CodexBar proxy／Console collectorの選定済み出力を読む。現状CPU・メモリ収集は未確認、欠測で返す。Archiveは整合snapshotとDrive保管のアダプターで、稼働中SQLiteの双方向同期はしない。
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
| `GET/POST /v1/projects`; `GET/PATCH /v1/projects/{id}` | `{name,instructionRef,instructionHash}` → `{id,version,...}`、Bridge管理候補 | 権限外の指示参照・古いversionを拒否。Projectとworkspace分離 |
| `GET/POST /v1/workspaces`; `GET /v1/workspaces/{id}` | `{projectId,repoId,worktreeName}` → `{id,path,status}`、既存Paseo/worktree | 正規化・symlink・許可外repo拒否、既存worktree非破壊 |
| `GET/POST /v1/sessions`; `GET /v1/sessions/{id}` | `{projectId,workspaceId,parentId,requestId,profile,prompt}` → `{id,requestId,status,requested,observed}`、personal-agent/Paseo | 同じrequest ID、親子・名称、実provider/model/effortと認証経路、作成不明の回収 |
| `POST /v1/sessions/{id}/messages`; `POST /v1/sessions/{id}/stop`; `POST /v1/sessions/{id}/resume` | `{message}`／`{}`／`{message}` → `{operationId,status}`、同上 | 送信不明、停止未確認、停止中再開拒否。resumeは既存のsend相当と確認できる場合のみ |
| `POST /v1/sessions/{id}/reply` | `{requestId,requestHash,answer,expiresAt}` → `{status}`、同上 | 改変・期限切れ・別session・workerの回答拒否。実際の承認消化を照合 |
| `GET /v1/sessions/{id}/events`; `GET /v1/sessions/{id}/artifacts` | cursor → event一覧／`{items:[{id,name,type}]}`、同上 | 認可・重複・欠落・ファイル範囲外・再接続を確認 |
| `GET /v1/tasks`; `POST /v1/tasks`; `GET/PATCH /v1/tasks/{id}` | `{title,owner,executor,status,dependencies,sourceId,version}` → task、Linear | 版競合・担当変更で自動起動しない・Linearに読戻し |
| `GET /v1/routines?date=...`; `POST /v1/routines/{id}/check` | `{date,checked,operationId,baseHash}` → `{status,hash}`、Brain daily | 日付切替・再送・同時編集、調停未実証時は書込拒否 |
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
- Paseoを置換するにはROADMAPの移行ゲート（手動・Ciel委譲・cron、provider/model/effort・課金、承認、停止・復帰、二重実行、再起動）を実測する。Linearは全属性・履歴・旧ID照合、単一writer、復元と正本更新が揃うまで唯一のタスク正本。Bridge稼働や画面完成だけで移行完了としない。
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

- 端末認証：要求ごとの署名・nonce台帳は採らない。Tailscale Serve のTLS、tailnetのACL（社長の端末のみ）、端末ごとの256bitランダムトークン（iOS Keychain、ThisDeviceOnly）、変更系の `Idempotency-Key` で足りる。単一利用者の閉じたtailnetで、署名の追加コストに見合う脅威がないため。トークンはBridgeにhashだけを保存する。
- 登録と失効：Mac側のCLI（`laa-bridge pair` / `revoke`）が10分有効・1回限りのペアリングコードを出し、アプリで入力またはQR読取する。CLIはエージェントも実行してよく、コードはチャット・ログへ出さず、Mac画面かアプリへの直接表示だけにする。
- 初期scope：社長の端末には `sessions:*`、`tasks:*`、`brain:read`、`media:read`、`photos:select`、`usage:read`、`archives:read`、`archives:create` を付与する。`brain:write`、`gui:operate`、`archives:restore`、`devices:admin` は各ゲートを満たすまで付与しない。
- 保持：idempotency台帳は7日、event cursorは24時間。期限切れのcursorは410を返し、アプリは全件を再取得する。
- 未決の3（GUI）と4（Brain書込み）は本書の案どおり、実証まで提供しない。5（Usage）はタスク05の結果で決める。

