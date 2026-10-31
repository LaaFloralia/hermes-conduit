#if LAA_BUILD && targetEnvironment(macCatalyst)
import XCTest
@testable import Conduit

@MainActor
final class LAAMacCatalystTests: XCTestCase {
    func testInAppVoiceCanStartWithoutSystemCall() async {
        XCTAssertFalse(HermesNativeCalls.ringingBuilt)
        let host = VoicePlacedCallHost(
            isSettingOn: { true }, isVoiceRunning: { false }, displayName: { "Test" },
            endVoice: {}, voiceMuted: { nil }, setVoiceMuted: { _ in },
            setCallActive: { _ in }, runsElsewhere: { false }
        )
        let calls = VoicePlacedCalls(callKit: HermesNativeCalls.shared, host: host)
        let start = await calls.prepareForVoiceStart()
        XCTAssertEqual(start, .withoutCall)
        XCTAssertTrue(calls.canStartVoice(start))
    }

    func testLiveActivityRequestsAreInert() {
        let activities = LiveTurnActivities.shared
        activities.turnStarted(sessionIDs: ["s1"], primaryID: "s1", title: "Test", profile: "p1")
        XCTAssertFalse(activities.reconcile(liveSessionIDs: ["s1"], profile: "p1", dashboardID: nil))
        XCTAssertEqual(LiveTurnActivities.sessionIDs(linkedTo: "s1", profile: "p1", dashboardID: nil), [])
    }
}
#endif
