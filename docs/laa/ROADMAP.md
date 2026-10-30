# LAA iPhoneアプリ：構成と実装順

2026-10-29。対象はLaaFloralia/hermes-conduitのLAA版。これは実装計画であり、接続・実機稼働を示さない。別作業中の署名／TestFlight、CallKit発信、ConsoleのUsage非表示には手を重ねない。各タスクは最大2作業日、日付や期限の約束ではない。iOS実装・独立レビューは [PROJECT-RULES](../../PROJECT-RULES.md) を優先し、その他の実装は公式DSH、デザインはdesign-worker、判断・統合・検証は親。D1・Jevの判断、指定モデル・認証・停止状態を維持する。

## 決定と境界

- 画面は「会話」「仕事」「Brain」「素材」「Usage」の5タブ。仕事にセッション／Project／タスク／ルーティン、素材にDrive／Inspiration／Studioを置く。設定と検索は各画面から開く。
- Mac mini上に**単一のLAA Bridgeサービス**を置き、既存Hermes Conduit pluginは会話・通話・通知の既存機能に使う。Bridgeは認証とAPI、既存サービスのアダプター、復帰可能なイベント配信を担当する。pluginにBrain・Drive・実行管理まで足すとHermesの更新とprofile単位の生存期間に全領域が結合する。逆にBridge内でHermes・Paseo・Kanban・Usage収集を再実装しない。既存 `laa-personal-agent`、daemon、cron、agent-control、Studio、Syncthingを段階的に接続する。サービス新設前に既存経路の実体とAPIを確認し、単一プロセス・明示的な権限分離で済むことを検証する。
- 個人と社員のタスク・判断待ち・進捗の現行正本は**Linear**。Brain dailyは習慣・日誌で、タスク台帳ではない。Inboxの旧案にある「個人タスクはBrain正本」は現行 `hq/tools/LINEAR.md` より古く採用しない。Kanbanは担当だけでworkerを自動起動し得るため、社長タスクを複製しない。Linear代替は移行ゲート後に正本を切り替える。
- Project（ジャンル・共通指示）、Workspace（repo／作業ディレクトリ／worktree）、Session（会話・担当・モデル）、Attempt（実行）を分ける。人が命名した名を優先し、自動命名と子の「子｜」を維持。社長・Ciel・定期処理が同じ契約を使う。
- 既存の会話モデル、provider、effort、サブスク認証と課金経路を維持。モデル名が一致するだけでは同等としない。MacのGUI操作は排他し、終了・失敗時に権利を回収する。長期memoryは既存方針どおり無効。

## 要件・制約・判断・受入

各行は「要件 → 制約 → 決定 → 段階／担当 → 受入」。段階は後述。

