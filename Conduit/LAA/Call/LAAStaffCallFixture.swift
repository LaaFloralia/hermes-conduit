#if DEBUG && LAA_BUILD
import SwiftUI

/// A simulator-only surface using the production header, call screen and bar.
/// The fake never accesses CallKit, the microphone, a network or credentials.
@MainActor
private final class LAAFixtureCallControl: LAAEmployeeCallControlling {
    var unavailableReason: String? = nil
    var onUpdate: ((LAAEmployeeCallSnapshot) -> Void)?
    var selectedVoice: String?
    private var snapshot: LAAEmployeeCallSnapshot?

    func start(_ context: LAAEmployeeCallContext) {
        guard LAAEmployeeCallPlan.make(profile: context.profile, engine: .geminiLive, savedVoice: selectedVoice) != nil else {
            onUpdate?(LAAEmployeeCallSnapshot(context: context, phase: .failed("社員が見つかりません")))
            return
        }
        let value = LAAEmployeeCallSnapshot(context: context, phase: .connected, connectedAt: Date(),
                                            usesSystemRoutePicker: ProcessInfo.processInfo.arguments.contains("-laa-native-call"))
        snapshot = value
        onUpdate?(value)
    }
    func setMuted(_ muted: Bool) { snapshot?.muted = muted; publish() }
    func setSpeaker(_ speaker: Bool) { snapshot?.speaker = speaker; publish() }
    func end() { snapshot?.phase = .ended; publish(); snapshot = nil }
    private func publish() { if let snapshot { onUpdate?(snapshot) } }
}

/// Even a regressed composer bypass stays away from the system call provider.
@MainActor
private final class LAAFixturePlacedCallKit: VoicePlacedCallKit {
    let isAvailable = false
    var onPlacedCallStarted: (@MainActor () -> Void)?
    var onPlacedCallAudioActivated: (@MainActor () -> Void)?
    var onPlacedCallAudioDeactivated: (@MainActor () -> Void)?
    var onPlacedCallEnded: (@MainActor (Bool) -> Void)?
    var onPlacedCallMuteChanged: (@MainActor (Bool) -> Void)?
    func placeCall(named name: String) -> Bool { false }
    func requestPlacedCallEnd() {}
    func reportPlacedCallMuted(_ muted: Bool, result: @escaping @MainActor (Bool) -> Void) { result(false) }
}

struct LAAStaffCallFixture: View {
    static let launchArgument = "-laa-staff-call-fixture"
    @MainActor static func makeCoordinator() -> LAAEmployeeCallCoordinator {
        useFixtureEngines()
        return LAAEmployeeCallCoordinator(control: LAAFixtureCallControl())
    }

    /// The fixture's own answer for the call engine: it never asks the real
    /// Bridge and never keeps what it answers. Local Live unless the launch
    /// names Gemini Live (its voice picker, a saved call's resume).
    @MainActor static func useFixtureEngines() {
        let arguments = ProcessInfo.processInfo.arguments
        let gemini = arguments.contains("-laa-gemini-call-engine") || arguments.contains("-laa-saved-call")
        let config = LAAStaffCallEngineConfig(order: [.geminiLive, .localLive], engines: [
            LAAStaffCallEngineName.geminiLive.rawValue: .init(enabled: gemini),
            LAAStaffCallEngineName.localLive.rawValue: .init(enabled: true),
        ])
        let store = LAAStaffCallEngineStore.shared
        store.persists = false
        store.read = { config }
        store.adopt(config)
    }
    @StateObject private var calls = Self.makeCoordinator()
    @State private var voice = LAAStaff.monet.defaultCallVoice(engine: .geminiLive) ?? ""
    private let args = ProcessInfo.processInfo.arguments
    private let profile = "laa-monet"
    private let conversationID = "fixture-conversation"

    private var reason: String? {
        if args.contains("-laa-unpaired") { return LAAEmployeeCallAvailability.bridgeReason(.unpaired) }
        if args.contains("-laa-revoked") { return LAAEmployeeCallAvailability.bridgeReason(.revoked) }
        if args.contains("-laa-offline") { return "Macに接続してください" }
        if args.contains("-laa-no-voice") {
            return LAAEmployeeCallAvailability.voiceReason(profile: profile, canStart: false, issue: .noTextToSpeech)
        }
        return nil
    }

    var body: some View {
        if args.contains("-laa-composer-fixture") {
            LAAEmployeeComposerFixture(calls: calls, savedCall: args.contains("-laa-saved-call"))
        } else {
            callFixture
        }
    }

