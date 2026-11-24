#if LAA_BUILD
import XCTest
@testable import Conduit

final class LAAWorkTranscriptPollTests: XCTestCase {
    func testUnavailableDoublesUntilSixtySecondsAndSuccessResets() {
        var now: TimeInterval = 0
        var poll = LAAWorkTranscriptPoll(now: { now }, jitter: { 1 })
        XCTAssertTrue(poll.allows(.heartbeat))
        for delay: TimeInterval in [10, 20, 40, 60, 60] {
            poll.complete(.unavailable)
            now += delay - 0.01
            XCTAssertFalse(poll.allows(.heartbeat))
            now += 0.02
            XCTAssertTrue(poll.allows(.heartbeat))
        }
        poll.complete(.success)
        now += 5
        XCTAssertTrue(poll.allows(.heartbeat))
        poll.complete(.unavailable)
        now += 11
        XCTAssertTrue(poll.allows(.heartbeat))
    }

    func testChangeAndUserBypassDelayButOnlyUserCanReopenStoppedSchedule() {
        var now: TimeInterval = 100
        var poll = LAAWorkTranscriptPoll(now: { now }, jitter: { 1.1 })
        poll.complete(.unavailable)
        now = 110.99
        XCTAssertFalse(poll.allows(.heartbeat))
        XCTAssertTrue(poll.allows(.changed))
        XCTAssertTrue(poll.allows(.user))
        now = 111
        XCTAssertTrue(poll.allows(.heartbeat))
        poll.complete(.stopped)
        XCTAssertFalse(poll.allows(.heartbeat))
        XCTAssertFalse(poll.allows(.changed))
        XCTAssertTrue(poll.allows(.user))
        poll.complete(.success)
        XCTAssertFalse(poll.isStopped)
        XCTAssertTrue(poll.allows(.changed))
    }
}
#endif
