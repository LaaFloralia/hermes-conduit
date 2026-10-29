#if LAA_BUILD
import SwiftUI
import UIKit

/// Semantic colours for the LAA interface. Content stays opaque; system
/// navigation and controls supply their own material or glass.
enum LAAColor {
    static let background = adaptive(light: 0xF6F2E9, dark: 0x0F1B1C)
    static let surface = adaptive(light: 0xFFFDF8, dark: 0x172627)
    static let subtleSurface = adaptive(light: 0xEBE6DC, dark: 0x243638)
    static let text = adaptive(light: 0x213536, dark: 0xECE7DC,
                               highContrastLight: 0x102627, highContrastDark: 0xFFFDF8)
    static let secondaryText = adaptive(light: 0x596968, dark: 0xA8B7B4,
                                        highContrastLight: 0x3A5150, highContrastDark: 0xD1DEDA)
    static let link = adaptive(light: 0x00585E, dark: 0x75C3C3,
                               highContrastLight: 0x003F43, highContrastDark: 0xA4DDDC)
    static let separator = adaptive(light: 0xD7D5CC, dark: 0x385052,
                                    highContrastLight: 0x899493, highContrastDark: 0x829D9A)
    static let selectionFill = adaptive(light: 0xDFEAE5, dark: 0x294844)
    static let ownBubble = adaptive(light: 0x00585E, dark: 0x1E6B70)
    static let ownBubbleText = adaptive(light: 0xF6F2E9, dark: 0xF6F2E9)
    static let filledButton = ownBubble
    static let filledButtonText = ownBubbleText
    // Compatibility aliases for the initial v2 token API.
    static let filledControl = filledButton
    static let filledControlText = filledButtonText
    static let attention = adaptive(light: 0x6C244C, dark: 0xD49AB6)
    static let end = Color.red
    static let decorativeTan = adaptive(light: 0xB99B7A, dark: 0xB99B7A)

    private static func adaptive(light: Int, dark: Int,
                                 highContrastLight: Int? = nil, highContrastDark: Int? = nil) -> Color {
        Color(uiColor: UIColor { traits in
            let darkMode = traits.userInterfaceStyle == .dark
            let increasedContrast = traits.accessibilityContrast == .high
            let value = darkMode
                ? (increasedContrast ? highContrastDark ?? dark : dark)
                : (increasedContrast ? highContrastLight ?? light : light)
            return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                           green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255,
                           alpha: 1)
        })
    }
}

/// Points rather than fixed frames: rows and content must grow with Dynamic Type.
extension LAASpacing {
    static let horizontal: CGFloat = x6
    static let compactHorizontal: CGFloat = x4
    static let section: CGFloat = x8
    static let minimumRowHeight: CGFloat = 56
    static let minimumTouchTarget: CGFloat = 44
}

enum LAARadius {
    static let card: CGFloat = 16
    static let bubble: CGFloat = 18
    static let selectionChip: CGFloat = 16
    static let photo: CGFloat = 24
    static let control: CGFloat = 28
}

enum LAAType {
    static let bodySize: CGFloat = 16
    static let secondarySize: CGFloat = 13
    static let sectionSize: CGFloat = 12
    static let screenTitle = Font.custom("Georgia", size: 34, relativeTo: .largeTitle)
    static let employeeName = Font.custom("Georgia", size: 16, relativeTo: .body)
    static let usageValue = Font.custom("Georgia", size: 36, relativeTo: .largeTitle).monospacedDigit()

    enum TextRole { case body, secondary, section }
}

/// Use for system-font text at the specified base size, scaled by Dynamic Type.
private struct LAATextStyle: ViewModifier {
    let role: LAAType.TextRole
    @ScaledMetric(relativeTo: .body) private var bodySize = LAAType.bodySize
    @ScaledMetric(relativeTo: .footnote) private var secondarySize = LAAType.secondarySize
    @ScaledMetric(relativeTo: .caption) private var sectionSize = LAAType.sectionSize

    func body(content: Content) -> some View {
        switch role {
        case .body: content.font(.system(size: bodySize))
        case .secondary: content.font(.system(size: secondarySize))
        case .section: content.font(.system(size: sectionSize))
        }
    }
}

extension View {
    func laaTextStyle(_ role: LAAType.TextRole) -> some View {
        modifier(LAATextStyle(role: role))
    }
}
#endif
