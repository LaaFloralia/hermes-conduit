#if LAA_BUILD
import LAAKit
import Observation
import UIKit
import XCTest
@testable import Conduit

@MainActor
final class LAAAppearanceThemeTests: XCTestCase {
    func testThemeStoreUsesTheAppGroupKeyAndNormalizesUnknownSets() throws {
        let suite = "laa.appearance-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LAAThemeStore(appGroup: suite)
        XCTAssertEqual(store.themeID, LAAThemeSets.defaultID)
        for set in LAAThemeSets.all {
            store.select(set.id)
            XCTAssertEqual(LAAThemeStore.storedThemeID(appGroup: suite), set.id)
        }
        defaults.set("retired-theme", forKey: LAAThemeStore.defaultsKey)
        store.reload()
        XCTAssertEqual(store.themeID, LAAThemeSets.defaultID)
    }

    func testLegacyIrisInLauncherDefaultsResolvesInAppAndWidget() throws {
        // Use an isolated suite in place of the configured launcher App Group.
        let suite = "laa.appearance-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("iris", forKey: LAAThemeStore.defaultsKey)

        // Widget reads may happen before the main app has launched and migrated the key.
        XCTAssertEqual(LAAThemeStore.storedThemeID(appGroup: suite), "ayame")
        XCTAssertEqual(defaults.string(forKey: LAAThemeStore.defaultsKey), "iris")

        let store = LAAThemeStore(appGroup: suite)
        XCTAssertEqual(store.theme, LAAThemeSets.ayame)
        XCTAssertEqual(defaults.string(forKey: LAAThemeStore.defaultsKey), "ayame")
        XCTAssertEqual(LAAThemeStore.storedThemeID(appGroup: suite), store.themeID)
    }

    func testLegacyColorsResolveSelectedPaletteAndPublishChanges() {
        let selection = LAASelectedTheme.shared
        let original = selection.themeID
        defer { selection.apply(original) }
        selection.apply(LAAThemeSets.defaultID)
        let defaultBackground = LAAColor.background
        XCTAssertEqual(defaultBackground, LAAColor.background)
        let changed = expectation(description: "Existing SwiftUI callers track palette changes")
        withObservationTracking { _ = LAAColor.background } onChange: { changed.fulfill() }
        selection.apply(LAAThemeSets.ayame.id)
        wait(for: [changed], timeout: 0.5)
        let ayameBackground = LAAColor.background
        XCTAssertNotEqual(ayameBackground, defaultBackground)
        XCTAssertEqual(ayameBackground, LAAColor.background)

        for (style, contrast) in [(UIUserInterfaceStyle.light, UIAccessibilityContrast.normal), (.dark, .high)] {
            let traits = UITraitCollection(traitsFrom: [
                UITraitCollection(userInterfaceStyle: style), UITraitCollection(accessibilityContrast: contrast),
            ])
            let raw = LAAThemeSets.ayame.colors(dark: style == .dark)
            func expected(_ rgb: LAARGB) -> UIColor {
                UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
            }
            XCTAssertEqual(UIColor(LAAColor.background).resolvedColor(with: traits), expected(raw.bg))
            XCTAssertEqual(UIColor(LAAColor.ownBubble).resolvedColor(with: traits), expected(raw.accentFill))
            XCTAssertEqual(UIColor(LAAColor.separator).resolvedColor(with: traits), expected(contrast == .high ? raw.text : raw.rule))
            XCTAssertEqual(UIColor(LAAColor.attention).resolvedColor(with: traits), expected(LAAThemeSets.laa.colors(dark: style == .dark).second))
        }
        selection.apply(LAAThemeSets.defaultID)
        XCTAssertEqual(defaultBackground, LAAColor.background, "A theme reuses the same role when reselected")
    }
}
#endif
