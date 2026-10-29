# Brain書き込みの競合と安全な調停

2026-10-29。タスク24（読取り＋使い捨て実験）。実vault・Syncthing設定・launchd設定は変更していない。実験は `/Users/laa/work/brain-write-24-20261029/` のスクラッチ2フォルダ（Syncthing 2.1.6を別home・別ポートで2プロセス）とローカルのCAS試験で行った。根拠は [BASELINE.md](BASELINE.md)・[BRIDGE.md](BRIDGE.md)・[ROADMAP.md](ROADMAP.md) と同日の実測。

## 1. 結論

- 既存内容を置き換える `brain:write` は**v1で有効にできない**。hash比較＋atomic renameは「競合の検知」までで「外部writerの保存の防止」にはならない（§3）。
- 新規パスの作成だけは原子的に安全。`O_EXCL` と `renameatx_np(RENAME_EXCL)` は「存在しなければ置く」を1操作で行い、既存内容を壊さない（実測）。
- Syncthingの両版保全には上限がある。同一パスの競合コピーは `maxConflicts=10` で頭打ちになり、超えた古い敗者版は trashcan にも残らず消える（12回の反復で2件消失）。
- したがって v1 は `brain:write` 無効、必要なら新規作成専用の `brain:create` を別scopeで追加する。タスク20（daily原本への習慣チェック）も同じ理由で保留（§7）。

## 2. writer台帳

| # | writer | 実体 | 競合の検知・解決 | 根拠 |
|---|---|---|---|---|
| 1 | Syncthing 2.1.6 | launchd `sh.brew.syncthing`、`brain`→`/Users/laa/Brain` は sendreceive、fsWatcher 10秒＋rescan 3600秒、versioning trashcan 30日、`maxConflicts=10`、端末定義10件（brain共有は Mac mini・MacBook Pro・iPhone16-ProMax の3台） | version vectorで比較。並行版は決定的なtie-breakで勝者を決め（実測では修正回数3対1でも device ID が大きい側が勝った）、敗者版を `<name>.sync-conflict-YYYYMMDD-HHMMSS-<勝者ID>.ext` として敗者側が作成し全端末へ複製する。10件を超えると古いコピーを削除 | `config.xml`、§3-2〜4 |
| 2 | git自動同期 | launchd `com.laa.vault-git-sync`（600秒）→ `hq/tools/vault-git-sync.sh`。quiet 300秒、`git add -A`、fetch後にff／rebase、失敗時は `merge_keep_both` で Mac版を本体に残し GitHub版を `（GitHub競合 YYYY-MM-DD HHMM）.md` として vault 内に作る | index.lock・rebase・merge中、master以外、未解決競合で停止。gitleaks pre-commit失敗時は reset＋通知 | スクリプト実体、§3-7 |
| 3 | Obsidian 1.11.7 | 起動中、vault `/Users/laa/Brain` を開いている。core `file-recovery` 有効、`sync` 無効、community plugin は0件（`obsidian-git` 2.38.6 は導入済みだが無効） | 競合解決を持たない。同時保存は last-writer-wins。復旧は file-recovery の snapshot のみ | `.obsidian/app.json`・`core-plugins.json`・`community-plugins.json` |
| 4 | iPhone | Syncthing の device `iPhone16-ProMax`（`MCPP2XC…`）。クライアント名は社長談の SyncTrain だが実体・保存方式は未確認 | Syncthing と同じ（端末側の競合コピー生成は観測済み） | `config.xml`、実vaultの競合コピー |
| 5 | brain_daily | `hq/harness/brain_daily.py`、毎日00:05。自作lock（`~/.local/state/laa/brain-daily/*.lock`）は**自分の実行間だけ**、expected-bytes CAS＋`os.replace`＋外vault台帳＋事後検証。一時ファイルは編集先と同一dirに `.{name}.*.tmp` | 外部editorは排他しない（コード注記）。置換後に本文が変わっていれば `concurrent_editor_change` で曖昧として止める | 実装（`atomic_write`・`_transaction`） |
| 6 | その他 | `obsidian-mcp` プロセス稼働（書込み範囲未確認）。`laa-brain` CLI は読取りのみ。旧 `laa-brain-pull.sh` は legacy のみで未スケジュール | — | `ps`、`launchctl list`、legacy配置 |

