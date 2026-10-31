#if LAA_BUILD
import SwiftUI

struct LAAEmployeeChatToolbar: ToolbarContent {
    var compactMenu: AnyView? = nil
    var compactWidth: CGFloat = 0
    var compactLeadingInset: CGFloat = 0
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var bridge: LAABridgeSession
    @EnvironmentObject private var calls: LAAEmployeeCallCoordinator

    private var profile: String { appState.conversationIdentityProfile }
    private var name: String {
        LAAStaff(profile: profile)?.name ?? (profile == "default" ? "LAA" : appState.conversationAgentIdentity.name)
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
                          status: status, isObscured: calls.isShowingCall,
                          voiceSetting: voiceSetting(for: profile), voiceSettingEnabled: appState.isConnected)
            .laaPhotoGlassScope()
    }

    private var callButton: some View {
        LAAEmployeeCallButton(reason: reason) {
            if LAAStaff(profile: profile) != nil {
                _ = calls.startEmployeeConversation(appState)
            } else if sameCall {
                calls.showCall()
            } else {
                calls.start(profile: profile, name: name, conversationID: appState.activeSessionId)
            }
        }
    }

    @ToolbarContentBuilder var body: some ToolbarContent {
        if let compactMenu {
            ToolbarItem(placement: .principal) {
                LAACompactConversationToolbar(width: compactWidth, leadingInset: compactLeadingInset) {
                    header
                } controls: {
                    callButton
                    compactMenu
                }
            }
        } else {
            ToolbarItem(placement: .principal) { header }
            ToolbarItem(placement: .topBarTrailing) { callButton }
        }
    }

    private func voiceSetting(for profile: String) -> Binding<String>? {
        guard let staff = LAAStaff(profile: profile) else { return nil }
        return Binding(get: { appState.laaEmployeeVoice(profile: profile) ?? staff.defaultGPTLiveVoice },
                       set: { appState.setLAAEmployeeVoice($0, profile: profile) })
    }
}

/// Keep the same controls in the header when the system would otherwise
/// place trailing toolbar items in the Duo's side rail.
struct LAACompactConversationToolbar<Title: View, Controls: View>: View {
    let width: CGFloat
    let leadingInset: CGFloat
    @ViewBuilder let title: Title
    @ViewBuilder let controls: Controls

    var body: some View {
        HStack(spacing: LAASpacing.x1) {
            if leadingInset > 0 {
                Color.clear
                    .frame(width: leadingInset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            title
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            HStack(spacing: LAASpacing.x1) { controls }
                .padding(.horizontal, LAASpacing.x1)
                .conduitGlassControl(cornerRadius: LAARadius.control, tint: LAAColor.link.opacity(0.08))
                .laaPhotoGlassScope()
                .fixedSize()
        }
        .frame(width: max(0, width - 2 * LAASpacing.horizontal))
    }
}

enum LAAEmployeeCallAvailability {
    @MainActor
    static func reason(appState: AppState, bridge: LAABridgeSession.Status, calls: LAAEmployeeCallCoordinator) -> String? {
        let profile = appState.conversationIdentityProfile
        if let snapshot = calls.snapshot {
            return snapshot.context.profile == profile && snapshot.context.conversationID == appState.activeSessionId
                ? nil : "別の会話の通話を確認してください"
        }
        if appState.isVoiceCallInProgress || appState.laaEmployeeGPTLivePlan != nil {
            return LAACopy.otherCallInProgress
        }
        if let reason = bridgeReason(bridge) { return reason }
        guard appState.isConnected else { return "Hermesに接続してください" }
        if let reason = voiceReason(profile: profile, canStart: appState.canStartPhoneVoiceConversation,
                                    issue: appState.voiceSetupIssue) { return reason }
        return calls.unavailableReason
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
    var isObscured = false
    var voiceSetting: Binding<String>? = nil
    var voiceSettingEnabled = true
    @Environment(\.laaClearGlassControls) private var clearGlass
    @State private var showDetails = false

    var body: some View {
        Button { showDetails = true } label: {
            HStack(spacing: 8) {
                StaffAvatarView(profile: profile, name: name, fallbackURL: avatarURL, size: 38,
                                scrolling: showDetails || isObscured)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.custom("Georgia", size: 16, relativeTo: .headline)).lineLimit(1)
                    Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .modifier(LAAEmployeeHeaderGlass(clear: clearGlass))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showDetails) {
            LAAStaffDetailView(profile: profile, name: name, avatarURL: avatarURL, status: status,
                               voiceSetting: voiceSetting, voiceSettingEnabled: voiceSettingEnabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("laa.employee.header")
    }
}

private struct LAAEmployeeHeaderGlass: ViewModifier {
    let clear: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if clear {
            content
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .conduitGlassControl(cornerRadius: 20, tint: .conduitAccent.opacity(0.06), interactive: false)
        } else {
            content
                .padding(.horizontal, LAASpacing.x2)
                .padding(.vertical, LAASpacing.x1)
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
                StaffAvatarView(profile: profile, name: name, fallbackURL: avatarURL, size: 156, scrolling: true)
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
                    Button(action: { dismiss() }) { Text(verbatim: "閉じる") }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct LAAEmployeeCallButton: View {
    let reason: String?
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
        .accessibilityHint(reason ?? "この会話の社員と通話します")
        .accessibilityIdentifier("laa.employee.call")
    }
}
#endif
