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
        if sameCall {
            if case .failed = calls.snapshot?.phase { return "通話を確認" }
            return "通話中"
        }
        return appState.isConnected ? "" : "接続中…"
    }

    private var header: some View {
        LAAEmployeeHeader(profile: profile, name: name, avatarURL: appState.profileAvatarURL(for: profile),
                          status: status, activity: appState.isBusy ? .lively : .resting,
                          isObscured: calls.isShowingCall,
                          voiceSetting: appState.laaEmployeeVoiceBinding(profile: profile), voiceSettingEnabled: appState.isConnected,
                          compact: dynamicTypeSize.isAccessibilitySize, information: menu)
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

    // The system's own slots: it centers the name on the screen and gives
    // the call button and menu one glass with Back's margin.
    @ToolbarContentBuilder var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            header
                .frame(maxWidth: LAAConversationHeaderLayout.nameWidth(screenWidth: screenWidth))
                .frame(minHeight: LAAConversationHeaderLayout.controlHeight)
        }
        if reason == nil, LAAStaff(profile: profile)?.supportsCalls != false {
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .topBarTrailing) { callButton }.sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .topBarTrailing) { callButton }
            }
        }
    }
}

/// The call button and the conversation menu at the bar's trailing end.
/// One item on iPhone, since two get a capsule too wide to leave the name
/// centered. Two on Mac, whose bar turns an item holding a menu into that
/// menu, so the call button there opened the menu (2026-11-09).
struct LAAConversationControlItems<Call: View>: ToolbarContent {
    let call: Call
    var menu: AnyView? = nil

    @ToolbarContentBuilder var body: some ToolbarContent {
        #if targetEnvironment(macCatalyst)
        ToolbarItem(placement: .topBarTrailing) { call }
        if let menu { ToolbarItem(placement: .topBarTrailing) { menu } }
        #else
        ToolbarItem(placement: .topBarTrailing) {
            LAAConversationControls {
                call
                if let menu { menu }
            }
        }
        #endif
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
    static let sideReserve: CGFloat = 76

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
            return "この会話はテキスト専用です"
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
    var information: AnyView? = nil
    @Environment(\.laaClearGlassControls) private var clearGlass
    @State private var showDetails = false
    /// The mascot is the bar's one picture: larger than the controls around it.
    private var mascotSize: CGFloat { compact ? 64 : 100 }

    var body: some View {
        headerLabel
            .frame(height: 44, alignment: .top)
            .overlay(alignment: .top) {
                Button { showDetails = true } label: {
                    Color.clear.frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: LAACopy.staffIntroHeaderLabel(name)))
                    .accessibilityIdentifier("laa.employee.header")
            }
            // The mascot opens the employee's introduction, as it did before
            // the header took the conversation menu (owner, 2026-11-11); the
            // conversation's information is a row inside it.
            .sheet(isPresented: $showDetails) {
                LAAStaffIntroView(profile: profile, name: name, avatarURL: avatarURL, status: status,
                                  voiceSetting: voiceSetting, voiceSettingEnabled: voiceSettingEnabled,
                                  information: information, onClose: { showDetails = false })
            }
    }

    private var headerLabel: some View {
        VStack(spacing: 0) {
            StaffAvatarView(profile: profile, name: name, fallbackURL: avatarURL, size: mascotSize,
                            scrolling: showDetails || isObscured, activity: activity)
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: LAAChatPerson.name(name)).font(LAAType.title(name, size: 17, relativeTo: .headline))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    if let role = LAAChatPerson.role(profile: profile) { LAARoleBadge(role: role) }
                }
                if !status.isEmpty {
                    Text(verbatim: status).font(.caption2).foregroundStyle(LAAColor.secondaryText).lineLimit(1)
                }
            }.modifier(LAAEmployeeHeaderGlass(clear: clearGlass))
        }.fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
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

struct LAAEmployeeCallButton: View {
    let reason: String?
    var hint: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "phone.fill")
                .font(.system(size: 20))
                .foregroundStyle(LAAColor.link)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .laaComposerGlass(in: Circle())
        .disabled(reason != nil)
        .accessibilityLabel(Text(verbatim: "電話"))
        .accessibilityHint(reason ?? hint ?? "この会話の社員と通話します")
        .accessibilityIdentifier("laa.employee.call")
    }
}
#endif