| 要件 | 制約・決定 | 段階／担当 | 受入 |
|---|---|---|---|
| LAA名・会社アイコン | 署名・App ID・拡張は別workerの成果に依存。既存版との識別を維持 | P0／親・design-worker | 署名済み版のホーム画面と起動後に名称・アイコンを実機確認 |
| Dots風の純正通話と社員の3D | CallKitの純正画面に任意のリアルタイム3Dを置く公開APIは確認できない。システム画面はCallKit、動く社員像と操作はアプリ内通話画面。純正アイコンはprovider用の静的マスク | P0–P1／DSH・design-worker | 対象社員と文脈を維持し、発信・終了・ミュート・スピーカー・ロックを実機確認。Dotsとの実物比較は未了 |
| 社員チャット・右上の電話 | アニメーションと入力欄の更新が競合し得る。社員ごとの3D、会話固有の電話導線 | P1／DSH・design-worker | 複数社員で像・文脈が混ざらず、通話後に元会話へ戻る |
| ホームウィジェット | WidgetKitは常時描画しない。更新時アニメーションは最大2秒。3Dモデルから生成した静止画を使いCielを初期値とする | P1／DSH・design-worker | ホームから指定社員の通話／チャットに遷移。必要な署名・App Groupを実機で確認 |
| LINE風背景・グループ | 既存roomを再利用。背景は会話別に設定、文字の可読性を優先。参加社員の変更は既存実装を確認して拡張 | P1／DSH・design-worker | 会話とグループを作成し、参加者・背景・履歴を再起動後も区別 |
| 入力のSimeji予測・小さい欄・文字サイズ | IME変換中の再生成を避ける。既存全画面・IME保護を再利用し、下書きを永続化 | P1／DSH | Simejiと標準日本語で変換中の返信、画面切替、終了復帰を実機確認。入力／回答の文字サイズ変更、添付・下書き復元、送信不明の表示を確認 |
| 社長・Cielのセッション、ジャンル別Project | Projectとworkspaceは別。共通指示の適用版を保存、明示指定を優先、曖昧な割当は候補提示 | P2／DSH・親 | 両者が作成・入力・停止・再開し、自動命名と手動名を保持。worktree、モデルと指示版を確認 |
| プレビュー | iPhoneのPC幅表示とMac実画面は別物。WebKitで横向きPC幅、Mac配信は既存資産を調査して別途実装 | P2／DSH | PCとiPhoneで同一対象を開き、横画面の幅・スクロールを検証。実画面配信は接続・権限・操作排他を別に検証 |
| 社長・社員タスクと習慣 | 現在Linearがタスク正本、Brain dailyが習慣原本。仕事Taskと実行Jobを分離し人の担当では自動起動しない | P2／DSH・親 | 同一Taskを今日／ボードで表示し、実行成功と社長確認待ちを区別。習慣は同一dailyのチェックを更新、再送・日替わりで重複しない |
| AI UsageとMac容量 | 既存Console／usage-meters／CodexBarの収集を再利用。推計・実請求・利用枠を混ぜない | P1／DSH | 出典・時刻・単位・未取得／古い値を表示。Mac空き容量・CPU・メモリを表示し、未取得を0にしない |
| BrainをNotion風・Markdownネイティブに | SyncTrain／Syncthing・Obsidian・Gitが別writer。無損失編集と競合保全が前提 | P3／DSH・design-worker | 見出し・リスト・チェック・表・画像・コード、検索・最近・タグ・ギャラリー、原文切替。frontmatter・wikiリンク・未知構文・相対画像を保持し同時編集の両版を復旧できる |
| Drive動画・Photos・審美眼 | Drive blobのRange取得をAVPlayerへ渡す。Photos既存全件の自由な一覧同期を前提にせずGoogle Photos Pickerで選択 | P3／DSH・design-worker | 実機で一覧・検索・再生・seek・回線断・非対応形式を確認。選択した写真だけ取り込み、出典・好きな理由・用途・採用状態を保存 |
| 古い会話とデータをDriveへ保持 | 稼働中SQLiteをDriveで双方向同期しない。整合したsnapshotをmanifestとhash付きで保管し、初版は自動削除しない | P3／DSH | Driveのアップロード後に読戻し・hash照合、別環境で本文・添付を復元。閲覧復元とruntime再開を別表示 |
| Liquid Glass・Studio iPhone Lab | Glassは操作層、本文は読みやすい面。既存Studioの素材・参考・版管理を使い、Web試作とSwiftUI実機確認を分ける | P0–P3／design-worker・DSH | 参考1〜3件の採用理由、色・文字・余白、通常／空／失敗／オフライン／競合の比較版を残し、社長が実物を選べる |

## Bridge契約（実装前の設計）