    private var callFixture: some View {
        NavigationStack {
            VStack {
                Text(verbatim: "元の会話")
                    .accessibilityIdentifier("laa.fixture.conversation")
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LAAColors.paper)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    // No picker where the engine has no voice to choose (Local Live).
                    LAAEmployeeHeader(profile: profile, name: "Monet", status: reason ?? "● 待機中",
                                      voiceSetting: LAAEmployeeCallVoice.choices(engine: LAAStaffCallEngineStore.shared.engine).isEmpty ? nil : $voice)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    LAAEmployeeCallButton(reason: reason) {
                        calls.start(profile: profile, name: "Monet", conversationID: conversationID)
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                LAAInCallBar(calls: calls, profile: profile, conversationID: conversationID)
            }
        }
        .modifier(LAACallPresentation(calls: calls))
        .onChange(of: voice) { _, value in
            (calls.control as? LAAFixtureCallControl)?.selectedVoice = value
        }
        .preferredColorScheme(args.contains("-laa-dark") ? .dark : .light)
        // SwiftUI exposes the read-only public environment value; its writable
        // backing key is used only in this DEBUG fixture for a still screenshot.
        .environment(\._accessibilityReduceMotion, args.contains("-laa-reduce-motion"))
    }
}

@MainActor
private final class LAAResumeFixtureEvidence: ObservableObject {
    @Published var readRow = "pending"
    @Published var readProfile = "pending"
    @Published var statusPath = "pending"
    @Published var personaPath = "pending"
}

@MainActor
private final class LAAEmployeeComposerHarness: ObservableObject {
    let appState: AppState
    let calls: LAAEmployeeCallCoordinator
    let evidence: LAAResumeFixtureEvidence

    init(fixtureCalls: LAAEmployeeCallCoordinator, savedCall: Bool) {
        let evidence = LAAResumeFixtureEvidence()
        let defaults = UserDefaults(suiteName: "LAAEmployeeComposerFixture.\(UUID().uuidString)")!
        let app = AppState(defaults: defaults, loadSavedConnection: false)
        app.connection = HermesConnection(baseUrl: "https://example.invalid", ticket: "fixture")
        app.isConnected = true
        let host = VoicePlacedCallHost(isSettingOn: { false }, isVoiceRunning: { false }, displayName: { "Fixture" },
                                      endVoice: {}, voiceMuted: { nil }, setVoiceMuted: { _ in },
                                      setCallActive: { _ in }, runsElsewhere: { false })
        app.voicePlacedCalls = VoicePlacedCalls(callKit: LAAFixturePlacedCallKit(), host: host)
        // A Local Live call here reaches no speech server: the fixture's
        // host says it has none, so the call screen opens and stops there.
        app.localLiveClient = LocalLiveClient(
            request: { _, _, _, _ in ["ok": true, "available": false, "reason": "fixture offline"] },
            mintTicket: { throw DashboardTicketBridgeError.notReady },
            socketRequest: { _, _ in throw DashboardTicketBridgeError.notReady })
        if savedCall {
            app.setActiveProfileForTesting("laa-cfo")
            // The Mac's answer in this fixture is Gemini Live (useFixtureEngines).
            app.setLAAEmployeeVoice("Kore", profile: "laa-cfo")
            app.sessions = [SessionSummary(id: "fixture-conversation", alternateIds: [], title: "Saved call",
                                           model: "Hermes", updatedLabel: "", profile: "laa-cfo",
                                           source: .chat, isActive: false, isArchived: false)]
            app.noteSavedVoiceCallForTesting("fixture-conversation", profile: "laa-cfo")
            app.voiceResumeContextReaderForTesting = { row, profile in
                evidence.readRow = row
                evidence.readProfile = profile
                return VoiceResumeContext(summary: "Morgan saved summary", recent: [
                    VoiceResumeTurn(speaker: .user, text: "Morgan saved turn")
                ])
            }
            // The host answers under the employee the call captured. No token
            // is minted: the fixture stops before a socket could open.
            app.geminiLiveTokenClient = app.laaStaffCallHostContext { path, _, _, _ in
                if path.contains(GeminiLiveTokenClient.personalityPath) {
                    evidence.personaPath = path
                    return ["ok": true, "available": true, "text": "Morgan fixture persona"]
                }
                if path.contains(GeminiLiveTokenClient.statusPath) {
                    evidence.statusPath = path
                    return ["ok": true, "available": true, "model": "fixture"]
                }
                return ["ok": true, "available": false]
            }
        } else {
            app.setActiveProfileForTesting("default")
            if !ProcessInfo.processInfo.arguments.contains("-laa-default-call") {
                app.noteBotChatSessionForTesting("fixture-conversation", profile: "laa-cfo")
            }
            app.geminiLiveTokenClient = app.laaStaffCallHostContext { _, _, _, _ in
                ["ok": true, "available": false, "reason": "fixture offline"]
            }
        }
        app.setGeminiLiveEnabled(true)
        app.activeSessionId = "fixture-conversation"
        if ProcessInfo.processInfo.arguments.contains("-laa-dictation-button") {
            app.setChatVoiceButtonOverride(.dictation)
        }
        if savedCall {
            let control = LAAEmployeeVoiceControl()
            control.bind(app)
            self.calls = LAAEmployeeCallCoordinator(control: control)
        } else {
            self.calls = fixtureCalls
        }
        self.appState = app
        self.evidence = evidence
    }
}

