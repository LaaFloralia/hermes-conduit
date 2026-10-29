#if LAA_BUILD
import XCTest
import AVFAudio
import Combine
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

    func testCallKitPresentationUsesBundledIconAndStaffNames() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "callkit-icon-template-120", withExtension: "png"))
        let configuration = LAACallKitPresentation.configuration()
        XCTAssertEqual(configuration.iconTemplateImageData, try Data(contentsOf: url))
        XCTAssertEqual(LAACallKitPresentation.localizedName, "LAA")
        for staff in LAAStaff.allCases {
            XCTAssertEqual(LAACallKitPresentation.callerName(profile: "laa-\(staff.rawValue)", fallback: "original"), staff.name)
        }
        XCTAssertEqual(LAACallKitPresentation.callerName(profile: "default", fallback: "original"), "original")
        XCTAssertEqual(LAACallKitPresentation.outgoingUpdate(name: "Talos").localizedCallerName, "Talos")
    }

    func testPlacedCallNameFollowsConversationAndKeepsDefaultName() {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let appState = harness.appState
        appState.setActiveProfileForTesting("default")
        let defaultName = HermesCallerName.name(profile: "default", mainName: appState.profileDisplayName("default"))
        XCTAssertEqual(appState.placedCallName, defaultName)

        appState.noteBotChatSessionForTesting("staff-chat", profile: "laa-cso")
        appState.activeSessionId = "staff-chat"
        XCTAssertEqual(appState.placedCallName, "Talos")

        appState.setActiveProfileForTesting("laa-cfo")
        XCTAssertEqual(appState.placedCallName, "Talos")
        appState.laaEmployeeGPTLivePlan = appState.laaEmployeeCallPlan(profile: "laa-cto")
        XCTAssertEqual(appState.placedCallName, "Ada", "a widget call names its selected employee")
        appState.laaEmployeeGPTLivePlan = nil
        appState.activeSessionId = nil
        XCTAssertEqual(appState.placedCallName, "Morgan")
    }

    func testProviderConsentStartsOnlyAfterAcceptedSheetDismisses() {
        let control = FakeControl()
        control.consent = .geminiLive
        let calls = LAAEmployeeCallCoordinator(control: control)
        calls.start(profile: "laa-ciel", name: "Ciel", conversationID: "chat-one")
        XCTAssertEqual(calls.consentRequest?.mode, .geminiLive)
        XCTAssertNil(calls.snapshot)
        calls.answerConsent(false)
        calls.consentDidDismiss()
        XCTAssertNil(control.context)
        XCTAssertNil(control.grantedConsent)

        calls.start(profile: "laa-ciel", name: "Ciel", conversationID: "chat-one")
        calls.answerConsent(true)
        XCTAssertEqual(control.grantedConsent, .geminiLive)
        XCTAssertNil(calls.snapshot)
        calls.consentDidDismiss()
        XCTAssertEqual(control.context?.conversationID, "chat-one")
        XCTAssertTrue(calls.isShowingCall)
    }

    func testBindingVoiceControlRefreshesAvailability() {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let calls = LAAEmployeeCallCoordinator(control: LAAEmployeeVoiceControl())
        XCTAssertEqual(calls.unavailableReason, "通話を準備中です")
        var notifications = 0
        let observer = calls.objectWillChange.sink { _ in notifications += 1 }
        calls.bindVoiceControl(harness.appState)
        XCTAssertEqual(notifications, 1)
        XCTAssertNil(calls.unavailableReason)
        observer.cancel()
    }

    func testVoiceAdapterTracksRealStatusAndExternalEnd() async {
        let fake = FakeVoiceHost()
        fake.voiceStatus = LAAEmployeeVoiceStatus(phase: .connected, muted: true, speaker: false,
                                                   nativeRoute: true, level: 0.4)
        fake.resolvedConversation = "new-chat"
        let control = LAAEmployeeVoiceControl(host: fake.makeHost())
        let connected = expectation(description: "voice connected")
        let updated = expectation(description: "voice updated")
        let ended = expectation(description: "voice ended externally")
        var snapshots: [LAAEmployeeCallSnapshot] = []
        control.onUpdate = { snapshot in
            snapshots.append(snapshot)
            if snapshot.phase == .connected, snapshots.count == 1 { connected.fulfill() }
            else if snapshot.phase == .connected { updated.fulfill() }
            else if snapshot.phase == .ended { ended.fulfill() }
        }
        let context = LAAEmployeeCallContext(profile: "laa-ciel", name: "Ciel", conversationID: nil)
        control.start(context)
        await fulfillment(of: [connected], timeout: 5)
        XCTAssertEqual(snapshots.last?.context.conversationID, "new-chat")
        XCTAssertEqual(snapshots.last?.audioLevel, 0.4)
        XCTAssertEqual(snapshots.last?.usesSystemRoutePicker, true)
        XCTAssertNotNil(snapshots.last?.connectedAt)
        XCTAssertEqual(fake.beginCount, 1)
        control.setMuted(false)
        control.setSpeaker(true)
        XCTAssertEqual(fake.mute, false)
        XCTAssertEqual(fake.speaker, true)
        fake.voiceStatus.muted = false
        fake.voiceStatus.level = nil
        fake.voiceStatus.voiceNote = "選んだ声を確認できません"
        fake.changed.send()
        await fulfillment(of: [updated], timeout: 5)
        XCTAssertNil(snapshots.last?.audioLevel)
        XCTAssertEqual(snapshots.last?.voiceNote, "選んだ声を確認できません")
        fake.voiceStatus.phase = .ended
        fake.changed.send()
        await fulfillment(of: [ended], timeout: 5)
        XCTAssertEqual(snapshots.last?.phase, .ended)
        XCTAssertEqual(fake.endCount, 0)
    }

    func testEndingPendingVoiceOpenCannotRestartIt() async {
        let fake = FakeVoiceHost()
        fake.holdOpen = true
        let began = expectation(description: "open waiting")
        fake.didBegin = { began.fulfill() }
        let control = LAAEmployeeVoiceControl(host: fake.makeHost())
        var snapshots: [LAAEmployeeCallSnapshot] = []
        control.onUpdate = { snapshots.append($0) }
        let context = LAAEmployeeCallContext(profile: "laa-ciel", name: "Ciel", conversationID: "chat")
        control.start(context)
        await fulfillment(of: [began], timeout: 5)
        control.end()
        fake.pendingOpen?.resume(returning: .opened(context))
        fake.pendingOpen = nil
        await Task.yield()
        XCTAssertEqual(fake.endCount, 1)
        XCTAssertEqual(fake.beginCount, 0)
        XCTAssertEqual(snapshots.map(\.phase), [.ended])
    }

    func testVoiceOpenFailureRemainsAvailableToDismiss() async {
        let fake = FakeVoiceHost()
        fake.failOpen = true
        let control = LAAEmployeeVoiceControl(host: fake.makeHost())
        let calls = LAAEmployeeCallCoordinator(control: control)
        let failed = expectation(description: "voice open failed")
        let observation = calls.$snapshot.sink { snapshot in
            if case .failed = snapshot?.phase { failed.fulfill() }
        }
        calls.start(profile: "laa-ciel", name: "Ciel", conversationID: "chat")
        await fulfillment(of: [failed], timeout: 5)
        calls.showChat()
        calls.showCall()
        XCTAssertTrue(calls.isShowingCall)
        calls.end()
        XCTAssertNil(calls.snapshot)
        XCTAssertEqual(fake.endCount, 1)
        observation.cancel()
    }

    func testDefaultProfileKeepsExistingClassicCallAndChat() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.appState.activeSessionId = "session-1"
        let kit = FakePlacedCallKit()
        let placed = makePlacedCallsForTesting(appState: harness.appState, kit: kit)
        let control = LAAEmployeeVoiceControl()
        control.bind(harness.appState)
        let calls = LAAEmployeeCallCoordinator(control: control)
        calls.start(profile: "default", name: "LAA", conversationID: "session-1")
        for _ in 0..<1_000 where !placed.isWaitingForCallAudio { await Task.yield() }
        XCTAssertTrue(placed.isWaitingForCallAudio)
        XCTAssertFalse(harness.appState.showVoiceSheet)
        kit.onPlacedCallStarted?()
        kit.onPlacedCallAudioActivated?()
        for _ in 0..<1_000 where calls.snapshot?.phase != .connected { await Task.yield() }
        XCTAssertTrue(harness.appState.showVoiceSheet)
        XCTAssertTrue(harness.controller.hasLiveVoiceSession)
        XCTAssertEqual(calls.snapshot?.phase, .connected)
        XCTAssertEqual(calls.snapshot?.context.profile, "default")
        XCTAssertEqual(calls.snapshot?.context.conversationID, "session-1")
        calls.showChat()
        XCTAssertFalse(calls.isShowingCall)
        calls.showCall()
        calls.end()
        XCTAssertFalse(harness.appState.showVoiceSheet)
        XCTAssertNil(calls.snapshot)
        XCTAssertEqual(harness.appState.activeSessionId, "session-1")
        XCTAssertEqual(harness.appState.conversationIdentityProfile, "default")
        XCTAssertEqual(kit.endRequests, 1)
        kit.onPlacedCallEnded?(false)
    }

    func testSystemHangupDuringCallKitActivationReturnsToChat() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.appState.activeSessionId = "session-1"
        let kit = FakePlacedCallKit()
        let placed = makePlacedCallsForTesting(appState: harness.appState, kit: kit)
        let control = LAAEmployeeVoiceControl()
        control.bind(harness.appState)
        let calls = LAAEmployeeCallCoordinator(control: control)
        calls.start(profile: "default", name: "LAA", conversationID: "session-1")
        for _ in 0..<1_000 where !placed.isWaitingForCallAudio { await Task.yield() }
        XCTAssertTrue(placed.isWaitingForCallAudio)
        kit.onPlacedCallStarted?()
        kit.onPlacedCallEnded?(true)
        for _ in 0..<1_000 where calls.snapshot != nil { await Task.yield() }
        XCTAssertNil(calls.snapshot)
        XCTAssertFalse(calls.isShowingCall)
        XCTAssertEqual(harness.appState.activeSessionId, "session-1")
        XCTAssertFalse(harness.appState.showVoiceSheet)
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
        XCTAssertNil(LAAEmployeeCallAvailability.voiceReason(profile: "laa-ciel", canStart: false, issue: .noTextToSpeech))
        XCTAssertEqual(LAAEmployeeCallAvailability.voiceReason(profile: "default", canStart: false, issue: .noTextToSpeech),
                       "音声出力を設定してください")
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
    var consent: LiveVoiceModeName?
    var grantedConsent: LiveVoiceModeName?
    func requiredConsent(for context: LAAEmployeeCallContext) -> LiveVoiceModeName? { consent }
    func grantConsent(_ mode: LiveVoiceModeName) { grantedConsent = mode }
    func start(_ context: LAAEmployeeCallContext) { self.context = context }
    func setMuted(_ muted: Bool) { requestedMute = muted }
    func setSpeaker(_ speaker: Bool) { requestedSpeaker = speaker }
    func end() { endCount += 1 }
    func publish(phase: LAAEmployeeCallPhase) {
        guard let context else { return }
        onUpdate?(LAAEmployeeCallSnapshot(context: context, phase: phase))
    }
}

