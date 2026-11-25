import SwiftUI

public extension Color {
    init(laa value: LAARGB, opacity: Double = 1) {
        self.init(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: opacity)
    }
}

/// The resolved colours for one theme set and one appearance. Read it from the environment
/// (`@Environment(\.laaPalette)`); never write a HEX or a system colour in a view.
public struct LAAPalette: Sendable, Equatable {
    public let themeID: String
    public let isDark: Bool
    public let increasedContrast: Bool
    public let raw: LAAThemeColors
    public let semantic: LAASemanticColors

    public init(theme: LAAThemeSet = LAAThemeSets.set(id: nil), dark: Bool = false, increasedContrast: Bool = false) {
        themeID = theme.id
        isDark = dark
        self.increasedContrast = increasedContrast
        raw = theme.colors(dark: dark)
        semantic = dark ? LAASemantic.dark : LAASemantic.light
    }

    public var bg: Color { Color(laa: raw.bg) }
    public var surface: Color { Color(laa: raw.surface) }
    public var wash: Color { Color(laa: raw.wash) }
    public var text: Color { Color(laa: raw.text) }
    public var textMuted: Color { Color(laa: raw.textMuted) }
    public var accent: Color { Color(laa: raw.accent) }
    public var accentFill: Color { Color(laa: raw.accentFill) }
    public var onAccent: Color { Color(laa: raw.onAccent) }
    /// Hairlines. With Increase Contrast the rule becomes the text colour (glass fallback rule).
    public var rule: Color { Color(laa: increasedContrast ? raw.text : raw.rule) }
    public var selection: Color { Color(laa: raw.selection) }
    /// Accent dots, thin rules and small shapes only: never text or fills.
    public var second: Color { Color(laa: raw.second) }
    public var positive: Color { Color(laa: semantic.positive) }
    public var caution: Color { Color(laa: semantic.caution) }
    public var critical: Color { Color(laa: semantic.critical) }

    public func meter(_ level: LAAMeterLevel) -> Color {
        switch level {
        case .normal: accent
        case .caution: caution
        case .critical: critical
        case .unknown: rule
        }
    }
}

private struct LAAPaletteKey: EnvironmentKey {
    static let defaultValue = LAAPalette()
}

private struct LAAThemeIDKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

public extension EnvironmentValues {
    var laaPalette: LAAPalette {
        get { self[LAAPaletteKey.self] }
        set { self[LAAPaletteKey.self] = newValue }
    }
    /// The chosen theme set; `nil` means the default (`LAAThemeSets.defaultID`).
    var laaThemeID: String? {
        get { self[LAAThemeIDKey.self] }
        set { self[LAAThemeIDKey.self] = newValue }
    }
}

private struct LAAThemeModifier: ViewModifier {
    let themeID: String?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .environment(\.laaThemeID, themeID)
            .environment(\.laaPalette, LAAPalette(theme: LAAThemeSets.set(id: themeID), dark: scheme == .dark,
                                                  increasedContrast: contrast == .increased))
    }
}

public extension View {
    /// Resolves the palette for the theme set and the current appearance. Apply once near the root
    /// (and in each widget's entry view).
    func laaTheme(_ themeID: String?) -> some View { modifier(LAAThemeModifier(themeID: themeID)) }
}
