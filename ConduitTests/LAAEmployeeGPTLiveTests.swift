#if LAA_BUILD
import Combine
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

    func testPreviouslySavedAPIBillingCannotChangeAnLAACall() async throws {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let app = harness.appState
        app.setActiveProfileForTesting("default")
        let key = "conduit.voice.preferences.v1.https://example.com.default"
        var previous = VoiceProfilePreferences()
        previous.gptLiveBilling = .api
        previous.gptLiveAPIHermesCalls = true
        previous.gptLiveVoice = "ember"
        previous.gptLiveAPIVoice = "cedar"
        harness.defaults.set(try JSONEncoder().encode(previous), forKey: key)

        XCTAssertEqual(app.activeProfileVoicePreferences.gptLiveBilling, .api)
        XCTAssertEqual(app.gptLiveBilling, .subscription)
        XCTAssertEqual(app.gptLiveCallBilling, .subscription)
        XCTAssertEqual(app.gptLiveCallVoice, "ember")
        app.pendingHermesCall = HermesCallOpening(kind: nil, title: nil, result: nil)
        XCTAssertEqual(app.gptLiveCallBilling, .subscription)
        app.pendingHermesCall = nil

        var requestBody: [String: Any]?
        let client = app.laaGPTLiveClient { _, _, body, _ in
            requestBody = body
            return ["ok": true, "auth": "subscription", "transport": ["type": "webrtc", "sdp": "v=0 answer"]]
        }
        _ = try await client.createSession(offer: "v=0 offer", history: [], voice: app.gptLiveCallVoice, briefing: nil)
        XCTAssertEqual(requestBody?["billing"] as? String, "subscription")
        XCTAssertEqual(requestBody?["voice"] as? String, "ember")
        XCTAssertEqual(app.activeProfileVoicePreferences.gptLiveBilling, .api, "The saved setting is retained")

        harness.defaults.removeObject(forKey: key)
        app.setGPTLiveBilling(.api)
        XCTAssertNil(app.storedActiveVoicePreferencesData, "LAA cannot opt in to API billing")
        XCTAssertEqual(app.gptLiveCallBilling, .subscription)
    }

    func testClientAndPersonaUseCapturedEmployeeAndSubscription() async throws {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let app = harness.appState
        app.setActiveProfileForTesting("default")
        app.setGPTLiveBilling(.api) // The LAA build does not opt in to API billing.
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
        XCTAssertEqual(app.gptLiveCallBilling, .subscription, "Hermes calls also use the ChatGPT plan")
        app.pendingHermesCall = nil
        app.activeSessionId = nil
        XCTAssertEqual(app.gptLiveCallBilling, .subscription)
    }

    func testEmployeeScopeDoesNotInheritWorkspaceHealthOrPhoneGrants() async throws {
        let suite = "LAAEmployeeScope.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dashboard = SavedDashboard(id: UUID(), label: "Test", normalizedURL: "https://example.com")
        let app = AppState(defaults: defaults, loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: dashboard.id, dashboards: [dashboard]))
        app.phoneSync = PhoneSyncEngine(calendarSource: EventKitPhoneSource(), statusSource: DevicePhoneStatusSource(), defaults: defaults)
        let workspace = VoiceHostToolScope(dashboardID: dashboard.id, profile: "default")
        let employee = VoiceHostToolScope(dashboardID: dashboard.id, profile: "laa-cfo")
        let otherDashboard = VoiceHostToolScope(dashboardID: UUID(), profile: "laa-cfo")
        let workspaceDestination = HealthSyncDestination(dashboardID: dashboard.id, profile: "default", host: "example.com")
        let employeeDestination = HealthSyncDestination(dashboardID: dashboard.id, profile: "laa-cfo", host: "example.com")
        var health = HealthSyncPreferences()
        health.destination = workspaceDestination
        health.categories = [.sleep]
        health.setVoiceRead(.gptLive, allowed: true)
        app.healthSyncPreferences = health
        XCTAssertTrue(app.voiceReadableKeys(for: .gptLive, scope: workspace).contains("health"))
        XCTAssertFalse(app.voiceReadableKeys(for: .gptLive, scope: employee).contains("health"))
        let healthTool = VoiceHostTool(name: "conduit_health", description: "", parameters: [:], key: "health")
        let deniedHealth = await app.callVoiceHostTool(healthTool, arguments: [:], mode: .gptLive, scope: employee)
        XCTAssertNotNil(deniedHealth["error"])

        var phone = PhoneSyncPreferences()
        phone.destination = workspaceDestination
        phone.calendar = .full
        app.phoneSync.savePreferences(phone)
        XCTAssertFalse(app.phoneVoiceSettingHint(for: .gptLive, scope: workspace).isEmpty)
        XCTAssertTrue(app.phoneVoiceSettingHint(for: .gptLive, scope: employee).isEmpty)
        phone.setVoiceUse(.gptLive, allowed: true)
        app.phoneSync.savePreferences(phone)
        let phoneTool = VoiceHostTool(name: "conduit_phone", description: "", parameters: [:], key: "phone")
        let deniedPhone = await app.callVoiceHostTool(phoneTool, arguments: [:], mode: .gptLive, scope: employee)
        XCTAssertNotNil(deniedPhone["error"])
        phone.destination = employeeDestination
        phone.setVoiceUse(.gptLive, allowed: false)
        app.phoneSync.savePreferences(phone)
        XCTAssertFalse(app.phoneVoiceSettingHint(for: .gptLive, scope: employee).isEmpty)
        XCTAssertTrue(app.phoneVoiceSettingHint(for: .gptLive, scope: workspace).isEmpty)

        health.destination = employeeDestination
        app.healthSyncPreferences = health
        XCTAssertTrue(app.voiceReadableKeys(for: .gptLive, scope: employee).contains("health"))
        XCTAssertFalse(app.voiceReadableKeys(for: .gptLive, scope: workspace).contains("health"))
        XCTAssertFalse(app.voiceReadableKeys(for: .gptLive, scope: otherDashboard).contains("health"))
        XCTAssertFalse(employee.matches(employeeDestination, currentDashboardID: UUID()))
    }

    func testEmployeeToolPreparationClearsOldToolsAndExpiresTheirRunner() async throws {
        let suite = "LAAEmployeeTools.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dashboard = SavedDashboard(id: UUID(), label: "Test", normalizedURL: "https://example.com")
        let app = AppState(defaults: defaults, loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: dashboard.id, dashboards: [dashboard]))
        app.healthSyncPreferences = HealthSyncPreferences()
        app.phoneSync = PhoneSyncEngine(calendarSource: EventKitPhoneSource(), statusSource: DevicePhoneStatusSource(), defaults: defaults)
        let supervisor = app.voiceBackgroundJobSupervisor
        supervisor.hostToolsMode = .gptLive
        supervisor.hostTools = [VoiceHostTool(name: "conduit_health", description: "", parameters: [:], key: "health")]
        var current = true
        await app.prepareVoiceHostTools(for: .gptLive,
            scope: VoiceHostToolScope(dashboardID: dashboard.id, profile: "laa-cfo"), isCurrent: { current })
        XCTAssertFalse(supervisor.hostTools.contains { $0.key == "health" })
        XCTAssertTrue(supervisor.hostTools.contains { $0.key == MapsVoiceTool.key })
        current = false
        let expired = await supervisor.callHostTool(MapsVoiceTool.tool, arguments: [:])
        XCTAssertNotNil(expired["error"])
    }

    func testEmployeeClientFencesPlanChangesBeforeAndDuringRequests() async throws {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let app = harness.appState
        let original = try XCTUnwrap(app.laaEmployeeCallPlan(profile: "laa-cfo"))
        let replacement = try XCTUnwrap(app.laaEmployeeCallPlan(profile: "laa-ciel"))
        app.laaEmployeeGPTLivePlan = original
        var paths: [String] = []
        var pending: CheckedContinuation<[String: Any], Never>?
        let client = app.laaGPTLiveClient { path, _, _, _ in
            paths.append(path)
            return await withCheckedContinuation { pending = $0 }
        }.captured(profile: original.profile, billing: original.billing, isCurrent: {
            app.laaEmployeeGPTLivePlan == original
        })
        app.laaEmployeeGPTLivePlan = replacement
        do {
            _ = try await client.createSession(offer: "offer", history: [])
            XCTFail("An expired call must not start a request")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(paths.isEmpty)

        app.laaEmployeeGPTLivePlan = original
        let request = Task { try await client.createSession(offer: "offer", history: []) }
        for _ in 0..<1_000 where pending == nil { await Task.yield() }
        guard let pending else {
            app.laaEmployeeGPTLivePlan = nil
            request.cancel()
            XCTFail("The fake request did not start")
            return
        }
        XCTAssertEqual(paths, [DashboardPath.withProfile(GPTLiveClient.sessionPath, profile: "laa-cfo")])
        app.laaEmployeeGPTLivePlan = replacement
        pending.resume(returning: ["ok": true, "auth": "subscription", "transport": ["type": "webrtc", "sdp": "answer"]])
        do {
            _ = try await request.value
            XCTFail("A late response must not revive an expired call")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testEmployeePersonalityRetriesTransientFailureAndExplainsMissingData() async throws {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let app = harness.appState
        let plan = try XCTUnwrap(app.laaEmployeeCallPlan(profile: "laa-cfo"))
        app.laaEmployeeGPTLivePlan = plan
        var paths: [String] = []
        let transient = app.laaGPTLiveHostContext { path, _, _, _ in
            paths.append(path)
            if paths.count == 1 { throw URLError(.timedOut) }
            return ["ok": true, "available": true, "text": "Morgan persona"]
        }.captured(profile: plan.profile)
        let loaded = await app.laaEmployeePersonality(transient, plan: plan)
        XCTAssertEqual(loaded, .available("Morgan persona"))
        XCTAssertEqual(paths, Array(repeating: DashboardPath.withProfile(GeminiLiveTokenClient.personalityPath, profile: "laa-cfo"), count: 2))

        let missingRoute = app.laaGPTLiveHostContext { _, _, _, _ in
            throw DashboardTicketBridgeError.http(status: 404, detail: "")
        }.captured(profile: plan.profile)
        let missingRouteResult = await app.laaEmployeePersonality(missingRoute, plan: plan)
        XCTAssertEqual(missingRouteResult, .missingRoute)
        let noPersona = app.laaGPTLiveHostContext { _, _, _, _ in
            ["ok": true, "available": false]
        }.captured(profile: plan.profile)
        let noPersonaResult = await app.laaEmployeePersonality(noPersona, plan: plan)
        XCTAssertEqual(noPersonaResult, .missingPersona)
        var stoppedRequests = 0
        let stopped = app.laaGPTLiveHostContext { _, _, _, _ in
            stoppedRequests += 1
            app.laaEmployeeGPTLivePlan = nil
            throw URLError(.timedOut)
        }.captured(profile: plan.profile)
        _ = await app.laaEmployeePersonality(stopped, plan: plan)
        XCTAssertEqual(stoppedRequests, 1)
    }

    func testEmployeeStylePhrasesRecordingAndResumeUseEmployeeProfile() async throws {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let app = harness.appState
        app.setActiveProfileForTesting("default")
        app.setLiveVoiceStyle(LiveVoiceStyle(greeting: "workspace"), profile: "default")
        XCTAssertTrue(app.setSpokenEndConversationPhrases(["workspace goodbye"]))
        app.setActiveProfileForTesting("laa-cfo")
        let employeeStyle = LiveVoiceStyle(tone: .professional, greeting: "Morgan", asksBeforeSending: true)
        app.setLiveVoiceStyle(employeeStyle, profile: "laa-cfo")
        XCTAssertTrue(app.setSpokenEndConversationPhrases(["Morgan goodbye"]))
        app.setActiveProfileForTesting("default")
        app.noteBotChatSessionForTesting("staff-chat", profile: "laa-cfo")
        app.activeSessionId = "staff-chat"
        app.laaEmployeeGPTLivePlan = try XCTUnwrap(app.laaEmployeeCallPlan(profile: "laa-cfo"))
        XCTAssertEqual(app.liveVoiceStyle, employeeStyle)
        XCTAssertEqual(app.gptLiveEndConversationPhrases, ["Morgan goodbye"])
        app.beginVoiceCallRecordingForTesting(engine: .gptLive, turns: [])
        XCTAssertEqual(app.voiceCallRecorderProfileForTesting, "laa-cfo")
        XCTAssertTrue(app.voiceBackgroundJobSupervisor.asksBeforeSending)

        var readProfile: String?
        app.voiceResumeContextReaderForTesting = { _, profile in
            readProfile = profile
            app.laaEmployeeGPTLivePlan = nil
            return nil
        }
        let resumed = await app.resumeVoiceCall(sessionID: "saved-call")
        app.voiceResumeContextReaderForTesting = nil
        XCTAssertEqual(readProfile, "laa-cfo")
        XCTAssertFalse(resumed, "A changed plan must not resume a stale call")
        XCTAssertEqual(app.liveVoiceStyle.greeting, "workspace")
        XCTAssertEqual(app.gptLiveEndConversationPhrases, ["workspace goodbye"])
        app.closeGPTLiveConversation()
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
        let pendingPlan = app.laaEmployeeGPTLivePlan
        let threadBeforeCarPlay = app.voiceBackgroundJobSupervisor.liveThread
        let carThread = VoiceThreadTarget(runtimeSessionID: "car-chat", storedSessionID: nil, title: "Car")
        await app.startGPTLiveForCarPlay(attachingTo: carThread)
        XCTAssertEqual(app.laaEmployeeGPTLivePlan, pendingPlan)
        XCTAssertEqual(app.voiceBackgroundJobSupervisor.liveThread, threadBeforeCarPlay)
        XCTAssertNil(app.voiceCallRecorderProfileForTesting)
        XCTAssertFalse(app.isGPTLiveActive)
        XCTAssertTrue(placed.isWaitingForCallAudio)
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
        for _ in 0..<1_000 {
            if case .failed = app.gptLiveController.phase { break }
            await Task.yield()
        }
        guard case .failed = app.gptLiveController.phase else {
            calls.end()
            kit.onPlacedCallEnded?(false)
            XCTFail("The fake GPT-Live failure did not arrive")
            return
        }
        XCTAssertFalse(app.isGPTLiveActive)
        XCTAssertFalse(app.hasScheduledLiveVoiceStart)
        app.installLiveVoiceHostContextForTesting()
        XCTAssertNotNil(app.voiceCallRecorderProfileForTesting)
        calls.end()
        XCTAssertEqual(app.activeSessionId, "staff-chat")
        XCTAssertNil(app.laaEmployeeGPTLivePlan)
        XCTAssertFalse(app.showGPTLiveSheet)
        XCTAssertNil(app.voiceCallRecorderProfileForTesting)
        XCTAssertFalse(app.liveVoiceHostContextForTesting.contains("gptMemory"))
        XCTAssertFalse(app.liveVoiceHostContextForTesting.contains("gptPersona"))
        XCTAssertNil(app.voiceBackgroundJobSupervisor.liveThread)
        XCTAssertEqual(kit.endRequests, 1)
        kit.onPlacedCallEnded?(false)
    }

    func testCarPlayDoesNotTakeAPlanCreatedWhileItsStartWaits() async throws {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let previousConsent = LiveVoiceProviderConsent.isGranted(.gptLive)
        LiveVoiceProviderConsent.setGranted(true, for: .gptLive)
        defer { LiveVoiceProviderConsent.setGranted(previousConsent, for: .gptLive) }
        let app = harness.appState
        app.setGPTLiveEnabled(true)
        app.gptLiveClient = app.laaGPTLiveClient { _, _, _, _ in
            ["ok": true, "available": false, "auth": "subscription", "reason": "fake offline"]
        }
        let plan = try XCTUnwrap(app.laaEmployeeCallPlan(profile: "laa-cfo"))
        let originalThread = VoiceThreadTarget(runtimeSessionID: "phone-chat", storedSessionID: nil, title: "Phone")
        app.voiceBackgroundJobSupervisor.attachLiveThread(originalThread)
        harness.coordinator.handleConnect(harness.spy)
        defer { harness.coordinator.handleDisconnect() }
        await harness.coordinator.waitForPresentation()
        harness.coordinator.liveCallStartGate = { app.laaEmployeeGPTLivePlan = plan }
        await harness.coordinator.establishVoice(generation: harness.coordinator.connectionGeneration)
        XCTAssertEqual(app.laaEmployeeGPTLivePlan, plan)
        XCTAssertEqual(app.voiceBackgroundJobSupervisor.liveThread, originalThread)
        XCTAssertNil(app.voiceCallRecorderProfileForTesting)
        XCTAssertFalse(app.isGPTLiveActive)

        let row = CarPlayChatRow(sessionID: "car-chat", storedSessionID: nil, title: "Car", detail: "")
        await harness.coordinator.performOpenChat(row, generation: harness.coordinator.connectionGeneration)
        XCTAssertNil(harness.coordinator.chosenChat)
        XCTAssertEqual(app.laaEmployeeGPTLivePlan, plan)
        XCTAssertEqual(app.voiceBackgroundJobSupervisor.liveThread, originalThread)
        harness.coordinator.endTapped()
        XCTAssertEqual(app.laaEmployeeGPTLivePlan, plan)
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
        let widgetPlan = app.laaEmployeeGPTLivePlan
        app.noteBotChatSessionForTesting("morgan-chat", profile: "laa-cfo")
        app.activeSessionId = "morgan-chat"
        let control = LAAEmployeeVoiceControl()
        control.bind(app)
        let calls = LAAEmployeeCallCoordinator(control: control)
        XCTAssertFalse(app.isVoiceCallInProgress, "CallKit is still waiting for audio")
        XCTAssertEqual(LAAEmployeeCallAvailability.reason(appState: app, bridge: .paired, calls: calls),
                       "別の通話を終了してください")
        XCTAssertFalse(calls.startEmployeeConversation(app))
        XCTAssertNil(calls.snapshot)
        XCTAssertEqual(app.laaEmployeeGPTLivePlan, widgetPlan)
        XCTAssertTrue(placed.isWaitingForCallAudio)
        kit.onPlacedCallStarted?()
        kit.onPlacedCallAudioActivated?()
        let outcome = await launch.value
        XCTAssertEqual(outcome, .handled)
        XCTAssertTrue(app.showGPTLiveSheet)
        app.closeGPTLiveConversation()
        XCTAssertNil(app.laaEmployeeGPTLivePlan)
        kit.onPlacedCallEnded?(false)
    }

    func testPhoneOpenCannotTakeOrEndAPlanCreatedBeforeItsAsyncStart() async throws {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let previousConsent = LiveVoiceProviderConsent.isGranted(.gptLive)
        LiveVoiceProviderConsent.setGranted(true, for: .gptLive)
        defer { LiveVoiceProviderConsent.setGranted(previousConsent, for: .gptLive) }
        let app = harness.appState
        app.setActiveProfileForTesting("default")
        app.noteBotChatSessionForTesting("morgan-chat", profile: "laa-cfo")
        app.activeSessionId = "morgan-chat"
        let kit = FakePlacedCallKit()
        _ = makePlacedCallsForTesting(appState: app, kit: kit)
        let control = LAAEmployeeVoiceControl()
        control.bind(app)
        let calls = LAAEmployeeCallCoordinator(control: control)
        XCTAssertTrue(calls.startEmployeeConversation(app))
        // The phone's Task has not run yet; a widget/Siri launch takes the
        // plan before that Task enters the real AppState host.
        let widgetPlan = try XCTUnwrap(app.laaEmployeeCallPlan(profile: "laa-cto"))
        app.laaEmployeeGPTLivePlan = widgetPlan
        for _ in 0..<1_000 {
            if case .failed? = calls.snapshot?.phase { break }
            await Task.yield()
        }
        if case .failed? = calls.snapshot?.phase {} else {
            XCTFail("The later phone open must be rejected")
        }
        XCTAssertEqual(app.laaEmployeeGPTLivePlan, widgetPlan)
        calls.end()
        XCTAssertEqual(app.laaEmployeeGPTLivePlan, widgetPlan)
        XCTAssertEqual(kit.endRequests, 0)
        XCTAssertFalse(app.showGPTLiveSheet)
        kit.onPlacedCallEnded?(false)
    }

    func testComposerUpdatesWhenAnEmployeePlanAppearsAndClears() async throws {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let app = harness.appState
        let updates = ComposerUpdates(app)
        let initial = updates.inputs
        let appeared = expectation(description: "pending call makes the composer update")
        let first = updates.objectWillChange.sink { _ in appeared.fulfill() }
        app.laaEmployeeGPTLivePlan = try XCTUnwrap(app.laaEmployeeCallPlan(profile: "laa-cto"))
        await fulfillment(of: [appeared], timeout: 5)
        first.cancel()
        XCTAssertNotEqual(updates.inputs, initial)
        let cleared = expectation(description: "cleared call makes the composer update")
        let second = updates.objectWillChange.sink { _ in cleared.fulfill() }
        app.laaEmployeeGPTLivePlan = nil
        await fulfillment(of: [cleared], timeout: 5)
        second.cancel()
        XCTAssertEqual(updates.inputs, initial)
    }

    func testConsentCannotStartASecondCallWhileAWidgetPlanWaits() throws {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let previousConsent = LiveVoiceProviderConsent.isGranted(.gptLive)
        LiveVoiceProviderConsent.setGranted(false, for: .gptLive)
        defer { LiveVoiceProviderConsent.setGranted(previousConsent, for: .gptLive) }
        let app = harness.appState
        app.noteBotChatSessionForTesting("morgan-chat", profile: "laa-cfo")
        app.activeSessionId = "morgan-chat"
        let control = LAAEmployeeVoiceControl()
        control.bind(app)
        let calls = LAAEmployeeCallCoordinator(control: control)
        XCTAssertTrue(calls.startEmployeeConversation(app))
        XCTAssertNotNil(calls.consentRequest)
        let widgetPlan = try XCTUnwrap(app.laaEmployeeCallPlan(profile: "laa-cto"))
        app.laaEmployeeGPTLivePlan = widgetPlan
        calls.answerConsent(true)
        calls.consentDidDismiss()
        XCTAssertNil(calls.snapshot)
        XCTAssertEqual(app.laaEmployeeGPTLivePlan, widgetPlan)
    }
}
#endif
