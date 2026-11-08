#if LAA_BUILD
import SwiftUI
import XCTest
@testable import Conduit

/// The decision board's client side: decoding the Bridge's two item kinds,
/// the order, the quiet meta line and the links.
@MainActor
final class LAADecisionTests: XCTestCase {
    private func page(_ json: String) throws -> LAADecisionPage {
        try JSONDecoder().decode(LAADecisionPage.self, from: Data(json.utf8))
    }

    func testDecodesBoardAndSessionItemsWithNullRefs() throws {
        let decoded = try page("""
        { "items": [
          { "kind": "board", "id": "dec_0123456789abcdef", "ref": null, "status": "open",
            "title": "HPの公開日を決める", "summary": "公開できる状態です。",
            "options": [ { "label": "延期", "detail": null, "recommended": false },
                         { "label": "15日に公開", "detail": "準備は完了", "recommended": true } ],
            "allowOther": true, "impact": null, "deadline": "2026-11-08T12:00:00Z",
            "source": { "paseoAgentId": "a1", "sessionId": null, "name": "HP｜公開準備" }, "sourceRef": null,
            "createdAt": "2026-11-08T00:00:00Z", "updatedAt": "2026-11-08T00:00:00Z", "answer": null, "delivery": null },
          { "kind": "session", "sessionId": "ses_2222222222222222", "ref": null, "title": "判断待ち",
            "summary": "どちらにしますか？", "kinds": ["question"], "createdAt": "2026-11-07T00:00:00Z", "deadline": null },
          { "kind": "board", "id": "dec_00000000000000ff", "title": "未来の項目", "summary": "", "unknownField": 1 }
        ], "fetchedAt": "2026-11-08T00:00:00Z" }
        """)
        XCTAssertEqual(decoded.items.count, 3)
        let board = decoded.items[0]
        XCTAssertEqual(board.kind, .board)
        // Stored recommended-first; the client keeps that order even if not.
        XCTAssertEqual(board.options.map(\.label), ["15日に公開", "延期"])
        XCTAssertEqual(board.recommended?.label, "15日に公開")
        XCTAssertNil(board.ref)
        XCTAssertEqual(board.sourceLine, "HP｜公開準備")
        let session = decoded.items[1]
        XCTAssertEqual(session.kind, .session)
        XCTAssertEqual(session.id, "ses_2222222222222222")
        XCTAssertEqual(session.sessionId, "ses_2222222222222222")
        XCTAssertNil(session.sourceLine)
        XCTAssertTrue(decoded.items[2].options.isEmpty)
        XCTAssertTrue(decoded.items[2].allowOther)
    }

    func testSourceLineUsesRefWhenTheBridgeAssignsOne() {
        let item = LAADecision(id: "dec_1", title: "t", summary: "s",
                               source: .init(paseoAgentId: nil, sessionId: nil, name: "会話"), sourceRef: "S5")
        XCTAssertEqual(item.sourceLine, "S5 · 会話")
        let session = LAADecision(kind: .session, id: "ses_1", ref: "S7", title: "名前", summary: "", sessionId: "ses_1")
        XCTAssertEqual(session.sourceLine, "S7")
    }

    func testOrderFailedFirstThenDeadlineThenNewest() {
        let failed = LAADecision(id: "failed", status: "answered", title: "f", summary: "",
                                 createdAt: "2026-11-01T00:00:00Z",
                                 delivery: .init(state: "failed", attempts: 1, deliveredAt: nil, error: "agent_archived"))
        let soon = LAADecision(id: "soon", title: "s", summary: "", deadline: "2026-11-08T03:00:00Z", createdAt: "2026-11-01T00:00:00Z")
        let later = LAADecision(id: "later", title: "l", summary: "", deadline: "2026-11-10T00:00:00Z", createdAt: "2026-11-07T00:00:00Z")
        let newest = LAADecision(id: "newest", title: "n", summary: "", createdAt: "2026-11-08T00:00:00Z")
        let older = LAADecision(id: "older", title: "o", summary: "", createdAt: "2026-11-02T00:00:00Z")
        let sorted = LAADecisionOrder.sorted([older, newest, later, soon, failed])
        XCTAssertEqual(sorted.map(\.id), ["failed", "soon", "later", "newest", "older"])
    }

    func testDeadlineIsRelativeAndUrgentWithinADay() throws {
        let now = try XCTUnwrap(LAAWorkFreshness.date("2026-11-08T00:00:00Z"))
        XCTAssertEqual(LAADecisionDeadline.describe("2026-11-08T00:30:00Z", now: now)?.text, "あと30分")
        XCTAssertEqual(LAADecisionDeadline.describe("2026-11-08T05:00:00Z", now: now)?.urgent, true)
        XCTAssertEqual(LAADecisionDeadline.describe("2026-11-08T05:00:00Z", now: now)?.text, "あと5時間")
        XCTAssertEqual(LAADecisionDeadline.describe("2026-11-10T00:00:00Z", now: now)?.text, "あと2日")
        XCTAssertEqual(LAADecisionDeadline.describe("2026-11-10T00:00:00Z", now: now)?.urgent, false)
        XCTAssertEqual(LAADecisionDeadline.describe("2026-11-07T00:00:00Z", now: now)?.text, "期限を過ぎています")
        XCTAssertEqual(LAADecisionDeadline.describe("2026-11-07T00:00:00Z", now: now)?.urgent, true)
        XCTAssertNil(LAADecisionDeadline.describe(nil, now: now))
        XCTAssertNil(LAADecisionDeadline.describe("not a date", now: now))
    }

