#if LAA_BUILD
import XCTest
import AVFAudio
@testable import Conduit

@MainActor
final class LAAStaffCallTests: XCTestCase {
    func testStaffProfilesAndUnknownProfile() {
        let expected: [String: String] = ["ciel": "Ciel", "argus": "Argus", "cfo": "Morgan",
                                          "cio": "Sherlock", "cmo": "Monet", "cos": "Merlin",
                                          "cso": "Talos", "cto": "Ada"]
        for (id, name) in expected {
            XCTAssertEqual(LAAStaff(profile: "laa-\(id)")?.name, name)
        }
        XCTAssertNil(LAAStaff(profile: "default"))
        XCTAssertNil(LAAStaff(profile: "laa-other"))
    }

    func testBundledAssetsAndFallbackWhenEntireSetMissing() {
        let root = URL(fileURLWithPath: "/test-bundle", isDirectory: true)
        let paths: Set<String> = ["/test-bundle/staff", "/test-bundle/staff/ciel/ciel-avatar-512.png",
                                  "/test-bundle/staff/ciel/ciel-idle-512.mov",
                                  "/test-bundle/ciel/ciel-avatar-512.png",
                                  "/test-bundle/callkit-icon-template-120.png"]
        let resolver = StaffAssetResolver(root: root, exists: { paths.contains($0.path) })
        let ciel = resolver.resolve(profile: "laa-ciel")
        XCTAssertEqual(ciel.avatar?.path, "/test-bundle/staff/ciel/ciel-avatar-512.png")
        XCTAssertNotNil(ciel.loop)
        XCTAssertNil(ciel.hero)
        XCTAssertNil(resolver.resolve(profile: "laa-cfo").avatar)
        XCTAssertNotNil(resolver.resolve(profile: "default").defaultMark)
        XCTAssertEqual(resolver.resolve(profile: "unknown"), StaffAssets())

        let old = StaffAssetResolver(root: root, exists: { paths.subtracting(["/test-bundle/staff"]).contains($0.path) })
        XCTAssertEqual(old.resolve(profile: "laa-ciel").avatar?.path, "/test-bundle/ciel/ciel-avatar-512.png")
        XCTAssertNil(old.resolve(profile: "laa-cfo").avatar)
    }

    func testAdoptedStaffAssetsAreInTheAppBundle() {
        for staff in LAAStaff.allCases {
            let assets = StaffAssetResolver.bundled.resolve(profile: "laa-\(staff.rawValue)")
            XCTAssertNotNil(assets.avatar, "Missing avatar for \(staff.rawValue)")
            XCTAssertNotNil(assets.hero, "Missing hero for \(staff.rawValue)")
            XCTAssertNotNil(assets.loop, "Missing loop for \(staff.rawValue)")
        }
        XCTAssertNotNil(StaffAssetResolver.bundled.resolve(profile: "default").defaultMark)
    }

    func testLoopRequiresEveryPlaybackCondition() {
        var policy = StaffAvatarPlaybackPolicy(visible: true, active: true, reduceMotion: false,
                                               lowPower: false, scrolling: false, hasLoop: true)
        XCTAssertTrue(policy.shouldPlay)
        policy.visible = false; XCTAssertFalse(policy.shouldPlay); policy.visible = true
        policy.active = false; XCTAssertFalse(policy.shouldPlay); policy.active = true
        policy.reduceMotion = true; XCTAssertFalse(policy.shouldPlay); policy.reduceMotion = false
        policy.lowPower = true; XCTAssertFalse(policy.shouldPlay); policy.lowPower = false
        policy.scrolling = true; XCTAssertFalse(policy.shouldPlay); policy.scrolling = false
        policy.hasLoop = false; XCTAssertFalse(policy.shouldPlay)
    }

    func testUnavailableVoiceExplainsTheActualSetupIssue() {
        XCTAssertEqual(LAAEmployeeCallAvailability.voiceReason(.voiceOff), "音声をオンにしてください")
        XCTAssertEqual(LAAEmployeeCallAvailability.voiceReason(.speechRecognitionDenied), "音声認識を許可してください")
        XCTAssertEqual(LAAEmployeeCallAvailability.voiceReason(.noSpeechToText(detail: nil)), "音声入力を設定してください")
        XCTAssertEqual(LAAEmployeeCallAvailability.voiceReason(.noTextToSpeech), "音声出力を設定してください")
    }

    func testPairingFailureExplainsItsState() {
        XCTAssertNil(LAAEmployeeCallAvailability.bridgeReason(.paired))
        XCTAssertEqual(LAAEmployeeCallAvailability.bridgeReason(.unpaired), "端末を接続すると通話できます")
        XCTAssertEqual(LAAEmployeeCallAvailability.bridgeReason(.revoked), "端末を再接続してください")
        XCTAssertEqual(LAAEmployeeCallAvailability.bridgeReason(.unauthorized), "端末を再接続してください")
        XCTAssertEqual(LAAEmployeeCallAvailability.bridgeReason(.keychainError), "接続情報を読み込めません")
    }

