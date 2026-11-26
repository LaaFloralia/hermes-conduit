import SwiftUI

public extension EnvironmentValues {
    /// Forces the Reduce Motion appearance of kit components (previews, snapshots, in-app settings).
    @Entry var laaForceReduceMotion = false
    /// Forces the Reduce Transparency appearance (opaque `surface` instead of glass).
    @Entry var laaForceReduceTransparency = false
}

public extension View {
    /// Shows kit components as if Reduce Motion / Reduce Transparency were on. The system settings always apply too.
    func laaAccessibility(reduceMotion: Bool = false, reduceTransparency: Bool = false) -> some View {
        environment(\.laaForceReduceMotion, reduceMotion)
            .environment(\.laaForceReduceTransparency, reduceTransparency)
    }
}

/// System setting OR the kit override.
@propertyWrapper struct LAAReduceMotion: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var system
    @Environment(\.laaForceReduceMotion) private var forced
    init() {}
    var wrappedValue: Bool { system || forced }
}

@propertyWrapper struct LAAReduceTransparency: DynamicProperty {
    @Environment(\.accessibilityReduceTransparency) private var system
    @Environment(\.laaForceReduceTransparency) private var forced
    init() {}
    var wrappedValue: Bool { system || forced }
}
