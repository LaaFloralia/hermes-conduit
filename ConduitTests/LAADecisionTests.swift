#if LAA_BUILD
import SwiftUI
import XCTest
@testable import Conduit

private final class DecisionAnswerProtocol: URLProtocol {
    nonisolated(unsafe) static var replies: [(Int, Data)] = []
    nonisolated(unsafe) static var paths: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.paths.append("\(request.httpMethod ?? "GET") \(request.url!.path)")
        let reply = Self.replies.isEmpty ? (503, Data()) : Self.replies.removeFirst()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil,
                                                              headerFields: ["Content-Type": "application/json"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.1); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// The decision board's client side: decoding the Bridge's two item kinds,
/// the order, the quiet meta line and the links.
@MainActor
final class LAADecisionTests: XCTestCase {
    private func page(_ json: String) throws -> LAADecisionPage {
        try JSONDecoder().decode(LAADecisionPage.self, from: Data(json.utf8))
    }

    /// An answer on its way is not something the owner has to do: it is not
    /// counted on the badge or the segment (2026-11-26).
    func testOnlyOpenQuestionsAndFailedDeliveriesNeedTheOwner() throws {
        func item(_ id: String, answered: Bool, delivery: String?) -> String {
            """
            { "kind": "board", "id": "\(id)", "ref": null, "status": "\(answered ? "answered" : "open")", "title": "t", "summary": "s",
              "options": [ { "label": "A", "detail": null, "recommended": true } ], "allowOther": false, "impact": null, "deadline": null,
              "source": null, "sourceRef": null, "createdAt": "2026-11-26T00:00:00Z",
              "answer": \(answered ? "{ \"optionIndex\": 0, \"label\": \"A\", \"note\": null, \"answeredAt\": \"2026-11-26T00:01:00Z\" }" : "null"),
              "delivery": \(delivery ?? "null") }
            """
        }
        let decoded = try page("""
        { "items": [
          \(item("dec_000000000000000a", answered: false, delivery: nil)),
          \(item("dec_000000000000000b", answered: true, delivery: #"{ "state": "pending", "attempts": 1, "deliveredAt": null, "error": null, "waiting": true }"#)),
          \(item("dec_000000000000000c", answered: true, delivery: #"{ "state": "failed", "attempts": 1, "deliveredAt": null, "error": "agent_archived" }"#)),
          \(item("dec_000000000000000d", answered: true, delivery: #"{ "state": "delivered", "attempts": 1, "deliveredAt": "2026-11-26T00:02:00Z", "error": null }"#)),
          \(item("dec_000000000000000e", answered: true, delivery: #"{ "state": "gone", "attempts": 1, "deliveredAt": null, "error": "agent_archived" }"#))
        ], "fetchedAt": "2026-11-26T00:03:00Z" }
        """)
        XCTAssertEqual(decoded.items.map(\.needsOwner), [true, false, true, false, false])
        let board = LAADecisionBoard()
        board.restoreIfNeeded(decoded.items)
        XCTAssertEqual(board.count, 2)
    }

