# LAA iPhoneアプリ：デザイン v2

2026-10-29。LAA版の再設計案。Studio「LAA iPhone Design v2」（project ID `7abd3938-1ee0-4b28-9a70-f584ba144dc2`、revision 24）のライト／ダーク画面とこの仕様を、実装時の基準にする。数値・会話・状態は表示例であり、接続・実装・実機動作を示さない。採否は社長が実物で決める。

v2の英語ナビゲーションと正方形ウィジェットは、[ROADMAP](ROADMAP.md) の旧ラベル・旧ウィジェット案に優先する。ロードマップの実装進捗は、この文書の更新だけでは変わらない。

## 参照と設計判断

| 参照 | 確認した点・採用 | 意図して変えた点・未確認 |
|---|---|---|
| [Apple HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials)・[Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) | Glassはナビゲーションと操作層に使い、本文は落ち着いた不透明面に置く。regularを基本に、clearは写真・映像上で使う | Studioの静止画は部品の位置と階層を示すもの。OSの光学表現・アクセシビリティ動作の実証ではない |
| LAA Console：Studioのモバイル画面（r49）と `/Users/laa/dev/inventory/shared/design-tokens.json`・`console-shell.ts` | 英語の短いタブ名、紙色の余白、Georgiaの見出し、細い罫線、青緑の選択状態 | Consoleの情報密度や画面をそのまま縮小せず、電話用の一覧とタッチ操作に組み替える |
| LAA HP：`/Users/laa/dev/hp`、[公開サイト](https://www.laa-inc.com/)、`/Users/laa/dev/laa-brand-system/DESIGN_SYSTEM_PROPOSAL.md` と保管スクリーンショット | 社員の実3D、紙・墨・青緑と余白の方向。ブランドシステム案から色の役割分離を採る | ブランドシステムの旧提案色は使わず、Studioの採用版v6を使う。保管スクリーンショットは旧版であり、公開HPの現行画面は接続不調で目視できていない |
| Slack iOS：[モバイル画面の実例](https://images.squarespace-cdn.com/content/v1/62b4cde29ebbf50911448f0d/b79659f8-14dc-4697-9ba7-7c728c5339d0/Message%2BButton)、[モバイルのカスタマイズ](https://slack.com/help/articles/29788684062739-Customize-the-Slack-mobile-app) | セクションから相手・グループを選ぶ一覧、最近の会話への短い導線 | 並びはCiel・Employees・Groups・Recent。Slack固有の配色や情報量は持ち込まない |
| Telegram：[引用表示の実例](https://ux-news.com/content/images/2023/10/image-5.png)、[公式説明](https://telegram.org/blog/reply-revolution?setln=en) | 引用を本文から区別し、画像やファイルも会話内で読める構成 | 背景模様や吹き出し色はLAAのものにする。見出し・箇条書き・コードも同じ会話内で扱う |
| [OpenAI Dots](https://openai.com/index/introducing-dots/) | 公式説明から、個別の相手と音声で話す方向を確認 | 実画面の視覚比較は未確認。社員別3D像や声は社長の要件であり、Dotsの画面仕様とは断定しない |
| [Apple App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons) | 文字を入れず、背景と前景を分ける | アイコンに人物や場面を描かない |

## 共通トークン

Studioブランド「LAA — Company Brand / 2026.10」v6を基準にする。ダークと補助面は今回の画面用の値。カラーは用途名で参照し、画面ごとに直接固定しない。

| 用途 | Light | Dark |
|---|---|---|
| 背景 | `#F6F2E9` | `#0F1B1C` |
| 本文・カード面 | `#FFFDF8` | `#172627` |
| 補助面・コード | `#EBE6DC` | `#243638` |
| 本文文字 | `#213536` | `#ECE7DC` |
| 補助文字 | `#596968` | `#A8B7B4` |
| リンク・選択文字 | `#00585E` | `#75C3C3` |
| 罫線 | `#D7D5CC` | `#385052` |
| 選択アイコンの下地 | `#DFEAE5` | `#294844` |
| 自分の吹き出し・塗りボタン | `#00585E` / 文字 `#F6F2E9` | `#1E6B70` / 文字 `#F6F2E9` |
| 要確認 | Plum `#6C244C` | `#D49AB6` |
| 終了 | システムの赤 | システムの赤 |

通常文字は下地とのコントラスト4.5:1以上。例として本文／背景はLight 11.55:1、Dark 14.27:1、塗りボタンはLight 7.35:1、Dark 5.54:1。Plum・Tan `#B99B7A` は装飾にも使うが、通常文字に使う場合は実際の下地との比を確認する。色だけで状態を伝えず、文言・記号を添える。

- 余白の基本は4・8・12・16・24・32pt。390pt幅の見本は左右24pt、セクション間32pt。小さい画面では左右16ptまで縮める。
- 標準行の高さは56pt以上。カードは角丸16pt、吹き出し18pt、選択チップ16pt、写真24pt、操作面の大きな角は28ptを基準とする。入れ子のカードを増やさず、余白と細罫で区切る。
- 本文・操作はシステム書体（SF Pro／日本語はシステムの日本語書体）、通常本文16pt、補助13pt、セクション名12pt。画面見出しはGeorgia Regular 34pt、社員名はGeorgia、Usageの数値はGeorgia 36pt・等幅数字。Dynamic Typeでは折り返しと行高を広げ、固定高で切らない。Studio上のHelvetica Neueはシステム書体の見本。
- タップ領域は44×44pt以上。小さく見えるアイコンやチップも透明な当たり領域を広げる。VoiceOverに名前・選択状態を渡す。色覚・文字サイズ・Reduce Motion・Reduce Transparencyを実機で確認する。
- 回答と入力は既存の `ChatTextSize` を維持し、システムの文字サイズに追従する。回答と入力の設定は分け、入力の既定は1.125倍。

## Glassと画面構造

| 操作層：Glassの対象 | 本文層：不透明に保つ |
|---|---|
| タブバー、チャットの戻る・社員情報・電話、通話操作、編集ツールバー、＋・送信 | チャットの吹き出しと入力面、Brain本文、仕事詳細、Usageの数値、ウィジェット本文 |

iOS 26以降は標準 `TabView`・`toolbar` のシステム表現を優先する。独自操作に必要な場合だけ `glassEffect` を `GlassEffectContainer` でまとめる。regularを既定とし、clearは写真・映像の上に限る。明るい写真上のclearには最低35%の暗い下地を敷く。透明度を下げる設定ではLight `#FFFDF8`／Dark `#172627` の不透明面にする。コントラストを上げる設定では文字・境界を強める。

対象はiOS 17以降。iOS 17–25は標準のナビゲーションと `Material` を使い、不透明設定では同じ代替面にする。iOS 26専用APIとスクロール時のタブ縮小はavailabilityで分岐する。静止画の半透明色をLiquid Glassの実装と見なさない。

下部タブは最上位だけに出し、個別チャット・通話・文書では隠す。Safe Area・キーボード・横幅に追従し、本文を操作面の下に隠さない。画面の描画値は390×844ptの見本であり、座標を全端末に固定しない。

| 順序 | 表示名 | 主な内容 | アイコン |
|---|---|---|---|
| 1 | Chats | Ciel、社員、グループ、最近 | `bubble.left.and.bubble.right` |
| 2 | Work | Sessions、Projects、Tasks、Routines | `checklist` |
| 3 | Brain | Recent、Folders、Tags、検索 | `doc.text` |
| 4 | Assets | Drive、Inspiration、Studio | `photo.on.rectangle` |
| 5 | Usage | 接続先ごとの使用状況とMac | `gauge.medium` |

ナビゲーションと操作ラベルは英語。会話本文や日本語の説明は自然な日本語でよい。内部の `source` など既存識別子・保存済みリンクは表示名の変更だけで壊さない。

## Chats：相手を選ぶ一覧

画面上部に `Chats`、検索、新規作成。縦スクロールの順は `Ciel`、`Employees`、`Groups`、`Recent`。Cielは最初に大きめの1行で固定し、Employeesは既存の社員データ、Groupsは参加中のグループ、Recentは最終更新順の会話を表示する。セクションの `See all` は省略分を開き、`+` は既存の作成フローへ進む。未実装の作成操作を成功したように見せない。

社員行は40〜44ptの静止アバター、表示名、役割または最後の会話を並べる。Recentには更新時刻と本文の短いプレビューを添える。実際に取得できない状態や未読数は作らない。検索は相手名・グループ名・取得済み会話を対象にし、結果なし、読み込み中、接続失敗を区別する。

## Chat：社員・グループとの会話

上部に戻る、40ptの社員像、名前、取得できる場合のみ状態、電話ボタン。電話はその社員と現在の会話文脈を渡す。グループでは実際に対応する通話先がない限り電話を無効にして理由を示す。一覧から選んだ会話IDを保ち、履歴や下書きを混ぜない。

本文は縦スクロールで、相手の吹き出しは左、自分は右。最大幅は画面の85%、内側16pt、角丸18pt。どちらも不透明にし、長文は自然に高さを伸ばす。到着時刻・送信中・失敗・再送は実データに従い、色以外でも区別する。ユーザーが過去を読んでいる間の自動スクロールを避け、末尾へ戻る導線を出す。

リッチ表示は既存Markdown／添付コンポーネントを再利用し、次を少なくとも表現する。

| 種別 | 表示と操作 |
|---|---|
| 見出し・段落・太字 | 行間を確保し、選択・コピーできる |
| 箇条書き・番号付き | 段落内でインデントし、折り返しても番号を読める |
| 引用 | 補助面と左の細線で本文と区別 |
| コード | 等幅、補助面、横スクロール、`Copy` |
| リンク | 青緑とリンク記号、VoiceOver名。外部遷移はOSの通常の開き方 |
| 画像 | 会話内サムネイルから拡大。読み込み・失敗・代替テキストを用意 |
| ファイル | 種別、名前、取得可能ならサイズと開く操作。未対応形式は理由を示す |

未対応の書式や添付を黙って捨てず、取得できる原文・ファイルへの導線を表示する。画像やファイルの例はサンプルで、送受信機能の完成を示さない。

下部は＋、不透明な入力面、送信。入力欄は3行から8行まで伸び、それ以上は欄内スクロール。全画面エディターへの導線を残し、日本語変換中に入力欄を再生成しない。送信可否、添付、下書き、キーボード位置は既存の動作を保つ。

## Call：アプリ内通話

`Chat` の電話とウィジェットの `Call` は、選んだ社員と会話を引き継ぐ。中央に直径270ptを上限とする社員の3Dレンダー、社員名、実際の状態と通話時間。下に `Mute`、`Speaker`、`Chat`、`End` の順で配置する。`Chat` は通話を切らず元の会話を開き、`End` は終了する。

接続中・接続済み・再接続・失敗・終了、マイク許可、音声経路を区別する。GPT-Liveを使う設計だが、社員別の声は利用可能な選択肢と既存接続方式を実装時に確認し、未対応なら共通の利用可能な声とする。画面の `GPT Live` は表示例。既存の送信先同意、ChatGPTプラン／APIの課金表示、利用経路の確認を省かない。

CallKitの純正画面には任意の3D・動画を置けない。アプリ内の社員像とは分け、`assets/callkit-icon-template-120.png` を単色マスクとして使う。表示名はLAA、発信者名は社員名。純正画面で連絡先の写真を使うには端末側の条件と社長の判断が必要。

## Work・Brain・Assets

| 画面 | 構成と操作 | データがない場合 |
|---|---|---|
| Work | `Sessions / Projects / Tasks / Routines` を切り替え、進行中と判断待ちを分ける。行には題名、種別、実際の担当を表示 | 0件、未接続、取得失敗を分ける。担当や状態を推測しない |
| Brain | `Recent / Folders / Tags`、検索、文書行、フォルダ。本文は紙色の面 | 0件・未接続・競合を分け、競合は両版への導線を示す |
| Assets | `Drive / Inspiration / Studio`、検索、種類フィルター、画像・文書の一覧 | 未接続・取得失敗・未対応形式を区別し、開けない理由を示す |

見本の項目名・説明・人数・ファイルは仮データ。既存の接続先と権限で取得できるものを表示し、未実装の操作は完成したように見せない。

## Usage

上部に `Usage`、更新ボタン、`Last updated`。サービスごとに、取得可能な利用枠・実利用・費用・リセット時刻を単位付きで表示し、Macの状態は別項目にする。比率は分母が明確なサービスだけに表示し、異なるサービスの利用率を合算しない。見本の62%、時刻、サービス状態は仮値。

更新中はボタンを重複実行できない状態にし、取得完了時刻を表示する。失敗時は前回取得値とその時刻を残してエラーを添える。未取得・利用不可・0・古い値を区別し、未取得を0で埋めない。時刻は端末のロケールとタイムゾーンで表示する。

## Widgetとロック画面

ホームは `systemSmall` の正方形。Cielを初期値とし、上段に名前・静止3D、下段に `Call` と `Chat` の2操作を並べる。見本は170×170pt、各ボタンの当たり領域は44pt以上。実寸はWidgetKitが決めるため、縮小時は画像と余白を調整し、文字と2操作を残す。ウィジェット全体の既定遷移はChat、Callは対象社員の通話、Chatはその社員の会話。iOS 17以降の `Link` と1つの `widgetURL` で行き先を区別する（[Appleの遷移仕様](https://developer.apple.com/documentation/widgetkit/linking-to-specific-app-scenes-from-your-widget-or-live-activity)）。ロック解除・権限・既存の通話同意が必要な場合はアプリ側で正規の流れを示す。

ロック画面は `accessoryRectangular`、単色の電話アイコンと `Ciel / Call`。1つの遷移先としてアプリの通話画面を開く。実際の色や形はOSのレンダリングに従うため、Studioの色付き見本と完全一致を要求しない。ロック画面に会話内容や接続状況を表示しない。

ウィジェットは静止画。ティント等の外観ではOSが画像を処理するため、文字・操作の視認性を実機で確認する。状態を表示する場合は最終確認時刻も表示し、古い値を最新に見せない。

## 会話の背景と動き

会話・グループごとに背景を保存する。既定は紙（Ivory）、選択肢は紙・青緑の夜・墨・端末の写真。写真の減光は0〜60%、ぼかしは0〜20pt。写真上の操作層には上記のGlass規則を適用する。文字が4.5:1を満たせないときは暗い下地を追加し、それでも足りなければ不透明な操作面に戻す。吹き出し自体は背景に関係なく常に不透明。

画面遷移・シートはシステム既定。送信・通話開始の状態変化はspring（response 0.35、dampingFraction 0.85）を基準とする。社員像の待機ループは2秒・30fps、呼吸1回と首の小さな揺れ。音量リングは1.00〜1.08倍、120msで平滑化する。Reduce Motion、低電力モード、画面外ではループを止め、1コマ目に戻す。表情で感情を断定せず、瞼の骨やブレンドシェイプがない素材に瞬きを追加しない。

## アプリアイコンと社員素材

アイコン原本はStudioブランドの「配信用 — PWA 1024 / any」。`Conduit/Resources/AppIcon-LAA.icon` は青緑の地に螺旋・四分円・円弧の3層、iOS 26未満は `Conduit/Resources/Assets.xcassets/AppIcon-LAA.appiconset` を使う。LAA用署名overlayで `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon-LAA` を指定し、上流のアイコン設定は維持する。既存の `ictool`・`actool` 検証は実機表示の確認を意味しない。

社員像は社長が採用した既存の8人の3Dレンダーを使う。原本・検証結果は [assets/staff/README.md](assets/staff/README.md)。

| ファイル | 用途 |
|---|---|
| `<id>-hero-1024.png` | 透過静止画。通話、正方形ウィジェット、必要時の連絡先写真 |
| `<id>-avatar-512.png` | ループの1コマ目。一覧、チャット上部、静止時 |
| `<id>-idle-512.mov` | HEVCアルファ付き、512²、2秒、30fps。チャット上部・通話中の待機 |

IDは `ciel`、`argus`、`cfo`（Morgan）、`cio`（Sherlock）、`cmo`（Monet）、`cos`（Merlin）、`cto`（Ada）、`cso`（Talos）。Talosの原本は骨がないため、既存の小さな動きと静止画を使う。`docs/laa/assets/ciel/` の旧2.5Dは3D素材を読めない場合の予備として残す。

## 社員3Dの制作手順

原本はHPの採用済みGLB（読むだけ。HP側を書き換えない）。7人は `hp/public/models/characters/fal-20260922/<id>-rigged.glb`（24骨、Meshy生成に骨とウェイトを転写）、Talosは `local-20261012/cso-masked.glb`（骨なし）。

1. テクスチャの読める形へ：rigged版はKTX2（Basis）で、Blenderが読めない。6人は同じ形状・骨・ウェイトのWebP版 `<id>-rigged-web.glb` を使う。CielはWebP版がないため、`scripts/laa/staff_3d/ktx2_to_png_glb.mjs` でKTX2をPNGに書き換えた作業用コピーを作る（形状・骨・動きのバイトは変えない。HPの `public/three/basis/` の変換器を使う）。
2. レンダー：`Blender -b --factory-startup -P scripts/laa/staff_3d/render.py -- --glb <glb> --out <dir> --id <id> --frame-h 0.55`（Blender 5.2、Cycles・Metal、64サンプル＋ノイズ除去、Standard表示、透過）。全員で同じ正射影カメラ・照明を使う。ループは縦0.55m、静止画は0.66mの範囲を写し、頭頂を上端から8%に合わせる（画像上で実測して補正）。照明は左上の柔らかい主光、右の弱い補助光、後ろの冷たい縁取り光で、紙・青緑・墨の上で輪郭が読めるようにした。
3. 姿勢：原本の頭は下向き・横に傾いているため、首と頭の骨で傾きを水平に戻し（`head_end` から自動計算）、目線を8度上げる。モデル自体は変えない。
4. 動き：同じ骨で、呼吸1回（背骨3本と肩を余弦で）、首と頭の小さな揺れ（位相をずらした正弦）を60コマに付ける。0コマ目と60コマ目が一致するので継ぎ目なく回る。骨のないTalosには、レンダー用の場面だけに4本の骨（高さで重みを付ける）を足して同じ動きを付ける。瞬きは、どのモデルにも瞼の骨・ブレンドシェイプがないため入れない。
5. 書出し：`ffmpeg -framerate 30 -i idle-%03d.png -c:v hevc_videotoolbox -alpha_quality 0.9 -q:v 70 -tag:v hvc1 -pix_fmt bgra <id>-idle-512.mov`。アルファは `swift scripts/laa/staff_3d/verify_alpha.swift <mov>` で確かめる（AVFoundationの `ContainsAlphaChannel` と、復号した1コマ目の角のアルファ0）。
6. 確認：44pt・270ptの円で、紙・青緑・墨・写真の上に並べる。継ぎ目、首と髪のゆがみ、1コマ目の静止画を見る。
7. RealityKit用：`Blender -b -P scripts/laa/staff_3d/to_usdz.py -- <PNG版glb> <id>.usdz` で骨付きUSDZ（約11〜13MB、`usdchecker --arkit` 合格）を作れる。容量が大きいためrepoには置かない。口の動き・表情には、口と瞼のブレンドシェイプを持つモデルが必要で、作るかどうかは社長の判断とする。
