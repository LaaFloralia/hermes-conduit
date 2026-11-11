#if LAA_BUILD
import XCTest
@testable import Conduit

/// Work's task sections: the genre a title reads as, Linear's project and
/// labels winning over the title, the four groupings, the quick filters, and
/// the due words the rows show.
final class LAATaskBoardTests: XCTestCase {
    private func task(_ title: String, id: Int = 1, priority: Int = 0, due: String? = nil,
                      project: LAALinearTask.Project? = nil, labels: [LAALinearTask.Label]? = nil,
                      staff: String? = nil, state: String? = nil) -> LAALinearTask {
        let run = staff.map {
            LAATaskRun(creator: "owner", assignee: .init(kind: "staff", staff: $0, name: LAATaskStaff.name($0)),
                       profile: "opus-high", profileLabel: nil, state: state, sessionId: nil, sessionRef: nil,
                       decisionRef: nil, report: nil, error: nil)
        }
        return LAALinearTask(id: String(format: "00000000-0000-4000-8000-%012d", id), identifier: "BUS-\(id)",
                             title: title, description: nil, dueDate: due, priority: priority, status: "todo",
                             stateName: "Todo", updatedAt: "2026-11-0\(id % 9 + 1)T00:00:00Z", url: nil,
                             ref: "T\(id)", run: run, project: project, labels: labels)
    }

    private func inputs(_ items: [LAALinearTask], grouping: LAATaskGrouping = .genre,
                        quick: LAATaskQuickFilter = .all, query: String = "") -> LAATaskBoard.Inputs {
        LAATaskBoard.Inputs(items: items, archived: false, filter: .related, quick: quick, query: query,
                            grouping: grouping, day: "2026-11-11")
    }

    /// 2026-11-11 12:00 in Tokyo, the day the owner asked for this list.
    private let now = ISO8601DateFormatter().date(from: "2026-11-11T03:00:00Z")!

    func testTitlesReadAsTheOwnersGenres() {
        let cases: [(String, LAATaskGenre)] = [
            ("LAAアプリ：キーボードの予測変換をSimeji水準へ", .app),
            ("Work：エンジン切替後のスマホのWorkタブを実機で確認する", .app),
            ("UI：ClaudeでLiquid Glassを基調に改善する", .app),
            ("AI社員の指示書：プロ水準の確認を終える（会話試験・Studioの実制作1件）", .ai),
            ("TalosのMythos接続経路を確認する", .ai),
            ("Claudeのログイン中端末とClaude PlatformのAPIキーを棚卸しする", .security),
            ("Mac miniの強化3件を本人操作で適用する", .security),
            ("1Password・Apple ID・GitHubの2要素と復旧手段を確認する", .security),
            ("Mac miniの空き容量不足を解消し、ビルド待機を減らす", .environment),
            ("MacBookのTailscaleを再ログインし、署名端末に加える", .environment),
            ("XAUUSD反転手法の因果検証と改善", .trade),
            ("裁量手法と過去検証を終えるまで取引を控える", .trade),
            ("【法人化】名刺の記載内容・印刷仕様・部数を確認する", .company),
            ("LAAのPR動画の最新版を作る（FLUXの動画モデル）", .creative),
            ("プレイリストとBGM収集の基準を決める", .creative),
            ("有給休暇の残り2日を12月14日までに取得する", .life),
            ("「はじめてのGRANDIT」を読み、業務と機能の流れを理解する", .life),
            ("AUDAYの使い方を決める", .other),
        ]
        for (title, genre) in cases {
            XCTAssertEqual(LAATaskGenre.classify(title: title).id, genre.id, title)
        }
    }

    func testShortCapitalsMatchOnlyAsCapitals() {
        // "Email" holds "ai", "Improve" holds "pr": neither is AI or PR work.
        XCTAssertEqual(LAATaskGenre.classify(title: "Email the agenda").id, LAATaskGenre.other.id)
        XCTAssertEqual(LAATaskGenre.classify(title: "Improve the agenda").id, LAATaskGenre.other.id)
    }