    /// A notification's board link opens the board once; building Work again
    /// later does not replay it (2026-11-26).
    func testAWorkLinkIsClaimedOncePerOpen() throws {
        let link = LAAWorkLinkRequest()
        XCTAssertNil(link.claim("work.hub"))
        link.open(URL(string: "laa://work/decisions/dec_0123456789abcdef")!)
        XCTAssertEqual(link.claim("work.hub")?.absoluteString, "laa://work/decisions/dec_0123456789abcdef")
        XCTAssertNil(link.claim("work.hub"))
        XCTAssertNotNil(link.claim("other"))
        XCTAssertTrue(link.decisionsLink)
        link.open(URL(string: "laa://work/decisions")!)
        XCTAssertNotNil(link.claim("work.hub"))
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

    /// An asker that is gone (owner, 2026-11-14): the Bridge retires the
    /// answer, the row leaves the board and offers nothing to resend.
    func testAnswerWhoseAskerIsGoneLeavesTheBoard() async throws {
        let json = #"{"kind":"board","id":"dec_7eb15a42de31c331","status":"answered","title":"公開日を決める","summary":"","options":[{"label":"来週","recommended":true}],"source":{"paseoAgentId":"a","sessionId":null,"name":"HP｜公開"},"answer":{"optionIndex":0,"label":"来週","note":null,"answeredAt":"2026-11-14T05:30:00Z"},"delivery":{"state":"gone","attempts":1,"messageId":"dec_7eb15a42de31c331:answer:1","deliveredAt":null,"error":"not_found"}}"#
        let gone = try JSONDecoder().decode(LAADecision.self, from: Data(json.utf8))
        XCTAssertTrue(gone.isGone)
        XCTAssertFalse(gone.deliveryFailed)
        XCTAssertFalse(LAADecisionBoardView.needsAttention(gone))
        let open = LAADecision(id: "dec_0000000000000c01", title: "残る判断", summary: "",
                               options: [.init(label: "進める", recommended: true)])
        let board = LAADecisionBoard()
        board.setForTesting([gone, open])
        let outcome = await board.answer(gone, optionIndex: 0, note: nil,
                                         bridge: LAABridgeSession(statusForTesting: .unpaired))
        XCTAssertEqual(outcome, .gone(LAADecisionCopy.gone(gone)))
        XCTAssertEqual(board.items.map(\.id), [open.id])
        let withdrawn = LAADecision(id: "dec_0000000000000c02", status: "withdrawn", title: "取り下げ", summary: "")
        XCTAssertTrue(withdrawn.isGone)
        XCTAssertNotEqual(LAADecisionCopy.gone(withdrawn), LAADecisionCopy.gone(gone))
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


    // MARK: A refused answer (owner, 2026-11-23)

    private func error(_ status: Int, _ code: String?, _ message: String?) -> LAABridgeHTTPError {
        LAABridgeHTTPError(status: status, code: code, message: message, retryable: false,
                           details: nil, requestId: nil, currentETag: nil)
    }

    /// A 1,000-character answer read as "Macからデータを取得できませんでした":
    /// a refusal says what is wrong with the answer, never the connection.
    func testARefusedAnswerSaysWhyNotThatTheMacIsUnreachable() {
        let connection = LAAWorkHTTP.message(error(400, "decision_invalid", "note must be at most 600 characters"))
        XCTAssertEqual(LAADecisionCopy.answerError(error(400, "decision_note_too_long", "回答は8000文字以内で入力してください。")),
                       "回答は8000文字以内で入力してください。")
        XCTAssertEqual(LAADecisionCopy.answerError(error(400, "decision_note_too_long", nil)), "回答は8000文字以内で入力してください。")
        XCTAssertEqual(LAADecisionCopy.answerError(error(400, "decision_invalid", "回答に使用できない制御文字があります。")),
                       "回答に使用できない制御文字があります。")
        let older = LAADecisionCopy.answerError(error(400, "decision_invalid", "note must be at most 600 characters"))
        XCTAssertEqual(older, "回答が長すぎるか、使えない文字が含まれています。短くしてから送ってください。")
        XCTAssertNotEqual(older, connection)
        XCTAssertEqual(LAADecisionCopy.answerError(error(422, "payload_invalid", "bad body")),
                       "回答を受け付けられませんでした。内容を確認して送り直してください。")
        XCTAssertEqual(LAADecisionCopy.answerError(error(409, "decision_closed", nil)), "この判断はすでに回答済みか、取り下げられています。")
        XCTAssertEqual(LAADecisionCopy.answerError(error(503, "unavailable", nil)), LAAWorkHTTP.message(error(503, "unavailable", nil)))
    }

    /// The field takes what the Bridge takes (8000 code points) and counts
    /// only near the end.
    func testTheFreeAnswerCountsOnlyNearTheLimit() {
        XCTAssertNil(LAADecisionCopy.noteCount(String(repeating: "あ", count: 1000)))
        XCTAssertNil(LAADecisionCopy.noteCount(String(repeating: "あ", count: 7599)))
        XCTAssertEqual(LAADecisionCopy.noteCount(String(repeating: "あ", count: 7600))?.text, "残り400字")
        XCTAssertEqual(LAADecisionCopy.noteCount(String(repeating: "あ", count: 8000))?.over, false)
        let over = LAADecisionCopy.noteCount(String(repeating: "あ", count: 8010))
        XCTAssertEqual(over?.text, "10字多すぎます（8000字まで）")
        XCTAssertEqual(over?.over, true)
        XCTAssertEqual(LAADecisionCopy.noteLength("👍🏽"), 2, "counted as the Bridge counts: code points")
    }

    /// The typed answer survives a refused send: the board keeps it, the
    /// reopened detail finds it, and nothing reads as a connection failure.
    func testARefusedSendKeepsTheDraft() async throws {
        DecisionAnswerProtocol.paths = []
        DecisionAnswerProtocol.replies = [
            (400, Data(#"{"error":{"code":"decision_note_too_long","message":"回答は8000文字以内で入力してください。","retryable":false},"requestId":"req_1"}"#.utf8)),
            (200, Data(#"{"data":{"kind":"board","id":"dec_0000000000000d01","status":"open","title":"公開日を決める","summary":"","options":[{"label":"来週","recommended":true}],"answer":null},"requestId":"req_2"}"#.utf8)),
        ]
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DecisionAnswerProtocol.self]
        let credentials = LAABridgeCredentials(baseURL: URL(string: "http://127.0.0.1:9")!, deviceID: UUID().uuidString, token: "fixture")
        let bridge = LAABridgeSession(client: LAABridgeClient(session: URLSession(configuration: config)),
                                      readCredentials: { credentials })
        let item = LAADecision(id: "dec_0000000000000d01", title: "公開日を決める", summary: "",
                               options: [.init(label: "来週", recommended: true)])
        let board = LAADecisionBoard()
        board.setForTesting([item])
        let long = String(repeating: "長い回答。", count: 200)
        let outcome = await board.answer(item, optionIndex: nil, note: long, bridge: bridge)
        XCTAssertEqual(outcome, .failed("回答は8000文字以内で入力してください。"))
        XCTAssertEqual(DecisionAnswerProtocol.paths.first, "POST /v1/decisions/dec_0000000000000d01/answer")
        XCTAssertEqual(board.noteDrafts[item.id], long, "the answer stays to send again")
        XCTAssertNil(board.records[item.id]?.answer)
    }
}
#endif
