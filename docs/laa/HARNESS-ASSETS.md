# Harness marks

Wherever a model is chosen or shown (the model capsule and its menu's harness headings in Chat and Work, Work's panes, headers and transcripts; `LAAHarnessMark` in `Conduit/LAA/Design/LAAHarness.swift`, D-21 E / D-33), the harness's own mark stands for it as its maker issues it: original colours, no recolouring, reshaping, rotation, outline or effect, used only to say which product runs the conversation. There is no separate harness capsule. Checked 2026-11-26; Hermes and DSH rows 2026-11-28.

| Harness | Asset | Source | Terms followed |
|---|---|---|---|
| Claude Code | `LAAClaudeMark` (shared with the Claude model face) | Anthropic's Claude Spark, already in the app (owner, 2026-11-13). Anthropic publishes no separate Claude Code mark. | [Anthropic trademark guidelines](https://www.anthropic.com/legal/trademark-guidelines): unmodified, referential use only. |
| Codex | `LAAOpenAIMark` (shared with the GPT model face) | OpenAI's Blossom from [openai.com/brand](https://openai.com/brand/). OpenAI publishes no separate Codex mark. | OpenAI brand guidelines: only where it relates to an OpenAI service, unaltered, at its approved colour (black, white in dark appearance). Accepted for this use on the owner's behalf (2026-11-13). |
| Pi | `LAAPiMark` (`pi-logo.svg`, SHA-256 `abd66e78…cb4d6b`) | `https://pi.dev/logo-auto.svg`, the logo the project's README embeds (github.com/earendil-works/pi). | The project is MIT-licensed; it publishes no logo policy. Used unmodified, original colours, vector. |
| Antigravity | `LAAAntigravityMark` (`antigravity-icon__full-color.png`, 540 px, SHA-256 `e0cd08cc…f51e`, identical to the press kit's `png/` file) | [antigravity.google/press](https://antigravity.google/press), "Icon – Full Color" (also in `Google-Antigravity-Press-Kit.zip`). | The press page and kit carry no separate terms (checked 2026-11-26), so Google's general brand rules apply: referential use, unmodified, original colours, not as LAA's own mark. The full-colour SVG draws its colour with blur filters that the asset catalogue cannot render, so the kit's PNG is used (540 px covers the 18 pt mark at every scale); the same full-colour mark sits on both appearances, as the kit offers no dark variant of it. |
| Hermes | `LAAHermesMark` (`hermes-icon-master.png`, light; `hermes-icon-master-dark.png`, dark appearance; 540 px) | Hermes Agent's own app icon, `assets/icon-master.svg` (SHA-256 `6c4968c1…536684`) and `assets/icon-master-dark.svg` (SHA-256 `e1517a2d…b8ef36`) in [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent/tree/main/assets), commit `c2b69de66d` (2026-09-29). Rasterised unmodified at 540 px with transparent corners (the SVG nests an `<svg>`, which the asset catalogue does not render). | The repository is MIT-licensed (© 2025 Nous Research) and publishes no separate logo policy; referential use only, unmodified, original colours, not as LAA's own mark. |
| DSH Orchestrator (Refuseless, uncensored), DSH Worker (OpenCode Go) | LAA's own badge: the initial in a hairline ring; the Orchestrator's on a filled purple disc (the Mythos colour of `tokens.json` `appSelection`: `ink.light` in light, `bodyTop.dark` in dark) | DSH is LAA's own harness; this badge is its mark (D-33). The model table (`hq/harness/models.json` `picker.harnesses`) names the two; Chat's `laa-monet-uncensored` is the Orchestrator, `laa-dsh` the Worker. | — |
| Muse, Dots (Chat rows `custom:laa-muse`, `custom:laa-dots`) | none: a neutral initial | Their own agents behind Hermes' custom rows; no mark is used. | No mark is drawn or imitated. |
| Echo (lab lane only) | none: a neutral initial | The isolated Work engine's built-in test provider. | — |

A maker that publishes a mark later replaces its badge here and in `LAAHarnessMark`; a maker that withdraws permission returns to the badge.

## Model makers

The menus' model rows carry the maker's mark (`LAAModelMark.officialMenuImage`) only where the app holds the maker's official file, so a harness (heading) and a maker (row) never read as one, e.g. DSH and DeepSeek (D-33 追記8). Makers without one show the name alone.

| Maker | Asset | Source | Terms followed |
|---|---|---|---|
| Anthropic (Claude) | `LAAClaudeMark` (`claude-spark-clay.svg`, SHA-256 `6d53db4b…60e219`) | The Claude Spark, as above. | Anthropic trademark guidelines: unmodified, referential. |
| OpenAI (GPT) | `LAAOpenAIMark` (`OAI_OpenAI-Blossom_Black.svg` `75c1e9ff…92a`, `_White.svg` `01d15876…287285`) | openai.com/brand, as above. | OpenAI brand guidelines, as above. |
| DeepSeek | `LAADeepSeekMark` (`deepseek-mark.svg`, SHA-256 `fc6b399b…dc6a70`) | The whale from deepseek.com's own header (owner, 2026-11-12), as a vector, in DeepSeek's blue. | DeepSeek publishes no brand kit or logo policy that LAA found (checked 2026-11-28: deepseek.com links no brand, press or logo page; `/brand` returns 404); referential use, unmodified shape, its own colour. |
| Google (Gemini) | none (the harness Antigravity's mark stands for it) | Google's Gemini mark is not in the app. | No mark is drawn or imitated in menus. |

## Mac (Catalyst) menus

Mac Catalyst menus show no item images anywhere in the app, SF Symbols included (checked on Mac mini, 2026-11-28, build 2611280658). On the Mac the section headings, the maker marks on rows and the purple DSH Orchestrator disc do not appear inside the menu; the identity stays in the text (harness section names, the row's maker and Metered line) and in the capsule, which draws the harness mark. Accepted as a platform limit (conductor, 2026-11-28); iPhone menus draw the images.
