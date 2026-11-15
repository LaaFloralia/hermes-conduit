# 社員マスコット

2026-11-08にMonetへ統合した8体に、2026-11-15採用の薬用石鹸を加えた9体。人物の像と旧2.5Dは削除した。作り方と追加時のチェックは [DESIGN.md「社員マスコットの制作手順」](../../DESIGN.md#社員マスコットの制作手順)。

各フォルダに `<id>-turn.heic`（360度、60コマ、768²、アルファ付き）、`<id>-idle-512.mov`（約4秒・24fps、HEVCアルファ hvc1、512²）、`<id>-avatar-512.png`（ループの1コマ目）、`<id>-hero-1024.png`（透過静止画）がある。

旧素材の確認（2026-11-06）：`scripts/laa/staff_3d/verify_alpha.swift` で9本とも `ContainsAlphaChannel` が true、角のアルファ0。全コマの輪郭を重ねて、512の円の外へ出ないことを確かめた。継ぎ目は生成の始点と終点でPSNR 40〜47dB、さらに末尾10コマを1コマ目へ寄せた。

Monet（無検閲）の動画は `verify_alpha.swift` でアルファ付き・角のアルファ0を確認した。

| id | 名前 | 像 | mov | avatar | hero | 動きの生成 |
|---|---|---|---:|---:|---:|---|
| monet-uncensored | Monet（無検閲） | 紫の花 | 243 KB | 189 KB | 883 KB | 採用素材 |
| argus | Argus | 孔雀 | 321 KB | 181 KB | 838 KB | Kling 2.6 |
| cfo | Morgan | サフラン色の丸屋根 | 246 KB | 181 KB | 848 KB | Flow Omni 1.1 Flash |
| cio | Sherlock | テラコッタの卵 | 400 KB | 205 KB | 911 KB | Flow Omni 1.1 Flash |
| monet | Monet | 藤色の花 | 408 KB | 181 KB | 828 KB | Flow Omni 1.1 Flash |
| cos | Merlin | すもも色の帽子と巻き髭 | 251 KB | 160 KB | 684 KB | Flow Omni 1.1 Flash |
| cso | Talos | 錫色の盾 | 370 KB | 194 KB | 891 KB | Kling 2.6 |
| cto | Ada | 青緑のクッション | 341 KB | 208 KB | 1021 KB | Flow Omni 1.1 Flash |
| soap | 薬用石鹸 | 白いフェルト石鹸と泡 | 353,435 B | 121,677 B | 556,712 B | Kling 2.6 |

- 旧素材の `<id>-turn.heic` はKling 2.6の周回動画から作った。背面はAIの推定（MonetとTalosの裏の飾りも生成物）。Monet（無検閲）は2026-11-08採用素材。
- 元の動画と採用画はStudio作品「LAAアプリ｜社員マスコット」（`cf51462f-250f-413b-9f6e-b41540841fec`）にある。

## 薬用石鹸（soap）の採用素材

社員「薬用石鹸」はMuse固定の会話専用。採用Bの体を白へ補正し、泡・黒目・青緑の口を保った。社員の表示色は温かいベージュ（#DCCAAA）で、体の色とは分ける。`soap/` の4素材は同梱・premultiply・回転60コマの検査に合格済み。待機は4秒・96コマ、回転HEICは768²・60コマ・1,006,740 B。全社員を調べる `LAAStaffCallTests` で継続検査する。会話リンクの許可と実アプリでの起動は、制作正本の「アプリへの社員追加チェック」に従う。
