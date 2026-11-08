#if LAA_BUILD
import XCTest
@testable import Conduit

@MainActor
final class LAAWatchAskTests: XCTestCase {
    func testExplicitNameRoutesAndLeavesRemainderUnchanged() throws {
        let member = try XCTUnwrap(LAAStaff.allCases.first { $0.name == "Argus" })
        let expected = "laa-\(member.rawValue)"
        let result = try XCTUnwrap(LAAWatchAskRouting.route("アーガスさんへ 本文、です", profile: nil))
        XCTAssertEqual(result.profile, expected)
        XCTAssertEqual(result.text, "アーガスさんへ 本文、です")
        let plain = try XCTUnwrap(LAAWatchAskRouting.route("知らない人へ本文", profile: nil))
        XCTAssertEqual(plain.profile, "laa-\(try XCTUnwrap(LAAStaff.allCases.first).rawValue)")
        XCTAssertEqual(plain.text, "知らない人へ本文")
        let chosen = try XCTUnwrap(LAAWatchAskRouting.route("アーガスに本文", profile: expected))
        XCTAssertEqual(chosen.text, "アーガスに本文")
        XCTAssertNil(LAAWatchAskRouting.route("本文", profile: "unknown"))
        XCTAssertEqual(LAAWatchAskRouting.route("シエルに本文", profile: nil)?.profile, "laa-monet")
        XCTAssertEqual(LAAWatchAskRouting.route("モネ無検閲に本文", profile: nil)?.profile, "laa-monet-uncensored")
        XCTAssertEqual(LAAWatchAskRouting.route("モネットさん、本文", profile: nil)?.profile, "laa-monet")
    }

    func testRequestAudioLimitsAndPhaseMapping() {
        XCTAssertTrue(LAAWatchAskService.validAudio(Data(count: 800_000), sampleRate: 16_000))
        XCTAssertFalse(LAAWatchAskService.validAudio(Data(count: 800_002), sampleRate: 16_000))
        XCTAssertFalse(LAAWatchAskService.validAudio(Data(count: 1), sampleRate: 16_000))
        XCTAssertFalse(LAAWatchAskService.validAudio(Data(count: 2), sampleRate: 44_100))
        XCTAssertFalse(LAAWatchAskService.validAudio(Data(), sampleRate: 16_000))
        XCTAssertEqual(LAAWatchAskService.phase(.answered("x")), .answered)
        XCTAssertEqual(LAAWatchAskService.phase(.stillWorking), .stillWorking)
        XCTAssertEqual(LAAWatchAskService.phase(.needsInput), .needsInput)
        XCTAssertEqual(LAAWatchAskService.phase(.joinedRunningReply), .queued)
        XCTAssertEqual(LAAWatchAskService.phase(.queued), .queued)
        XCTAssertEqual(LAAWatchAskService.failure(LAABridgeError.forbidden), "Watchの音声はまだ接続されていません")
    }

    func testCallableProfilesContextRoundTripsAndOlderContextDecodes() throws {
        var context = WatchPhoneContext()
        context.laaCallableProfiles = LAAStaff.allCases.compactMap { member in
            let profile = "laa-\(member.rawValue)"
            return LAAEmployeeGPTLivePlan.make(profile: profile, savedVoice: nil) == nil ? nil : profile
        }
        XCTAssertEqual(WatchPhoneContext.decode(context.encoded())?.laaCallableProfiles, context.laaCallableProfiles)
        let older = try JSONDecoder().decode(WatchPhoneContext.self, from: Data("{\"voices\":{},\"callsRing\":false}".utf8))
        XCTAssertNil(older.laaCallableProfiles)
    }

    func testQueuedNotificationNeverContainsBody() {
        let state = LAAWatchAsk.State(requestID: UUID().uuidString, phase: .answered, profile: "example", transcript: "private", reply: "private", failure: "private")
        let queued = LAAWatchAskService.queuedNotification(state)
        XCTAssertEqual(queued.requestID, state.requestID)
        XCTAssertEqual(queued.phase, .answered)
        XCTAssertEqual(queued.profile, state.profile)
        XCTAssertNil(queued.transcript)
        XCTAssertNil(queued.reply)
        XCTAssertNil(queued.failure)
    }
}
#endif
