#if LAA_BUILD
import Combine
import XCTest
@testable import Conduit

/// Employee calls: the plan a call captures, the engine the Mac chooses for
/// it (Gemini Live or Local Live, never GPT-Live), and the phone's start
/// paths around that plan.
@MainActor
final class LAAEmployeeCallPlanTests: XCTestCase {
    private var savedConfig: LAAStaffCallEngineConfig!
    private var savedRead: (@MainActor () async throws -> LAAStaffCallEngineConfig)!

    /// The Mac's answer in these tests, never the real Bridge.
    private static func config(gemini: Bool, local: Bool = true,
                               order: [LAAStaffCallEngineName] = [.geminiLive, .localLive]) -> LAAStaffCallEngineConfig {
        LAAStaffCallEngineConfig(order: order, engines: [
            LAAStaffCallEngineName.geminiLive.rawValue: .init(enabled: gemini, code: gemini ? nil : "waiting_for_contract"),
            LAAStaffCallEngineName.localLive.rawValue: .init(enabled: local, code: local ? nil : "switched_off"),
        ])
    }

    private func useEngines(gemini: Bool, local: Bool = true) {
        let config = Self.config(gemini: gemini, local: local)
        LAAStaffCallEngineStore.shared.persists = false
        LAAStaffCallEngineStore.shared.read = { config }
        LAAStaffCallEngineStore.shared.adopt(config)
    }

    /// A speech server that answers "not available", so a Local Live call
    /// opens its screen and fails without a socket.
    private func offlineLocalLive(_ app: AppState) {
        app.localLiveClient = LocalLiveClient(
            request: { _, _, _, _ in ["ok": true, "available": false, "reason": "fake offline"] },
            mintTicket: { throw DashboardTicketBridgeError.notReady },
            socketRequest: { _, _ in throw DashboardTicketBridgeError.notReady })
    }

    override func setUp() async throws {
        try await super.setUp()
        savedConfig = LAAStaffCallEngineStore.shared.config
        savedRead = LAAStaffCallEngineStore.shared.read
        useEngines(gemini: false)
    }

    override func tearDown() async throws {
        LAAStaffCallEngineStore.shared.read = savedRead
        LAAStaffCallEngineStore.shared.adopt(savedConfig)
        LAAStaffCallEngineStore.shared.persists = true
        try await super.tearDown()
    }

    // MARK: The plan

    func testSevenDefaultsAreDistinctGeminiVoicesAndLocalLiveHasNone() throws {
        let voices = Set(GeminiLiveVoice.all.map(\.name))
        let callable = LAAStaff.allCases.filter { $0.supportsCalls }
        let gemini = try callable.map {
            try XCTUnwrap(LAAEmployeeCallPlan.make(profile: "laa-\($0.rawValue)", engine: .geminiLive, savedVoice: nil))
        }
        XCTAssertEqual(Set(gemini.compactMap(\.voice)).count, 7)
        XCTAssertTrue(gemini.allSatisfy { $0.voice.map(voices.contains) == true && $0.engine == .geminiLive })
        let local = try callable.map {
            try XCTUnwrap(LAAEmployeeCallPlan.make(profile: "laa-\($0.rawValue)", engine: .localLive, savedVoice: "Kore"))
        }
        XCTAssertTrue(local.allSatisfy { $0.voice == nil && $0.engine == .localLive }, "Local Live speaks in the speech server's voice")
        XCTAssertNil(LAAEmployeeCallPlan.make(profile: "default", engine: .localLive, savedVoice: nil))
        XCTAssertNil(LAAEmployeeCallPlan.make(profile: "laa-monet-uncensored", engine: .localLive, savedVoice: nil))
        XCTAssertNil(LAAEmployeeCallPlan.make(profile: "laa-monet-dots", engine: .geminiLive, savedVoice: "Kore"))
        XCTAssertEqual(LAAEmployeeCallPlan.make(profile: "laa-monet", engine: .geminiLive, savedVoice: "vale")?.voice,
                       LAAStaff.monet.defaultCallVoice(engine: .geminiLive), "A voice Gemini doesn't have falls back to the employee's own")
        XCTAssertEqual(LAAEmployeeCallPlan.make(profile: "laa-monet", engine: .geminiLive, savedVoice: "Kore")?.voice, "Kore")
    }

