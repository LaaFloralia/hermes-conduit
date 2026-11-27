#if LAA_BUILD
import SwiftUI
#if canImport(LAATokens)
import LAATokens
#endif

/// Cross-platform values for surfaces that cannot use UIColor, such as Watch.
/// Keep these semantic values shared with the adaptive iPhone tokens.
enum LAAColorValues {
    #if canImport(LAATokens)
    // DESIGN.md ruleWarm, not exported by kit-v0.1.0.
    static let ruleWarm = LAARGB(0xB99B7A)
    #endif

    static let backgroundDark = 0x0F1B1C
    static let surfaceDark = 0x172627
    static let linkLight = 0x00585E
    static let linkDark = 0x75C3C3
    static let attentionDark = 0xD49AB6

    /// DeepSeek's issued whale color, shared by the model mark and Usage.
    static let deepSeekBrand = color(0x4D6BFE)

    static func color(_ rgb: Int) -> Color {
        Color(red: Double((rgb >> 16) & 0xFF) / 255,
              green: Double((rgb >> 8) & 0xFF) / 255,
              blue: Double(rgb & 0xFF) / 255)
    }
}
#endif
