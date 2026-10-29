# /v1/usage・/v1/mac/status のfixture

[USAGE.md](../../USAGE.md) の契約に対応する応答例。値は匿名化した例で、実測値のコピーではない。`data.items`・`data.nextCursor`・`requestId` の封筒は [BRIDGE.md](../../BRIDGE.md) §3に合わせる。

| file | 何を示すか |
|---|---|
| `usage-normal.json` | 通常。quota・balance（`verified`）・unitCredits・usage・cost が並び、DeepSeekは `unavailable`（値は null）、Geminiは期限切れ、費用は `estimated` |
| `usage-degraded.json` | 劣化。CodexBarが古く `stale`、Codex/DeepSeekは取得失敗、dashboardは401で `auth_required`。0で埋めない |
| `mac-status-normal.json` | CPU・メモリのサンプラ実装後、空き容量が新しい状態 |
| `mac-status-unavailable.json` | 現状（CPU・メモリ収集なし）と、storage-guardの状態ファイルが26時間超前で `stale` |

検証は各fileがJSONとして読み込め、`availability: unavailable` の項目が `value: null` と `nullReason` を持ち、`available` の項目が null でないこと。
