#if LAA_BUILD
import XCTest
@testable import Conduit

@MainActor
final class LAAEmployeeGPTLiveTests: XCTestCase {
    func testEightDefaultsAreDistinctChatGPTVoices() throws {
        let voices = Set(GPTLiveVoice.all.map(\.name))
        let plans = try LAAStaff.allCases.map {
            try XCTUnwrap(LAAEmployeeGPTLivePlan.make(profile: "laa-\($0.rawValue)", savedVoice: nil))
        }
        XCTAssertEqual(Set(plans.map(\.voice)).count, 8)
        XCTAssertTrue(plans.allSatisfy { voices.contains($0.voice) && $0.engine == .gptLive && $0.billing == .subscription })
        XCTAssertNil(LAAEmployeeGPTLivePlan.make(profile: "default", savedVoice: nil))
        XCTAssertEqual(LAAEmployeeGPTLivePlan.make(profile: "laa-ciel", savedVoice: "marin")?.voice, LAAStaff.ciel.defaultGPTLiveVoice)
        XCTAssertEqual(LAAEmployeeGPTLivePlan.make(profile: "laa-ciel", savedVoice: "cove")?.voice, "cove")
    }

    func testVoiceSettingIsPersistedForTheEmployeeRatherThanTheWorkspace() {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let app = harness.appState
        app.setActiveProfileForTesting("default")
        app.setLAAEmployeeVoice("breeze", profile: "laa-ciel")
        app.setLAAEmployeeVoice("spruce", profile: "laa-cfo")
        app.setLAAEmployeeVoice("marin", profile: "laa-ciel")
        XCTAssertEqual(app.laaEmployeeVoice(profile: "laa-ciel"), "breeze")
        XCTAssertEqual(app.laaEmployeeVoice(profile: "laa-cfo"), "spruce")
        app.setActiveProfileForTesting("laa-ciel")
        XCTAssertEqual(app.gptLiveVoice, "breeze")
        XCTAssertEqual(app.laaEmployeeCallPlan(profile: "laa-cfo")?.voice, "spruce")
    }

    func testClientAndPersonaUseCapturedEmployeeAndSubscription() async throws {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let app = harness.appState
        app.setActiveProfileForTesting("default")
        app.setGPTLiveBilling(.api) // An unrelated workspace preference must never bill this call.
        app.setGeminiLiveEnabled(true)
        XCTAssertEqual(app.laaVoiceResumeEngine(profile: "default"), .geminiLive)
        app.setLAAEmployeeVoice("spruce", profile: "laa-cfo")
        app.laaEmployeeGPTLivePlan = try XCTUnwrap(app.laaEmployeeCallPlan(profile: "laa-cfo"))
        XCTAssertEqual(app.laaVoiceResumeEngine(profile: "default"), .gptLive)
        var personaPath = ""
        let context = app.laaGPTLiveHostContext { path, _, _, _ in
            personaPath = path
            return ["ok": true, "available": true, "text": "Morgan persona"]
        }
        let persona = await context.personality()
        XCTAssertEqual(personaPath, DashboardPath.withProfile(GeminiLiveTokenClient.personalityPath, profile: "laa-cfo"))
        let briefing = GPTLiveConversationController.briefing(personality: persona)
        var requests: [(String, [String: Any]?)] = []
        let client = app.laaGPTLiveClient { path, _, body, _ in
            requests.append((path, body))
            if body == nil { return ["ok": true, "available": true, "auth": "subscription"] }
            return ["ok": true, "auth": "subscription", "transport": ["type": "webrtc", "sdp": "v=0 answer"]]
        }
        let availability = try await client.availability()
        XCTAssertTrue(availability.isAvailable)
        _ = try await client.createSession(offer: "v=0 offer", history: [], voice: app.gptLiveCallVoice, briefing: briefing)
        XCTAssertEqual(requests.map { $0.0 }, [
            DashboardPath.withProfile(GPTLiveClient.statusPath, profile: "laa-cfo"),
            DashboardPath.withProfile(GPTLiveClient.sessionPath, profile: "laa-cfo")
        ])
        XCTAssertEqual(requests.last?.1?["billing"] as? String, "subscription")
        XCTAssertEqual(requests.last?.1?["voice"] as? String, "spruce")
        XCTAssertTrue((requests.last?.1?["briefing"] as? String)?.contains("Morgan persona") == true)
        XCTAssertEqual(app.activeProfile, "default")
        XCTAssertEqual(app.gptLiveCallBilling, .subscription)
        XCTAssertThrowsError(try GPTLiveClient.answer(from: ["ok": true, "auth": "api"], billing: .subscription))

        app.laaEmployeeGPTLivePlan = nil
        app.noteBotChatSessionForTesting("staff-chat", profile: "laa-cfo")
        app.activeSessionId = "staff-chat"
        XCTAssertEqual(app.gptLiveCallBilling, .subscription)
        app.setGPTLiveAPIHermesCalls(true)
        app.pendingHermesCall = HermesCallOpening(kind: nil, title: nil, result: nil)
        XCTAssertEqual(app.gptLiveCallBilling, .api, "an unrelated incoming Hermes call keeps its existing policy")
        app.pendingHermesCall = nil
        app.activeSessionId = nil
        XCTAssertEqual(app.gptLiveCallBilling, .api)
    }

