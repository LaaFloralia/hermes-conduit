import SwiftUI
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
        // Content ends 8 pt above the bar's top on both kinds of screen (iPhone SE: 667 − 12 − 56 − 8).
        for safeBottom in [0.0, 21, 34] {
            let barTop = LAATabBarToken.height + LAAGlassTabBarLayout.bottomPadding(safeBottom: safeBottom)
            #expect(LAAGlassTabBarLayout.contentClearance(safeBottom: safeBottom) + safeBottom == barTop + 8)
        }
        #expect(LAAGlassTabBarLayout.contentClearance(safeBottom: 0) == 76)
    }

    /// The right capsule is the owner's picture, never the app icon (D-21): the deprecated icon entry points
    /// are accepted but draw the profile (the initial when the app passes none).
    @available(*, deprecated)
    @Test func identityShowsProfileNotAppIcon() {
        let plain = LAAAppIdentity.main(name: "Hortensia")
        #expect(plain.profile == nil)
        #expect(plain.name == "Hortensia")
        let legacy = LAAAppIdentity.main(name: "Primula", icon: Image(systemName: "app"))
        #expect(legacy.profile == nil)
        let made = LAAAppIdentity(name: "Console", version: "1", icon: Image(systemName: "app"))
        #expect(made.profile == nil)
        #expect(LAAAppIdentity.ownerName == "LAA")
    }

    /// A finger anywhere over a slot picks that slot; past either end it stays on the end tab.
    @Test(arguments: [2, 3, 5]) func slideIndexAcrossTabs(count: Int) {
        let item = 64.0, inset = LAATabBarToken.inset
        for index in 0..<count {
            let left = inset + Double(index) * item
            #expect(LAAGlassTabBarLayout.tabIndex(atX: left + 0.5, count: count, itemWidth: item) == index)
            #expect(LAAGlassTabBarLayout.tabIndex(atX: left + item / 2, count: count, itemWidth: item) == index)
            #expect(LAAGlassTabBarLayout.tabIndex(atX: left + item - 0.5, count: count, itemWidth: item) == index)
        }
        // Boundaries belong to the slot that starts there.
        #expect(LAAGlassTabBarLayout.tabIndex(atX: inset + item, count: count, itemWidth: item) == 1)
        // Edges and beyond clamp.
        #expect(LAAGlassTabBarLayout.tabIndex(atX: 0, count: count, itemWidth: item) == 0)
        #expect(LAAGlassTabBarLayout.tabIndex(atX: -200, count: count, itemWidth: item) == 0)
        #expect(LAAGlassTabBarLayout.tabIndex(atX: 2 * inset + Double(count) * item, count: count, itemWidth: item) == count - 1)
        #expect(LAAGlassTabBarLayout.tabIndex(atX: 5_000, count: count, itemWidth: item) == count - 1)
        #expect(LAAGlassTabBarLayout.tabIndex(atX: .nan, count: count, itemWidth: item) == 0)
    }

    @Test func slideIndexDegenerate() {
        #expect(LAAGlassTabBarLayout.tabIndex(atX: 100, count: 0, itemWidth: 64) == 0)
        #expect(LAAGlassTabBarLayout.tabIndex(atX: 100, count: 3, itemWidth: 0) == 0)
    }

    /// The lens follows the finger exactly between the end tabs' centres, then gives a little (never more
    /// than a quarter slot) and grows stiffer the further the finger goes.
    @Test(arguments: [2, 3, 5]) func lensFollowsFingerWithRubberBand(count: Int) {
        let item = 64.0
        let low = LAAGlassTabBarLayout.centerX(ofIndex: 0, itemWidth: item)
        let high = LAAGlassTabBarLayout.centerX(ofIndex: count - 1, itemWidth: item)
        #expect(low == LAATabBarToken.inset + item / 2)
        #expect(high == LAATabBarToken.inset + (Double(count) - 0.5) * item)
        for x in stride(from: low, through: high, by: 7) {
            #expect(LAAGlassTabBarLayout.clampedCenterX(x, count: count, itemWidth: item) == x)
        }
        let limit = item * LAAGlassTabBarLayout.edgeGiveFraction
        var previous = high
        for over in [1.0, 10, 40, 200, 10_000] {
            let right = LAAGlassTabBarLayout.clampedCenterX(high + over, count: count, itemWidth: item)
            #expect(right > previous)
            #expect(right < high + limit)
            #expect(right - high < over) // it lags the finger
            previous = right
            let left = LAAGlassTabBarLayout.clampedCenterX(low - over, count: count, itemWidth: item)
            #expect(left < low && left > low - limit)
        }
        #expect(LAAGlassTabBarLayout.clampedCenterX(.infinity, count: count, itemWidth: item) == low)
    }

    @Test func lensProportions() {
        #expect(LAAGlassTabBarLayout.lensScale.width == 1.14)
        #expect(LAAGlassTabBarLayout.lensScale.height == 1.16)
        #expect(LAAGlassTabBarLayout.trackSpace == "laa.tabbar.track")
    }

    /// The right capsule, the card header and the sidebar entry show the owner (D-30), never the app's name.
    @MainActor @Test func identityShowsOwnerNeverAppName() throws {
        let store = LAAOwnerProfileStore(appGroup: nil, directory: OwnerProfileStoreTests.temporaryDirectory())
        defer { try? FileManager.default.removeItem(at: store.directory) }
        for appName in ["Primula", "Console", "Hortensia"] {
            let app = LAAAppIdentity(name: appName, version: "1.0", profile: nil)
            #expect(app.displayedOwnerName(store: store) == "LAA")
            #expect(app.displayedInitial(store: store) == "L")
            #expect(app.displayedProfile(store: store) == nil)
            #expect(app.settingsAccessibilityLabel(store: store) == "LAA, Settings")
            #expect(!app.settingsAccessibilityLabel(store: store).contains(appName))
        }
        store.saveDisplayName("  saya  ")
        let app = LAAAppIdentity.main(name: "Primula")
        #expect(app.displayedOwnerName(store: store) == "saya")
        #expect(app.displayedInitial(store: store) == "S")
        // `.owner(store:)` reads the store live, not a snapshot.
        let live = LAAAppIdentity.owner(store: store, version: "2.0")
        #expect(live.version == "2.0")
        #expect(live.displayedOwnerName() == "saya")
        store.saveDisplayName("Monet")
        #expect(live.displayedOwnerName() == "Monet")
        // The store's picture is drawn when the host passes none; an explicit one wins.
        try store.saveAvatar(imageData: OwnerProfileStoreTests.jpeg(width: 40, height: 30))
        #expect(live.displayedProfile() != nil)
        let explicit = LAAAppIdentity(name: "Hortensia", version: "", profile: Image(systemName: "person"),
                                      ownerName: "Owner", ownerStore: store)
        #expect(explicit.displayedOwnerName() == "Owner")
        #expect(explicit.displayedInitial() == "O")
        #expect(explicit.displayedProfile() != nil)
        // A blank explicit name falls back to the store.
        let blank = LAAAppIdentity(name: "Console", version: "", profile: nil, ownerName: "  ", ownerStore: store)
        #expect(blank.displayedOwnerName() == "Monet")
    }

    @Test func atMostFiveTabs() {
        #expect(LAATabBarToken.maxTabs == 5)
    }
}
