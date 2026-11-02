# fixes 引継ぎ（2026-11-02）

`laa/fixes`。最終ゲートは b92 統合担当へ引き継ぐ（親指示 `dp-20261102211127-92a595`）。この担当では追加ビルド・再試験・新規UI試験を開始しない。実データ変更、新規認可、サービス再起動は行っていない。

修正は、375pt／拡大文字での名前優先表示、ログインのLAAアイコン、Usageの表示中の鮮度評価・自動更新・失敗時の数値非表示・サービスリンク、Widgetの期限切れ数値非表示。追加依頼の入力欄全高の確保、写真背景のグループplaceholder、拒否文テストのCiel／LAA期待値も含む。音楽と5タブ共通設定の本体修正は既存masterにあった。

Debug `build-for-testing` は成功。ただし、その後の中央配置修正は未ビルド・未再試験。初回の `LAACompactChatSnapshotTests.testCompactChatLightAndDark` は名前中心104pt／期待220±2ptでライト・ダークの2assertが失敗した。原因の `.toolbarRole(.editor)` を除去し、独自Backも取りやめた。`V2ConversationScreen.swift` は `f752d5e2` と同一で、native Backと戻るジェスチャーを維持する。**中央名2assertの解消と新規UI検証は未了**。

検証証跡は `/Users/laa/work/fixes-20261102/evidence/`。`debug-incremental.log`、`unit-tests.log`、`acceptance.json`、`performance-observations.json` を参照。既存runはexit 65で終了し、234件中233件通過・1件失敗（上記中央名の2assert）。Usage18状態、Widget画像全件、音声関連は通過。画像112枚とmanifestを `evidence/unit-screenshots/` へexportし、名前対応は `evidence/screenshot-index.json`、集計は `evidence/unit-summary.json` に保存した。翻訳6543箇所／13言語、FEATURE_MAP 104項目／1579パス、ブランドスクリプト32件、Usage Bridge関連37件は通過。

BUS-323は未解決。Actionsはenabled・allowed_actions=all、workflowはactive、masterのpush対象と設定差分なしを確認したが、最新runは2026-10-29T23:34:30Z／5c6654a4のまま。設定は変更していない。fixes branchへのpush後も13分時点でActions runは0件で、master固有の不発とは確認できていない。API管理者キーと音声・WidgetKitの実機確認も残る。

統合後の同じLAA_BUILDで次を選ぶ。`xcodebuild` は共通 `build-slot.sh` 経由、`-jobs 4`、統合担当の専用sim・DerivedDataを使う。

```text
-only-testing:ConduitTests/LAACompactChatSnapshotTests/testCompactChatLightAndDark
-only-testing:ConduitTests/LAAConversationHeaderSnapshotTests/testNarrowNamesAndDynamicTypeLightAndDark
-only-testing:ConduitTests/ComposerDraftStoreTests/testRefusedCommandSaysSoWithHermesHint
-only-testing:ConduitUITests/LAAChromeUITests/testAllTabsOpenSettingsAtTheSamePositionAndCapture
-only-testing:ConduitUITests/LAAChromeUITests/testDisconnectedChatsOpenSettingsAndCapture
-only-testing:ConduitUITests/LAAChromeUITests/testSettingsAndDataUseLAAContentAndCapture
-only-testing:ConduitUITests/LAAChatDesignUITests/testCompactHeadersKeepTheirControlsTogether
-only-testing:ConduitUITests/LAAChatDesignUITests/testCompactHeaderKeepsBackAndMenuUsable
-only-testing:ConduitUITests/LAAChatDesignUITests/testCompactGroupHeaderKeepsBackAndMenuUsable
-only-testing:ConduitUITests/LAAChatDesignUITests/testComposerGlassScreenshots
-only-testing:ConduitUITests/LAAChatDesignUITests/testGroupPlaceholderOnPhotoLightAndDark
-only-testing:ConduitUITests/LAAChatDesignUITests/testComposerIsPlainTextOnTheKeyboard
```

