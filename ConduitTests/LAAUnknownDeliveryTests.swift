#if LAA_BUILD
import XCTest
@testable import Conduit

/// A message sent just before the app stopped is settled, not re-offered,
/// when Hermes's saved conversation already holds it (2026-11-14 crash).
@MainActor
final class LAAUnknownDeliveryTests: XCTestCase {
    private func row(_ id: String, _ role: MessageRole, _ text: String) -> ChatMessage {
        ChatMessage(id: id, role: role, content: text, rawContent: nil, timestamp: "2026-11-14T21:48:43", author: nil, attachments: nil)
    }

    private let sent = "基本はOpasでやって、DotsのせっとあっぷだけMythosで続けて"

    func testTheNewestSavedOwnerRowWithTheSameWordsMeansItArrived() {
        let rows = [row("1", .user, "前の依頼"), row("2", .assistant, "是。"), row("3", .user, sent), row("4", .reasoning, "考え中")]
        XCTAssertTrue(LAAUnknownDelivery.landed(sent + "\n", messages: rows, durableIDs: ["1", "2", "3"]))
    }

    func testARowThatIsOnlyOnScreenProvesNothing() {
        // The optimistic bubble the app drew itself is not Hermes's copy.
        let rows = [row("1", .user, "前の依頼"), row("local-1", .user, sent)]
        XCTAssertFalse(LAAUnknownDelivery.landed(sent, messages: rows, durableIDs: ["1"]))
    }

    func testAShortOldMessageDoesNotCountWhenANewerOneFollows() {
        // "続けて" repeats by chance; without a reservation time only the
        // newest owner row can carry it.
        let rows = [row("1", .user, "続けて"), row("2", .assistant, "是。"), row("3", .user, "別の依頼")]
        XCTAssertFalse(LAAUnknownDelivery.landed("続けて", messages: rows, durableIDs: ["1", "2", "3"]))
    }

    func testALongMessageFollowedByLaterTurnsStillArrived() {
        // MacBook, 2026-11-15: the 20:11 message stayed "unconfirmed" while
        // later owner messages and background notices followed it.
        let rows = [row("1", .user, sent), row("2", .assistant, "是。"),
                    row("3", .user, "[IMPORTANT: Background process completed]"), row("4", .user, "別の依頼")]
        XCTAssertTrue(LAAUnknownDelivery.landed(sent, messages: rows, durableIDs: ["1", "2", "3", "4"]))
    }

    private func dated(_ id: String, _ text: String, _ stamp: String) -> ChatMessage {
        ChatMessage(id: id, role: .user, content: text, rawContent: nil, timestamp: stamp, author: nil, attachments: nil)
    }

    func testWithAReservationTimeAnySavedCopyAfterItArrived() {
        let reserved = MessageTimestampFormatter.date(from: "2026-11-14T11:11:50Z")!
        let rows = [dated("1", "続けて", "2026-11-14T11:11:56Z"), dated("2", "別の依頼", "2026-11-14T12:49:54Z")]
        XCTAssertTrue(LAAUnknownDelivery.landed("続けて", reservedAt: reserved, messages: rows, durableIDs: ["1", "2"]))
    }

    func testWithAReservationTimeACopyFromBeforeItProvesNothing() {
        // The same words sent an hour earlier are a different message.
        let reserved = MessageTimestampFormatter.date(from: "2026-11-14T12:48:40Z")!
        let rows = [dated("1", sent, "2026-11-14T11:11:56Z"), dated("2", "別の依頼", "2026-11-14T11:30:00Z")]
        XCTAssertFalse(LAAUnknownDelivery.landed(sent, reservedAt: reserved, messages: rows, durableIDs: ["1", "2"]))
    }

    func testANewReservationRecordsItsTime() {
        let store = ComposerDraftStore(capacity: 8, fileURL: nil)
        let key = ComposerDraftKey(profile: "laa-monet", sessionID: "s1", dashboardID: UUID())
        let item = ComposerDraftStore.Submission(id: UUID(), key: key, dashboardID: key.dashboardID!,
                                                 draft: ComposerDraft(text: sent, attachments: [], replyReference: nil),
                                                 pendingSendID: nil)
        let before = Date()
        XCTAssertTrue(store.beginSubmission(item, clearingDraft: true))
        store.markSubmissionUnknown(item.id)
        let stamp = try? XCTUnwrap(store.unknownSubmissions.first?.reservedAt)
        XCTAssertNotNil(stamp)
        XCTAssertGreaterThanOrEqual((stamp ?? .distantPast).timeIntervalSince(before), -1)
    }

    func testAQuotedReplyKeepsTheWordsAtItsEnd() {
        let rows = [row("1", .user, "> 引用した文\n\n" + sent)]
        XCTAssertTrue(LAAUnknownDelivery.landed(sent, messages: rows, durableIDs: ["1"]))
        XCTAssertFalse(LAAUnknownDelivery.landed("", messages: rows, durableIDs: ["1"]))
    }

    func testASettledSubmissionLeavesTheUnknownList() {
        let store = ComposerDraftStore(capacity: 8, fileURL: nil)
        let key = ComposerDraftKey(profile: "laa-monet", sessionID: "s1", dashboardID: UUID())
        let item = ComposerDraftStore.Submission(id: UUID(), key: key, dashboardID: key.dashboardID!,
                                                 draft: ComposerDraft(text: sent, attachments: [], replyReference: nil),
                                                 pendingSendID: nil)
        XCTAssertTrue(store.beginSubmission(item, clearingDraft: true))
        store.markSubmissionUnknown(item.id)
        XCTAssertEqual(store.unknownSubmissions.map(\.id), [item.id])
        XCTAssertTrue(store.finishSubmission(item.id, restoring: false))
        XCTAssertTrue(store.unknownSubmissions.isEmpty)
    }
}
#endif
