#if LAA_BUILD && DEBUG
import XCTest
@testable import Conduit

/// The project detail's requirements (Bridge contract 2026-11-23): optional
/// new fields, a row the app cannot read, the order the page draws and the
/// marks the lists show.
final class LAAWorkProjectRequirementTests: XCTestCase {
    private func project(_ json: String) throws -> LAAWorkProject {
        try JSONDecoder().decode(LAAWorkProject.self, from: Data(json.utf8))
    }

    func testOlderBridgeOmitsEveryNewField() throws {
        let value = try project(#"{"id":"prj_000000000001","name":"LAA","etag":"\"p-1\""}"#)
        XCTAssertNil(value.requirementSummary)
        XCTAssertNil(value.progressNote)
        XCTAssertNil(value.requirements)
        XCTAssertNil(value.sessions)
        XCTAssertNil(value.sessionCounts)
        XCTAssertNil(value.nextSessionsCursor)
        XCTAssertNil(value.progress, "no summary and no rows reads as no requirements, not as 0 of 0 done")
    }

    func testListItemCarriesSummaryAndNote() throws {
        let value = try project(#"""
        {"id":"prj_000000000001","name":"LAA","requirementSummary":{"completed":3,"total":7},
         "progressNote":"次はTestFlight。"}
        """#)
        XCTAssertEqual(value.progress, LAAWorkRequirementSummary(completed: 3, total: 7))
        XCTAssertEqual(value.progressNote, "次はTestFlight。")
    }

    func testBlankNoteIsNoNote() throws {
        XCTAssertNil(try project(#"{"id":"prj_000000000001","name":"LAA","progressNote":"  \n"}"#).progressNote)
        XCTAssertNil(try project(#"{"id":"prj_000000000001","name":"LAA","progressNote":null}"#).progressNote)
    }

    func testDetailDecodesRequirementsAndSessions() throws {
        let value = try project(#"""
        {"id":"prj_000000000001","name":"LAA","instructions":"x","files":[],
         "requirementSummary":{"completed":1,"total":2},"progressNote":null,
         "requirements":[
          {"id":"req_0123456789ab","title":"一覧で分かる","details":null,"source":"owner","status":"in_progress",
           "sessionIds":["ses_0123456789abcdef"],"order":0,"updatedAt":"2026-11-23T00:00:00Z"},
          {"id":"req_0123456789ac","title":"既定のプロジェクト","details":"補足","source":"ai","status":"completed",
           "sessionIds":[],"order":1,"updatedAt":"2026-11-23T00:00:00Z"}],
         "sessions":[{"id":"ses_0123456789abcdef","name":"S","status":"waiting","model":null,
           "updatedAt":"2026-11-23T00:00:00Z","parentId":null,"archivedAt":null}]}
        """#)
        let requirements = try XCTUnwrap(value.requirements)
        XCTAssertEqual(requirements.map(\.status), [.inProgress, .completed])
        XCTAssertFalse(requirements[0].addedByAI)
        XCTAssertTrue(requirements[1].addedByAI)
        XCTAssertEqual(requirements[1].details, "補足")
        XCTAssertEqual(value.sessions?.first?.statusLabel, "待機")
        XCTAssertEqual(value.sessions?.first?.mark, .waiting)
        // The detail's own rows win over the list's summary.
        XCTAssertEqual(value.progress, LAAWorkRequirementSummary(completed: 1, total: 2))
    }

    func testUnreadableRowIsLeftOutAndUnknownStatusStaysUnknown() throws {
        let value = try project(#"""
        {"id":"prj_000000000001","name":"LAA",
         "requirements":[{"id":"req_0123456789ab"},
          {"id":"req_0123456789ac","title":"新しい状態","source":"owner","status":"blocked","sessionIds":[],"order":0}],
         "sessions":[{"id":"x"}]}
        """#)
        XCTAssertEqual(value.requirements?.count, 1, "a row without a title is skipped, the project still opens")
        XCTAssertEqual(value.requirements?.first?.status, .unknown)
        XCTAssertEqual(value.sessions, [])
    }

    func testBoardOrdersByStateThenBridgeOrderAndFoldsDoneWork() {
        let rows: [LAAWorkRequirement] = [
            .init(id: "req_000000000001", title: "a", status: .completed, order: 0),
            .init(id: "req_000000000002", title: "b", status: .notStarted, order: 1),
            .init(id: "req_000000000003", title: "c", status: .inProgress, order: 3),
            .init(id: "req_000000000004", title: "d", status: .awaitingDecision, order: 2),
            .init(id: "req_000000000005", title: "e", status: .inProgress, order: 2),
        ]
        let board = LAAWorkRequirementBoard(rows)
        XCTAssertEqual(board.groups.map(\.status), [.inProgress, .awaitingDecision, .notStarted, .completed])
        XCTAssertEqual(board.groups[0].items.map(\.id), ["req_000000000005", "req_000000000003"])
        XCTAssertEqual(board.summary, LAAWorkRequirementSummary(completed: 1, total: 5))
        XCTAssertEqual(board.count(.inProgress), 2)
        XCTAssertTrue(board.foldsCompleted)
        XCTAssertFalse(LAAWorkRequirementBoard([rows[0]]).foldsCompleted, "all done opens the done group")
        XCTAssertTrue(LAAWorkRequirementBoard([]).groups.isEmpty)
    }

    /// The opened project leads with what needs the owner and what is moving;
    /// not started and done start folded (owner, 2026-11-26).
    func testOnlyGroupsThatNeedAttentionStartOpen() {
        func board(_ statuses: [LAAWorkRequirementStatus]) -> LAAWorkRequirementBoard {
            LAAWorkRequirementBoard(statuses.enumerated().map { .init(id: "req_\($0.offset)", title: "t", status: $0.element, order: $0.offset) })
        }
        XCTAssertEqual(board([.completed, .notStarted, .inProgress, .awaitingDecision]).openByDefault, [.inProgress, .awaitingDecision])
        XCTAssertEqual(board([.completed, .notStarted]).openByDefault, [.notStarted], "nothing open: the first group opens")
        XCTAssertEqual(board([.completed]).openByDefault, [.completed])
        XCTAssertEqual(board([]).openByDefault, [])
    }

    /// A requirement's line is one line: the title up to its first line
    /// break or sentence end; the full title is on its own page.
    func testRequirementNameIsOneLine() {
        XCTAssertEqual(LAAWorkRequirementName.short("Macの一覧も5秒ごとに読み直す"), "Macの一覧も5秒ごとに読み直す")
        XCTAssertEqual(LAAWorkRequirementName.short("要件を短くする。長い説明が続く場合でも一覧は1行"), "要件を短くする")
        XCTAssertEqual(LAAWorkRequirementName.short("1行目\n2行目"), "1行目")
        XCTAssertEqual(LAAWorkRequirementName.short("v2.1を出す"), "v2.1を出す", "an ASCII dot is not a sentence end")
        XCTAssertEqual(LAAWorkRequirementName.short("短い。続き"), "短い。続き", "too short a head keeps the line")
    }

    /// Status names and the disclosure controls follow DESIGN 「日本語と英語」
    /// (2026-11-26): short English words, no Japanese open/close labels.
    func testStatusNamesAndTogglesAreShortEnglish() {
        for status in LAAWorkRequirementStatus.allCases {
            let label = status.label
            XCTAssertLessThanOrEqual(label.split(separator: " ").count, 2, label)
            XCTAssertTrue(label.allSatisfy(\.isASCII), label)
        }
        for word in [LAACopy.WorkProject.readMore, LAACopy.WorkProject.showArchived, LAACopy.WorkProject.hideArchived,
                     LAACopy.WorkProject.archivedCount(3), LAACopy.WorkProject.done(1, of: 2)] {
            XCTAssertTrue(word.allSatisfy(\.isASCII), word)
        }
    }

    /// The paged detail (2026-11-23): unarchived sessions only, totals before
    /// paging and a cursor to the next page.
    func testDetailCarriesSessionTotalsAndCursor() throws {
        let value = try project(#"""
        {"id":"prj_000000000000","name":"未分類","requirements":[],"sessions":[],
         "sessionCounts":{"active":6,"archived":1584},"nextSessionsCursor":"eyJtb2RlIjoiYWN0aXZlIn0"}
        """#)
        XCTAssertEqual(value.sessionCounts, LAAWorkSessionCounts(active: 6, archived: 1584))
        XCTAssertEqual(value.nextSessionsCursor, "eyJtb2RlIjoiYWN0aXZlIn0")
        let malformed = try project(#"{"id":"prj_000000000000","name":"未分類","sessionCounts":{"active":"x"},"nextSessionsCursor":7}"#)
        XCTAssertNil(malformed.sessionCounts, "a malformed total is left out, the project still opens")
        XCTAssertNil(malformed.nextSessionsCursor)
        XCTAssertEqual(LAAWorkProjectSnapshot(value).sessionCounts, LAAWorkSessionCounts(active: 6, archived: 1584))
    }

    func testSessionPagesAskForTheirOwnList() {
        func names(_ items: [URLQueryItem]) -> [String] { items.map { "\($0.name)=\($0.value ?? "")" } }
        XCTAssertEqual(names(LAAWorkProjectSessionsAPI.query("prj_000000000001", archived: false, cursor: nil)),
                       ["projectId=prj_000000000001", "limit=100"])
        XCTAssertEqual(names(LAAWorkProjectSessionsAPI.query("prj_000000000001", archived: true, cursor: "c2")),
                       ["projectId=prj_000000000001", "limit=100", "archived=only", "cursor=c2"])
    }

    func testLinkedSessionOutsideThePageStillOpens() {
        let row = LAAWorkLinkedSession.unlisted("ses_00000000000000ff")
        XCTAssertEqual(row.id, "ses_00000000000000ff")
        XCTAssertEqual(row.name, "一覧にないセッション")
        XCTAssertEqual(row.mark, .pending)
    }

    func testSummaryFraction() {
        XCTAssertEqual(LAAWorkRequirementSummary(completed: 0, total: 0).fraction, 0)
        XCTAssertEqual(LAAWorkRequirementSummary(completed: 3, total: 4).fraction, 0.75)
        XCTAssertEqual(LAAWorkRequirementSummary(completed: 9, total: 4).fraction, 1)
    }

    func testActivityFromCompactSessions() {
        func row(_ status: String, archived: Bool = false) -> LAAWorkProjectSession {
            .init(id: UUID().uuidString, name: "s", status: status, model: nil, updatedAt: nil, parentId: nil,
                  archivedAt: archived ? "2026-11-23T00:00:00Z" : nil)
        }
        XCTAssertEqual(LAAWorkProjectActivity.of([row("waiting"), row("completed")]), .idle)
        XCTAssertEqual(LAAWorkProjectActivity.of([row("running"), row("running"), row("waiting")]), .running(2))
        XCTAssertEqual(LAAWorkProjectActivity.of([row("running"), row("awaiting_decision")]), .decision(1))
        XCTAssertEqual(LAAWorkProjectActivity.of([row("running", archived: true)]), .idle)
    }

    func testActivityFromSessionListFollowsParents() {
        let parent = LAAWorkProjectFixtureView.session("ses_00000000000000f1", ref: "S1", name: "p", phase: "awaiting_review",
                                                       model: "claude-opus-5-5", effort: "high", updated: "2026-11-23T00:00:00Z")
        let child = LAAWorkProjectFixtureView.session("ses_00000000000000f2", ref: "S2", name: "c", phase: "running",
                                                      model: "claude-opus-5-5", effort: "high", updated: "2026-11-23T00:00:00Z",
                                                      parent: "ses_00000000000000f1")
        XCTAssertEqual(LAAWorkProjectActivity.of("prj_00000000000a", sessions: [parent, child]), .running(1))
        XCTAssertEqual(LAAWorkProjectActivity.of("prj_00000000000b", sessions: [parent, child]), .idle)
    }

    func testLinkedSessionsPreferTheFullRow() {
        let compact = [LAAWorkProjectSession(id: "ses_00000000000000a1", name: "old", status: "waiting", model: nil,
                                             updatedAt: nil, parentId: nil, archivedAt: nil)]
        let full = [LAAWorkProjectFixtureView.session("ses_00000000000000a1", ref: "S4", name: "new", phase: "awaiting_decision",
                                                      model: "claude-opus-5-5", effort: "high", updated: "2026-11-23T00:00:00Z")]
        let only = LAAWorkLinkedSession.lookup(compact: compact, full: [])
        XCTAssertEqual(only["ses_00000000000000a1"]?.statusLabel, "待機")
        let both = LAAWorkLinkedSession.lookup(compact: compact, full: full)
        XCTAssertEqual(both["ses_00000000000000a1"]?.name, "new")
        XCTAssertEqual(both["ses_00000000000000a1"]?.ref, "S4")
        XCTAssertEqual(both["ses_00000000000000a1"]?.mark, .decision)
    }

    func testRequestBodiesMatchTheContract() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let add = String(decoding: try encoder.encode(LAAWorkRequirementAPI.Addition(title: "要件", details: nil)), as: UTF8.self)
        XCTAssertEqual(add, #"{"source":"owner","title":"要件"}"#)
        let withNote = String(decoding: try encoder.encode(LAAWorkRequirementAPI.Addition(title: "要件", details: "補足")), as: UTF8.self)
        XCTAssertEqual(withNote, #"{"details":"補足","source":"owner","title":"要件"}"#)
        let change = String(decoding: try encoder.encode(LAAWorkRequirementAPI.StatusChange(status: "completed")), as: UTF8.self)
        XCTAssertEqual(change, #"{"status":"completed"}"#)
        XCTAssertEqual(LAAWorkRequirementAPI.path("prj_000000000001"), "/v1/projects/prj_000000000001/requirements")
        XCTAssertEqual(LAAWorkRequirementAPI.path("prj_000000000001", "req_0123456789ab"),
                       "/v1/projects/prj_000000000001/requirements/req_0123456789ab")
        XCTAssertEqual(LAAWorkRequirementStatus.choices.map(\.rawValue),
                       ["in_progress", "awaiting_decision", "not_started", "completed"])
    }

    func testSnapshotRoundTripsAndComparesContentOnly() throws {
        let source = LAAWorkProjectFixtureView.projects[0]
        let first = LAAWorkProjectSnapshot(source, at: Date(timeIntervalSince1970: 1))
        let later = LAAWorkProjectSnapshot(source, at: Date(timeIntervalSince1970: 2))
        XCTAssertTrue(first.sameContent(as: later), "a re-read with the same rows is not rewritten")
        let data = try JSONEncoder().encode(first)
        XCTAssertEqual(try JSONDecoder().decode(LAAWorkProjectSnapshot.self, from: data), first)
        // A reading kept by an earlier build has no totals; it still opens.
        let kept = #"{"progressNote":null,"requirements":[],"sessions":[],"savedAt":0}"#
        XCTAssertNil(try JSONDecoder().decode(LAAWorkProjectSnapshot.self, from: Data(kept.utf8)).sessionCounts)
    }
}
#endif
