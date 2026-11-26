import Foundation

/// An sRGB colour as stored in tokens.json (`#RRGGBB`). Platform-neutral: no SwiftUI, UIKit or AppKit.
public struct LAARGB: Sendable, Hashable {
    public let red: Double, green: Double, blue: Double
    public init(_ hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }
    public var hex: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
    /// WCAG relative luminance.
    public var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }
    public func contrast(with other: LAARGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// The eleven roles a theme set may change (`theme.roles`). Type, size, spacing, shape and the
/// semantic colours never change with the set.
public struct LAAThemeColors: Sendable, Hashable {
    public let bg, surface, wash, text, textMuted, accent, accentFill, onAccent, rule, selection, second: LAARGB
    public init(bg: LAARGB, surface: LAARGB, wash: LAARGB, text: LAARGB, textMuted: LAARGB, accent: LAARGB,
                accentFill: LAARGB, onAccent: LAARGB, rule: LAARGB, selection: LAARGB, second: LAARGB) {
        self.bg = bg; self.surface = surface; self.wash = wash; self.text = text; self.textMuted = textMuted
        self.accent = accent; self.accentFill = accentFill; self.onAccent = onAccent; self.rule = rule
        self.selection = selection; self.second = second
    }
}

public struct LAAThemeSet: Sendable, Hashable, Identifiable {
    public let id: String, name: String, nameJa: String, status: String
    public let light: LAAThemeColors, dark: LAAThemeColors
    public func colors(dark isDark: Bool) -> LAAThemeColors { isDark ? dark : light }
}

public extension LAAThemeSets {
    /// Identifiers of renamed sets → their current identifier, so a stored choice survives the rename.
    /// `iris` became `ayame` on 2026-11-26 (the staff member Iris keeps the name).
    static let renamedIDs: [String: String] = ["iris": "ayame"]

    /// The current identifier for a stored one (renamed sets map forward; others are returned as they are).
    static func currentID(_ id: String?) -> String? { id.map { renamedIDs[$0] ?? $0 } }

    /// The set for an identifier; renamed identifiers map to their new set, unknown or retired ones
    /// fall back to the default set.
    static func set(id: String?) -> LAAThemeSet {
        let id = currentID(id)
        return all.first { $0.id == id } ?? all.first { $0.id == defaultID } ?? all[0]
    }
}

public struct LAASemanticColors: Sendable, Hashable {
    public let positive, caution, critical: LAARGB
}

public enum LAAMeterLevel: Sendable, Hashable {
    case normal, caution, critical, unknown
    /// `remaining` is 0…1 of what is left; nil means no current reading.
    public init(remaining: Double?) {
        guard let value = remaining, value.isFinite else { self = .unknown; return }
        if value < LAASemantic.criticalBelow { self = .critical }
        else if value < LAASemantic.cautionBelow { self = .caution }
        else { self = .normal }
    }
    /// The shape that always travels with the colour (never colour alone).
    public var shape: String {
        switch self {
        case .normal: LAAShape.normal
        case .caution, .critical: LAAShape.attention
        case .unknown: LAAShape.unknown
        }
    }
}

public struct LAAControlSize: Sendable, Hashable {
    public let height, label, weight, paddingH, radius: Double
}

public struct LAAIconButtonSize: Sendable, Hashable {
    public let visual, icon: Double
}

public struct LAASpringToken: Sendable, Hashable {
    public let response, damping: Double
}

public struct LAAWorkingStripSize: Sendable, Hashable {
    public let height, label, weight, paddingH, hitArea, gapAboveComposer, mergeSpacing, orb, jump, jumpIcon: Double
}
