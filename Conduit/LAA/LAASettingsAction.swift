#if LAA_BUILD

import SwiftUI

private struct LAASettingsActionKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// Opens Conduit's settings (the same sheet the drawer's gear opens).
    var laaSettingsAction: (() -> Void)? {
        get { self[LAASettingsActionKey.self] }
        set { self[LAASettingsActionKey.self] = newValue }
    }
}

/// Where Settings is entered. On the iPhone the app icon in the glass tab bar opens the settings card, whose
/// last row is Settings, so no tab draws a gear (2026-11-26). The Mac keeps its sidebar entry and ⌘,.
enum LAASettingsEntry {
    static var showsToolbarGear: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }
}

/// The same system toolbar control is used at the root of each tab. The Mac
/// keeps one Settings entry instead — the row under its sidebar — so the
/// toolbar button stays on the phone.
struct LAASettingsButton: View {
    @Environment(\.laaDesktop) private var laaDesktop
    let action: () -> Void

    var body: some View {
        if !laaDesktop, LAASettingsEntry.showsToolbarGear {
            LAAToolbarIconButton(systemName: "gearshape", label: "Settings", action: action)
                .accessibilityLabel(Text(verbatim: "Settings"))
                .accessibilityIdentifier("laa.settings.open")
                .macTooltip(LAACopy.settings)
        }
    }
}

#endif