/// The saved-call fixture runs the real call control and resume path with fake IO.
@MainActor
private struct LAAEmployeeComposerFixture: View {
    @StateObject private var harness: LAAEmployeeComposerHarness
    private let savedCall: Bool

    init(calls: LAAEmployeeCallCoordinator, savedCall: Bool) {
        self.savedCall = savedCall
        _harness = StateObject(wrappedValue: LAAEmployeeComposerHarness(fixtureCalls: calls, savedCall: savedCall))
    }

    var body: some View {
        LAAEmployeeComposerContent(appState: harness.appState, calls: harness.calls,
                                   evidence: harness.evidence, savedCall: savedCall)
    }
}

@MainActor
private struct LAAEmployeeComposerContent: View {
    @ObservedObject var appState: AppState
    @ObservedObject var calls: LAAEmployeeCallCoordinator
    @ObservedObject var evidence: LAAResumeFixtureEvidence
    @StateObject private var bridge = LAABridgeSession(statusForTesting: .paired)
    let savedCall: Bool

    var body: some View {
        VStack {
            Text(verbatim: "元の会話")
                .accessibilityIdentifier("laa.fixture.conversation")
            if savedCall && appState.openChatCallToResume != nil {
                Text(verbatim: "保存した通話")
                    .accessibilityIdentifier("laa.fixture.saved-call")
            }
            if LAAStaff(profile: appState.conversationIdentityProfile) != nil {
                // The header's phone, the one way a staff call starts now
                // that the composer has no voice button.
                LAAEmployeeCallButton(reason: LAAEmployeeCallAvailability.reason(appState: appState, bridge: bridge.status, calls: calls)) {
                    _ = calls.startEmployeeConversation(appState)
                }
            }
            if ProcessInfo.processInfo.arguments.contains("-laa-pending-call") {
                Button {
                    appState.laaStaffCallPlan = appState.laaStaffCallPlan == nil
                        ? appState.laaEmployeeCallPlan(profile: "laa-cto") : nil
                } label: {
                    Text(verbatim: "Wait for widget call")
                }
                .accessibilityIdentifier("laa.fixture.pending-call")
            }
            if ProcessInfo.processInfo.arguments.contains("-laa-default-call") {
                V2VoiceButton(context: .home, style: .capsule)
                    .accessibilityIdentifier("laa.fixture.default-call")
            }
            if ProcessInfo.processInfo.arguments.contains("-laa-dictation-button") {
                V2VoiceButton(context: .conversation)
                    .accessibilityIdentifier("laa.fixture.dictation")
            }
            if let context = calls.snapshot?.context {
                Text(verbatim: "\(context.profile)|\(context.conversationID ?? "")")
                    .accessibilityIdentifier("laa.fixture.call-context")
            }
            Spacer()
            ComposerBar(appState: appState)
                .environment(\.v2ComposerRests, true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environmentObject(appState)
        .environmentObject(bridge)
        .environmentObject(calls)
        .fullScreenCover(isPresented: $calls.isShowingCall) {
            ZStack(alignment: .topLeading) {
                LAAEmployeeCallView(calls: calls)
                if savedCall {
                    VStack(alignment: .leading) {
                        Text(verbatim: "\(evidence.readRow)|\(evidence.readProfile)|\(appState.voiceCallRecorderSessionIDForTesting ?? "pending")|\(appState.voiceCallRecorderProfileForTesting ?? "pending")")
                            .accessibilityIdentifier("laa.fixture.resume-evidence")
                        Text(verbatim: evidence.statusPath)
                            .accessibilityIdentifier("laa.fixture.status-path")
                        Text(verbatim: evidence.personaPath)
                            .accessibilityIdentifier("laa.fixture.persona-path")
                    }
                    .font(.system(size: 7))
                    .padding(4)
                    .background(.thinMaterial)
                    .allowsHitTesting(false)
                }
            }
        }
        .sheet(item: $calls.consentRequest, onDismiss: calls.consentDidDismiss) { request in
            LiveVoiceConsentSheet(mode: request.mode, onAnswer: calls.answerConsent)
                .presentationDetents([.medium, .large])
        }
    }
}
#endif
