#if LAA_BUILD
import SwiftUI

struct LAAEmployeeChatToolbar: ToolbarContent {
    /// The screen width, which bounds the name so the bar can keep it on
    /// the screen's center.
    var screenWidth: CGFloat = 0
    /// The conversation menu, after the call button in the same glass.
    var menu: AnyView? = nil
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var calls: LAAEmployeeCallCoordinator

    private var profile: String { appState.conversationIdentityProfile }
    private var name: String {
        LAAStaff(profile: profile)?.name ?? (profile == "default" ? LAACopy.agent : appState.conversationAgentIdentity.name)
    }
    private var sameCall: Bool {
        calls.snapshot?.context.profile == profile && calls.snapshot?.context.conversationID == appState.activeSessionId
    }
    private var reason: String? {
        LAAEmployeeCallAvailability.reason(appState: appState, bridge: bridge.status, calls: calls)
    }
    private var status: String {
        if let reason { return reason }
        if sameCall {
            if case .failed = calls.snapshot?.phase { return "▲ 通話を確認" }
            return "● 通話中"
        }
        return appState.isBusy ? "● 応答中" : "● 待機中"
    }

    private var header: some View {
        LAAEmployeeHeader(profile: profile, name: name, avatarURL: appState.profileAvatarURL(for: profile),
                          status: status, activity: appState.isBusy ? .lively : .resting,
                          isObscured: calls.isShowingCall,
                          voiceSetting: voiceSetting(for: profile), voiceSettingEnabled: appState.isConnected,
                          compact: (LAAConversationHeaderLayout.nameWidth(screenWidth: screenWidth) ?? 200) < 140 || dynamicTypeSize.isAccessibilitySize)
            .laaPhotoGlassScope()
    }

    private var callButton: some View {
        let dotCall = LAAStaff(profile: profile)?.dotCallURL
        return LAAEmployeeCallButton(reason: reason, hint: dotCall.map(LAAEmployeeCallAvailability.dotCallHint)) {
            if let dotCall {
                openURL(dotCall)
            } else if LAAStaff(profile: profile) != nil {
                _ = calls.startEmployeeConversation(appState)
            } else if sameCall {
                calls.showCall()
            } else {
                calls.start(profile: profile, name: name, conversationID: appState.activeSessionId)
            }
        }
    }

    // The system's own slots: it centers the name on the screen and gives
    // the call button and menu one glass with Back's margin. One item, not
    // two: two get a capsule too wide to leave the name centered.
    @ToolbarContentBuilder var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            header
                .frame(maxWidth: LAAConversationHeaderLayout.nameWidth(screenWidth: screenWidth))
                .frame(minHeight: LAAConversationHeaderLayout.controlHeight)
        }
        ToolbarItem(placement: .topBarTrailing) {
            LAAConversationControls {
                callButton
                if let menu { menu }
            }
        }
    }

    private func voiceSetting(for profile: String) -> Binding<String>? {
        guard let staff = LAAStaff(profile: profile), staff.supportsCalls else { return nil }
        return Binding(get: { appState.laaEmployeeVoice(profile: profile) ?? staff.defaultGPTLiveVoice },
                       set: { appState.setLAAEmployeeVoice($0, profile: profile) })
    }
}

/// The call button and the conversation menu side by side in one bar item,
/// so the system draws one glass around both.
struct LAAConversationControls<Controls: View>: View {
    @ViewBuilder let controls: Controls

    var body: some View {
        HStack(spacing: 0) { controls }
            .frame(height: LAAConversationHeaderLayout.controlHeight)
            .fixedSize()
    }
}

enum LAAConversationHeaderLayout {
    /// The bar's controls are all this tall, so their centers line up.
    static let controlHeight: CGFloat = 44
    /// What the call/menu capsule and its margin take on the trailing side.
    /// A name no wider than the screen less this on both sides fits between
    /// equal margins, so the bar keeps it on the screen's center.
    static let sideReserve: CGFloat = 136

    /// The widest the name may be; nil until the screen width is known.
    static func nameWidth(screenWidth: CGFloat) -> CGFloat? {
        guard screenWidth > 0 else { return nil }
        return max(96, screenWidth - 2 * sideReserve)
    }
}

enum LAAEmployeeCallAvailability {
    @MainActor
    static func reason(appState: AppState, bridge: LAABridgeSession.Status, calls: LAAEmployeeCallCoordinator) -> String? {
        let profile = appState.conversationIdentityProfile
        if let staff = LAAStaff(profile: profile), !staff.supportsCalls {
            guard staff == .monetDots else { return "この会話はテキスト専用です" }
            // The call itself runs in ChatGPT: only a call here holds it back.
            guard staff.dotCallURL != nil else { return "通話先が設定されていません" }
            let callHere = calls.snapshot != nil || appState.isVoiceCallInProgress || appState.laaEmployeeGPTLivePlan != nil
            return callHere ? LAACopy.otherCallInProgress : nil
        }
        if let snapshot = calls.snapshot {
            return snapshot.context.profile == profile && snapshot.context.conversationID == appState.activeSessionId
                ? nil : "別の会話の通話を確認してください"
        }
        if appState.isVoiceCallInProgress || appState.laaEmployeeGPTLivePlan != nil {
            return LAACopy.otherCallInProgress
        }
        if let reason = bridgeReason(bridge) { return reason }
        guard appState.isConnected else { return "Macに接続してください" }
        if let reason = voiceReason(profile: profile, canStart: appState.canStartPhoneVoiceConversation,
                                    issue: appState.voiceSetupIssue) { return reason }
        return calls.unavailableReason
    }

