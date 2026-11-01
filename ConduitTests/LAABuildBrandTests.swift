#if LAA_BUILD
import XCTest
@testable import Conduit

/// The LAA build's own contract: what it calls itself, and the one-time
/// migration away from the upstream alternate icon (BUS-330).
final class LAABuildBrandTests: XCTestCase {
    @MainActor
    func testDefaultProfileNameUsesCielAndPreservesANameTheUserSaved() {
        let suite = "laa.brand.profile.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProfileAppearanceStore(defaults: defaults)
        XCTAssertEqual(store.loadDefaultName(dashboardID: nil), "Ciel")
        store.saveDefaultName("Hermes", dashboardID: nil)
        XCTAssertEqual(store.loadDefaultName(dashboardID: nil), "Hermes")
        store.saveDefaultName(" ", dashboardID: nil)
        XCTAssertEqual(store.loadDefaultName(dashboardID: nil), "Ciel")
    }

    func testPairingCodeIsTrimmedBeforeItReachesTheBridge() {
        XCTAssertEqual(LAAPairingView.normalizedCode(" 123456\n"), "123456")
        XCTAssertEqual(LAAPairingView.normalizedCode("\tABC123 "), "ABC123")
        XCTAssertEqual(LAAPairingView.normalizedCode("   "), "")
        XCTAssertEqual(LAAPairingView.normalizedCode("123456"), "123456")
    }

    @MainActor
    func testAnInheritedAlternateAppIconIsResetAtLaunch() {
        var resets: [String?] = []
        let choice = AppState.startupAppIconChoice(alternateIconName: "Light") { resets.append($0) }
        XCTAssertEqual(choice, .dark)
        XCTAssertEqual(resets, [nil])
    }

    @MainActor
    func testNoAlternateAppIconNeedsNoReset() {
        var resets = 0
        let choice = AppState.startupAppIconChoice(alternateIconName: nil) { _ in resets += 1 }
        XCTAssertEqual(choice, .dark)
        XCTAssertEqual(resets, 0)
    }

    func testTheBuildNamesItselfInTextForTheModel() {
        XCTAssertEqual(LAAProductBrand.appName, "LAA")
        XCTAssertEqual(LAAProductBrand.display("Open Conduit"), "Open LAA")
        XCTAssertEqual(LAAProductBrand.display("Open LAA"), "Open LAA")
        XCTAssertEqual(LAAProductBrand.display("the Conduit plugin"), "the connection service")
    }

    func testTheRedactedApprovalKeepsTheNotifiersTextAndIsBrandedForDisplay() {
        // Matching a redacted push depends on the notifier's exact sentence.
        XCTAssertEqual(AppState.redactedApprovalPushDescription,
                       "Hermes needs your approval. Open Conduit for details.")
        XCTAssertEqual(NotificationCopy.redactedApprovalBody(AppState.redactedApprovalPushDescription),
                       "Ciel needs your approval. Open LAA for details.")
        let prefixed = "Conduit: " + AppState.redactedApprovalPushDescription
        XCTAssertEqual(NotificationCopy.redactedApprovalBody(prefixed), prefixed)
        XCTAssertEqual(NotificationCopy.redactedApprovalBody("Hermes asked about Conduit."), "Hermes asked about Conduit.")
    }

    @MainActor
    func testUserAndModelContentIsNotBranded() {
        let persona = "Conduit and Hermes are names in this persona."
        let memory = "Remember the Conduit Hermes project."
        let prompt = GeminiLiveConversationController.instructions(
            search: .hermes, memory: GeminiLiveMemoryContext(text: memory, canRecall: false), personality: persona)
        XCTAssertTrue(prompt.contains(persona))
        XCTAssertTrue(prompt.contains(memory))

        let title = "Conduit Hermes job"
        XCTAssertTrue(VoiceBackgroundJobSupervisor.finishedNotice(title).contains(title))
        XCTAssertTrue(VoiceBackgroundJobSupervisor.waitingNotice(title).contains(title))
        XCTAssertTrue(VoiceBackgroundJobSupervisor.failedNotice(title, reason: "").contains(title))
        XCTAssertTrue(WatchJobAnswer.failedNotice(title, reason: "").contains(title))

        let answer = "Conduit Hermes answer"
        let question = "Conduit Hermes question?"
        let result = WatchCallAnswer.result(body: ["ok": true, "status": "answered", "answer": answer,
                                                    "next": ["question": question]])
        XCTAssertEqual(result["choice"], answer)
        XCTAssertTrue(result["message"]?.contains(answer) == true)
        XCTAssertTrue(result["message"]?.contains(question) == true)
        XCTAssertEqual(WatchCallAnswer.result(body: ["ok": false, "detail": answer])["error"], answer)
    }

    func testSpeechSetupKeepsKeysAddressesAndModelNames() throws {
        let status = SpeechServerVoiceStatus(response: [
            "available": true, "model_path": "/Conduit/Hermes", "model_name": "Conduit-Hermes",
            "api_key": "test-Conduit-Hermes", "speech_server": ["url": "wss://example.test/Conduit/Hermes"],
        ], dashboardBaseURL: "https://example.test/Conduit/Hermes")
        let setup = try XCTUnwrap(status.agentSetupText)
        XCTAssertTrue(setup.contains("test-Conduit-Hermes"))
        XCTAssertTrue(setup.contains("https://example.test/Conduit/Hermes/Conduit/Hermes"))
        XCTAssertTrue(setup.contains("wss://example.test/Conduit/Hermes"))
        XCTAssertTrue(setup.contains("Conduit-Hermes"))
        XCTAssertTrue(setup.contains(try XCTUnwrap(status.serverFlags)))
    }
}
#endif
