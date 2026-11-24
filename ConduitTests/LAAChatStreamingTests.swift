#if LAA_BUILD
import XCTest
@testable import Conduit

/// Streaming without movement (LAAStreamingText): 50 ms commits, frozen
/// chunks with stable ids, only the tail re-parsed, heights kept by key.
@MainActor
final class LAAChatStreamingTests: XCTestCase {
    func testCommitsAreCoalescedToFiftyMilliseconds() {
        var model = LAAStreamingModel()
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertEqual(model.delayBeforeNextCommit(now: t0), 0, "The first commit lands at once")
        model.commit("Hello", at: t0)
        XCTAssertEqual(model.delayBeforeNextCommit(now: t0.addingTimeInterval(0.01)), 0.04, accuracy: 0.0001)
        XCTAssertEqual(model.delayBeforeNextCommit(now: t0.addingTimeInterval(0.06)), 0)
    }

    func testFinishedBlocksFreezeWithStableIDs() {
        var model = LAAStreamingModel()
        model.commit("First paragraph.\n\nSecond")
        XCTAssertEqual(model.chunks.map(\.text), ["First paragraph."])
        XCTAssertEqual(model.tail, "Second")
        let firstID = model.chunks.first?.id
        model.commit("First paragraph.\n\nSecond paragraph, longer.\n\n- a list\n- going")
        XCTAssertEqual(model.chunks.first?.id, firstID, "A frozen chunk keeps its id as the reply grows")
        XCTAssertEqual(model.chunks.map(\.text), ["First paragraph.", "Second paragraph, longer."])
        XCTAssertEqual(model.tail, "- a list\n- going", "Only the tail is live")
    }

    func testAFenceIsNeverCutOpen() {
        var model = LAAStreamingModel()
        model.commit("Intro.\n\n```swift\nlet a = 1\n\nlet b = 2\n")
        XCTAssertEqual(model.chunks.map(\.text), ["Intro."])
        XCTAssertTrue(model.tail.hasPrefix("```swift"), "The open fence stays in the tail")
    }

    func testARewriteStartsOver() {
        var model = LAAStreamingModel()
        model.commit("Old answer.\n\nMore")
        model.commit("New answer")
        XCTAssertTrue(model.chunks.isEmpty)
        XCTAssertEqual(model.tail, "New answer")
    }

    func testHeightCacheKeysOnRevisionWidthAndFontEpoch() {
        let cache = LAATranscriptHeightCache.shared
        let key = LAATranscriptHeightCache.Key(id: 0, revision: 7, width: 400, epoch: "default-r")
        cache.store(120, for: key)
        XCTAssertEqual(cache.height(for: key), 120)
        XCTAssertEqual(cache.height(for: .init(id: 0, revision: 7, width: 400.2, epoch: "default-r")), 120, "Sub-point width noise is the same width")
        XCTAssertNil(cache.height(for: .init(id: 0, revision: 8, width: 400, epoch: "default-r")), "New content, new height")
        XCTAssertNil(cache.height(for: .init(id: 0, revision: 7, width: 300, epoch: "default-r")), "Another width, another height")
        XCTAssertNil(cache.height(for: .init(id: 0, revision: 7, width: 400, epoch: "larger-r")), "Another text size, another height")
    }
}
#endif
