#if LAA_BUILD
import XCTest
@testable import Conduit

final class LAAWatchVoiceContractTests: XCTestCase {
    func testAudioLimitAndMetadataRoundTrip() {
        XCTAssertEqual(LAAWatchAsk.maxAudioBytes, 800_000)
        let request = LAAWatchAsk.Request(requestID: "request", profile: nil)
        XCTAssertEqual(LAAWatchAsk.request(fromMetadata: LAAWatchAsk.fileMetadata(request)), request)
    }

    func testStateWirePreservesJapaneseReplyAndFinalPhases() {
        let state = LAAWatchAsk.State(requestID: "request", phase: .answered, profile: nil, transcript: "今日の予定", reply: "予定です。")
        XCTAssertEqual(WatchVoiceWire.decode(WatchVoiceWire.encode(.laaAskState(state))), .laaAskState(state))
        XCTAssertFalse(LAAWatchAsk.Phase.transcribing.isFinal)
        XCTAssertFalse(LAAWatchAsk.Phase.sending.isFinal)
        XCTAssertTrue(LAAWatchAsk.Phase.answered.isFinal)
        XCTAssertTrue(LAAWatchAsk.Phase.failed.isFinal)
    }
}
#endif