実vaultの証拠：`daily journal/2026-10-19.sync-conflict-20261020-201228-MCPP2XC.md` と `…-201230-…`（各62,815B、内容は相互に同一、現行 `2026-10-19.md` と90行差、生成から9日後も残存）。gitでは未追跡で、`Brain/.git/info/exclude` の `*.sync-conflict-*`・`/.stfolder`・`/.stversions` が除外している。この除外は**版管理外**なので再cloneで失われる。

## 3. 実測（スクラッチ）

1. 伝播遅延：9Bのファイルで2.38秒（fsWatcherDelay=1秒設定）。実設定の10秒では約11秒以上。
2. オフライン分岐：A・Bが同じファイルを別内容で編集→再接続で両版が残り、競合コピーが両端末に現れた。コピー名の末尾は勝者deviceの短縮ID、コピーの作成者は敗者側（`/rest/db/file` の `modifiedBy` で確認）。
3. 同一窓の同時書込み6回：6/6で両版保全。ただし毎回競合コピーが増え、直前版のコピーも生成された。
4. `maxConflicts`：同一パスで12回競合させると競合コピーは10件で止まり、cycle3・cycle10 の敗者版が消えていた。`.stversions` にも残っていない（削除はversioningを通らない）。
5. 途中で止めた in-place 書込み：4MBのうち2MB書いた所で6秒止めると、peer は2MBの途中状態を受け取った（完了後に4MBへ更新）。atomic rename では部分状態は0/75サンプル。
6. 同一Macの非協調writer：`flock(LOCK_EX)` 保持中でも他プロセスの rename は成功し、同じpathへの再flockも成功（lockは旧inodeに残る）。CAS check→rename の50ms窓で外部writerが保存すると、その保存は最終ファイルから消失し、Bridge側の事後hash検証は成功したまま（検知不能）。
7. 新規作成：`O_EXCL` は2プロセス同時で成功1・失敗1。`renameatx_np(RENAME_EXCL)` は既存targetに `EEXIST` を返し内容を保った（macOSに比較付きrenameは無い）。
8. git job：分岐時は Mac版を本体、GitHub版を `（GitHub競合 …）.md` として両版保全し push した。除外設定の無いcloneでは `.sync-conflict-*` と `.tmp-*` が commit された（`git add -A`）。`index.lock` があれば `skip: git operation in progress`。
9. `.stversions`・`.stfolder` は同期対象外（Syncthingの内部除外）。競合コピー自体は通常ファイルとして全端末へ複製される。

再現（CAS窓、§3-6）：

```python
base = sha256(read(path))            # 1 読み取り
assert sha256(read(path)) == base    # 2 CAS検査は通る
time.sleep(0.05)                     # 3 外部writerが保存する窓
atomic_write(path, data + b'BRIDGE\n')  # 4 古い読み取りを元に rename
# 事後検証は成功する。外部writerの保存は消える
```

## 4. 書き込み手順（実装する場合の最低線）

1. path検証：realpathがvault内、symlink拒否、`.git`・`.obsidian`・`.stfolder`・`.stversions`・`.stignore` 拒否、`*.sync-conflict-*` と `（GitHub競合` を拒否、scope外の領域を拒否、64KB上限。
2. 前提検査：Syncthing `/rest/db/status?folder=brain` が `idle`・`errors=0`・`pullErrors=0`、対象のmtimeが10秒より新しければ待つ（未索引の変更と衝突しない）、gitに `index.lock`／`rebase-merge`／`rebase-apply`／`MERGE_HEAD`／`CHERRY_PICK_HEAD`／未解決競合が無く master、同一pathの競合コピーが直近30分に無い。
3. 読取り：content・sha256・size・mtime_ns・dev+ino を版として返す。
4. CAS：要求の `baseHash` が現行sha256と一致しなければ409（現行hashと版を返す）。直前に再計算する。
5. 外vault journal（`~/.local/state/laa-bridge/brain-write/`、0600）へ base本文・新本文・両hash・requestId を fsync してから vault を触る。これが「両版保全」の最後の砦。
6. 同一vault内のステージング（`.bridge-tmp/`、`.stignore` と git 除外の追加が前提）へ書き fsync → `os.replace` → ディレクトリfsync。
7. 直後に `POST /rest/db/scan?folder=brain&sub=<path>` で索引を進め、`idle` まで待つ（上限5秒）。
8. 事後検証：本文hashが新hashと一致、同一pathに新しい競合コピーが無い、`/rest/db/file` の勝者が自分の版。不一致は `outcome_unknown` として以後そのpathの書込みを拒否。
9. 結果を journal に committed／ambiguous として残し、hashとjournal idを返す。自動マージ・自動再試行・自動削除をしない。
10. 途中失敗では vault を触らず、両版を外vaultに残して人へ渡す。

