# 社員マスコット

2026-11-06に社長が9体を採用した。人物の像と旧2.5Dは削除した。作り方は [DESIGN.md「社員マスコットの制作手順」](../../DESIGN.md#社員マスコットの制作手順)。

各フォルダに `<id>-turn.heic`（360度、60コマ、768²、アルファ付き）、`<id>-idle-512.mov`（約4秒・24fps、HEVCアルファ hvc1、512²）、`<id>-avatar-512.png`（ループの1コマ目）、`<id>-hero-1024.png`（透過静止画）がある。

確認（2026-11-06）：`scripts/laa/staff_3d/verify_alpha.swift` で9本とも `ContainsAlphaChannel` が true、角のアルファ0。全コマの輪郭を重ねて、512の円の外へ出ないことを確かめた。継ぎ目は生成の始点と終点でPSNR 40〜47dB、さらに末尾10コマを1コマ目へ寄せた。黒鳥は順再生と逆再生なので始点と終点が一致する。

| id | 名前 | 像 | mov | avatar | hero | 動きの生成 |
|---|---|---|---:|---:|---:|---|
| ciel | Ciel | 青い白鳥 | 325 KB | 162 KB | 748 KB | Kling 2.6 |
| ciel-uncensored | Ciel（無検閲） | 黒鳥 | 431 KB | 151 KB | 696 KB | Kling 2.6（順再生＋逆再生） |
| argus | Argus | 孔雀 | 321 KB | 181 KB | 838 KB | Kling 2.6 |
| cfo | Morgan | サフラン色の丸屋根 | 246 KB | 181 KB | 848 KB | Flow Omni 1.1 Flash |
| cio | Sherlock | テラコッタの卵 | 400 KB | 205 KB | 911 KB | Flow Omni 1.1 Flash |
| cmo | Monet | 藤色の花 | 408 KB | 181 KB | 828 KB | Flow Omni 1.1 Flash |
| cos | Merlin | すもも色の帽子と巻き髭 | 251 KB | 160 KB | 684 KB | Flow Omni 1.1 Flash |
| cso | Talos | 錫色の盾 | 370 KB | 194 KB | 891 KB | Kling 2.6 |
| cto | Ada | 青緑のクッション | 341 KB | 208 KB | 1021 KB | Flow Omni 1.1 Flash |

- `<id>-turn.heic` は全員Kling 2.6の周回動画から作った。合計17 MB。背面はAIの推定（MonetとTalosの裏の飾りも生成物）。
- 元の動画と採用画はStudio作品「LAAアプリ｜社員マスコット」（`cf51462f-250f-413b-9f6e-b41540841fec`）にある。
- 黒鳥は暗い地で体が沈むが、冠・くちばし・目と毛の輪郭で読める。
