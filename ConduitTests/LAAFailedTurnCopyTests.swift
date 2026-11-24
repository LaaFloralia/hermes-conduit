#if LAA_BUILD
import XCTest
@testable import Conduit

/// R2 intentionally stopped inferring failures from English assistant text.
@MainActor
final class LAAFailedTurnCopyTests: XCTestCase {
    func testSavedFailedTurnUsesDisplayMetadataOnly() {
        let prose = "This turn did not complete. Some actions may already have run; verify their effects before resending."
        let rows: [[String: Any]] = [
            ["role": "assistant", "text": prose, "display_kind": "failed_turn", "failure_class": "model_unavailable"],
            // Hermes types every boundary row it writes; one without a class still reads in Japanese.
            ["role": "assistant", "text": prose, "display_kind": "failed_turn"],
            ["role": "assistant", "text": prose]
        ]
        XCTAssertEqual(MessageNormalizer.normalizeMessages(rows.map(AnyCodable.from)).map(\.content),
                       [ChatRuntimeFailure(.modelUnavailable).localizedDescription,
                        ChatRuntimeFailure(.internal).localizedDescription, prose])
    }

    func testLiveFailureUsesStatusAndCodeInsteadOfText() {
        let prose = "Your request was not processed. Send it again if you still want me to carry it out."
        func parse(_ payload: [String: Any]) -> StreamEvent? {
            StreamEventParser.parse(params: AnyCodable.from(["type": "message.complete", "session_id": "fixture", "payload": payload]))
        }
        guard case .messageError(_, let message) = parse(["status": "failed", "failure_class": "tool_failed", "text": prose]) else {
            return XCTFail("Expected the structured failure")
        }
        XCTAssertEqual(message, ChatRuntimeFailure(.toolFailed).localizedDescription)
        // The gateway's own terminal status for a failed turn is "error" (prompt_turn.py).
        guard case .messageError(_, let untyped) = parse(["status": "error", "text": prose]) else {
            return XCTFail("Expected the status-only failure")
        }
        XCTAssertEqual(untyped, ChatRuntimeFailure(.internal).localizedDescription)
        guard case .messageComplete(_, _, let retained, _, _) = parse(["text": prose]) else {
            return XCTFail("Unmarked prose must stay a normal reply")
        }
        XCTAssertEqual(retained, prose)
    }
}
#endif
