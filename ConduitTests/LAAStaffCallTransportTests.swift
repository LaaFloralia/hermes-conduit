#if LAA_BUILD
import XCTest
@testable import Conduit

/// An employee's call keeps the chat connection coming back while the
/// phone is locked, and speaks as that employee from its first words
/// (owner, 2026-11-09: the call said "I'm ChatGPT", and after one request
/// every other one was answered with "not connected").
@MainActor
final class LAAStaffCallTransportTests: XCTestCase {
    private final class ReconnectRecorder {
        var scheduledDelays: [TimeInterval] = []
    }

    private func makeAppState(recorder: ReconnectRecorder) -> AppState {
        let defaults = makeScratchDefaults("LAAStaffCallTransportTests")
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            reconnectScheduler: { delay, _ in
                recorder.scheduledDelays.append(delay)
                return {}
            },
            reconnectExecutor: { _ in }
        )
        appState.connection = HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket")
        appState.isConnected = false
        appState.isConnecting = false
        appState.reconnectJitter = { 1 }
        appState.deviceConditions = { DeviceConditions() }
        return appState
    }

    func testALiveCallOnALockedPhoneReconnectsADroppedSocket() {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        appState.handleScenePhase(.background)
        appState.scheduleReconnect(immediately: true)
        XCTAssertTrue(recorder.scheduledDelays.isEmpty, "without a call, off screen still waits for the screen")

        appState.liveVoiceCallActiveForTesting = true
        appState.recoverTransportForCarPlayIfNeeded()
        XCTAssertEqual(recorder.scheduledDelays.count, 1, "the running call re-arms the reconnect")
    }

    func testACallRequestOffScreenWaitsForTheReconnectInsteadOfFailingAtOnce() async throws {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        appState.handleScenePhase(.background)
        appState.liveVoiceCallActiveForTesting = true
        appState.isConnecting = true
        appState.voiceRequestConnectionWait = .seconds(30)
        let client = HermesClient(
            connection: HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket"),
            profile: "laa-monet"
        )
        appState.client = client

        var finished = false
        let request = Task { @MainActor () -> HermesClient? in
            defer { finished = true }
            return try? await appState.clientForVoiceRequest()
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(finished, "the request waits for the connection to come back")

        appState.isConnected = true
        appState.isConnecting = false
        let resolved = await request.value
        XCTAssertTrue(resolved === client)
    }

    func testEveryEmployeeCallNamesTheEmployeeAndGreetsByName() throws {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let app = harness.appState
        app.setActiveProfileForTesting("default")
        XCTAssertFalse(app.gptLiveBriefing().contains("LAA employee call"), "a workspace call is unchanged")
        XCTAssertNil(app.liveVoiceStyle.greeting)

        for staff in LAAStaff.allCases where staff.supportsCalls {
            app.laaEmployeeGPTLivePlan = try XCTUnwrap(app.laaEmployeeCallPlan(profile: "laa-\(staff.rawValue)"))
            let briefing = app.gptLiveBriefing()
            XCTAssertTrue(briefing.hasPrefix("[LAA employee call. You are \(staff.name), \(staff.role) at LAA"), staff.name)
            XCTAssertTrue(briefing.contains("Never call yourself ChatGPT"))
            XCTAssertEqual(app.liveVoiceStyle.greeting, "社長、\(staff.name)です。")
            XCTAssertTrue(app.liveVoiceStyle.openingPrompt?.contains("Say: \"社長、\(staff.name)です。\"") == true)
        }
        app.laaEmployeeGPTLivePlan = nil
        XCTAssertNil(app.liveVoiceStyle.greeting)
    }

    func testAGreetingTheOwnerSetForTheEmployeeStillWins() throws {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let app = harness.appState
        app.setActiveProfileForTesting("default")
        app.setLiveVoiceStyle(LiveVoiceStyle(greeting: "お疲れさまです、Adaです"), profile: "laa-cto")
        app.laaEmployeeGPTLivePlan = try XCTUnwrap(app.laaEmployeeCallPlan(profile: "laa-cto"))
        XCTAssertEqual(app.liveVoiceStyle.greeting, "お疲れさまです、Adaです")
        app.laaEmployeeGPTLivePlan = nil
    }
}
#endif

#if LAA_BUILD
/// Writes the instructions an employee call sends, for the headless call
/// check in the work folder. Runs only when that folder is named.
@MainActor
final class LAAStaffCallBriefingDump: XCTestCase {
    func testDumpEmployeeBriefings() throws {
        guard let folder = ProcessInfo.processInfo.environment["LAA_BRIEFING_DUMP_DIR"] else {
            throw XCTSkip("no dump folder")
        }
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let app = harness.appState
        for profile in ["laa-monet", "laa-cfo", "laa-cto"] {
            let persona = try String(contentsOfFile: "\(folder)/persona-\(profile).txt", encoding: .utf8)
            app.laaEmployeeGPTLivePlan = try XCTUnwrap(app.laaEmployeeCallPlan(profile: profile))
            app.setGPTLivePersonalityForTesting(persona)
            try app.gptLiveBriefing().write(toFile: "\(folder)/briefing-\(profile).txt", atomically: true, encoding: .utf8)
            try (app.liveVoiceStyle.greeting ?? "").write(toFile: "\(folder)/greeting-\(profile).txt", atomically: true, encoding: .utf8)
            try (app.liveVoiceStyle.openingPrompt ?? "").write(toFile: "\(folder)/opening-\(profile).txt", atomically: true, encoding: .utf8)
        }
        app.setGPTLivePersonalityForTesting(nil)
        app.laaEmployeeGPTLivePlan = nil
    }
}
#endif
