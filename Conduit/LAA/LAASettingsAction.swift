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

#endif