@MainActor
private final class FakeVoiceHost {
    let changed = PassthroughSubject<Void, Never>()
    var voiceStatus = LAAEmployeeVoiceStatus(phase: .connecting)
    var resolvedConversation: String?
    var holdOpen = false
    var failOpen = false
    var pendingOpen: CheckedContinuation<LAAEmployeeVoiceOpenResult, Never>?
    var didBegin: (() -> Void)?
    var beginCount = 0
    var endCount = 0
    var mute: Bool?
    var speaker: Bool?

    func makeHost() -> LAAEmployeeVoiceHost {
        LAAEmployeeVoiceHost(
            unavailable: { nil }, consent: { _ in nil }, grant: { _ in },
            open: { context in
                if self.failOpen { return .failed }
                if self.holdOpen {
                    return await withCheckedContinuation { continuation in
                        self.pendingOpen = continuation
                        self.didBegin?()
                    }
                }
                return .opened(LAAEmployeeCallContext(id: context.id, profile: context.profile, name: context.name,
                                                      conversationID: self.resolvedConversation ?? context.conversationID))
            },
            status: { self.voiceStatus },
            observe: { changed in [self.changed.sink { _ in changed() }] },
            beginClassicListening: { self.beginCount += 1 },
            mute: { self.mute = $0 }, speaker: { self.speaker = $0 },
            end: { self.endCount += 1 }
        )
    }
}
#endif