5〜8を満たしても、同一Macの外部writerが手順4〜6の間に保存した内容は保証できない。§3-6がその限界の実測。SyncthingのpauseとObsidianの終了で窓は狭められるが、agent CLI・`obsidian-mcp` など未知のwriterが残るため単一writer調停とは言えない。

## 5. 停止条件（Bridgeが書込みを拒否する）

- `baseHash` 不一致（409）、対象が競合コピー・`（GitHub競合`・symlink・許可外path。
- Syncthing：folder停止／paused、state ≠ `idle`、`errors`／`pullErrors` > 0、`need` あり、`.stfolder` 欠落、APIキー読取り不能、制御APIへ到達不能。
- git：`index.lock`・rebase・merge・未解決競合・master以外、commit失敗（gitleaks含む）、push結果不明。
- 同一pathの競合コピーが直近30分に生成された、または8件以上ある（上限10件に接近）。
- journal書込み失敗・台帳破損、書込み後の検証不一致・timeout（`outcome_unknown`）。
- vaultの空き容量不足、`.bridge-tmp` の除外が未整備。

## 6. 試験項目（`brain:write` を実装する場合）

| # | 試験 | 期待 |
|---|---|---|
| 1 | 正常な置換（baseHash一致） | 200、新hashが読戻しと一致、journal が committed |
| 2 | `baseHash` 不一致（他端末が先に保存） | 409、現行hashと版を返し、vault無変更 |
| 3 | CAS窓で外部writerが保存（§3-6の再現） | 外部の保存が失われないこと。失われるなら `brain:write` は不可（現状は失われる） |
| 4 | Syncthing が該当pathをpull中 | 423/409で拒否、`idle` 復帰後に再受付 |
| 5 | folder paused・`.stfolder` 欠落・APIキー不能 | 503で拒否、状態を `health` に出す |
| 6 | 同一pathの競合コピーが直近30分にあり | 409で拒否、人による解決を促す |
| 7 | git `index.lock`／rebase中／master以外 | 423で拒否、gitを触らない |
| 8 | commit失敗（gitleaks）・push結果不明 | 書込みは成功でも `outcome_unknown` として以後拒否 |
| 9 | journal書込み失敗・台帳破損 | vaultを触る前に拒否 |
| 10 | temp作成後・rename前に強制終了 | 中断状態を検出し、次回は書込み拒否＋孤児tempの掃除（vault内容は不変） |
| 11 | 同一pathへの新規作成の競合（`RENAME_EXCL`） | 片方だけ成功（EEXIST）、既存内容は不変 |
| 12 | symlink・vault外・許可外領域・競合コピーへの書込み | 403/404で拒否、realpath検証を通す |
| 13 | 同一pathで10件目の競合コピー発生 | 書込み停止（§5）と、コピーの外部退避を提案 |

## 7. v1判定

- `brain:write`（既存の置換・追記）：**いいえ**。BRIDGE §6の受入「外部writer間の安全な調停を両版保全で実証」を満たせない。
- 代替案：`brain:create`（新規pathのみ、unique name、`RENAME_EXCL`、journal付き）は安全。既存ノートの編集は Obsidian とエージェントに残す。
- タスク20：daily原本への追記はCAS窓と10件上限の両方に触れるため保留。代替は Bridge専有の sidecar（例 `daily journal/_bridge/YYYY-MM-DD.md`、単一writer）へ追記し、人が原本へ移す運用。
- タスク25の受入「同時書込・中断・オフラインで両版保持」は、§4の手順と§5の停止条件で**検知と保全**まで到達する。無損失を保証できるのは新規作成だけ。

## 8. タスク25の実装（2026-10-29）