    func testProjectAndLabelsWinOverTheTitle() {
        let project = task("XAUUSDの検証", project: .init(id: "p1", name: "LAAアプリ"))
        XCTAssertEqual(LAATaskGenre.classify(project).id, LAATaskGenre.app.id)
        let unknownProject = task("名刺", project: .init(id: "p2", name: "春の展示"))
        XCTAssertEqual(LAATaskGenre.classify(unknownProject).id, "project:p2")
        XCTAssertEqual(LAATaskGenre.classify(unknownProject).title, "春の展示")
        let label = task("名刺", labels: [.init(id: "l1", name: "トレード", color: "#86661C")])
        XCTAssertEqual(LAATaskGenre.classify(label).id, LAATaskGenre.trade.id)
        let custom = task("名刺", labels: [.init(id: "l2", name: "家族", color: "#5E6AD2")])
        XCTAssertEqual(LAATaskGenre.classify(custom).id, "label:家族")
    }

    func testGenreSectionDropsOnlyThePrefixThatRepeatsIt() {
        XCTAssertEqual(LAATaskGenre.app.shortTitle("LAAアプリ：キーボードの予測変換"), "キーボードの予測変換")
        XCTAssertEqual(LAATaskGenre.company.shortTitle("【法人化】名刺を確認する"), "名刺を確認する")
        // A sub-area is information, not repetition: it stays.
        XCTAssertEqual(LAATaskGenre.app.shortTitle("Work：Workタブを確認する"), "Work：Workタブを確認する")
        XCTAssertEqual(LAATaskGenre.app.shortTitle("LAAアプリ："), "LAAアプリ：")
    }

    func testGenreSectionsStandInTheFixedOrderWithOtherLast() {
        let board = LAATaskBoard(inputs([
            task("AUDAYの使い方を決める", id: 1),
            task("XAUUSDの検証", id: 2),
            task("LAAアプリ：一覧を速くする", id: 3),
            task("2要素を確認する", id: 4),
        ]), now: now)
        XCTAssertEqual(board.sections.map(\.title), ["LAAアプリ", "セキュリティ", "トレード", "その他"])
        XCTAssertEqual(board.sections.first?.rows.first?.title, "一覧を速くする")
        XCTAssertEqual(board.total, 4)
    }

    func testRowsKeepTheListOrderInsideASection() {
        let board = LAATaskBoard(inputs([
            task("LAAアプリ：低", id: 1, priority: 4),
            task("LAAアプリ：指定なし", id: 2, priority: 0),
            task("LAAアプリ：緊急", id: 3, priority: 1),
            task("LAAアプリ：高・期限あり", id: 4, priority: 2, due: "2026-11-12"),
            task("LAAアプリ：高", id: 5, priority: 2),
        ]), now: now)
        XCTAssertEqual(board.sections.first?.rows.map(\.title), ["緊急", "高・期限あり", "高", "低", "指定なし"])
    }

    func testDueSectionsAndWords() {
        let board = LAATaskBoard(inputs([
            task("a", id: 1, due: "2026-11-09"),
            task("b", id: 2, due: "2026-11-11"),
            task("c", id: 3, due: "2026-11-12"),
            task("d", id: 4, due: "2026-11-14"),
            task("e", id: 5, due: "2026-12-14"),
            task("f", id: 6),
        ], grouping: .due), now: now)
        XCTAssertEqual(board.sections.map(\.title), ["期限切れ", "今日", "明日", "7日以内", "それ以降", "期限なし"])
        XCTAssertEqual(LAATaskDue.make("2026-11-11", now: now)?.label, "今日")
        XCTAssertEqual(LAATaskDue.make("2026-11-12", now: now)?.label, "明日")
        XCTAssertEqual(LAATaskDue.make("2026-11-14", now: now)?.label, "土曜")
        XCTAssertEqual(LAATaskDue.make("2026-11-09", now: now)?.tone, .overdue)
        XCTAssertEqual(LAATaskDue.make("2026-12-14", now: now)?.label, "12月14日")
        XCTAssertNil(LAATaskDue.make("not a date", now: now))
    }

    func testAssigneeSectionsPutTheOwnerFirstThenStaffInTheirOrder() {
        let board = LAATaskBoard(inputs([
            task("a", id: 1, staff: "cto", state: "queued"),
            task("b", id: 2),
            task("c", id: 3, staff: "monet", state: "running"),
        ], grouping: .assignee), now: now)
        XCTAssertEqual(board.sections.map(\.title), ["社長", "Monet", "Ada"])
        XCTAssertEqual(board.sections[1].staff, .monet)
    }