- 通信はTailscale内のMac miniへ限定し、Tailscaleの接続だけをアプリ利用者の認証と見なさない。端末単位の認証と認可、TLS、失効、再登録、監査、最小権限を設計・検証する。インターネットへ公開しない。トークンはKeychain等の正規保管先、Google認証はMacの既存正規経路を使い、秘密をログ・URL・モデルへ渡さない。Tailscale切断時は明示し、未送信を保持する。
- `/v1/projects`：一覧・作成・更新。共通指示の版hashと参照権限を保存。`/v1/workspaces`：repo／worktree選択・作成・状態。パスは許可済み範囲に限定し既存worktreeを破壊しない。
- `/v1/sessions`：一覧・作成・詳細、`/{id}/messages`、`/{id}/stop`、`/{id}/resume`、`/{id}/events`、`/{id}/artifacts`。子は親ID、request ID、workspaceと実際のprovider／model／effortを記録。eventは連番と再接続cursorを持つ。作成・送信にidempotency keyを要求し、結果不明時は再照合して二重起動を防ぐ。承認・質問回答はsession／request／内容hash／期限に束ねる。
- `/v1/tasks`：現行はLinearの読み書きアダプター、将来は移行済みKanbanの単一正本。owner、executor、status、依存、結果、元IDを分離。`/v1/routines`：Brain dailyの習慣に対する読取・チェック操作。日付・対象・操作IDで重複防止し、チェックは実行許可にしない。
- `/v1/brain/files`：許可されたvault内の一覧・取得・検索。`PUT /v1/brain/files/{id}`に取得時のcontent hashと新本文を渡す。パス正規化・symlink検査、書込直前の実ファイルhash照合、同一filesystemの一時ファイルからatomic renameを行う。API内の同時書込は直列化するが、外部writerとの間のcheck→rename競合はこれだけでは防げない。Syncthing／他writerとの調停方式を実装前に検証し、安全なCASを保証できない経路は書込を止める。hash不一致なら409と双方の識別情報を返し、元ファイルとユーザーの編集案を別に永続保存して解決を待つ。オフライン下書きも保持し、Git同期・既存のBrain禁止を尊重。
- `/v1/drive/files`：既存権限内の一覧・検索・metadata、`/{id}/content`はRange・206・Content-Range・長さ・MIME・キャンセルを中継し、AVPlayerで認証付き再生・seek。Driveのダウンロード可否、形式・エラーを表示。非対応は原本を保持しMacでプレビュー生成。Workspace文書のexportはRange再生と区別。
- `/v1/photos/picker/sessions`：Google Photos Pickerの作成・選択画面への遷移・完了確認・選択項目取得・終了を仲介。選ばれた素材だけを取込み、セッション有効期限と権限を扱う。iOSのPhotosPickerとGoogle Photos Pickerは別物。
- `/v1/usage`・`/v1/mac/status`：既存取得結果を読取専用で返す。観測時刻・出典・単位・失敗・鮮度を付け、資格情報は返さない。`/v1/archives`：整合snapshot／manifest／添付hashの作成、Drive転送、検証、復元。自動削除APIは作らない。
- セッション、task、Brain、メディアは権限範囲を分け、巨大データや秘密を一般ログへ出さない。障害時は既存Hermes・Paseo・Linear・同期を止めずにBridgeだけ戻せるようにする。

## 移行ゲート

**Paseo**：画面を隠すだけで置換完了にしない。社長の手動、Cielの `laa-personal-agent` 委譲、既存cronの代表ジョブをPaseo非起動で実行し、各provider・指定モデル／effort・認証／課金、worktree、承認・質問、子セッション、命名、ログ・成果物、停止・再開、再接続・二重実行防止、Mac再起動からの復旧を実測する。既存ジョブの停止・Brain禁止・通知先とagent-controlを保持し、同じslotを二重実行しない。各経路の依存と復帰手順を照合し、切替後の受信確認まで旧経路を保管。欠落があればPaseoを維持する。

**Linear**：移行前はLinearのみ正本。新タブで人のTaskと社員Jobを分離し、担当変更で実行されないこと、状態・担当・期限・リンク・コメント・添付・履歴・旧IDの照合、検索・作成・更新・確認待ち・完了・復元、障害時の戻しを実証する。移行期間は1件につきwriterを1つに固定し、再実行時も重複しない。全対象の件数・内容を読戻し後、旧側を参照用にし、新正本とHQ／共通指示・運用文書・台帳を同一切替で更新し `laa-console integrity` を実行する。旧データの削除は別途確定が必要。完了までは現行Linear運用とDone保存・整理を保持する。

## 実施順と依存

P0 基準版：署名／発信の並行作業の結果を取り込み、設計・現状を実測。P1 日常：入力・外観・Usage。P2 仕事：Bridgeとセッション、タスク移行。P3 文書・素材：Brain・Drive・保管。各番号は1担当・最大2作業日。依存は完了済み成果を指し、並列作業は所有ファイルを分ける。設計・実装のPRでは `docs/FEATURE_MAP.md` の兄弟画面と未対応を照合する。

