#if LAA_BUILD
import XCTest
@testable import Conduit

/// Hermes' fixed notice for a turn that failed before any reply is shown to
/// the owner in Japanese, live and from the saved transcript (owner's
/// Merlin chat, 2026-11-15). A reply that merely quotes it stays as written.
@MainActor
final class LAAFailedTurnCopyTests: XCTestCase {
    private func rows(_ json: String) -> [AnyCodable] {
        let data = json.data(using: .utf8)!
        let array = try! JSONSerialization.jsonObject(with: data) as! [Any]
        return array.map { AnyCodable.from($0) }
    }

    func testSavedFailedTurnRowReadsInJapanese() {
        let messages = MessageNormalizer.normalizeMessages(rows(#"""
        [
          {"role": "user", "text": "あなたは？"},
          {"role": "assistant", "text": "Your request was not processed. Send it again if you still want me to carry it out.", "display_kind": "failed_turn"},
          {"role": "assistant", "text": "This turn did not complete. Some actions may already have run; verify their effects before resending."},
          {"role": "assistant", "text": "He wrote: Your request was not processed. Send it again if you still want me to carry it out."}
        ]
        """#))
        XCTAssertEqual(messages.map(\.content), [
            "あなたは？",
            LAAFailedTurnCopy.failedJapanese,
            LAAFailedTurnCopy.partialJapanese,
            "He wrote: Your request was not processed. Send it again if you still want me to carry it out.",
        ])
    }

    func testLiveFailedTurnCompletionReadsInJapanese() throws {
        let frame: [String: Any] = ["type": "message.complete", "session_id": "s",
            "payload": ["text": "Your request was not processed. Send it again if you still want me to carry it out."]]
        let event = try XCTUnwrap(StreamEventParser.parse(params: AnyCodable.from(frame)))
        guard case .messageComplete(_, _, let content, _, _) = event else { return XCTFail("not a completion") }
        XCTAssertEqual(content, LAAFailedTurnCopy.failedJapanese)
        let reply: [String: Any] = ["type": "message.complete", "session_id": "s", "payload": ["text": "解。COSのMerlinです。"]]
        guard case .messageComplete(_, _, let kept, _, _)? = StreamEventParser.parse(params: AnyCodable.from(reply)) else { return XCTFail() }
        XCTAssertEqual(kept, "解。COSのMerlinです。")
    }
}
#endif