    func testNoPlanCanNameGPTLiveOrAnotherEngine() {
        for engine in [VoiceCallEngine.gptLive, .grokLive, .qwenLive] {
            XCTAssertNil(LAAEmployeeCallPlan.make(profile: "laa-monet", engine: engine, savedVoice: nil), "\(engine)")
        }
        XCTAssertEqual(LAAEmployeeCallPlan.engines, [.geminiLive, .localLive])
        XCTAssertFalse(VoiceModeChoice.offered.contains(.gpt), "LAA builds don't offer GPT-Live")
    }

    func testCallIdentityNamesNoModelOrProduct() {
        for staff in LAAStaff.allCases {
            let identity = staff.callIdentity
            XCTAssertTrue(identity.contains("You are \(staff.name)"))
            XCTAssertTrue(identity.contains("Never deny using AI technology"))
            XCTAssertFalse(identity.contains("GPT-Live"))
            XCTAssertFalse(identity.contains("runs on Gemini"))
        }
    }

    func testVoiceSettingIsPersistedForTheEmployeeRatherThanTheWorkspace() {
        useEngines(gemini: true)
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let app = harness.appState
        app.setActiveProfileForTesting("default")
        let workspaceVoice = app.geminiLiveVoice
        app.setLAAEmployeeVoice("Kore", profile: "laa-monet")
        app.setLAAEmployeeVoice("Fenrir", profile: "laa-cfo")
        app.setLAAEmployeeVoice("not-a-voice", profile: "laa-cto")
        XCTAssertEqual(app.laaEmployeeVoice(profile: "laa-monet"), "Kore")
        XCTAssertEqual(app.laaEmployeeVoice(profile: "laa-cfo"), "Fenrir")
        XCTAssertEqual(app.laaEmployeeVoice(profile: "laa-cto"), LAAStaff.cto.defaultCallVoice(engine: .geminiLive))
        XCTAssertEqual(app.geminiLiveVoice, workspaceVoice, "The workspace keeps its own voice")
        XCTAssertEqual(app.laaEmployeeCallPlan(profile: "laa-cfo")?.voice, "Fenrir")
        XCTAssertNotNil(app.laaEmployeeVoiceBinding(profile: "laa-cfo"))
        // On Local Live there is no voice to choose, so no picker.
        useEngines(gemini: false)
        XCTAssertNil(app.laaEmployeeVoice(profile: "laa-cfo"))
        XCTAssertNil(app.laaEmployeeVoiceBinding(profile: "laa-cfo"))
        XCTAssertEqual(app.laaEmployeeCallPlan(profile: "laa-cfo")?.engine, .localLive)
    }

    // MARK: The engine the Mac chooses

    func testEngineConfigReadsTheBridgeAnswerAndIgnoresWhatItDoesNotKnow() throws {
        let waiting = #"{"engine":"local_live","order":["gemini_live","local_live"],"engines":{"local_live":{"enabled":true},"gemini_live":{"enabled":false,"code":"waiting_for_contract","reason":"waiting for the Google AI Ultra contract / Gemini API key","reasonJa":"Google AI Ultraの契約とGemini APIキーを待っています"}},"source":"default"}"#
        let config = try JSONDecoder().decode(LAAStaffCallEngineConfig.self, from: Data(waiting.utf8))
        XCTAssertEqual(config.candidates, [.localLive])
        XCTAssertEqual(config.offReason(.geminiLive), "Google AI Ultraの契約とGemini APIキーを待っています")
        XCTAssertNil(config.offReason(.localLive))
        XCTAssertEqual(config, .fallback, "The answer before the Mac is reached is the Mac's own default")

        let both = #"{"order":["gemini_live","gpt_live","local_live"],"engines":{"local_live":{"enabled":true},"gemini_live":{"enabled":true},"gpt_live":{"enabled":true}}}"#
        XCTAssertEqual(try JSONDecoder().decode(LAAStaffCallEngineConfig.self, from: Data(both.utf8)).candidates,
                       [.geminiLive, .localLive], "A name this build doesn't know is never an engine")
        let malformed = #"{"order":"gemini_live","engines":{"local_live":{"enabled":"yes"}}}"#
        XCTAssertTrue(try JSONDecoder().decode(LAAStaffCallEngineConfig.self, from: Data(malformed.utf8)).candidates.isEmpty)
        // The saved copy reads back as it was written.
        let saved = try JSONEncoder().encode(Self.config(gemini: true))
        XCTAssertEqual(try JSONDecoder().decode(LAAStaffCallEngineConfig.self, from: saved), Self.config(gemini: true))
    }

