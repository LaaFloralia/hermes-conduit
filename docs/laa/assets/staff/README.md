# 社員マスコット

2026-11-06に社長が9体を採用した。人物の3D像は既定から外し、旧2.5DのCiel（`../ciel/`）だけ素材を読めない時の予備に残す。作り方は [DESIGN.md「社員マスコットの制作手順」](../../DESIGN.md#社員マスコットの制作手順)。

各フォルダに `<id>-idle-512.mov`（3.96秒・24fps・95コマ、HEVCアルファ hvc1、512²）、`<id>-avatar-512.png`（ループの1コマ目）、`<id>-hero-1024.png`（透過静止画）がある。

確認（2026-11-06）：`scripts/laa/staff_3d/verify_alpha.swift` で9本とも `ContainsAlphaChannel` が true、角のアルファ0。全コマの輪郭を重ねて、512の円の外へ出ないことを確かめた。Argusだけ途中で翼を広げるが、円の内側に収まる。継ぎ目は生成の始点と終点でPSNR 40〜47dB、さらに末尾10コマを1コマ目へ寄せた。黒鳥は順再生と逆再生なので始点と終点が一致する。

| id | 名前 | 像 | mov | avatar | hero | 動きの生成 |
|---|---|---|---:|---:|---:|---|
| ciel | Ciel | 白鳥 | 352 KB | 129 KB | 623 KB | Flow Omni 1.1 Flash |
| ciel-uncensored | Ciel（無検閲） | 黒鳥 | 657 KB | 151 KB | 696 KB | Kling 2.6（順再生＋逆再生） |
| argus | Argus | ふくろう | 370 KB | 195 KB | 973 KB | Flow Omni 1.1 Flash |
| cfo | Morgan | サフラン色の丸屋根 | 323 KB | 181 KB | 848 KB | Flow Omni 1.1 Flash |
| cio | Sherlock | テラコッタの卵 | 533 KB | 205 KB | 911 KB | Flow Omni 1.1 Flash |
| cmo | Monet | 藤色の花 | 547 KB | 181 KB | 828 KB | Flow Omni 1.1 Flash |
| cos | Merlin | すもも色の帽子と巻き髭 | 343 KB | 160 KB | 684 KB | Flow Omni 1.1 Flash |
| cso | Talos | 錫色の盾 | 497 KB | 194 KB | 891 KB | Kling 2.6 |
| cto | Ada | 青緑のクッション | 436 KB | 208 KB | 1021 KB | Flow Omni 1.1 Flash |

- 元の動画と採用画はStudio作品「LAAアプリ｜社員マスコット」（`cf51462f-250f-413b-9f6e-b41540841fec`）にある。
- 黒鳥は暗い地で体が沈むが、冠・くちばし・目と毛の輪郭で読める。
