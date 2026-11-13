#if LAA_BUILD
import XCTest
@testable import Conduit

/// Where a swipe on a Work row ends (2026-11-13): a short swipe opens the
/// button and leaves it there; only a full swipe the finger really made
/// chooses it, and a quick flick opens it instead.
final class LAAWorkSwipeTests: XCTestCase {
    private func outcome(settled: CGFloat = 0, moved: CGFloat, predicted: CGFloat? = nil, trailing: Bool = true) -> LAAWorkSwipe.Outcome {
        LAAWorkSwipe.outcome(settled: settled, moved: moved, predicted: predicted ?? moved, hasTrailing: trailing)
    }

    func testShortSwipeOpensTheButtonAndStays() {
        XCTAssertEqual(outcome(moved: 40), .rest(LAAWorkSwipe.reveal))
        XCTAssertEqual(outcome(moved: 120), .rest(LAAWorkSwipe.reveal))
        XCTAssertEqual(outcome(moved: -40), .rest(-LAAWorkSwipe.reveal))
    }

    func testTinyMovementOpensNothing() {
        XCTAssertEqual(outcome(moved: 20), .rest(0))
        XCTAssertEqual(outcome(moved: -20), .rest(0))
    }

    func testQuickFlickOpensTheButtonButDoesNotChooseIt() {
        XCTAssertEqual(outcome(moved: 60, predicted: 600), .rest(LAAWorkSwipe.reveal))
        XCTAssertEqual(outcome(moved: -60, predicted: -600), .rest(-LAAWorkSwipe.reveal))
    }

    func testFullSwipeChoosesTheButton() {
        XCTAssertEqual(outcome(moved: 230), .runLeading)
        XCTAssertEqual(outcome(moved: -230), .runTrailing)
        XCTAssertEqual(outcome(settled: LAAWorkSwipe.reveal, moved: 130), .runLeading)
    }

    func testRowWithoutTrailingNeverOpensRight() {
        XCTAssertEqual(outcome(moved: -230, trailing: false), .rest(0))
        XCTAssertEqual(outcome(moved: -60, trailing: false), .rest(0))
    }

    func testOpenButtonClosesWithADragBack() {
        XCTAssertEqual(outcome(settled: LAAWorkSwipe.reveal, moved: -40), .rest(0))
        XCTAssertEqual(outcome(settled: LAAWorkSwipe.reveal, moved: -10), .rest(LAAWorkSwipe.reveal))
        XCTAssertEqual(outcome(settled: -LAAWorkSwipe.reveal, moved: 40), .rest(0))
    }

    func testRefusalSaysWhyInFull() {
        let running = LAABridgeHTTPError(status: 409, code: "session_running", message: nil, retryable: false,
                                         details: nil, requestId: nil, currentETag: nil)
        let text = LAAWorkArchivePrompt.refusal(running)
        XCTAssertTrue(text.contains("実行中"))
        XCTAssertTrue(text.contains("そのまま残っています"))
        XCTAssertNil(LAAWorkArchivePrompt.refused(running).archive)
    }
}
#endif