    func testEngineStoreKeepsTheLastAnswerWhenTheMacIsAway() async throws {
        let suite = "LAAStaffCallEngineStore.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var answer: Result<LAAStaffCallEngineConfig, Error> = .success(Self.config(gemini: true))
        let store = LAAStaffCallEngineStore(defaults: defaults, read: { try answer.get() })
        XCTAssertEqual(store.engine, .localLive, "Before the Mac answers once")
        await store.refresh()
        XCTAssertEqual(store.engine, .geminiLive)
        answer = .failure(URLError(.timedOut))
        await store.refresh()
        XCTAssertEqual(store.engine, .geminiLive, "A failed read keeps the last answer")
        answer = .success(LAAStaffCallEngineConfig(order: [], engines: [:]))
        await store.refresh()
        XCTAssertEqual(store.engine, .geminiLive, "An answer naming no engine keeps the last one")
        XCTAssertEqual(LAAStaffCallEngineStore(defaults: defaults, read: { throw URLError(.timedOut) }).engine, .geminiLive,
                       "The last answer survives a relaunch")
        answer = .success(Self.config(gemini: false, local: false))
        await store.refresh()
        XCTAssertTrue(store.config.candidates.isEmpty)
    }

    func testCallEngineFallsBackToLocalLiveUntilGeminiLiveCanConnect() async throws {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let app = harness.appState
        let previousConsent = LiveVoiceProviderConsent.isGranted(.geminiLive)
        defer { LiveVoiceProviderConsent.setGranted(previousConsent, for: .geminiLive) }
        var statusPaths: [String] = []
        var hostAvailable = false
        app.geminiLiveTokenClient = app.laaStaffCallHostContext { path, _, _, _ in
            statusPaths.append(path)
            return hostAvailable ? ["ok": true, "available": true, "model": "fixture"]
                : ["ok": true, "available": false, "reason": "no_api_key"]
        }
        // Switched off on the Mac: the host is never asked.
        LiveVoiceProviderConsent.setGranted(true, for: .geminiLive)
        var engine = await app.laaStaffCallEngine(profile: "laa-cfo")
        XCTAssertEqual(engine, .localLive)
        XCTAssertTrue(statusPaths.isEmpty)
        // Switched on, but the host has no key yet.
        useEngines(gemini: true)
        engine = await app.laaStaffCallEngine(profile: "laa-cfo")
        XCTAssertEqual(engine, .localLive)
        XCTAssertEqual(statusPaths, [DashboardPath.withProfile(GeminiLiveTokenClient.statusPath, profile: "laa-cfo")])
        // The key exists, but the owner hasn't allowed Gemini Live to hear the call.
        hostAvailable = true
        LiveVoiceProviderConsent.setGranted(false, for: .geminiLive)
        engine = await app.laaStaffCallEngine(profile: "laa-cfo")
        XCTAssertEqual(engine, .localLive)
        LiveVoiceProviderConsent.setGranted(true, for: .geminiLive)
        engine = await app.laaStaffCallEngine(profile: "laa-cfo")
        XCTAssertEqual(engine, .geminiLive)
        // Nothing switched on: no call, rather than another engine.
        useEngines(gemini: false, local: false)
        engine = await app.laaStaffCallEngine(profile: "laa-cfo")
        XCTAssertNil(engine)
    }

    // MARK: Scope, tools and persona

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
        health.setVoiceRead(.geminiLive, allowed: true)
        app.healthSyncPreferences = health
        XCTAssertTrue(app.voiceReadableKeys(for: .geminiLive, scope: workspace).contains("health"))
        XCTAssertFalse(app.voiceReadableKeys(for: .geminiLive, scope: employee).contains("health"))
        let healthTool = VoiceHostTool(name: "conduit_health", description: "", parameters: [:], key: "health")
        let deniedHealth = await app.callVoiceHostTool(healthTool, arguments: [:], mode: .geminiLive, scope: employee)
        XCTAssertNotNil(deniedHealth["error"])