| ID | タスク（担当） | 依存 | 受入 |
|---|---|---|---|
| 01 | 現状・依存棚卸し（DSH） | なし | 実体、稼働版、重複作業、移行リスクを証拠付きで確定 |
| 02 | Bridge契約・脅威と復旧設計（親） | 01 | 契約、認証、失効、責務と切戻しをレビュー可能にする |
| 03 | Studio iPhone Labの視覚案（design-worker） | 01 | 参考・画面・状態・採用理由を実物で比較可能 |
| 04 | 実機ベースライン・入力再現（DSH） | 01、署名workerの成果 | 未確認と実測を分離し、IME・入力・通話・widgetを記録 |
| 05 | Usage・Mac監視の既存データ契約（DSH） | 01 | 同一取得元・鮮度・欠測と認証境界を特定 |
| 06 | Bridgeの認証・health・起動停止（DSH） | 02 | 許可／拒否・失効・再起動・Tailscale断を検証 |
| 07 | 5タブ骨格・名前とアイコン（DSH） | 03、04 | 署名済み実機で5入口と既存画面へ遷移 |
| 08 | 入力サイズ・全画面・永続下書き（DSH） | 04、07 | Simeji／標準IME、強制終了・送信不明を検証 |
| 09 | UsageタブとMac状態（DSH） | 05–07 | 実測時刻と欠測を含め既存取得値と照合 |
| 10 | 個別背景・グループ操作（DSH） | 07 | 履歴・社員・可読性と再起動後の設定を確認 |
| 11 | 社員3Dとアプリ内通話（DSH） | 03、07、CallKit worker | 選択社員・文脈、発信・復帰を実機確認 |
| 12 | Cielウィジェット（DSH） | 03、07、署名worker | 静止3D画像と通話／会話導線を実機確認 |
| 13 | Project・workspace契約と指示版（DSH） | 06 | Projectと作業場所の分離、指定・手動名の優先を検証 |
| 14 | Sessionアダプターとイベント再接続（DSH） | 06、13 | 起動・追加入力・停止・重複防止・ログ回収を検証 |
| 15 | Ciel委譲・子セッションの互換（DSH） | 14 | 指定モデルと親子対応、質問往復、成果物回収を実測 |
| 16 | provider・worktreeの同等性（DSH） | 14 | 実認証経路・effort・分離・復帰を実測 |
| 17 | cron・再起動・通知の移行試験（DSH） | 15、16 | 停止状態・slot・通知先を維持し代表業務を二重実行せず完了 |
| 18 | Paseo切替判定（親） | 15–17 | 全ゲートの証拠と戻し方を確認。欠落時は継続利用 |
| 19 | タスク読取と人／Job分離（DSH） | 06 | Linearと照合し担当だけでworkerが起動しない |
| 24 | Brain競合・同期調査（親） | 01、02 | 外部writer間の安全な調停と停止条件を実証 |
| 25 | Brain読取・保存・競合保全（DSH） | 06、24 | 同時書込・中断・オフラインで両版保持 |
| 20 | 習慣チェック（DSH） | 19、25 | daily原本に競合安全で反映、日付・再送で重複しない |
| 21 | Kanban書込と移行リハーサル（DSH） | 19 | 旧ID・全必要属性・件数・履歴と戻しを照合 |
| 22 | Linear切替と正本更新（親） | 20、21 | ゲートを満たし、正本文書と台帳を更新・整合検査 |
| 23 | PC幅プレビュー（DSH） | 06、14 | iPhone横画面・PCで同一画面を表示 |
| 26 | Brain Markdown編集・検索（DSH） | 25、03 | 未知構文と相対画像を保ちiPhoneで編集・検索 |
| 27 | Brainギャラリー・関連表示（DSH） | 26 | 最近・タグ・関連・ギャラリーが原本と一致 |
| 28 | Drive一覧・Range動画（DSH） | 06 | 実機再生・seek・認証期限・通信断を確認 |
| 29 | Photos選択・Inspiration（DSH） | 28、03 | 選択項目のみ取り込み、出典・理由・用途を検索 |
| 30 | 履歴snapshot・Drive保管（DSH） | 06、14、28 | 整合性照合・別環境復元。自動削除なし |
| 31 | Mac実画面配信の調査・試作（DSH） | 23 | 既存資産・OS権限・GUI排他と接続の実測 |
| 32 | 実機総合検証・Lab版照合（親） | 08–12、18、22、26–31 | 実機、オフライン、復旧、アクセシビリティ、採用デザインを確認 |

## 最初の5件：派遣仕様

**共通**：入力は本書、対象repoと適用PROJECT-RULES、既存正本の必要節。秘密や会話全文を子へ渡さない。iOS実装・独立レビューはPROJECT-RULES、その他の実装は公式DSH `deepseek-v4.1-flash` High、デザインはdesign-worker、親は現在のモデルを維持。各自のworktreeと所有範囲を指定し、競合作業やmasterを変更しない。結果に実provider／model／effort、証拠、未確認、検証と停止理由を添える。起動値と結果を親が照合する。

