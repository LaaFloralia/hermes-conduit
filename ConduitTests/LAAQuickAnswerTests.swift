#if LAA_BUILD
import UserNotifications
import XCTest
@testable import Conduit

/// Answering a Bridge notification from its buttons (iPhone, Mac, Apple
/// Watch): what the notification says about itself, the buttons it gets, and
/// the protections on the way to the Bridge — the same question id, one
/// answer per notification, nothing after the deadline, and an answer kept
/// while the Mac is out of reach.
@MainActor
final class LAAQuickAnswerTests: XCTestCase {
    private let decision = "dec_0123456789abcdef"
    private let pendingHash = String(repeating: "ab", count: 32)

    private func sessionID(_ link: String, _ meta: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "laa-bridge:\(link)#\(encoded)"
    }

    private func boardMeta(deadline: Date? = nil, options: [String] = ["15日に公開", "延期"]) -> LAANotificationMeta {
        var meta: [String: Any] = ["v": 1, "k": "decision.new", "id": decision, "o": options]
        if let deadline { meta["d"] = Int(deadline.timeIntervalSince1970) }
        return LAANotificationMeta.parse(sessionID("laa://work/decisions/\(decision)", meta))!
    }

    // MARK: What the notification says

    func testParsesABoardDecisionWithItsOptionsAndDeadline() {
        let meta = boardMeta(deadline: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(meta.kind, "decision.new")
        XCTAssertEqual(meta.link, "laa://work/decisions/\(decision)")
        XCTAssertEqual(meta.deadline, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(meta.quick, .board(id: decision, options: ["15日に公開", "延期"]))
        XCTAssertFalse(meta.quiet)
    }

    func testParsesAQuestionAndAnApprovalBoundToTheirPendingHash() {
        let question = LAANotificationMeta.parse(sessionID("laa://work/sessions/ses_1", [
            "v": 1, "k": "session.question", "sid": "ses_1", "h": pendingHash, "o": ["はい", "いいえ"]]))
        XCTAssertEqual(question?.quick, .question(sessionID: "ses_1", requestHash: pendingHash, options: ["はい", "いいえ"]))
        let approval = LAANotificationMeta.parse(sessionID("laa://work/sessions/ses_1", [
            "v": 1, "k": "session.approval", "sid": "ses_1", "h": pendingHash, "a": 1]))
        XCTAssertEqual(approval?.quick, .approval(sessionID: "ses_1", requestHash: pendingHash))
    }

    func testAnIdThatIsNotTheLinkedOneGivesNoAnswer() {
        // The buttons answer the decision the notification opens, no other.
        let other = LAANotificationMeta.parse(sessionID("laa://work/decisions/dec_ffffffffffffffff", [
            "v": 1, "k": "decision.new", "id": decision, "o": ["A", "B"]]))
        XCTAssertNotNil(other)
        XCTAssertNil(other?.quick)
        let session = LAANotificationMeta.parse(sessionID("laa://work/sessions/ses_2", [
            "v": 1, "k": "session.approval", "sid": "ses_1", "h": pendingHash, "a": 1]))
        XCTAssertNil(session?.quick)
    }

    func testMetadataThatCannotBeAnsweredStillSaysItsKindAndLevel() {
        let finished = LAANotificationMeta.parse(sessionID("laa://work/sessions/ses_1", ["v": 1, "k": "session.finished", "sid": "ses_1", "lv": "p"]))
        XCTAssertEqual(finished?.kind, "session.finished")
        XCTAssertEqual(finished?.quiet, true)
        XCTAssertNil(finished?.quick)
        // One option, a short pendingHash, a session without the hash: no buttons.
        XCTAssertNil(boardMetaOrNil(options: ["A"])?.quick)
        XCTAssertNil(LAANotificationMeta.parse(sessionID("laa://work/sessions/ses_1", [
            "v": 1, "k": "session.question", "sid": "ses_1", "h": "abc", "o": ["A", "B"]]))?.quick)
        XCTAssertNil(LAANotificationMeta.parse(sessionID("laa://work/sessions/ses_1", [
            "v": 1, "k": "session.approval", "sid": "ses_1", "h": pendingHash]))?.quick)
    }

    private func boardMetaOrNil(options: [String]) -> LAANotificationMeta? {
        LAANotificationMeta.parse(sessionID("laa://work/decisions/\(decision)", ["v": 1, "k": "decision.new", "id": decision, "o": options]))
    }

    func testAnOlderNotificationAndAForeignOneAreNotRead() {
        XCTAssertNil(LAANotificationMeta.parse("laa-bridge:laa://work/decisions/\(decision)"))
        XCTAssertNil(LAANotificationMeta.parse("laa-bridge:laa://work/decisions/\(decision)#not-base64!"))
        XCTAssertNil(LAANotificationMeta.parse("20261114_120000_abcdef"))
        XCTAssertNil(LAANotificationMeta.parse(nil))
        XCTAssertNil(LAANotificationMeta.parse(sessionID("https://example.com/x", ["v": 1, "k": "decision.new"])))
        XCTAssertNil(LAANotificationMeta.parse(sessionID("laa://work/decisions/\(decision)", ["v": 2, "k": "decision.new"])))
    }

    func testTheLinkStillOpensWithTheMetadataAttached() {
        // The app built before this change opens the same link: the metadata
        // is a fragment, which the link parser never reads.
        let url = URL(string: String(sessionID("laa://work/decisions/\(decision)", ["v": 1, "k": "decision.new"]).dropFirst("laa-bridge:".count)))
        XCTAssertEqual(url?.host, "work")
        XCTAssertEqual(url?.pathComponents, ["/", "decisions", decision])
    }

    // MARK: The buttons

    func testOptionsBecomeButtonsThatNeedTheDeviceUnlocked() {
        let actions = LAANotificationActions.actions(for: .board(id: decision, options: ["15日に公開", "延期", String(repeating: "長", count: 60)]))
        XCTAssertEqual(actions.map(\.identifier), ["LAA_ANSWER_OPTION_0", "LAA_ANSWER_OPTION_1", "LAA_ANSWER_OPTION_2"])
        XCTAssertEqual(actions[0].title, "15日に公開")
        XCTAssertEqual(actions[2].title.count, LAANotificationActions.maxTitleLength)
        XCTAssertTrue(actions[2].title.hasSuffix("…"))
        XCTAssertTrue(actions.allSatisfy { $0.options.contains(.authenticationRequired) && !$0.options.contains(.foreground) })
    }

    func testAnApprovalOffersAllowAndDeny() {
        let actions = LAANotificationActions.actions(for: .approval(sessionID: "ses_1", requestHash: pendingHash))
        XCTAssertEqual(actions.map(\.identifier), [LAANotificationActions.allowAction, LAANotificationActions.denyAction])
        XCTAssertTrue(actions[1].options.contains(.destructive))
        XCTAssertTrue(actions.allSatisfy { $0.options.contains(.authenticationRequired) })
        XCTAssertEqual(LAANotificationActions.choice(for: LAANotificationActions.allowAction), .allow)
        XCTAssertEqual(LAANotificationActions.choice(for: "LAA_ANSWER_OPTION_4"), .option(4))
        XCTAssertNil(LAANotificationActions.choice(for: "LAA_ANSWER_OPTION_9"))
        XCTAssertNil(LAANotificationActions.choice(for: UNNotificationDefaultActionIdentifier))
    }

    func testTheSameChoicesShareOneCategoryAndDifferentOnesDoNot() {
        let a = LAANotificationActions.category(for: .board(id: decision, options: ["A", "B"]))
        let b = LAANotificationActions.category(for: .question(sessionID: "ses_1", requestHash: pendingHash, options: ["A", "B"]))
        let c = LAANotificationActions.category(for: .board(id: decision, options: ["A", "C"]))
        XCTAssertEqual(a.identifier, b.identifier)
        XCTAssertNotEqual(a.identifier, c.identifier)
        XCTAssertTrue(a.identifier.hasPrefix(LAANotificationActions.categoryPrefix))
    }

    private final class Center: LAANotificationCategoryCenter {
        var categories: Set<UNNotificationCategory> = []
        var delivered: Set<String> = []
        var sets = 0
        func laaCategories(_ completion: @escaping (Set<UNNotificationCategory>) -> Void) { completion(categories) }
        func laaSetCategories(_ categories: Set<UNNotificationCategory>) { self.categories = categories; sets += 1 }
        func laaDeliveredCategoryIdentifiers(_ completion: @escaping (Set<String>) -> Void) { completion(delivered) }
    }

    func testTheExtensionAttachesTheButtonsAndKeepsOtherCategories() {
        let center = Center()
        center.categories = [UNNotificationCategory(identifier: "HERMES_CALL", actions: [], intentIdentifiers: [], options: [])]
        let content = UNMutableNotificationContent()
        content.sound = .default
        var done = 0
        LAANotificationActions.decorate(content, sessionID: sessionID("laa://work/decisions/\(decision)", [
            "v": 1, "k": "decision.new", "id": decision, "o": ["A", "B"]]), center: center) { done += 1 }
        XCTAssertEqual(done, 1)
        XCTAssertTrue(content.categoryIdentifier.hasPrefix(LAANotificationActions.categoryPrefix))
        XCTAssertEqual(Set(center.categories.map(\.identifier)), ["HERMES_CALL", content.categoryIdentifier])
        XCTAssertNotNil(content.sound)
    }

    func testAQuietKindLosesItsSoundAndADeadlinePassedLosesItsButtons() {
        let center = Center()
        let quiet = UNMutableNotificationContent()
        quiet.sound = .default
        LAANotificationActions.decorate(quiet, sessionID: sessionID("laa://work/sessions/ses_1", [
            "v": 1, "k": "session.finished", "sid": "ses_1", "lv": "p"]), center: center) {}
        XCTAssertNil(quiet.sound)
        XCTAssertEqual(quiet.interruptionLevel, .passive)
        XCTAssertEqual(quiet.categoryIdentifier, "")
        XCTAssertEqual(center.sets, 0)

        let late = UNMutableNotificationContent()
        LAANotificationActions.decorate(late, sessionID: sessionID("laa://work/decisions/\(decision)", [
            "v": 1, "k": "decision.new", "id": decision, "o": ["A", "B"], "d": 1_000]),
            now: Date(timeIntervalSince1970: 2_000), center: center) {}
        XCTAssertEqual(late.categoryIdentifier, "")
        XCTAssertEqual(center.sets, 0)

        // Any other notification is left exactly as it came.
        let chat = UNMutableNotificationContent()
        chat.sound = .default
        chat.categoryIdentifier = "HERMES_CALL"
        LAANotificationActions.decorate(chat, sessionID: "20261114_120000_abcdef", center: center) {}
        XCTAssertNotNil(chat.sound)
        XCTAssertEqual(chat.categoryIdentifier, "HERMES_CALL")
    }

    func testUnusedAnswerCategoriesAreDroppedOnlyOnceThereAreTooMany() {
        let own = UNNotificationCategory(identifier: "HERMES_CALL", actions: [], intentIdentifiers: [], options: [])
        var existing: Set<UNNotificationCategory> = [own]
        for index in 0..<LAANotificationActions.maxCategories {
            existing.insert(UNNotificationCategory(identifier: "LAA_ANSWER_\(index)", actions: [], intentIdentifiers: [], options: []))
        }
        let added = UNNotificationCategory(identifier: "LAA_ANSWER_new", actions: [], intentIdentifiers: [], options: [])
        let merged = LAANotificationActions.merged(existing: existing, adding: added, delivered: ["LAA_ANSWER_3"])
        XCTAssertEqual(Set(merged.map(\.identifier)), ["HERMES_CALL", "LAA_ANSWER_3", "LAA_ANSWER_new"])
        let few = LAANotificationActions.merged(existing: [own, added], adding: added, delivered: [])
        XCTAssertEqual(few.count, 2)
    }

    func testTheAppsOwnRegistrationKeepsTheAnswerCategories() {
        let center = Center()
        center.categories = [UNNotificationCategory(identifier: "LAA_ANSWER_x", actions: [], intentIdentifiers: [], options: []),
                             UNNotificationCategory(identifier: "OLD", actions: [], intentIdentifiers: [], options: [])]
        LAANotificationActions.registering([UNNotificationCategory(identifier: "HERMES_CALL", actions: [], intentIdentifiers: [], options: [])], center: center)
        XCTAssertEqual(Set(center.categories.map(\.identifier)), ["HERMES_CALL", "LAA_ANSWER_x"])
    }

    // MARK: Sending, and what protects it

    private final class Harness {
        var results: [LAAQuickAnswerResult] = []
        var sent: [LAAQuickAnswerRequest] = []
        var notices: [LAAQuickAnswerNotice] = []
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("laa-quick-\(UUID().uuidString).json")
        lazy var store = LAAQuickAnswerStore(file: file)
        @MainActor lazy var center = LAAQuickAnswerCenter(store: store, send: { [unowned self] request in
            self.sent.append(request)
            return self.results.isEmpty ? .unknown : self.results.removeFirst()
        }, post: { [unowned self] in self.notices.append($0) }, now: { [unowned self] in self.clock })
        deinit { try? FileManager.default.removeItem(at: file) }
    }

    func testAnAnswerGoesToTheSameDecisionWithAStableRequestId() async throws {
        let h = Harness()
        h.results = [.delivered]
        await h.center.answer(meta: boardMeta(), choice: .option(1), notificationKey: "kid:msg-1", title: "判断 J3: 公開日")
        XCTAssertEqual(h.sent.count, 1)
        let request = h.sent[0]
        XCTAssertEqual(request.target, .board(id: decision, optionIndex: 1))
        XCTAssertEqual(request.path, "/v1/decisions/\(decision)/answer")
        XCTAssertEqual(request.id, LAAQuickAnswerRequest.identifier(notificationKey: "kid:msg-1"))
        XCTAssertNotNil(LAABridgeIdempotencyKey(restoring: request.id))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(body["optionIndex"] as? Int, 1)
        XCTAssertEqual(body["quick"] as? Bool, true)
        XCTAssertEqual(body["requestId"] as? String, request.id)
        XCTAssertTrue(body["note"] is NSNull)
        XCTAssertEqual(h.notices.map(\.title), [LAAQuickAnswerCopy.sent])
        XCTAssertEqual(h.notices[0].tone, .confirmation)
        XCTAssertTrue(h.notices[0].body.contains("延期"))
        XCTAssertEqual(h.notices[0].link, "laa://work/decisions/\(decision)")
        XCTAssertTrue(h.center.pending.isEmpty)
    }

    func testAQuestionAndAnApprovalCarryTheHashTheyWereAskedWith() async throws {
        let h = Harness()
        h.results = [.delivered, .delivered]
        let question = LAANotificationMeta.parse(sessionID("laa://work/sessions/ses_1", [
            "v": 1, "k": "session.question", "sid": "ses_1", "h": pendingHash, "o": ["はい", "いいえ"]]))!
        await h.center.answer(meta: question, choice: .option(0), notificationKey: "q", title: "会話")
        let approval = LAANotificationMeta.parse(sessionID("laa://work/sessions/ses_1", [
            "v": 1, "k": "session.approval", "sid": "ses_1", "h": pendingHash, "a": 1]))!
        await h.center.answer(meta: approval, choice: .deny, notificationKey: "a", title: "会話")
        XCTAssertEqual(h.sent.map(\.path), ["/v1/sessions/ses_1/quick-reply", "/v1/sessions/ses_1/quick-reply"])
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: h.sent[0].body) as? [String: Any])
        XCTAssertEqual(first["requestHash"] as? String, pendingHash)
        XCTAssertEqual((first["choice"] as? [String: Any])?["optionIndex"] as? Int, 0)
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: h.sent[1].body) as? [String: Any])
        XCTAssertEqual(second["requestHash"] as? String, pendingHash)
        XCTAssertEqual(second["choice"] as? String, "deny")
    }

    func testAChoiceTheNotificationDidNotOfferSendsNothing() async {
        let h = Harness()
        await h.center.answer(meta: boardMeta(), choice: .option(5), notificationKey: "k1", title: "判断")
        await h.center.answer(meta: boardMeta(), choice: .allow, notificationKey: "k2", title: "判断")
        XCTAssertTrue(h.sent.isEmpty)
        XCTAssertEqual(h.notices.map(\.title), [LAAQuickAnswerCopy.notAnswered, LAAQuickAnswerCopy.notAnswered])
    }

    func testNothingIsSentAfterTheDeadline() async {
        let h = Harness()
        await h.center.answer(meta: boardMeta(deadline: h.clock.addingTimeInterval(-60)), choice: .option(0), notificationKey: "k", title: "判断")
        XCTAssertTrue(h.sent.isEmpty)
        XCTAssertTrue(h.center.pending.isEmpty)
        XCTAssertEqual(h.notices.map(\.title), [LAAQuickAnswerCopy.notAnswered])
        XCTAssertTrue(h.notices[0].body.contains("期限"))
        XCTAssertEqual(h.notices[0].tone, .attention)
    }

    func testASecondAnswerFromTheSameNotificationIsRefusedOnTheDevice() async {
        let h = Harness()
        h.results = [.delivered]
        await h.center.answer(meta: boardMeta(), choice: .option(0), notificationKey: "same", title: "判断")
        // The Watch and the iPhone both showed it; the second tap picks the other option.
        await h.center.answer(meta: boardMeta(), choice: .option(1), notificationKey: "same", title: "判断")
        XCTAssertEqual(h.sent.count, 1)
        XCTAssertEqual(h.sent[0].target, .board(id: decision, optionIndex: 0))
        XCTAssertEqual(h.notices.last?.title, LAAQuickAnswerCopy.notAnswered)
        XCTAssertEqual(h.notices.last?.body.contains("すでに回答"), true)
    }

    func testARefusalFromTheBridgeEndsTheAnswerAndSaysWhy() async {
        let h = Harness()
        h.results = [.refused("decision_closed"), .refused("decision_expired"), .refused("pending_request_changed")]
        await h.center.answer(meta: boardMeta(), choice: .option(0), notificationKey: "1", title: "判断")
        await h.center.answer(meta: boardMeta(), choice: .option(0), notificationKey: "2", title: "判断")
        await h.center.answer(meta: boardMeta(), choice: .option(0), notificationKey: "3", title: "判断")
        XCTAssertTrue(h.center.pending.isEmpty)
        XCTAssertEqual(h.notices.map(\.tone), [.attention, .attention, .attention])
        XCTAssertTrue(h.notices[0].body.contains("すでに回答済み"))
        XCTAssertTrue(h.notices[1].body.contains("期限"))
        XCTAssertTrue(h.notices[2].body.contains("質問が変わりました"))
        // Nothing is repeated later.
        await h.center.retryPending()
        XCTAssertEqual(h.sent.count, 3)
    }

    func testOutOfReachTheAnswerWaitsAndGoesOutWithTheSameRequest() async {
        let h = Harness()
        h.results = [.unknown, .unknown, .waiting]
        await h.center.answer(meta: boardMeta(), choice: .option(0), notificationKey: "offline", title: "判断 J3")
        XCTAssertEqual(h.center.pending.count, 1)
        XCTAssertEqual(h.notices.map(\.title), [LAAQuickAnswerCopy.queued])
        // A second device, a relaunch: the file is what survives.
        let relaunched = LAAQuickAnswerCenter(store: LAAQuickAnswerStore(file: h.file), send: { request in
            h.sent.append(request)
            return h.results.removeFirst()
        }, post: { h.notices.append($0) }, now: { h.clock })
        await relaunched.retryPending()
        XCTAssertEqual(relaunched.pending.count, 1)
        XCTAssertEqual(relaunched.pending[0].attempts, 2)
        // Still unknown: said once, not again.
        XCTAssertEqual(h.notices.count, 1)
        await relaunched.retryPending()
        XCTAssertTrue(relaunched.pending.isEmpty)
        XCTAssertEqual(Set(h.sent.map(\.id)).count, 1)
        XCTAssertEqual(Set(h.sent.map(\.body)).count, 1)
        XCTAssertEqual(h.notices.last?.title, LAAQuickAnswerCopy.waiting)
        // And the notification stays answered.
        await relaunched.answer(meta: boardMeta(), choice: .option(1), notificationKey: "offline", title: "判断 J3")
        XCTAssertEqual(h.sent.count, 3)
    }

    func testAWaitingAnswerIsDroppedAtItsDeadlineNotSent() async {
        let h = Harness()
        h.results = [.unknown]
        await h.center.answer(meta: boardMeta(deadline: h.clock.addingTimeInterval(600)), choice: .option(0), notificationKey: "late", title: "判断")
        XCTAssertEqual(h.center.pending.first?.expiresAt, h.clock.addingTimeInterval(600))
        h.clock = h.clock.addingTimeInterval(601)
        await h.center.retryPending()
        XCTAssertEqual(h.sent.count, 1)
        XCTAssertTrue(h.center.pending.isEmpty)
        XCTAssertEqual(h.notices.last?.title, LAAQuickAnswerCopy.gaveUp)
    }

    func testWithNoDeadlineAnAnswerWaitsAtMostADay() async {
        let h = Harness()
        h.results = [.unknown]
        await h.center.answer(meta: boardMeta(), choice: .option(0), notificationKey: "day", title: "判断")
        XCTAssertEqual(h.center.pending.first?.expiresAt, h.clock.addingTimeInterval(LAAQuickAnswerCenter.maxWait))
        h.clock = h.clock.addingTimeInterval(LAAQuickAnswerCenter.maxWait + 1)
        await h.center.retryPending()
        XCTAssertEqual(h.sent.count, 1)
        XCTAssertEqual(h.notices.last?.title, LAAQuickAnswerCopy.gaveUp)
    }

    func testASavedAnswerThatDidNotArriveSendsTheOwnerToTheBoard() async {
        let h = Harness()
        h.results = [.notDelivered]
        await h.center.answer(meta: boardMeta(), choice: .option(0), notificationKey: "nd", title: "判断")
        XCTAssertEqual(h.notices.map(\.title), [LAAQuickAnswerCopy.notDelivered])
        XCTAssertEqual(h.notices[0].tone, .attention)
        XCTAssertTrue(h.center.pending.isEmpty)
    }

    // MARK: What the Bridge's replies mean

    func testBridgeRepliesMapToOutcomes() {
        func error(_ status: Int, _ code: String?) -> LAABridgeHTTPError {
            LAABridgeHTTPError(status: status, code: code, message: nil, retryable: nil, details: nil, requestId: nil, currentETag: nil)
        }
        XCTAssertEqual(LAAQuickAnswerCenter.result(for: error(409, "decision_expired")), .refused("decision_expired"))
        XCTAssertEqual(LAAQuickAnswerCenter.result(for: error(409, "decision_closed")), .refused("decision_closed"))
        XCTAssertEqual(LAAQuickAnswerCenter.result(for: error(409, "pending_request_changed")), .refused("pending_request_changed"))
        XCTAssertEqual(LAAQuickAnswerCenter.result(for: error(404, "not_found")), .refused("not_found"))
        XCTAssertEqual(LAAQuickAnswerCenter.result(for: error(401, "unauthorized")), .refused("unpaired"))
        // Not known to have been refused: kept and repeated with the same key.
        XCTAssertEqual(LAAQuickAnswerCenter.result(for: error(503, "paseo_unavailable")), .unknown)
        XCTAssertEqual(LAAQuickAnswerCenter.result(for: error(409, "idempotency_key_in_flight")), .unknown)

        func decision(_ state: String, waiting: Bool? = nil) -> LAADecision {
            LAADecision(id: self.decision, status: "answered", title: "t", summary: "",
                        answer: .init(optionIndex: 0, label: "A", note: nil, answeredAt: nil),
                        delivery: .init(state: state, attempts: 1, deliveredAt: nil, error: nil, waiting: waiting))
        }
        XCTAssertEqual(LAAQuickAnswerCenter.result(for: decision("delivered")), .delivered)
        XCTAssertEqual(LAAQuickAnswerCenter.result(for: decision("pending", waiting: true)), .waiting)
        XCTAssertEqual(LAAQuickAnswerCenter.result(for: decision("stored")), .stored)
        XCTAssertEqual(LAAQuickAnswerCenter.result(for: decision("failed")), .notDelivered)
    }

    func testANoticeOpensItsLinkAndOnlyAProblemSounds() {
        let ok = LAAQuickAnswerNotifications.content(for: .init(id: "x", title: "t", body: "b", link: "laa://work/decisions/\(decision)", tone: .confirmation))
        XCTAssertNil(ok.sound)
        XCTAssertEqual(ok.userInfo[LAAQuickAnswerNotifications.linkKey] as? String, "laa://work/decisions/\(decision)")
        let problem = LAAQuickAnswerNotifications.content(for: .init(id: "x", title: "t", body: "b", link: "laa://work/decisions", tone: .attention))
        XCTAssertNotNil(problem.sound)
    }
}
#endif