§7の判定どおり `brain:write` は無効のまま、`brain:read` と新規作成専用 `brain:create` をBridgeへ実装した。端点は `GET /v1/brain/files`、`GET /v1/brain/files/{id}`、`GET /v1/brain/search`、`POST /v1/brain/files`（作成のみ）、`GET /v1/brain/gates`。コードは `bridge/src/routes/brain.mjs` と `bridge/src/brain/`。

- 作成の順序: 空き容量64MB以上 → git（`master`・`index.lock`/rebase/merge/cherry-pick無し）→ Syncthing（paused・`errors`・`pullErrors`）→ journal `intent`（fsync）→ 親フォルダ検証 → `O_EXCL` で作成 → 本文fsync・ディレクトリfsync → 読戻しで長さとhashを照合 → journal `committed`。どこかで止まれば vault は不変か、作成済みなら `brain_create_unverified`／`brain_journal_incomplete` として人へ渡す。
- 名前衝突: 既定は `onConflict:"suffix"`（`Note 2.md` を `O_EXCL` で確保）。`"reject"` は 409 `path_exists`。上書き・rename・切詰め・削除の経路は持たない。
- `brain:create` は**既定scopeに加えない**。§9の初期集合を変えず、端末ごとに `laa-bridge pair --scopes brain:read,brain:create` で付与する。§7が「安全」とするのは新規作成経路だけで、全端末へ広げる根拠にはならないため。
- 領域は `laa-brain` の `policy.json` をそのまま読み、既定は default 領域のみ。旧資料・Inbox・Sources・`Journal/`（日記）・研究/振り返り・添付・Templates・未分類は `?area=` で明示した時だけ足す。`daily journal/`・`Tasks/`・`Context/`・`Guide/` は policy どおり既定で含み、Jevへは送らない（`--no-jev`）。タスク指示の「daily journals を既定で除外」は現行 policy／BRAIN-SEARCH.md と食い違うため、検索CLIの実挙動（`Journal/` のみ除外）に合わせた。検索は `laa-brain search --json` を再利用し、既定は `--no-jev`（ローカル順位のみ）、`rerank=1` の時だけJev再判定を通す。電話からの検索を、既定でBrain抜粋を外部モデルへ送る新しい経路にしないため。

§5との差分（意図的）:

| §5の条件 | タスク25での扱い | 理由 |
|---|---|---|
| Syncthing `state ≠ idle` で拒否 | 新規作成では `paused`・`errors`・`pullErrors` のみ拒否 | 新規pathにはCAS窓が無く、scan中でも失う版が無い。`state` 語彙は§9のとおり未確定 |
| 同一pathの競合コピーが30分以内／8件以上 | 新規作成では判定しない | 対象pathが存在しないため。既存内容の置換を実装する時の条件 |
| `.bridge-tmp` へ書いて `os.replace` | 使わない | 新規作成は `O_EXCL` で直接置くので rename が無い。`.stignore`・git除外の変更も不要 |
| 依存状態を `health` に出す | `GET /v1/brain/gates` で出す | 共有の `/v1/health` を他領域と同時に触らない |

検証: `bridge/scripts/verify-brain.mjs` を実vaultへ1回実行し、一覧64件、gates（git `master`・Syncthing `idle`/errors 0）、検索1件、`Inbox/_bridge-create-verify-20261029-….md` の作成201、読戻し本文・hash一致、同名再作成409、`onConflict:"reject"` 409を確認した。試験ノートは削除せず vault の既定に合わせて `~/.Trash/` へ移動した（vaultに `.trash` は無く、Obsidianの `trashOption` も未設定＝システムTrashが既定）。検証用の端末は実行後に失効させ、stateから消した。テストは `bridge/test/brain.test.mjs`（fake vault・fake search・fake gates）で同じ契約を固定し、`npm test` 130件が通る。iPhone側writerと `maxConflicts` の挙動は§9（未確認）のままで、新規作成の安全性は「既存内容を壊さない」ことに限る。

## 9. 未確認

- iPhone側writerの実体（SyncTrainの版・保存方式・競合コピーの扱い）。
- Obsidianの保存がatomicか、file-recoveryの間隔と保持数。
- `obsidian-mcp` の書込み範囲。
- Syncthingの `state` 語彙の全集合（`idle` 以外を拒否する判定に使う値の確定）。
- 実vaultへの `.bridge-tmp` 除外追加（設定変更は未実施）。
- `maxConflicts` の削除単位がファイル単位かブロック単位か（同一pathのみ確認）。
