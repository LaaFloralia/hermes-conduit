#if LAA_BUILD
import SwiftUI

/// Compatibility names for existing LAA screens. New views should use the
/// semantic roles in LAAColor and LAAType directly.
enum LAAColors {
    static let paper = LAAColor.background
    static let surface = LAAColor.surface
    static let ink = LAAColor.text
    static let muted = LAAColor.secondaryText
    static let teal = LAAColor.link
    static let plum = LAAColor.attention
    static let tan = LAAColor.decorativeTan
    static let hairline = LAAColor.separator
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
    static let largeHeading = LAAType.screenTitle
    static let row = Font.body
    static let caption = Font.footnote
}
#endif
