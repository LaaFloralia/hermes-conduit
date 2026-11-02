#if LAA_BUILD && targetEnvironment(macCatalyst)
import SwiftUI

/// Chats on the Mac: the phone's list in the left column, the open
/// conversation beside it. Selecting a row switches the detail column; it
/// never pushes a screen, so Back and the tab bar stay out of the way.
struct LAAMacChatsSection: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var commands: LAAMacCommandsModel
    @Binding var conversationShown: Bool

    private var requiresLogin: Bool { LAAMacLogin.isRequired(appState) }

    private var hasConversation: Bool {
        appState.activeRoomSurface != nil || appState.activeSessionId != nil
    }

    /// The highlighted row: a room by its id, a person by the profile whose
    /// conversation is open.
    private var selection: LAAChatsListSelection {
        LAAChatsListSelection(
            profile: conversationShown && appState.activeRoomSurface == nil
                ? appState.conversationIdentityProfile : nil,
            roomID: conversationShown ? appState.activeRoomSurface?.room.roomID : nil,
            focusSearch: commands.focusSearch,
            reload: commands.reload,
            newChat: commands.newChat
        )
    }

    var body: some View {
        if requiresLogin {
            // Sign-in, where the phone's Chats tab shows it: a card at a
            // readable width in the middle of the window, not stretched
            // across it. The other sections keep their own screens.
            // The phone's sign-in draws its own backdrop and centres its own
            // form, so it fills the column rather than sitting in a frame:
            // framed, the backdrop showed as a floating rectangle with a hard
            // edge and the form left a wide empty margin beside it.
            LoginView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.horizontalSizeClass, .compact)
        } else {
            split
        }
    }

    private var split: some View {
        LAAMacListDetail(listWidth: LAADesktopMetrics.listIdealWidth) {
            LAAChatsView(appState: appState, selection: selection)
                // The list polls only while it is the shown tab, exactly as
                // the phone's Chats tab does.
                .environment(\.v2Shell, V2ShellContext(values: .init(isTabActive: true, isRootCovered: false)))
                .environment(\.horizontalSizeClass, .compact)
                .modifier(LAAMacFlatTopEdge())
        } detail: {
            detail
        }
        .onChange(of: appState.activeSessionId) { _, id in
            guard id != nil else { return }
            conversationShown = true
        }
        .onChange(of: appState.activeRoomSurface?.room.roomID) { _, id in
            guard id != nil else { return }
            conversationShown = true
        }
        .onChange(of: appState.showSidebar) { _, covered in
            if covered {
                conversationShown = false
            } else if !conversationShown, hasConversation {
                conversationShown = true
            }
        }
        .onChange(of: conversationShown, initial: true) { _, shown in
            // Covered means streaming rows needn't redraw and the chat isn't
            // counted as seen (AppState.showSidebar), as on the phone.
            if appState.showSidebar == shown { appState.showSidebar = !shown }
        }
        // Leaving a room ends its screen, as popping it does on the phone.
        .onChange(of: conversationShown) { _, shown in
            guard !shown, appState.activeRoomSurface != nil else { return }
            let epoch = appState.groupRoomEpoch
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                guard !conversationShown, appState.activeRoomSurface != nil else { return }
                if appState.groupRoomEpoch == epoch {
                    appState.closeGroupRoom()
                } else if !appState.isVoiceCallScreenPresented {
                    conversationShown = true
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch LAAMacChatDetail.resolve(shown: conversationShown, hasConversation: hasConversation) {
        case .conversation:
            V2ConversationScreen()
                // Beside the list: no Back, and its close button returns the
                // column to the list (V2ConversationScreen's split branch).
                .environment(\.v2Shell, V2ShellContext(
                    values: .init(isTabActive: true, isRootCovered: false, isSplit: true)
                ))
                .environment(\.horizontalSizeClass, .compact)
                .laaReadableWidth(LAADesktopMetrics.readingWidth)
                .modifier(LAAMacFlatTopEdge())
                .accessibilityIdentifier("laa.mac.conversation")
                .onKeyPress(.escape) {
                    appState.showSidebar = true
                    return .handled
                }
        case .empty:
            LAAMacEmptyDetail(symbol: "bubble.left.and.bubble.right",
                              title: LAACopy.macNoChatTitle,
                              message: LAACopy.macNoChatBody)
                .accessibilityIdentifier("laa.mac.chats.empty")
        }
    }
}

/// What the Chat section's detail column shows. A conversation is there only
/// when one is open and the list hasn't been returned to: the same rule the
/// phone's pushed screen follows, stated once so it can be tested.
enum LAAMacChatDetail: Equatable {
    case conversation
    case empty

    static func resolve(shown: Bool, hasConversation: Bool) -> LAAMacChatDetail {
        shown && hasConversation ? .conversation : .empty
    }
}

/// The Mac shows sign-in in the Chat section, where the phone's Chats tab
/// shows it, instead of covering the whole window.
@MainActor
enum LAAMacLogin {
    static func isRequired(_ appState: AppState) -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CONDUIT_UITEST"] == "1",
           ProcessInfo.processInfo.arguments.contains("-LAA_UI_TEST_FORCE_LOGIN") { return true }
        #endif
        return appState.showLogin || (appState.connection == nil && appState.offlineChatPresentation == nil)
    }
}

#endif
