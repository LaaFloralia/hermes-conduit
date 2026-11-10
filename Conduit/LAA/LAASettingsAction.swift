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

/// The same system toolbar control is used at the root of each tab. The Mac
/// keeps one Settings entry instead — the row under its sidebar — so the
/// toolbar button stays on the phone.
struct LAASettingsButton: View {
    @Environment(\.laaDesktop) private var laaDesktop
    let action: () -> Void

    var body: some View {
        if !laaDesktop {
            LAAToolbarIconButton(systemName: "gearshape", label: "設定", action: action)
                .accessibilityLabel(Text(verbatim: "設定"))
                .accessibilityIdentifier("laa.settings.open")
                .macTooltip(LAACopy.settings)
        }
    }
}

#endif
