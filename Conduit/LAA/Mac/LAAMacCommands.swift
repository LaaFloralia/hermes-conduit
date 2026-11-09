#if LAA_BUILD && targetEnvironment(macCatalyst)
import SwiftUI

/// The Mac menu bar. Navigation and window items leave a request in
/// `LAAMacCommandsModel`; the items that act on a section's content read the
/// commands that section publishes, so ⌘N, ⌘F and ⌘R exist once — in the
/// menu — and only in the sections that can carry them out.
struct LAAMacCommands: Commands {
    @ObservedObject private var model = LAAMacCommandsModel.shared
    @FocusedValue(\.laaMacSectionCommands) private var section

    var body: some Commands {
        CommandMenu(LAACopy.macMenuGo) {
            ForEach(LAAMacSection.allCases) { item in
                Button(item.title) { model.pendingSection = item }
                    .keyboardShortcut(item.shortcutKey, modifiers: .command)
            }
            Divider()
            Button(LAACopy.macToggleSidebar) { model.toggleSidebar += 1 }
                .keyboardShortcut("s", modifiers: [.command, .control])
        }
        // Where a Mac app keeps them, so no menu is named after one section:
        // Search in Edit, Reload and closing the conversation in View.
        CommandGroup(after: .textEditing) {
            Button(LAACopy.macSearch) { section?.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(section?.canSearch != true)
        }
        CommandGroup(before: .toolbar) {
            Button(LAACopy.macReload) { section?.reload() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(section?.canReload != true)
            // Escape closes the conversation where it is read (the
            // conversation's own key handler); the menu repeats the action
            // without taking the key from sheets and dialogs.
            Button(LAACopy.macCloseConversation) { model.closeConversation += 1 }
                .disabled(model.activeSection != .chats)
            Divider()
        }
        // New Window is not this app's: one window holds the LAA desktop.
        CommandGroup(replacing: .newItem) {
            Button(section?.newTitle ?? LAACopy.macNewChat) { section?.create() }
                .keyboardShortcut(section?.newShortcut ?? "n", modifiers: section?.newModifiers ?? .command)
                .disabled(section?.canCreate != true)
        }
        CommandGroup(replacing: .appSettings) {
            Button(LAACopy.macSettingsMenu) { model.openSettings += 1 }
                .keyboardShortcut(",", modifiers: .command)
        }
    }
}
#endif
