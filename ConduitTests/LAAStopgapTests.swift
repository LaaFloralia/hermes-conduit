#if LAA_BUILD
import SwiftUI
import XCTest
@testable import Conduit

/// The 2026-11-23 stopgap: answered decisions leave the board, Return sends
/// from Work's field, and the Session lists tell running from waiting.
@MainActor
final class LAAStopgapTests: XCTestCase {
    private func decision(_ id: String, answered: Bool = false) -> LAADecision {
        LAADecision(id: id, title: "判断 \(id)", summary: "",
                    answer: answered ? .init(optionIndex: 0, label: "A", note: nil, answeredAt: "2026-11-23T10:00:00Z") : nil,
                    delivery: answered ? .init(state: "delivered", attempts: 1, deliveredAt: nil, error: nil) : nil)
    }

    private func session(_ id: String, phase: String, archived: Bool = false, pending: Bool = false) throws -> LAAWorkSession {
        var json: [String: Any] = [
            "id": id, "name": id, "nameSource": "owner", "requestId": id, "parentId": NSNull(), "workspaceId": "ws_test",
            "profile": "test", "requested": [:] as [String: String], "observed": NSNull(),
            "phase": phase, "createdAt": "2026-11-23T10:00:00Z", "updatedAt": "2026-11-23T10:00:00Z",
            "events": ["lastSeq": 1, "oldestSeq": 1, "cursor": "cursor"]
        ]
        if archived { json["archivedAt"] = "2026-11-23T11:00:00Z" }
        if pending { json["pending"] = ["count": 1, "kinds": ["question"]] }
        return try JSONDecoder().decode(LAAWorkSession.self, from: JSONSerialization.data(withJSONObject: json))
    }

    // MARK: 1. Decision board

    func testAnEmptyReadEmptiesTheBoardAndItsCount() {
        let board = LAADecisionBoard()
        board.setForTesting([decision("dec_0000000000000001"), decision("dec_0000000000000002")])
        XCTAssertEqual(board.count, 2)
        board.finishLoadForTesting([])
        XCTAssertEqual(board.count, 0)
        XCTAssertEqual(board.phase, .loaded)
    }

    func testAReadThatCrossedTheAnswerDoesNotBringTheRowBack() {
        let board = LAADecisionBoard()
        board.setForTesting([decision("dec_0000000000000001")])
        board.noteAnsweredForTesting("dec_0000000000000001")
        // The poll started before the answer still lists it as open.
        board.finishLoadForTesting([decision("dec_0000000000000001"), decision("dec_0000000000000002")])
        XCTAssertEqual(board.items.map(\.id), ["dec_0000000000000002"])
    }

    func testAFailedDeliveryStaysOnTheBoardAfterAnAnswer() {
        let failed = LAADecision(id: "dec_0000000000000001", title: "判断", summary: "",
                                 answer: .init(optionIndex: 0, label: "A", note: nil, answeredAt: nil),
                                 delivery: .init(state: "failed", attempts: 1, deliveredAt: nil, error: "session_busy"))
        XCTAssertEqual(LAADecisionBoard.visible([failed], answeredHere: [failed.id]).map(\.id), [failed.id])
    }

    func testAnsweredRowsLeaveOnceALaterReadComesBack() {
        let answered = [decision("dec_0000000000000001", answered: true), decision("dec_0000000000000002", answered: true)]
        let marks = ["dec_0000000000000001": 3, "dec_0000000000000002": 5]
        // Read 4 began after the first answer and before the second.
        let kept = LAADecisionBoardView.keptAnswered(answered, marks: marks, linkedOnly: [], selectedID: nil,
                                                     boardIDs: [], lastLoadStart: 4)
        XCTAssertEqual(kept.map(\.id), ["dec_0000000000000002"])
        // A later read empties 回答済み, so the board can say it is empty.
        XCTAssertTrue(LAADecisionBoardView.keptAnswered(answered, marks: marks, linkedOnly: [], selectedID: nil,
                                                        boardIDs: [], lastLoadStart: 6).isEmpty)
    }

    func testARecordOpenedFromALinkStaysWhileItIsShown() {
        let linked = [decision("dec_0000000000000001", answered: true)]
        let marks = ["dec_0000000000000001": 1]
        XCTAssertEqual(LAADecisionBoardView.keptAnswered(linked, marks: marks, linkedOnly: ["dec_0000000000000001"],
                                                         selectedID: "dec_0000000000000001", boardIDs: [], lastLoadStart: 9).count, 1)
        XCTAssertTrue(LAADecisionBoardView.keptAnswered(linked, marks: marks, linkedOnly: ["dec_0000000000000001"],
                                                        selectedID: nil, boardIDs: [], lastLoadStart: 9).isEmpty)
    }

