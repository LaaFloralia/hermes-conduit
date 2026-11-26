#if LAA_BUILD
import LAATokens
import SwiftUI

/// Compatibility names for existing LAA screens. New views should use the
/// semantic roles in LAAColor and LAAType directly.
enum LAAColors {
    static var paper: Color { LAAColor.background }
    static var surface: Color { LAAColor.surface }
    static var ink: Color { LAAColor.text }
    static var muted: Color { LAAColor.secondaryText }
    static var teal: Color { LAAColor.link }
    static var plum: Color { LAAColor.attention }
    static var tan: Color { LAAColor.decorativeTan }
    static var hairline: Color { LAAColor.separator }
}

/// Spacing uses multiples of four points.
enum LAASpacing {
    static let x1: CGFloat = LAASpace.s4
    static let x2: CGFloat = LAASpace.s8
    static let x3: CGFloat = LAASpace.s12
    static let x4: CGFloat = LAASpace.s16
    static let x5: CGFloat = LAASpace.s16 + LAASpace.s4
    static let x6: CGFloat = LAASpace.s24
    static let x8: CGFloat = LAASpace.s32
}

enum LAAFont {
    static let largeHeading = LAAType.screenTitle
    static let row = Font.body
    static let caption = Font.footnote
}
#endif
