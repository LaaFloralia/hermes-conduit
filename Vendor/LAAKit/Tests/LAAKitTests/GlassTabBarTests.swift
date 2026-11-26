import Testing
@testable import LAAKit

struct GlassTabBarTests {
    /// Five tabs and the app icon fit the smallest iPhone width (375: SE, mini) without dropping below the
    /// 44 pt hit area, and stop growing at the token maximum on the 440 pt Pro Max.
    @Test func widthBudget() {
        for width in [375.0, 390, 402, 414, 440] {
            let margin = LAAGlassTabBarLayout.margin(forWidth: width)
            let (bar, item) = LAAGlassTabBarLayout.widths(count: 5, available: width - 2 * margin)
            #expect(bar <= width - 2 * margin)
            #expect(item >= LAAControl.IPhone.hitArea)
            #expect(item <= LAATabBarToken.itemMax)
        }
        let wide = LAAGlassTabBarLayout.widths(count: 5, available: 900)
        #expect(wide.item == LAATabBarToken.itemMax)
        #expect(wide.bar == LAATabBarToken.gap + LAATabBarToken.appCapsule + 2 * LAATabBarToken.inset + 5 * LAATabBarToken.itemMax)
    }

    @Test func compactMarginBelow390() {
        #expect(LAAGlassTabBarLayout.margin(forWidth: 375) == LAATabBarToken.marginCompact)
        #expect(LAAGlassTabBarLayout.margin(forWidth: 440) == LAATabBarToken.margin)
    }

    /// The bar floats 12 pt into the home-indicator area like the system bar, and never sits on the edge.
    @Test func bottomPlacement() {
        #expect(LAAGlassTabBarLayout.bottomPadding(safeBottom: 34) == 22)
        #expect(LAAGlassTabBarLayout.bottomPadding(safeBottom: 0) == LAATabBarToken.bottomMin)
        #expect(LAAGlassTabBarLayout.contentClearance == LAATabBarToken.height + LAATabBarToken.bottomFromSafeArea + 8)
    }

    @Test func atMostFiveTabs() {
        #expect(LAATabBarToken.maxTabs == 5)
    }
}
