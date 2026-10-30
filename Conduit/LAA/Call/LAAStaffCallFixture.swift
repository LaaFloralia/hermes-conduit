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
        guard LAAEmployeeGPTLivePlan.make(profile: context.profile, savedVoice: selectedVoice) != nil else {
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
    @StateObject private var calls = LAAEmployeeCallCoordinator(control: LAAFixtureCallControl())
    @State private var voice = LAAStaff.ciel.defaultGPTLiveVoice
    private let args = ProcessInfo.processInfo.arguments
    private let profile = "laa-ciel"
    private let conversationID = "fixture-conversation"

    private var reason: String? {
        if args.contains("-laa-unpaired") { return LAAEmployeeCallAvailability.bridgeReason(.unpaired) }
        if args.contains("-laa-revoked") { return LAAEmployeeCallAvailability.bridgeReason(.revoked) }
        if args.contains("-laa-offline") { return "Hermesに接続してください" }
        if args.contains("-laa-no-voice") {
            return LAAEmployeeCallAvailability.voiceReason(profile: profile, canStart: false, issue: .noTextToSpeech)
        }
        return nil
    }

    var body: some View {
        if args.contains("-laa-gpt-live-settings") {
            settingsFixture
        } else if args.contains("-laa-composer-fixture") {
            LAAEmployeeComposerFixture(calls: calls, savedCall: args.contains("-laa-saved-call"))
        } else {
            callFixture
        }
    }

    private var settingsFixture: some View {
        ScrollView {
            GPTLiveSettingsSection(model: GPTLiveSettingsModel(
                enabled: true,
                setEnabled: { _ in },
                checkAvailability: { .success(.available(model: "fixture", voice: "vale")) },
                voice: "vale",
                billing: .api,
                apiVoice: "cedar"
            ))
            .padding()
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
                    LAAEmployeeHeader(profile: profile, name: "Ciel", status: reason ?? "● 待機中",
                                      voiceSetting: $voice)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    LAAEmployeeCallButton(reason: reason) {
                        calls.start(profile: profile, name: "Ciel", conversationID: conversationID)
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
    @Published var session = "pending"
    @Published var started = false
}

/// The controller starts this session instead of touching a microphone or network.
@MainActor
private final class LAAResumeFixtureSession: GPTLiveSessionControlling {
    var onEvent: (@MainActor (GPTLiveProtocol.ServerEvent) -> Void)?
    var onStateChange: (@MainActor (GPTLiveSession.State) -> Void)?
    var onAudioPaused: (@MainActor (Bool) -> Void)?
    let isReady = false
    let voiceNote: String? = nil
    let briefingApplied = false
    private let evidence: LAAResumeFixtureEvidence

    init(evidence: LAAResumeFixtureEvidence) { self.evidence = evidence }
    func start() { evidence.started = true }
    func stop() {}
    func appendContext(_ text: String, channel: GPTLiveProtocol.Channel, delegationID: String?) -> Bool { false }
    func setMicrophoneEnabled(_ enabled: Bool) {}
    func setSpeakerEnabled(_ enabled: Bool) {}
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
        if savedCall {
            app.setActiveProfileForTesting("laa-cfo")
            app.setLAAEmployeeVoice("spruce", profile: "laa-cfo")
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
            app.gptLiveClient = app.laaGPTLiveClient { path, _, _, _ in
                evidence.statusPath = path
                return ["ok": true, "available": true, "auth": "subscription"]
            }
            app.gptLiveHostRequestForTesting = { path, _, _, _ in
                if path.contains(GeminiLiveTokenClient.personalityPath) {
                    evidence.personaPath = path
                    return ["ok": true, "available": true, "text": "Morgan fixture persona"]
                }
                return ["ok": true, "available": false]
            }
            app.gptLiveSessionFactoryForTesting = { history, voice, briefing in
                let json = (try? JSONSerialization.data(withJSONObject: history))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                evidence.session = "\(voice ?? "none")|\(briefing.contains("Morgan fixture persona"))|\(briefing.contains("Morgan saved summary"))|\(json.contains("Morgan saved turn"))"
                return LAAResumeFixtureSession(evidence: evidence)
            }
            app.gptLiveController.requestPermissionForTesting = { true }
        } else {
            app.setActiveProfileForTesting("default")
            if !ProcessInfo.processInfo.arguments.contains("-laa-default-call") {
                app.noteBotChatSessionForTesting("fixture-conversation", profile: "laa-cfo")
            }
            app.gptLiveClient = app.laaGPTLiveClient { _, _, _, _ in
                ["ok": true, "available": false, "auth": "subscription", "reason": "fixture offline"]
            }
        }
        app.setGPTLiveEnabled(true)
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
            if ProcessInfo.processInfo.arguments.contains("-laa-pending-call") {
                Button {
                    appState.laaEmployeeGPTLivePlan = appState.laaEmployeeGPTLivePlan == nil
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
                        Text(verbatim: "\(evidence.session)|\(evidence.started)")
                            .accessibilityIdentifier("laa.fixture.session-evidence")
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
