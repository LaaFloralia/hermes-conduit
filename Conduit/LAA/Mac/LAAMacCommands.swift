#if LAA_BUILD && targetEnvironment(macCatalyst)
import SwiftUI

/// The Mac menu bar. Every item leaves a request in `LAAMacCommandsModel`;
/// the window owns the selection, the split view and the chat, so the menu
/// and the window never hold two copies of the same state.
struct LAAMacCommands: Commands {
    @ObservedObject private var model = LAAMacCommandsModel.shared

    var body: some Commands {
        CommandMenu(LAACopy.macMenuGo) {
            ForEach(LAAMacSection.allCases) { section in
                Button(section.title) { model.pendingSection = section }
                    .keyboardShortcut(section.shortcutKey, modifiers: .command)
            }
            Divider()
            Button(LAACopy.macToggleSidebar) { model.toggleSidebar += 1 }
                .keyboardShortcut("s", modifiers: [.command, .control])
        }
        CommandMenu(LAACopy.macMenuChat) {
            Button(LAACopy.macSearch) { model.focusSearch += 1 }
                .keyboardShortcut("f", modifiers: .command)
            Button(LAACopy.macReload) { model.reload += 1 }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button(LAACopy.macCloseConversation) { model.closeConversation += 1 }
        }
        // New Window is not this app's: one window holds the LAA desktop.
        CommandGroup(replacing: .newItem) {
            Button(LAACopy.macNewChat) { model.newChat += 1 }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(replacing: .appSettings) {
            Button(LAACopy.macSettingsMenu) { model.openSettings += 1 }
                .keyboardShortcut(",", modifiers: .command)
        }
    }
}
#endif