        var phone = PhoneSyncPreferences()
        phone.destination = workspaceDestination
        phone.calendar = .full
        app.phoneSync.savePreferences(phone)
        XCTAssertFalse(app.phoneVoiceSettingHint(for: .geminiLive, scope: workspace).isEmpty)
        XCTAssertTrue(app.phoneVoiceSettingHint(for: .geminiLive, scope: employee).isEmpty)
        phone.setVoiceUse(.geminiLive, allowed: true)
        app.phoneSync.savePreferences(phone)
        let phoneTool = VoiceHostTool(name: "conduit_phone", description: "", parameters: [:], key: "phone")
        let deniedPhone = await app.callVoiceHostTool(phoneTool, arguments: [:], mode: .geminiLive, scope: employee)
        XCTAssertNotNil(deniedPhone["error"])
        phone.destination = employeeDestination
        phone.setVoiceUse(.geminiLive, allowed: false)
        app.phoneSync.savePreferences(phone)
        XCTAssertFalse(app.phoneVoiceSettingHint(for: .geminiLive, scope: employee).isEmpty)
        XCTAssertTrue(app.phoneVoiceSettingHint(for: .geminiLive, scope: workspace).isEmpty)

        health.destination = employeeDestination
        app.healthSyncPreferences = health
        XCTAssertTrue(app.voiceReadableKeys(for: .geminiLive, scope: employee).contains("health"))
        XCTAssertFalse(app.voiceReadableKeys(for: .geminiLive, scope: workspace).contains("health"))
        XCTAssertFalse(app.voiceReadableKeys(for: .geminiLive, scope: otherDashboard).contains("health"))
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
        supervisor.hostToolsMode = .geminiLive
        supervisor.hostTools = [VoiceHostTool(name: "conduit_health", description: "", parameters: [:], key: "health")]
        var current = true
        await app.prepareVoiceHostTools(for: .geminiLive,
            scope: VoiceHostToolScope(dashboardID: dashboard.id, profile: "laa-cfo"), isCurrent: { current })
        XCTAssertFalse(supervisor.hostTools.contains { $0.key == "health" })
        XCTAssertTrue(supervisor.hostTools.contains { $0.key == MapsVoiceTool.key })
        current = false
        let expired = await supervisor.callHostTool(MapsVoiceTool.tool, arguments: [:])
        XCTAssertNotNil(expired["error"])
    }

    func testHostRoutesFollowTheCapturedEmployeeAndFencePlanChanges() async throws {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let app = harness.appState
        app.setActiveProfileForTesting("default")
        app.setGeminiLiveEnabled(true)
        XCTAssertEqual(app.laaVoiceResumeEngine(profile: "default"), .geminiLive)
        let original = try XCTUnwrap(app.laaEmployeeCallPlan(profile: "laa-cfo"))
        let replacement = try XCTUnwrap(app.laaEmployeeCallPlan(profile: "laa-monet"))
        app.laaStaffCallPlan = original
        XCTAssertEqual(app.laaVoiceResumeEngine(profile: "default"), .localLive, "A resumed call stays on its plan's engine")
        var paths: [String] = []
        let context = app.laaStaffCallHostContext { path, _, _, _ in
            paths.append(path)
            return ["ok": true, "available": true, "text": "Morgan persona"]
        }
        let persona = await context.personality()
        XCTAssertEqual(persona, "Morgan persona")
        XCTAssertEqual(paths, [DashboardPath.withProfile(GeminiLiveTokenClient.personalityPath, profile: "laa-cfo")])
        XCTAssertEqual(app.activeProfile, "default")

        // A request for a call whose plan was replaced never starts, and a
        // late answer never revives it.
        paths = []
        var pending: CheckedContinuation<[String: Any], Never>?
        let fenced = app.laaStaffCallHostContext { path, _, _, _ in
            paths.append(path)
            return await withCheckedContinuation { pending = $0 }
        }.captured(profile: original.profile, isCurrent: { app.laaStaffCallPlan == original })
        app.laaStaffCallPlan = replacement
        do {
            _ = try await fenced.availability()
            XCTFail("An expired call must not start a request")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(paths.isEmpty)
        app.laaStaffCallPlan = original
        let request = Task { try await fenced.availability() }
        for _ in 0..<1_000 where pending == nil { await Task.yield() }
        guard let pending else {
            app.laaStaffCallPlan = nil
            request.cancel()
            XCTFail("The fake request did not start")
            return
        }
        XCTAssertEqual(paths, [DashboardPath.withProfile(GeminiLiveTokenClient.statusPath, profile: "laa-cfo")])
        app.laaStaffCallPlan = replacement
        pending.resume(returning: ["ok": true, "available": true])
        do {
            _ = try await request.value
            XCTFail("A late response must not revive an expired call")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        app.laaStaffCallPlan = nil
    }

    func testEmployeePersonalityRetriesTransientFailureAndExplainsMissingData() async throws {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let app = harness.appState
        let plan = try XCTUnwrap(app.laaEmployeeCallPlan(profile: "laa-cfo"))
        app.laaStaffCallPlan = plan
        var paths: [String] = []
        let transient = app.laaStaffCallHostContext { path, _, _, _ in
            paths.append(path)
            if paths.count == 1 { throw URLError(.timedOut) }
            return ["ok": true, "available": true, "text": "Morgan persona \u{1F319}"]
        }.captured(profile: plan.profile)
        let loaded = await app.laaEmployeePersonality(transient, plan: plan)
        XCTAssertEqual(loaded, .available("Morgan persona \u{1F319}"))
        XCTAssertEqual(paths, Array(repeating: DashboardPath.withProfile(GeminiLiveTokenClient.personalityPath, profile: "laa-cfo"), count: 2))
        let spoken = try await app.laaEmployeeSpokenPersona(transient, plan: plan)
        XCTAssertFalse(spoken.contains("\u{1F319}"), "The call speaks the SOUL's words, not its emoji")

        let missingRoute = app.laaStaffCallHostContext { _, _, _, _ in
            throw DashboardTicketBridgeError.http(status: 404, detail: "")
        }.captured(profile: plan.profile)
        let missingRouteResult = await app.laaEmployeePersonality(missingRoute, plan: plan)
        XCTAssertEqual(missingRouteResult, .missingRoute)
        let noPersona = app.laaStaffCallHostContext { _, _, _, _ in
            ["ok": true, "available": false]
        }.captured(profile: plan.profile)
        let noPersonaResult = await app.laaEmployeePersonality(noPersona, plan: plan)
        XCTAssertEqual(noPersonaResult, .missingPersona)
        do {
            _ = try await app.laaEmployeeSpokenPersona(noPersona, plan: plan)
            XCTFail("A call without the employee's persona must not start")
        } catch let error as LAAStaffCallError {
            XCTAssertFalse(error.reason.isEmpty)
        }
        var stoppedRequests = 0
        let stopped = app.laaStaffCallHostContext { _, _, _, _ in
            stoppedRequests += 1
            app.laaStaffCallPlan = nil
            throw URLError(.timedOut)
        }.captured(profile: plan.profile)
        _ = await app.laaEmployeePersonality(stopped, plan: plan)
        XCTAssertEqual(stoppedRequests, 1)
    }

    func testEmployeeStyleRecordingAndResumeUseEmployeeProfile() async throws {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let app = harness.appState
        app.setActiveProfileForTesting("default")
        app.setLiveVoiceStyle(LiveVoiceStyle(greeting: "workspace"), profile: "default")
        let employeeStyle = LiveVoiceStyle(tone: .professional, greeting: "Morgan", asksBeforeSending: true)
        app.setLiveVoiceStyle(employeeStyle, profile: "laa-cfo")
        app.noteBotChatSessionForTesting("staff-chat", profile: "laa-cfo")
        app.activeSessionId = "staff-chat"
        let plan = try XCTUnwrap(app.laaEmployeeCallPlan(profile: "laa-cfo"))
        app.laaStaffCallPlan = plan
        XCTAssertEqual(app.liveVoiceStyle, employeeStyle)
        XCTAssertFalse(app.localLiveCallUsesAgent, "The employee's own chat answers each turn")
        XCTAssertNil(app.localLiveAgentSetup())
        app.beginVoiceCallRecordingForTesting(engine: plan.engine, turns: [])
        XCTAssertEqual(app.voiceCallRecorderProfileForTesting, "laa-cfo")
        XCTAssertTrue(app.voiceBackgroundJobSupervisor.asksBeforeSending)

        var readProfile: String?
        app.voiceResumeContextReaderForTesting = { _, profile in
            readProfile = profile
            app.laaStaffCallPlan = nil
            return nil
        }
        let resumed = await app.resumeVoiceCall(sessionID: "saved-call")
        app.voiceResumeContextReaderForTesting = nil
        XCTAssertEqual(readProfile, "laa-cfo")
        XCTAssertFalse(resumed, "A changed plan must not resume a stale call")
        XCTAssertEqual(app.liveVoiceStyle.greeting, "workspace")
        app.closeLocalLiveConversation()
    }

    func testAnEmployeePlanEndsWithItsOwnCallOnly() throws {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let app = harness.appState
        let local = try XCTUnwrap(app.laaEmployeeCallPlan(profile: "laa-cfo", engine: .localLive))
        app.laaStaffCallPlan = local
        // Another engine's teardown at a call's start leaves the plan.
        app.closeGeminiLiveConversation()
        app.closeGPTLiveConversation()
        XCTAssertEqual(app.laaStaffCallPlan, local)
        app.closeLocalLiveConversation()
        XCTAssertNil(app.laaStaffCallPlan)
        let gemini = try XCTUnwrap(app.laaEmployeeCallPlan(profile: "laa-cfo", engine: .geminiLive))
        app.laaStaffCallPlan = gemini
        app.closeLocalLiveConversation()
        XCTAssertEqual(app.laaStaffCallPlan, gemini)
        app.closeGeminiLiveConversation()
        XCTAssertNil(app.laaStaffCallPlan)
    }

    func testGPTLiveCannotBeTurnedOnOrResolvedInAnLAABuild() {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let app = harness.appState
        app.setActiveProfileForTesting("default")
        app.setGPTLiveEnabled(true)
        XCTAssertFalse(app.isGPTLiveEnabled)
        XCTAssertNil(app.configuredLiveVoiceEngine(profile: "default"))
    }

    // MARK: Start paths

    func testHeaderUsesCallKitThenLocalLiveForBotChatWithoutSwitchingWorkspace() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let app = harness.appState
        app.setActiveProfileForTesting("default")
        app.noteBotChatSessionForTesting("staff-chat", profile: "laa-cfo")
        app.activeSessionId = "staff-chat"
        offlineLocalLive(app)
        let kit = FakePlacedCallKit()
        let placed = makePlacedCallsForTesting(appState: app, kit: kit)
        let control = LAAEmployeeVoiceControl()
        control.bind(app)
        let calls = LAAEmployeeCallCoordinator(control: control)
        XCTAssertNil(control.requiredConsent(for: LAAEmployeeCallContext(id: UUID(), profile: "laa-cfo", name: "Morgan", conversationID: "staff-chat")),
                     "Local Live sends nothing to a third party")
        calls.start(profile: "laa-cfo", name: "Morgan", conversationID: "staff-chat")
        for _ in 0..<1_000 where !placed.isWaitingForCallAudio { await Task.yield() }
        XCTAssertTrue(placed.isWaitingForCallAudio)
        XCTAssertEqual(app.laaStaffCallPlan?.profile, "laa-cfo")
        XCTAssertEqual(app.laaStaffCallPlan?.engine, .localLive)
        XCTAssertFalse(app.showLocalLiveSheet)
        let pendingPlan = app.laaStaffCallPlan
        let threadBeforeCarPlay = app.voiceBackgroundJobSupervisor.liveThread
        let carThread = VoiceThreadTarget(runtimeSessionID: "car-chat", storedSessionID: nil, title: "Car")
        await app.startLocalLiveForCarPlay(attachingTo: carThread)
        XCTAssertEqual(app.laaStaffCallPlan, pendingPlan)
        XCTAssertEqual(app.voiceBackgroundJobSupervisor.liveThread, threadBeforeCarPlay)
        XCTAssertNil(app.voiceCallRecorderProfileForTesting)
        XCTAssertFalse(app.isLocalLiveActive)
        XCTAssertTrue(placed.isWaitingForCallAudio)
        let unrelatedIncoming = await app.openVoiceConversation(PendingVoiceIntent(
            profile: "default", startsFreshConversation: false, source: .hermesCall))
        XCTAssertFalse(unrelatedIncoming)
        kit.onPlacedCallStarted?()
        kit.onPlacedCallAudioActivated?()
        for _ in 0..<1_000 where !app.showLocalLiveSheet { await Task.yield() }
        XCTAssertTrue(app.showLocalLiveSheet)
        XCTAssertFalse(app.showGPTLiveSheet)
        XCTAssertFalse(app.showVoiceSheet)
        XCTAssertEqual(app.activeProfile, "default")
        XCTAssertEqual(app.voiceBackgroundJobSupervisor.liveThread?.profile, "laa-cfo")
        XCTAssertEqual(app.voiceBackgroundJobSupervisor.liveThread?.runtimeSessionID, "staff-chat")
        XCTAssertNil(app.voiceModeSwitch(for: .localLive))
        await app.switchVoiceMode(to: .gemini)
        XCTAssertTrue(app.showLocalLiveSheet)
        XCTAssertFalse(app.showGeminiLiveSheet)
        for _ in 0..<1_000 {
            if case .failed = app.localLiveController.phase { break }
            await Task.yield()
        }
        guard case .failed = app.localLiveController.phase else {
            calls.end()
            kit.onPlacedCallEnded?(false)
            XCTFail("The fake Local Live failure did not arrive")
            return
        }
        XCTAssertFalse(app.isLocalLiveActive)
        XCTAssertFalse(app.hasScheduledLiveVoiceStart)
        XCTAssertNotNil(app.voiceCallRecorderProfileForTesting)
        calls.end()
        XCTAssertEqual(app.activeSessionId, "staff-chat")
        XCTAssertNil(app.laaStaffCallPlan)
        XCTAssertFalse(app.showLocalLiveSheet)
        XCTAssertNil(app.voiceCallRecorderProfileForTesting)
        XCTAssertNil(app.voiceBackgroundJobSupervisor.liveThread)
        XCTAssertEqual(kit.endRequests, 1)
        kit.onPlacedCallEnded?(false)
    }

    func testACallWithNoEngineSwitchedOnSaysSoAndPlacesNoCall() async {
        useEngines(gemini: false, local: false)
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let app = harness.appState
        app.setActiveProfileForTesting("default")
        app.noteBotChatSessionForTesting("staff-chat", profile: "laa-cfo")
        app.activeSessionId = "staff-chat"
        let kit = FakePlacedCallKit()
        let placed = makePlacedCallsForTesting(appState: app, kit: kit)
        let control = LAAEmployeeVoiceControl()
        control.bind(app)
        let calls = LAAEmployeeCallCoordinator(control: control)
        calls.start(profile: "laa-cfo", name: "Morgan", conversationID: "staff-chat")
        for _ in 0..<1_000 {
            if case .failed? = calls.snapshot?.phase { break }
            await Task.yield()
        }
        guard case .failed(let reason)? = calls.snapshot?.phase else {
            calls.end()
            XCTFail("A call with no engine must fail")
            return
        }
        XCTAssertEqual(reason, LAAStaffCallError.noEngine.reason)
        XCTAssertNil(app.laaStaffCallPlan)
        XCTAssertFalse(placed.isWaitingForCallAudio)
        calls.end()
    }

    func testCarPlayDoesNotTakeAPlanCreatedWhileItsStartWaits() async throws {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let app = harness.appState
        app.setLocalLiveAgent(true)
        app.setLocalLiveEnabled(true)
        offlineLocalLive(app)
        let plan = try XCTUnwrap(app.laaEmployeeCallPlan(profile: "laa-cfo"))
        let originalThread = VoiceThreadTarget(runtimeSessionID: "phone-chat", storedSessionID: nil, title: "Phone")
        app.voiceBackgroundJobSupervisor.attachLiveThread(originalThread)
        harness.coordinator.handleConnect(harness.spy)
        defer { harness.coordinator.handleDisconnect() }
        await harness.coordinator.waitForPresentation()
        harness.coordinator.liveCallStartGate = { app.laaStaffCallPlan = plan }
        await harness.coordinator.establishVoice(generation: harness.coordinator.connectionGeneration)
        XCTAssertEqual(app.laaStaffCallPlan, plan)
        XCTAssertEqual(app.voiceBackgroundJobSupervisor.liveThread, originalThread)
        XCTAssertNil(app.voiceCallRecorderProfileForTesting)
        XCTAssertFalse(app.isLocalLiveActive)

        let row = CarPlayChatRow(sessionID: "car-chat", storedSessionID: nil, title: "Car", detail: "")
        await harness.coordinator.performOpenChat(row, generation: harness.coordinator.connectionGeneration)
        XCTAssertNil(harness.coordinator.chosenChat)
        XCTAssertEqual(app.laaStaffCallPlan, plan)
        XCTAssertEqual(app.voiceBackgroundJobSupervisor.liveThread, originalThread)
        // The phone is still waiting on CallKit: the car has no call to end.
        harness.coordinator.endTapped()
        XCTAssertEqual(app.laaStaffCallPlan, plan)
        app.laaStaffCallPlan = nil
    }

    func testEmployeeWidgetUsesItsProfileAndTheSameCallKitPath() async {
        let suite = "LAAEmployeeCallWidget.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let dashboard = SavedDashboard(id: UUID(), label: "Test", normalizedURL: "https://example.com")
        let app = AppState(defaults: defaults, loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: dashboard.id, dashboards: [dashboard]))
        app.connection = HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket")
        app.isConnected = true
        app.setActiveProfileForTesting("laa-cto")
        offlineLocalLive(app)
        let kit = FakePlacedCallKit()
        let placed = makePlacedCallsForTesting(appState: app, kit: kit)
        let lease = WidgetLaunchLease(isCurrent: { true })
        let workspace = WidgetWorkspaceID(dashboardID: dashboard.id, profile: "laa-cto")
        let launch = Task { await app.openWidgetVoice(workspace: workspace, lease: lease) }
        for _ in 0..<1_000 where !placed.isWaitingForCallAudio { await Task.yield() }
        XCTAssertTrue(placed.isWaitingForCallAudio)
        XCTAssertEqual(app.laaStaffCallPlan?.profile, "laa-cto")
        XCTAssertEqual(app.laaStaffCallPlan?.engine, .localLive)
        let widgetPlan = app.laaStaffCallPlan
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
        XCTAssertEqual(app.laaStaffCallPlan, widgetPlan)
        XCTAssertTrue(placed.isWaitingForCallAudio)
        kit.onPlacedCallStarted?()
        kit.onPlacedCallAudioActivated?()
        let outcome = await launch.value
        XCTAssertEqual(outcome, .handled)
        XCTAssertTrue(app.showLocalLiveSheet)
        app.closeLocalLiveConversation()
        XCTAssertNil(app.laaStaffCallPlan)
        kit.onPlacedCallEnded?(false)
    }

    func testPhoneOpenCannotTakeOrEndAPlanCreatedBeforeItsAsyncStart() async throws {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
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
        app.laaStaffCallPlan = widgetPlan
        for _ in 0..<1_000 {
            if case .failed? = calls.snapshot?.phase { break }
            await Task.yield()
        }
        if case .failed? = calls.snapshot?.phase {} else {
            XCTFail("The later phone open must be rejected")
        }
        XCTAssertEqual(app.laaStaffCallPlan, widgetPlan)
        calls.end()
        XCTAssertEqual(app.laaStaffCallPlan, widgetPlan)
        XCTAssertEqual(kit.endRequests, 0)
        XCTAssertFalse(app.showLocalLiveSheet)
        kit.onPlacedCallEnded?(false)
        app.laaStaffCallPlan = nil
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
        app.laaStaffCallPlan = try XCTUnwrap(app.laaEmployeeCallPlan(profile: "laa-cto"))
        await fulfillment(of: [appeared], timeout: 5)
        first.cancel()
        XCTAssertNotEqual(updates.inputs, initial)
        let cleared = expectation(description: "cleared call makes the composer update")
        let second = updates.objectWillChange.sink { _ in cleared.fulfill() }
        app.laaStaffCallPlan = nil
        await fulfillment(of: [cleared], timeout: 5)
        second.cancel()
        XCTAssertEqual(updates.inputs, initial)
    }

    func testConsentCannotStartASecondCallWhileAWidgetPlanWaits() throws {
        // Gemini Live is the Mac's choice here: it asks before it may hear.
        useEngines(gemini: true)
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let previousConsent = LiveVoiceProviderConsent.isGranted(.geminiLive)
        LiveVoiceProviderConsent.setGranted(false, for: .geminiLive)
        defer { LiveVoiceProviderConsent.setGranted(previousConsent, for: .geminiLive) }
        let app = harness.appState
        app.noteBotChatSessionForTesting("morgan-chat", profile: "laa-cfo")
        app.activeSessionId = "morgan-chat"
        let control = LAAEmployeeVoiceControl()
        control.bind(app)
        let calls = LAAEmployeeCallCoordinator(control: control)
        XCTAssertTrue(calls.startEmployeeConversation(app))
        XCTAssertEqual(calls.consentRequest?.mode, .geminiLive)
        let widgetPlan = try XCTUnwrap(app.laaEmployeeCallPlan(profile: "laa-cto"))
        app.laaStaffCallPlan = widgetPlan
        calls.answerConsent(true)
        calls.consentDidDismiss()
        XCTAssertNil(calls.snapshot)
        XCTAssertEqual(app.laaStaffCallPlan, widgetPlan)
        app.laaStaffCallPlan = nil
    }
}
#endif