    func testHeaderUsesCallKitThenGPTLiveForBotChatWithoutSwitchingWorkspace() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let previousConsent = LiveVoiceProviderConsent.isGranted(.gptLive)
        LiveVoiceProviderConsent.setGranted(true, for: .gptLive)
        defer { LiveVoiceProviderConsent.setGranted(previousConsent, for: .gptLive) }
        let app = harness.appState
        app.setActiveProfileForTesting("default")
        app.noteBotChatSessionForTesting("staff-chat", profile: "laa-cfo")
        app.activeSessionId = "staff-chat"
        app.gptLiveClient = app.laaGPTLiveClient { _, _, _, _ in
            ["ok": true, "available": false, "auth": "subscription", "reason": "fake offline"]
        }
        let kit = FakePlacedCallKit()
        let placed = makePlacedCallsForTesting(appState: app, kit: kit)
        let control = LAAEmployeeVoiceControl()
        control.bind(app)
        let calls = LAAEmployeeCallCoordinator(control: control)
        calls.start(profile: "laa-cfo", name: "Morgan", conversationID: "staff-chat")
        for _ in 0..<1_000 where !placed.isWaitingForCallAudio { await Task.yield() }
        XCTAssertTrue(placed.isWaitingForCallAudio)
        XCTAssertEqual(app.laaEmployeeGPTLivePlan?.profile, "laa-cfo")
        XCTAssertFalse(app.showGPTLiveSheet)
        let unrelatedIncoming = await app.openVoiceConversation(PendingVoiceIntent(
            profile: "default", startsFreshConversation: false, source: .hermesCall))
        XCTAssertFalse(unrelatedIncoming)
        kit.onPlacedCallStarted?()
        kit.onPlacedCallAudioActivated?()
        for _ in 0..<1_000 where !app.showGPTLiveSheet { await Task.yield() }
        XCTAssertTrue(app.showGPTLiveSheet)
        XCTAssertFalse(app.showVoiceSheet)
        XCTAssertEqual(app.activeProfile, "default")
        XCTAssertEqual(app.voiceBackgroundJobSupervisor.liveThread?.profile, "laa-cfo")
        XCTAssertEqual(app.voiceBackgroundJobSupervisor.liveThread?.runtimeSessionID, "staff-chat")
        XCTAssertNil(app.voiceModeSwitch(for: .gptLive))
        await app.switchVoiceMode(to: .gemini)
        XCTAssertTrue(app.showGPTLiveSheet)
        XCTAssertFalse(app.showGeminiLiveSheet)
        calls.end()
        XCTAssertEqual(app.activeSessionId, "staff-chat")
        XCTAssertNil(app.laaEmployeeGPTLivePlan)
        XCTAssertEqual(kit.endRequests, 1)
        kit.onPlacedCallEnded?(false)
    }

    func testEmployeeWidgetUsesItsProfileAndTheSameCallKitPath() async {
        let suite = "LAAEmployeeGPTLiveWidget.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let dashboard = SavedDashboard(id: UUID(), label: "Test", normalizedURL: "https://example.com")
        let app = AppState(defaults: defaults, loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: dashboard.id, dashboards: [dashboard]))
        app.connection = HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket")
        app.isConnected = true
        app.setActiveProfileForTesting("laa-cto")
        app.setLAAEmployeeVoice("vale", profile: "laa-cto")
        app.gptLiveClient = app.laaGPTLiveClient { _, _, _, _ in
            ["ok": true, "available": false, "auth": "subscription", "reason": "fake offline"]
        }
        let previousConsent = LiveVoiceProviderConsent.isGranted(.gptLive)
        LiveVoiceProviderConsent.setGranted(true, for: .gptLive)
        defer { LiveVoiceProviderConsent.setGranted(previousConsent, for: .gptLive) }
        let kit = FakePlacedCallKit()
        let placed = makePlacedCallsForTesting(appState: app, kit: kit)
        let lease = WidgetLaunchLease(isCurrent: { true })
        let workspace = WidgetWorkspaceID(dashboardID: dashboard.id, profile: "laa-cto")
        let launch = Task { await app.openWidgetVoice(workspace: workspace, lease: lease) }
        for _ in 0..<1_000 where !placed.isWaitingForCallAudio { await Task.yield() }
        XCTAssertTrue(placed.isWaitingForCallAudio)
        XCTAssertEqual(app.laaEmployeeGPTLivePlan?.profile, "laa-cto")
        XCTAssertEqual(app.laaEmployeeGPTLivePlan?.voice, "vale")
        XCTAssertEqual(app.gptLiveCallBilling, .subscription)
        kit.onPlacedCallStarted?()
        kit.onPlacedCallAudioActivated?()
        let outcome = await launch.value
        XCTAssertEqual(outcome, .handled)
        XCTAssertTrue(app.showGPTLiveSheet)
        app.closeGPTLiveConversation()
        XCTAssertNil(app.laaEmployeeGPTLivePlan)
        kit.onPlacedCallEnded?(false)
    }
}
#endif