1. **01 現状・依存棚卸し**：DSH High、読取のみ。対象はConduitのFEATURE_MAP・widget・Kanban、HQのPASEO-HERMES／AI-OPERATING-MODEL／LINEAR、`laa-personal-agent`、既存Usage・Studio・同期経路。所有物は作業用の棚卸し結果のみ。署名／CallKitの別workerの状態、稼働版とrepo版、Paseo依存とcron、ConsoleのUsage変更、Brainの同期writer・ディレクトリを照合。完了はパス・版・観測方法・未確認と後続への影響を返すこと。認証・設定・サービスを変更しない。最大2日。
2. **02 Bridge契約・安全設計**：親、01に依存。所有物はBridge設計文書のみ。対象別認可、Tailscale＋端末認証、リプレイ防止、イベントcursor、異常終了・復旧、GUI排他、Brain外部writerの競合と切戻しを具体化。既存の認証・サービス・agent-controlを再利用し、通信失敗と権限拒否を区別。受入は脅威・端点・データ所有者・テスト・未決定が独立レビュー可能なこと。実装・権限変更なし。最大2日。
3. **03 Studio iPhone Lab視覚案**：design-worker、01に依存。Studioの既存Lab候補領域のみ所有し、Conduitコードは触らない。`hq/tools/CREATIVE-REFERENCES.md`の実物1〜3件とAppleの標準を見て、5タブ・会話・入力・通話・Brainの通常／空／失敗／オフライン／競合を比較。会社アイコン、3D・背景、Glassの操作層、文字・余白を示し、参考の採用理由と版を記録。Web試作とSwiftUI実機を区別し、社長が候補を選べる状態を返す。契約・有料素材の追加なし。最大2日。
4. **04 実機基準と入力再現**：DSH High、01と署名workerの成果に依存。所有物は検証記録のみ、署名設定と他workerの変更は触らない。実機でSimejiと標準日本語、長文・返信中変換・全画面切替・文字サイズ・下書き復元を確認。署名版の通話・ロック・widget導線も別worker成果に干渉せず検証。実機が使えない項目は未確認として、機種・OS・版・再現操作・期待／実際・添付証拠を返す。通話品質や予測修正の成功を推測しない。最大2日。
5. **05 Usage・Mac監視契約**：DSH High、01に依存。所有物は読取仕様・fixtureのみ。inventory lookupと既存Console／usage-meters／CodexBar／Mac監視の収集・出力を確認し、利用枠・実利用・費用・CPU・メモリ・空き容量について取得元・単位・鮮度・欠測・認証境界を表にする。Console非表示の別workerには触れず、資格情報を読まずに形だけ照合。受入は既存データの再利用経路と未取得・期限切れ・推計の表示例、実データとの照合方法を示すこと。最大2日。

## 根拠・未確認

現行仕様は [FEATURE_MAP](../FEATURE_MAP.md)、[WIDGETS](../WIDGETS.md)、[Kanban lifecycle](../KANBAN_LIFECYCLE_MATRIX.md)、`hq/tools/PASEO-HERMES.md`、`AI-OPERATING-MODEL.md`、`LINEAR.md`、台帳lookupと社長指定のBrain Inbox案。Inbox案は検討資料であり現行正本を上書きしない。OS制約は [CallKit](https://developer.apple.com/documentation/callkit)、[CallKitのアイコン](https://developer.apple.com/documentation/callkit/cxproviderconfiguration/icontemplateimagedata)、[WidgetKit](https://developer.apple.com/documentation/widgetkit/animating-data-updates-in-widgets-and-live-activities)、[Drive Range](https://developers.google.com/workspace/drive/api/guides/manage-downloads)、[Google Photos Picker](https://developers.google.com/photos/picker/guides/get-started-picker) を参照。

未確認：署名・TestFlight・CallKit別workerの完了と実機、Dotsの実画面、Simeji症状、StudioとSyncTrain実機の現在状態、Drive動画不具合の原因、Photos認可、Mac配信の既存資産、保管期間。設計の受入条件は今後の実測であり、現在動作中と断定しない。保管期間やデザイン採用は実物と利用状況を基に社長が決める。
