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
#endif