比較条件は440×956ptのライト／ダーク。中央名は画面中心±2pt、右カプセルはBackと同じ余白、Back・menuを操作して戻れること。375pt／accessibility3の8枚は単体snapshotで確認し、名前の欠けと44pt操作領域を画像でも見る。

composer試験は紙／写真×ライト／ダークの4条件。キーボード表示後に9改行を入力し、`chat.transcript.maxY <= composer.field.minY + 1` と Model／使用率行の後ろに本文がないことを確認する。写真グループは空欄の `Message the room` を両外観で比較する。fixtureは試験内設定済み（`-LAA_UI_TEST_BACKGROUND -LAA_V2_CHAT_FIXTURE rich -LAA_CAPTURE_SURFACE chat|group -LAA_CAPTURE_KIND paper|photo`、ダークは `-LAA_V2_DARK`）。手動の写真placeholder画像は `evidence/screenshots/group-placeholder-photo-{light,dark}.png`。

実機では音楽を流して会話・社員詳細・スクロール・社員切替を試し、通話／音声入力の開始時だけ音声が切り替わり、終了後に他アプリの音楽を再開できることを確認する。Widgetは期限切れ数値、色調、Call／Chatの遷移を確認。5アプリの操作別置換表は各機能担当の成果と統合し、この品質修正だけで削除可能とは判定しない。

取得遅延はホスト負荷を伴う。20:59時点でload average 246.63、CPU空き1.17%、swap使用48,375MB。18状態snapshotは20:49開始、添付はbalance-dark 21:00:53、extras-dark 21:08:11、cost-light 21:13:17へ進行した。先行2画面は3.655秒。18状態は1568.410秒で通過し、全試験は7336.439秒。Widgetも22:05:42の30/41枚で一度止まり、22:28:51から再開、22:36:33に最後の画像を保存した。追加sampleはRunLoop内のCA transaction処理で、最終的に完走したため無限layoutループとは確定しない。停止も同一条件の再実行も行っていない。

専用sim `E555BA47-800E-4A8F-92F2-A4B197DBE77A` は停止・削除し、一覧からの消失、slot1とPID 68879／68887／69356の消失を読み戻した。解放は親とb92へ直接報告済み。`evidence/resource-release.json` を参照。

画像確認では375pt／拡大文字の名前、Usageの古い数値非表示とリンク、写真壁紙上Widgetの会社アイコン・Ciel・裸の操作アイコンを確認した。169pt単独Widget fixtureは上端が欠けるが、300pt壁紙fixtureでは全体が見えるため、単独画像だけでWidgetKit実表示を合格とは扱わない。実機確認は引き続き必要。

## fixes runの最終結果（2026-11-02、親の照合済み）

- unit: exit 65。234件中233 pass、1 failed。失敗は既知の中央名（`LAACompactChatSnapshotTests.testCompactChatLightAndDark` 内の2 assert）で、名前中心104pt／期待220±2pt。source修正（`.toolbarRole(.editor)` 除去・独自Backの撤回）は未ビルド・未再試験のため、統合ゲートで再確認する。
- 画像: 112 PNG＋manifestをexport済み（index は `evidence/screenshot-index.json`、作業側は `/Users/laa/work/fixes-20261102/`）。
- 解放: 専用sim E555BA47をshutdown→delete、simctl一覧から消失。slot1なし、wrapper/xcodebuild/test app（68879/68887/69356）の消失を確認。DerivedData削除済み。証跡 `evidence/resource-release.json`。
- 候補SHA: origin/laa/fixes = 687853c0df259934081b4180ee90c86caf37a7c7（5fa0b607からの差は本文書と証跡JSONのみでsource不変）。
- 統合側の扱い: 5fa0b607を `laa/integrate-1102` へ通常merge済み（6a0f84b6）。最終doc commit 687853c0もmergeする。上記1 failedは統合ビルドで再試験し、結果を統合ゲート証跡へ記録する。
