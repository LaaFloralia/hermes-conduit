#if LAA_BUILD
import SwiftUI

/// Cross-platform values for surfaces that cannot use UIColor, such as Watch.
/// Keep these semantic values shared with the adaptive iPhone tokens.
enum LAAColorValues {
    static let backgroundDark = 0x0F1B1C
    static let surfaceDark = 0x172627
    static let linkLight = 0x00585E
    static let linkDark = 0x75C3C3
    static let attentionDark = 0xD49AB6

    static func color(_ rgb: Int) -> Color {
        Color(red: Double((rgb >> 16) & 0xFF) / 255,
              green: Double((rgb >> 8) & 0xFF) / 255,
              blue: Double(rgb & 0xFF) / 255)
    }
}
#endif