    // MARK: 2. Return sends

    func testReturnSendsByDefaultInLAA() {
        XCTAssertTrue(ComposerReturnKey.sendsByDefault(onMac: false))
        XCTAssertTrue(ComposerReturnKey.sendsByDefault(onMac: true))
    }

    func testWorkFieldReturnSendsShiftReturnAndIMEConfirmKeepTheText() {
        let view = ImagePasteTextView()
        var sent = 0
        view.returnKeySends = true
        view.canSubmitFromReturn = true
        view.onSubmitFromReturn = { sent += 1; return true }
        XCTAssertFalse(view.handleReturnKeyPress(shiftPressed: false, hasMarkedText: true), "変換確定のReturnは送らない")
        XCTAssertFalse(view.returnKeyCommandApplies(hasMarkedText: true))
        XCTAssertFalse(view.handleReturnKeyPress(shiftPressed: true, hasMarkedText: false), "Shift+Returnは改行")
        XCTAssertEqual(sent, 0)
        XCTAssertTrue(view.handleReturnKeyPress(shiftPressed: false, hasMarkedText: false))
        XCTAssertEqual(sent, 1)
        view.canSubmitFromReturn = false
        XCTAssertFalse(view.handleReturnKeyPress(shiftPressed: false, hasMarkedText: false), "空の欄は改行のまま")
        XCTAssertEqual(sent, 1)
    }

    func testShiftReturnIsTheViewsOwnNewlineOnlyWhileTheShortcutIsOn() {
        let view = ImagePasteTextView()
        view.onSubmitFromReturn = { true }
        view.returnKeySends = false
        XCTAssertFalse(view.shiftReturnInsertsNewline(hasMarkedText: false), "off: the text system keeps it")
        view.returnKeySends = true
        XCTAssertTrue(view.shiftReturnInsertsNewline(hasMarkedText: false))
        XCTAssertFalse(view.shiftReturnInsertsNewline(hasMarkedText: true), "the IME keeps its Shift-Return")
        XCTAssertTrue(view.keyCommands?.contains { $0.input == "\r" && $0.modifierFlags == .shift } == true)
        XCTAssertEqual(view.keyCommands?.first { $0.input == "\r" }?.modifierFlags, [])
        view.text = "一行目"
        view.shiftReturnKeyCommandPressed()
        XCTAssertEqual(view.text, "一行目\n")
    }

    // MARK: 3. Running and waiting Sessions (BUS-508)

    func testTallyCountsOnlyRunningSessionsAsRunning() throws {
        let rows = [try session("ses_1", phase: "running"), try session("ses_2", phase: "created"),
                    try session("ses_3", phase: "awaiting_review"), try session("ses_4", phase: "awaiting_review"),
                    try session("ses_5", phase: "idle"), try session("ses_6", phase: "awaiting_review", pending: true),
                    try session("ses_7", phase: "closed"), try session("ses_8", phase: "running", archived: true)]
        let tally = LAAWorkSessionTally(sessions: rows)
        XCTAssertEqual(tally, LAAWorkSessionTally(running: 2, decision: 1, waiting: 3))
        XCTAssertEqual(tally.accessibilityText, "実行中 2件、判断待ち 1件、待機 3件")
    }

    func testSevenWaitingSessionsSayNothingIsRunning() {
        let tally = LAAWorkSessionTally(counts: .init(active: 7, archived: 0, running: 0, awaitingDecision: 0, waiting: 7), compact: nil)
        XCTAssertEqual(tally.parts.map(\.label), ["実行中", "待機"])
        XCTAssertEqual(tally.accessibilityText, "実行中 0件、待機 7件")
    }

    func testAnOlderBridgeFallsBackToTheCompactRows() throws {
        let counts = try JSONDecoder().decode(LAAWorkSessionCounts.self, from: Data(#"{"active":3,"archived":1}"#.utf8))
        XCTAssertNil(counts.running)
        let compact = ["running", "waiting", "awaiting_decision"].enumerated().map {
            LAAWorkProjectSession(id: "ses_\($0.offset)", name: "s", status: $0.element, model: nil, updatedAt: nil, parentId: nil, archivedAt: nil)
        }
        XCTAssertEqual(LAAWorkSessionTally(counts: counts, compact: compact), LAAWorkSessionTally(running: 1, decision: 1, waiting: 1))
    }

    func testBridgeBreakdownDecodes() throws {
        let counts = try JSONDecoder().decode(LAAWorkSessionCounts.self, from: Data(
            #"{"active":7,"archived":1,"running":2,"awaitingDecision":1,"waiting":3}"#.utf8))
        XCTAssertEqual(LAAWorkSessionTally(counts: counts, compact: []), LAAWorkSessionTally(running: 2, decision: 1, waiting: 3))
    }
}
#endif
