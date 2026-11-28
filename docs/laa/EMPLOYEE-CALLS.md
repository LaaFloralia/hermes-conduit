# 社員への電話

Monetを含む7社員の電話は、LAAの通話画面から始める。通話のエンジンはMacの設定で決まり、アプリは選択肢を持たない。切り替えにアプリの配信は要らない。GPT-Liveは使わない（D-42。LAA版では選べず、起動もできない）。Monet · Dotsは2026-11-26にアプリから外れた。アプリ内通話の既定は通常Monet。

## エンジン

| エンジン | 状態 | 動き |
|---|---|---|
| Local Live（`local_live`） | 稼働（予備） | Macの音声サーバーが聞き取りと読み上げを行い、各発話はその社員のHermesチャットで処理する。社員のモデル・人格・道具をそのまま使う。外部の音声モデルへ送らないので同意は求めない |
| Gemini Live（`gemini_live`） | 稼働（優先、`gemini-3.8-live`） | Gemini Live APIへWebSocketで接続する。キーはHermesホストに置き、ホストが接続ごとに使い切りのトークンを発行する（`CONDUIT_GEMINI_LIVE_API_VERSION=v1beta`）。アプリにキーを入れない |

アプリは通話の直前にBridgeの `GET /v1/calls/engine` を読み、`order` の順に、ONで接続できる最初のエンジンを使う（`LAAStaffCallEngine.swift`）。Bridgeに届かない時は最後に受け取った答えを使い、一度も受け取っていなければLocal Live。待ち時間は2秒まで。

- Gemini LiveがONでも、Hermesホストの状態確認が「使えない」と返す間、または社長がGemini Liveへの送信をまだ許可していない間は、その通話をLocal Liveで始める。同意は次の通話の前に尋ねる。
- どのエンジンもONでなければ通話を始めず「通話の接続先がありません」と表示する。別のエンジンへは切り替えない。

## Gemini Liveへ切り替える手順（契約とキーが揃ってから）

1. Gemini APIキーを1Passwordに保存し、`~/.config/laa/hermes-personal.env.tpl` に `GEMINI_API_KEY` の参照行を足す。値は書かない。
2. Hermesホストに `CONDUIT_GEMINI_LIVE_API_VERSION=v1beta` を設定する。使い切りトークンは `v1beta` でしか発行できない。
3. `~/.config/laa/staff-call-engine.json` に `{"gemini_live": {"enabled": true}}` を書く。順番を変える時は `order` を足す。
4. Hermesを再起動する。Bridgeは読むたびにファイルを見るので再起動は要らない。

スイッチと参照行のどちらかが欠けている間、Bridgeは `gemini_live` をOFFとし、理由（`waiting_for_contract`・`key_reference_missing`）を返す。Bridge側の詳細は `bridge/README.md`。

## 通話の中身

接続前に社員profile・声・エンジンを計画（`LAAEmployeeCallPlan`）として固定する。開いているチャットのワークスペースが変わっても、通話中の社員は変わらない。計画は自分のエンジンの通話が終わる時だけ消える。

指示の先頭に社員の名前・一人称「私」・呼称「社長」を入れる（`LAAStaff.callIdentity`、全エンジン共通で、モデル名や製品名を含まない）。Gemini Liveでは同じprofileのSOULを取得できない限り通話を始めない。絵文字と顔文字は読み上げない。通話は「社長、（社員名）です。」で始まり、社長がそのprofileに設定した挨拶があればそちらを使う。

開いている同じチャットの直近8発言を、社長と社員の両方から最大4,000文字取り込む。道具・思考・システムの行を除き、引用した会話データとして渡す。別チャットの内容は混ぜない。依頼は `VoiceBackgroundJobSupervisor.liveThread` が示す社員の通常会話へ送り、結果は同じ会話に残る。

声はGemini Liveの時だけ社員ごとに選べる（7社員に別々の既定の声）。Local Liveは音声サーバーの声で話すので、声の設定欄を出さない。

通話画面はマスコットと4操作の配置を維持する。状態は「接続中…」「話せます」「再接続中…」「切れました」。操作は「消音・スピーカー・チャット・終了」。出力先はVoiceOverで確認でき、消音中は解除操作として読み上げる。失敗の内部メッセージは表に出さない。「聞いています」「考えています」の表示はGPT-Live専用の実装だったため、今は出ない。

## Apple Watch

Watchの社員通話は `bridgeStartFor`（エンジン名 `staff`、社員profile）をiPhoneへ送る。iPhoneがMacの設定からエンジンを決め、Gemini Liveの接続情報かLocal Liveの接続情報を返す。Watchは返ってきた種類で通話する。iPhoneとWatchは同じ版に揃える：古いWatchが `gpt_live` を指定した開始は拒否される。

## 確認

`LAAEmployeeCallPlanTests` は、計画と声、エンジン設定の読み取りと保持、Gemini Liveが使えない時のLocal Liveへの切替、社員の範囲と道具、人格の取得、CallKitからLocal Liveまでの開始経路、CarPlay・ウィジェット・同意との競合を確認する。`LAAEmployeeCallContinuityTests` は名乗りと同じチャットの文脈、`LAAStaffCallUITests` は通話からチャットへ戻る操作、消音、ライト・ダーク、出力先の画面を確認する。Gemini Liveの実通話は、契約とキーが揃うまで確認できていない。