    func testMetaLineAndVoiceOverLabel() throws {
        let now = try XCTUnwrap(LAAWorkFreshness.date("2026-11-08T00:00:00Z"))
        let item = LAADecision(id: "dec_1", title: "HPの公開日を決める", summary: "",
                               options: [.init(label: "15日に公開", recommended: true), .init(label: "延期")],
                               deadline: "2026-11-08T05:00:00Z",
                               source: .init(paseoAgentId: "a", sessionId: nil, name: "HP｜公開準備"))
        let meta = try XCTUnwrap(LAADecisionBoardView.meta(item, now: now))
        XCTAssertEqual(String(meta.characters), "HP｜公開準備 · あと5時間 · 推奨 15日に公開")
        XCTAssertEqual(LAADecisionCopy.accessibilityLabel(item, now: now),
                       "判断、HPの公開日を決める、推奨 15日に公開、あと5時間、HP｜公開準備")
        // An answer that did not arrive shows the choice instead of the advice.
        let failed = LAADecision(id: "dec_2", status: "answered", title: "週報の送り先を決める", summary: "",
                                 options: [.init(label: "Driveに保存", recommended: true)],
                                 source: .init(paseoAgentId: "a", sessionId: nil, name: "週報｜作成"),
                                 answer: .init(optionIndex: 0, label: "Driveに保存", note: nil, answeredAt: nil),
                                 delivery: .init(state: "failed", attempts: 1, deliveredAt: nil, error: "agent_archived"))
        XCTAssertEqual(String(try XCTUnwrap(LAADecisionBoardView.meta(failed, now: now)).characters), "週報｜作成 · 回答 Driveに保存")
        XCTAssertEqual(LAADecisionCopy.accessibilityLabel(failed, now: now), "判断、週報の送り先を決める、回答 Driveに保存、届いていません、週報｜作成")
        // With numbers: the decision's J leads VoiceOver, the source's S leads the source line.
        let numbered = LAADecision(id: "dec_3", ref: "J3", title: "名刺の紙を選ぶ", summary: "",
                                   options: [.init(label: "マットな白", recommended: true)],
                                   source: .init(paseoAgentId: "a", sessionId: "ses_0000000000000001", name: "Studio｜名刺"), sourceRef: "S5")
        XCTAssertEqual(String(try XCTUnwrap(LAADecisionBoardView.meta(numbered, now: now)).characters), "S5 · Studio｜名刺 · 推奨 マットな白")
        XCTAssertEqual(LAADecisionCopy.accessibilityLabel(numbered, now: now), "判断、J3、名刺の紙を選ぶ、推奨 マットな白、S5 · Studio｜名刺")
        // A bare record still reads: no empty separators.
        XCTAssertNil(LAADecisionBoardView.meta(LAADecision(id: "x", title: "t", summary: ""), now: now))
    }

    func testDeliveryErrorsReadAsSentences() {
        for code in ["agent_archived", "pending_decision_requires_reply", "paseo_unavailable", "delivery_unconfirmed", "not_found", nil, "new_code"] {
            XCTAssertFalse(LAADecisionCopy.deliveryError(code).isEmpty)
        }
        let closed = LAABridgeHTTPError(status: 409, code: "decision_closed", message: nil, retryable: false,
                                        details: nil, requestId: nil, currentETag: nil)
        XCTAssertEqual(LAADecisionCopy.answerError(closed), "この判断はすでに回答済みか、取り下げられています。")
    }

    func testDecisionLinks() throws {
        let route = LAAWorkLinkRequest()
        XCTAssertTrue(route.open(try XCTUnwrap(URL(string: "laa://work/decisions"))))
        XCTAssertTrue(route.decisionsLink)
        XCTAssertNil(route.decisionTarget)
        XCTAssertNil(route.sessionTarget)
        XCTAssertTrue(route.open(try XCTUnwrap(URL(string: "laa://work/decisions/dec_0123456789abcdef"))))
        XCTAssertTrue(route.decisionsLink)
        XCTAssertEqual(route.decisionTarget, "dec_0123456789abcdef")
        XCTAssertTrue(route.open(try XCTUnwrap(URL(string: "laa://work/decisions/../etc"))))
        XCTAssertNil(route.decisionTarget)
        XCTAssertTrue(route.open(try XCTUnwrap(URL(string: "laa://work/sessions/ses_0123456789abcdef"))))
        XCTAssertFalse(route.decisionsLink)
    }

    func testBoardStateTreatsAnOlderBridgeAsUnsupported() async {
        let board = LAADecisionBoard()
        board.setForTesting([], phase: .unsupported)
        XCTAssertEqual(board.phase, .unsupported)
        XCTAssertEqual(board.count, 0)
        board.setForTesting([LAADecision(id: "a", title: "t", summary: "")])
        XCTAssertEqual(board.count, 1)
        board.remove("a")
        XCTAssertEqual(board.count, 0)
        // Unpaired: nothing is read and nothing is chosen for the hub.
        let unpaired = LAABridgeSession(statusForTesting: .unpaired)
        let chose = await board.loadForDefaultSection(unpaired)
        XCTAssertFalse(chose)
        XCTAssertEqual(board.phase, .idle)
    }
}
#endif
