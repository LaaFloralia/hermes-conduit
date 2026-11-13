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
        XCTAssertEqual(board.sourceLine, "HP · 公開準備")
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
        XCTAssertEqual(String(meta.characters), "HP · 公開準備 · あと5時間 · 推奨 15日に公開")
        XCTAssertEqual(LAADecisionCopy.accessibilityLabel(item, now: now),
                       "判断、HPの公開日を決める、推奨 15日に公開、あと5時間、HP · 公開準備")
        // An answer that did not arrive shows the choice instead of the advice.
        let failed = LAADecision(id: "dec_2", status: "answered", title: "週報の送り先を決める", summary: "",
                                 options: [.init(label: "Driveに保存", recommended: true)],
                                 source: .init(paseoAgentId: "a", sessionId: nil, name: "週報｜作成"),
                                 answer: .init(optionIndex: 0, label: "Driveに保存", note: nil, answeredAt: nil),
                                 delivery: .init(state: "failed", attempts: 1, deliveredAt: nil, error: "agent_archived"))
        XCTAssertEqual(String(try XCTUnwrap(LAADecisionBoardView.meta(failed, now: now)).characters), "週報 · 作成 · 回答 Driveに保存")
        XCTAssertEqual(LAADecisionCopy.accessibilityLabel(failed, now: now), "判断、週報の送り先を決める、回答 Driveに保存、届いていません、週報 · 作成")
        // With numbers: the decision's J leads VoiceOver, the source's S leads the source line.
        let numbered = LAADecision(id: "dec_3", ref: "J3", title: "名刺の紙を選ぶ", summary: "",
                                   options: [.init(label: "マットな白", recommended: true)],
                                   source: .init(paseoAgentId: "a", sessionId: "ses_0000000000000001", name: "Studio｜名刺"), sourceRef: "S5")
        XCTAssertEqual(String(try XCTUnwrap(LAADecisionBoardView.meta(numbered, now: now)).characters), "S5 · Studio · 名刺 · 推奨 マットな白")
        XCTAssertEqual(LAADecisionCopy.accessibilityLabel(numbered, now: now), "判断、J3、名刺の紙を選ぶ、推奨 マットな白、S5 · Studio · 名刺")
        // A bare record still reads: no empty separators.
        XCTAssertNil(LAADecisionBoardView.meta(LAADecision(id: "x", title: "t", summary: ""), now: now))
    }

    /// A busy conversation holds the answer; the board says the Bridge will
    /// deliver it and offers nothing to resend (2026-11-13).
    func testHeldAnswerReadsAsWaitingNotAsFailure() throws {
        let json = #"{"kind":"board","id":"dec_9","status":"answered","title":"公開日を決める","summary":"","options":[{"label":"来週","recommended":true}],"source":{"paseoAgentId":"a","sessionId":null,"name":"HP｜公開"},"answer":{"optionIndex":0,"label":"来週","note":null,"answeredAt":"2026-11-13T11:00:00Z"},"delivery":{"state":"pending","attempts":1,"messageId":"dec_9:answer:1","deliveredAt":null,"error":null,"waiting":true,"waitingSince":"2026-11-13T11:00:00Z","holds":1}}"#
        let held = try JSONDecoder().decode(LAADecision.self, from: Data(json.utf8))
        XCTAssertTrue(held.deliveryWaiting)
        XCTAssertFalse(held.deliveryFailed)
        XCTAssertFalse(LAADecisionBoardView.needsAttention(held))
        XCTAssertEqual(LAADecisionCopy.pending(held), LAADecisionCopy.waitingDetail)
        let line = String(LAADecisionBoardView.answeredLine(held, answer: try XCTUnwrap(held.answer)).characters)
        XCTAssertTrue(line.hasSuffix(LAADecisionCopy.waiting), line)
        XCTAssertFalse(line.contains(LAADecisionCopy.replied))
        XCTAssertTrue(LAADecisionCopy.accessibilityLabel(held).contains(LAADecisionCopy.waiting))
        XCTAssertFalse(LAADecisionCopy.accessibilityLabel(held).contains(LAADecisionCopy.notDelivered))
        // An interrupted send keeps the older wording; a delivery an older Bridge wrote has no flag.
        let plain = LAADecision(id: "dec_8", title: "t", summary: "", delivery: .init(state: "pending", attempts: 1, deliveredAt: nil, error: nil))
        XCTAssertFalse(plain.deliveryWaiting)
        XCTAssertEqual(LAADecisionCopy.pending(plain), LAADecisionCopy.pendingDetail)
    }

    func testDeliveryErrorsReadAsSentences() {
        for code in ["agent_archived", "pending_decision_requires_reply", "paseo_unavailable", "delivery_unconfirmed", "not_found", "delivery_wait_expired", nil, "new_code"] {
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

    /// The free answer is an answer, not a supplement: optionIndex stays on
    /// the wire as null and the words travel in note. Choosing an option may
    /// still add a note beside it.
    func testFreeAnswerKeepsOptionIndexNullAndCarriesTheNote() throws {
        let free = try JSONEncoder().encode(LAADecisionBoard.answerBody(
            optionIndex: nil, note: "  制作を優先し、公開は11月28日にします。 ", requestId: "req-1"))
        let fields = try XCTUnwrap(try JSONSerialization.jsonObject(with: free) as? [String: Any])
        XCTAssertTrue(fields["optionIndex"] is NSNull)
        XCTAssertEqual(fields["note"] as? String, "制作を優先し、公開は11月28日にします。")
        XCTAssertEqual(fields["requestId"] as? String, "req-1")

        let chosen = try JSONEncoder().encode(LAADecisionBoard.answerBody(
            optionIndex: 1, note: "  ", requestId: "req-2"))
        let chosenFields = try XCTUnwrap(try JSONSerialization.jsonObject(with: chosen) as? [String: Any])
        XCTAssertEqual(chosenFields["optionIndex"] as? Int, 1)
        XCTAssertTrue(chosenFields["note"] is NSNull)
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
    func testKnownDeliveredAnswerCannotBeSentAgainFromStaleCard() async {
        let old = LAADecision(id: "dec_0000000000000b04", title: "試験用の判断", summary: "",
                              options: [.init(label: "作業を進める", recommended: true)])
        let delivered = LAADecision(id: old.id, status: "answered", title: old.title, summary: old.summary,
                                    options: old.options,
                                    answer: .init(optionIndex: 0, label: "作業を進める", note: nil,
                                                  answeredAt: "2026-11-13T03:57:56.476Z"),
                                    delivery: .init(state: "delivered", attempts: 3,
                                                    deliveredAt: "2026-11-13T04:02:28.067Z", error: nil))
        let board = LAADecisionBoard()
        board.setForTesting([delivered])
        // No connection exists: the result can only come from the known saved
        // record, never a second write of the old option card.
        let outcome = await board.answer(old, optionIndex: 0, note: nil,
                                         bridge: LAABridgeSession(statusForTesting: .unpaired))
        XCTAssertEqual(outcome, .done(stored: false))
        XCTAssertEqual(board.records[old.id]?.delivery?.attempts, 3)
        XCTAssertEqual(board.records[old.id]?.answer, delivered.answer)
    }

    func testBoardCacheRetainsNativeQuestionsAndFailedDelivery() throws {
        let values = [
            LAADecision(kind: .session, id: "ses_native", title: "判断", summary: "どちら", sessionId: "ses_native"),
            LAADecision(id: "dec_failed", title: "保存先", summary: "", options: [.init(label: "Drive", recommended: true)],
                        answer: .init(optionIndex: 0, label: "Drive", note: nil, answeredAt: nil),
                        delivery: .init(state: "failed", attempts: 1, deliveredAt: nil, error: "not_found"))
        ]
        let restored = try JSONDecoder().decode([LAADecision].self, from: JSONEncoder().encode(values))
        XCTAssertEqual(restored, values)
        let board = LAADecisionBoard(); board.restoreIfNeeded(restored)
        XCTAssertEqual(board.items.map(\.id), ["dec_failed", "ses_native"])
        board.reset()
        XCTAssertTrue(board.items.isEmpty)
        XCTAssertEqual(board.phase, .idle)
    }

}
#endif
