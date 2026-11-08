#if LAA_BUILD
import SwiftUI

extension AppState {
    /// The person left a chat that was still opening: drop the launch, so it
    /// doesn't bring the chat back on screen when the switch lands.
    func laaCancelOpeningEmployeeChat() {
        guard laaOpeningEmployeeChat != nil,
              widgetLaunchCoordinator.pendingLink?.action == .employeeChat else { return }
        widgetLaunchCoordinator.supersede()
    }
}

/// The phone's chat route: the opening screen while a tapped employee's chat
/// is on its way, the conversation once it is open.
struct LAAConversationRoute: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if let profile = appState.laaOpeningEmployeeChat {
                LAAEmployeeChatOpeningView(profile: profile)
            } else {
                V2ConversationScreen()
            }
        }
        .toolbar(.hidden, for: .tabBar)
    }
}

/// Shown the moment an employee is tapped, before the profile switch and the
/// chat's own read finish: the tap answers at once with the employee it asked
/// for, and the conversation replaces this screen when it is ready.
struct LAAEmployeeChatOpeningView: View {
    let profile: String
    @EnvironmentObject private var appState: AppState

    private var name: String {
        LAAStaff(profile: profile)?.name ?? appState.profileHermesNames[profile] ?? profile
    }

    var body: some View {
        VStack(spacing: LAASpacing.x4) {
            StaffAvatarView(profile: profile, name: name, fallbackURL: appState.profileAvatarURL(for: profile),
                            size: 132, activity: .lively)
                .accessibilityHidden(true)
            VStack(spacing: LAASpacing.x1) {
                Text(verbatim: name).font(LAAType.employeeName).foregroundStyle(LAAColor.text)
                if let role = LAAStaff(profile: profile)?.role {
                    Text(verbatim: role).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                }
            }
            HStack(spacing: LAASpacing.x2) {
                ProgressView().controlSize(.small)
                Text(verbatim: LAACopy.chatsOpening).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
        }
        .padding(LAASpacing.x8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LAAColor.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: name + "、" + LAACopy.chatsOpening))
        .accessibilityIdentifier("laa.chats.opening")
    }
}
#endif
