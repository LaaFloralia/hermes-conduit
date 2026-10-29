#if LAA_BUILD

import SwiftUI

enum LAAColors {
    /// Screen background.
    static let paper = dynamic(light: 0xF6F2E9, dark: 0x0F1B1C)
    /// Input and content surface.
    static let surface = dynamic(light: 0xFFFDF8, dark: 0x172627)
    /// Primary text.
    static let ink = dynamic(light: 0x213536, dark: 0xECE7DC)
    /// Secondary text.
    static let muted = dynamic(light: 0x596968, dark: 0x9AA9A7)
    /// Selection and primary actions.
    static let teal = dynamic(light: 0x00585E, dark: 0x6FBFC2)
    /// Items needing attention.
    static let plum = dynamic(light: 0x6C244C, dark: 0xD49AB6)
    /// Decorative tan.
    static let tan = Color(red: 0xB9 / 255, green: 0x9B / 255, blue: 0x7A / 255)
    /// Separators adapt to appearance and increased contrast.
    static let hairline = Color(uiColor: UIColor { traits in
        let alpha: CGFloat = traits.accessibilityContrast == .high ? 0.4 : 0.12
        return traits.userInterfaceStyle == .dark
            ? UIColor(red: 0xF6 / 255, green: 0xF2 / 255, blue: 0xE9 / 255, alpha: alpha)
            : UIColor(red: 0x21 / 255, green: 0x35 / 255, blue: 0x36 / 255, alpha: alpha)
    })

    /// A colour that resolves per interface style, so light and dark are one
    /// declaration instead of two branches in every screen.
    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

private extension UIColor {
    convenience init(hex: Int) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Spacing uses multiples of four points.
enum LAASpacing {
    static let x1: CGFloat = 4
    static let x2: CGFloat = 8
    static let x3: CGFloat = 12
    static let x4: CGFloat = 16
    static let x6: CGFloat = 24
    static let x8: CGFloat = 32
}

enum LAAFont {
    /// Headings use Georgia and scale with
    /// Dynamic Type like the rest of the screen.
    static let largeHeading = Font.custom("Georgia", size: 34, relativeTo: .largeTitle)
    static let row = Font.body
    static let caption = Font.footnote
}

#endif
