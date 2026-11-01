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

/// The same system toolbar control is used at the root of each tab.
struct LAASettingsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: "gearshape") }
            .accessibilityLabel(Text(verbatim: LAACopy.settings))
            .accessibilityIdentifier("laa.settings.open")
    }
}

#endif