    func testPrioritySectionsPutNoPriorityLast() {
        let board = LAATaskBoard(inputs([task("a", id: 1), task("b", id: 2, priority: 3), task("c", id: 3, priority: 1)],
                                        grouping: .priority), now: now)
        XCTAssertEqual(board.sections.map(\.title), ["緊急", "中", "指定なし"])
    }

    func testQuickFiltersCountBeforeFiltering() {
        let items = [
            task("a", id: 1, due: "2026-11-10"),
            task("b", id: 2, staff: "monet", state: "awaiting_decision"),
            task("c", id: 3, due: "2026-12-30"),
        ]
        let all = LAATaskBoard(inputs(items), now: now)
        XCTAssertEqual(all.counts[.all], 3)
        XCTAssertEqual(all.counts[.soon], 1)
        XCTAssertEqual(all.counts[.attention], 2, "an overdue task and a decision wait both need the owner")
        XCTAssertEqual(all.counts[.ai], 1)
        let soon = LAATaskBoard(inputs(items, quick: .soon), now: now)
        XCTAssertEqual(soon.total, 1)
        XCTAssertEqual(soon.counts[.all], 3, "the chips keep the unfiltered counts")
    }

    func testSearchFindsTheShortNumberAndTheTitle() {
        let items = [task("名刺を確認する", id: 12), task("写真の選定", id: 13)]
        XCTAssertEqual(LAATaskBoard(inputs(items, query: "t12"), now: now).orderedIDs, [items[0].id])
        XCTAssertEqual(LAATaskBoard(inputs(items, query: "写真"), now: now).orderedIDs, [items[1].id])
    }

    func testTheSameTasksBuildTheSameBoard() {
        // The 15-second refresh brings the same tasks: the board compares
        // equal, so the list draws nothing new.
        let items = [task("LAAアプリ：a", id: 1), task("XAUUSD", id: 2)]
        XCTAssertEqual(LAATaskBoard(inputs(items), now: now), LAATaskBoard(inputs(items), now: now))
    }

    func testFoldingRoundTrips() {
        let folded: Set<String> = ["genre:app", "due:today"]
        XCTAssertEqual(LAATaskFolding.decode(LAATaskFolding.encode(folded)), folded)
        XCTAssertEqual(LAATaskFolding.decode(""), [])
    }

    func testPicksToggleKeepOnlyWhatIsOnScreenAndFollowItsOrder() {
        var picks = LAATaskPicks()
        XCTAssertTrue(picks.isEmpty)
        picks.toggle("c"); picks.toggle("a"); picks.toggle("b")
        picks.toggle("b")
        XCTAssertEqual(picks.count, 2)
        XCTAssertEqual(picks.ordered(in: ["a", "b", "c"]), ["a", "c"], "Sent in screen order")
        // A filter or a fold takes "c" off the screen: it is unpicked.
        XCTAssertTrue(picks.keep(only: ["a", "b"]))
        XCTAssertEqual(picks.ordered(in: ["a", "b", "c"]), ["a"])
        XCTAssertFalse(picks.keep(only: ["a", "b"]), "Nothing changed")
        picks.remove("a")
        XCTAssertTrue(picks.isEmpty)
        picks.toggle("x"); picks.clear()
        XCTAssertTrue(picks.isEmpty)
    }

    func testOlderBridgeTasksDecodeWithoutProjectOrLabels() throws {
        let json = #"{"id":"00000000-0000-4000-8000-000000000001","identifier":"BUS-1","title":"a","priority":0,"status":"todo","stateName":"Todo","updatedAt":"x"}"#
        let decoded = try JSONDecoder().decode(LAALinearTask.self, from: Data(json.utf8))
        XCTAssertNil(decoded.project)
        XCTAssertNil(decoded.labels)
        let withGenre = ##"{"id":"00000000-0000-4000-8000-000000000001","identifier":"BUS-1","title":"a","priority":0,"status":"todo","stateName":"Todo","updatedAt":"x","project":{"id":"p","name":"LAAアプリ"},"labels":[{"id":"l","name":"UI","color":"#5E6AD2"}]}"##
        let full = try JSONDecoder().decode(LAALinearTask.self, from: Data(withGenre.utf8))
        XCTAssertEqual(full.project?.name, "LAAアプリ")
        XCTAssertEqual(full.labels?.first?.name, "UI")
    }
}
#endif