    func testCallRetainsConversationAndLateEventsCannotResurrectIt() {
        let control = FakeControl()
        let calls = LAAEmployeeCallCoordinator(control: control)
        calls.start(profile: "laa-ciel", name: "Ciel", conversationID: "chat-one")
        let initial = try! XCTUnwrap(calls.snapshot)
        XCTAssertEqual(initial.context.conversationID, "chat-one")
        XCTAssertTrue(calls.isShowingCall)
        control.publish(phase: .connected)
        calls.showChat()
        XCTAssertFalse(calls.isShowingCall)
        calls.showCall()
        XCTAssertTrue(calls.isShowingCall)
        calls.toggleMute(); XCTAssertEqual(control.requestedMute, true)
        calls.toggleSpeaker(); XCTAssertEqual(control.requestedSpeaker, true)
        calls.end(); XCTAssertEqual(calls.snapshot?.phase, .ending)
        calls.end(); XCTAssertEqual(control.endCount, 1)
        control.publish(phase: .connected)
        XCTAssertEqual(calls.snapshot?.phase, .ending)
        control.publish(phase: .ended)
        XCTAssertNil(calls.snapshot)
        XCTAssertFalse(calls.isShowingCall)
        control.onUpdate?(initial)
        XCTAssertNil(calls.snapshot)
    }

    func testUnavailableAndOtherCallCannotStartAndFailureCanClose() {
        let control = FakeControl()
        let calls = LAAEmployeeCallCoordinator(control: control)
        control.unavailableReason = "未接続"
        calls.start(profile: "laa-ciel", name: "Ciel", conversationID: nil)
        XCTAssertNil(calls.snapshot)
        control.unavailableReason = nil
        calls.start(profile: "laa-ciel", name: "Ciel", conversationID: nil)
        let first = calls.snapshot?.context.id
        calls.start(profile: "laa-cfo", name: "Morgan", conversationID: "other")
        XCTAssertEqual(calls.snapshot?.context.id, first)
        control.publish(phase: .failed("接続できません"))
        control.publish(phase: .connected)
        XCTAssertEqual(calls.snapshot?.phase, .failed("接続できません"))
        calls.end()
        XCTAssertNil(calls.snapshot)
        XCTAssertFalse(calls.isShowingCall)
    }

    func testMeasuredLevelAndElapsedAreBounded() {
        XCTAssertEqual(LAAEmployeeCallView.level(nil), 0)
        XCTAssertEqual(LAAEmployeeCallView.level(.nan), 0)
        XCTAssertEqual(LAAEmployeeCallView.level(-1), 0)
        XCTAssertEqual(LAAEmployeeCallView.level(2), 1)
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(LAAEmployeeCallView.elapsed(since: start, now: start.addingTimeInterval(61)), "01:01")
        XCTAssertEqual(LAAEmployeeCallView.elapsed(since: start, now: start.addingTimeInterval(-1)), "00:00")
    }

    func testAudioRouteLabelsUseTheActualOutputName() {
        XCTAssertEqual(LAAAudioRouteLabel.labels([]), "出力先なし")
        XCTAssertEqual(LAAAudioRouteLabel.label(type: .builtInReceiver, name: "Receiver"), "受話口")
        XCTAssertEqual(LAAAudioRouteLabel.label(type: .builtInSpeaker, name: "Speaker"), "スピーカー")
        XCTAssertEqual(LAAAudioRouteLabel.label(type: .bluetoothHFP, name: " Ciel’s AirPods "), "Ciel’s AirPods")
        XCTAssertEqual(LAAAudioRouteLabel.label(type: .bluetoothA2DP, name: ""), "Bluetooth")
        XCTAssertEqual(LAAAudioRouteLabel.label(type: .headphones, name: "Headphones"), "Headphones")
        XCTAssertEqual(LAAAudioRouteLabel.labels([(.builtInSpeaker, "Speaker"), (.bluetoothLE, "AirPods")]), "スピーカー・AirPods")
    }
}

@MainActor
private final class FakeControl: LAAEmployeeCallControlling {
    var unavailableReason: String?
    var onUpdate: ((LAAEmployeeCallSnapshot) -> Void)?
    var context: LAAEmployeeCallContext?
    var requestedMute: Bool?
    var requestedSpeaker: Bool?
    var endCount = 0
    func start(_ context: LAAEmployeeCallContext) { self.context = context }
    func setMuted(_ muted: Bool) { requestedMute = muted }
    func setSpeaker(_ speaker: Bool) { requestedSpeaker = speaker }
    func end() { endCount += 1 }
    func publish(phase: LAAEmployeeCallPhase) {
        guard let context else { return }
        onUpdate?(LAAEmployeeCallSnapshot(context: context, phase: phase))
    }
}
#endif