    static func dotCallHint(_ link: URL) -> String {
        link.scheme == "shortcuts" ? "ChatGPTでMonetと通話します" : "ブラウザでMonetの通話画面を開きます"
    }

    static func voiceReason(profile: String, canStart: Bool, issue: VoiceSetupIssue?) -> String? {
        guard LAAStaff(profile: profile) == nil, !canStart else { return nil }
        return voiceReason(issue)
    }

    static func bridgeReason(_ status: LAABridgeSession.Status) -> String? {
        switch status {
        case .paired: return nil
        case .unpaired: return "端末を接続すると通話できます"
        case .revoked, .unauthorized: return "端末を再接続してください"
        case .keychainError: return "接続情報を読み込めません"
        }
    }

    static func voiceReason(_ issue: VoiceSetupIssue?) -> String {
        switch issue {
        case .voiceOff: return "音声をオンにしてください"
        case .speechRecognitionDenied: return "音声認識を許可してください"
        case .speechRecognitionUnsupported: return "この言語の音声認識を設定してください"
        case .noSpeechToText: return "音声入力を設定してください"
        case .noTextToSpeech: return "音声出力を設定してください"
        default: return "音声設定を確認してください"
        }
    }
}

struct LAAEmployeeHeader: View {
    let profile: String
    let name: String
    var avatarURL: URL? = nil
    let status: String
    var activity: StaffAvatarActivity = .resting
    var isObscured = false
    var voiceSetting: Binding<String>? = nil
    var voiceSettingEnabled = true
    var compact = false
    @Environment(\.laaClearGlassControls) private var clearGlass
    @State private var showDetails = false
    /// The mascot is the bar's one picture: larger than the controls around it.
    private static let mascotSize: CGFloat = 66

    var body: some View {
        Button { showDetails = true } label: {
            HStack(spacing: 6) {
                if !compact {
                    // Outside the pill and taller than it: the mascot stands
                    // in the bar on its own, with nothing drawn around it.
                    StaffAvatarView(profile: profile, name: name, fallbackURL: avatarURL, size: Self.mascotSize,
                                    scrolling: showDetails || isObscured, activity: activity)
                        .frame(height: LAASpacing.minimumTouchTarget)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.custom("Georgia", size: 16, relativeTo: .headline))
                        .lineLimit(1).minimumScaleFactor(compact ? 0.5 : 0.8)
                        .multilineTextAlignment(compact ? .center : .leading)
                    if !compact { Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
                .modifier(LAAEmployeeHeaderGlass(clear: clearGlass))
            }
            .frame(minHeight: LAASpacing.minimumTouchTarget)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showDetails) {
            LAAStaffDetailView(profile: profile, name: name, avatarURL: avatarURL, status: status,
                               voiceSetting: voiceSetting, voiceSettingEnabled: voiceSettingEnabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: name + ", " + status))
        .accessibilityIdentifier("laa.employee.header")
    }
}

private struct LAAEmployeeHeaderGlass: ViewModifier {
    let clear: Bool

    @ViewBuilder func body(content: Content) -> some View {
        // The pill holds only the name: Back, the pill and the call capsule
        // share a center line.
        if clear {
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .conduitGlassControl(cornerRadius: 20, tint: .conduitAccent.opacity(0.06), interactive: false)
        } else {
            content
                .padding(.horizontal, LAASpacing.x2)
                .padding(.vertical, 5)
                .conduitGlassControl(cornerRadius: LAARadius.control, tint: LAAColor.link.opacity(0.06), interactive: false)
        }
    }
}

private struct LAAStaffDetailView: View {
    let profile: String
    let name: String
    let avatarURL: URL?
    let status: String
    let voiceSetting: Binding<String>?
    let voiceSettingEnabled: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                StaffMascotView(profile: profile, name: name, fallbackURL: avatarURL, size: 220)
                Text(name).font(.custom("Georgia", size: 26, relativeTo: .title))
                if let role = LAAStaff(profile: profile)?.role { Text(role).font(.subheadline) }
                Text(status).font(.caption).foregroundStyle(.secondary)
                if let voiceSetting {
                    Picker(selection: voiceSetting) {
                        ForEach(GPTLiveVoice.all) { voice in Text(voice.label).tag(voice.name) }
                    } label: {
                        Text(verbatim: "通話の声")
                    }
                    .pickerStyle(.menu)
                    .disabled(!voiceSettingEnabled)
                    .accessibilityIdentifier("laa.employee.voice-setting")
                    .padding(.horizontal, LAASpacing.horizontal)
                    Text(verbatim: "ChatGPT の声を社員ごとに設定します")
                        .laaTextStyle(.secondary)
                        .foregroundStyle(LAAColor.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(Text(verbatim: "社員の詳細"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: { dismiss() }) { Text(verbatim: LAACopy.close) }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct LAAEmployeeCallButton: View {
    let reason: String?
    var hint: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "phone.fill")
                .frame(width: 40, height: 40)
                .contentShape(Circle())
                .laaToolbarGlass()
        }
        .disabled(reason != nil)
        .accessibilityLabel(Text(verbatim: "電話"))
        .accessibilityHint(reason ?? hint ?? "この会話の社員と通話します")
        .accessibilityIdentifier("laa.employee.call")
    }
}
#endif
