import Foundation
import SwiftUI
import Testing
@testable import LAATokens
#if canImport(AppKit)
import AppKit
#endif

struct TokenTests {
    @Test func lockMatchesGeneratedHash() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let lock = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("kit.lock.json"))) as? [String: Any]
        #expect(lock?["tokenHash"] as? String == LAATokenInfo.tokenHash)
        #expect(lock?["kitVersion"] as? String == LAATokenInfo.kitVersion)
        let version = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
        #expect(version.trimmingCharacters(in: .whitespacesAndNewlines) == LAATokenInfo.kitVersion)
    }

    @Test(arguments: LAAThemeSets.all)
    func themeTextMeetsContrast(_ theme: LAAThemeSet) {
        for dark in [false, true] {
            let c = theme.colors(dark: dark)
            #expect(c.text.contrast(with: c.bg) >= 7, "\(theme.id) text/bg")
            #expect(c.textMuted.contrast(with: c.bg) >= 4.5, "\(theme.id) muted/bg")
            #expect(c.onAccent.contrast(with: c.accentFill) >= 4.5, "\(theme.id) onAccent")
        }
    }

    @Test func unknownThemeFallsBackToDefault() {
        #expect(LAAThemeSets.set(id: "nope").id == LAAThemeSets.defaultID)
        #expect(LAAThemeSets.set(id: nil).id == LAAThemeSets.defaultID)
    }

    @Test func meterLevelsCarryShapes() {
        #expect(LAAMeterLevel(remaining: nil) == .unknown)
        #expect(LAAMeterLevel(remaining: .nan) == .unknown)
        #expect(LAAMeterLevel(remaining: 0.9) == .normal)
        #expect(LAAMeterLevel(remaining: 0.01) == .critical)
        #expect(LAAMeterLevel(remaining: 0.01).shape == LAAShape.attention)
        #expect(LAAMeterLevel(remaining: 0.9).shape == LAAShape.normal)
    }

    @Test func v2ComponentTokens() {
        #expect(LAAComponentToken.Meter.barHeight == 4 && LAAComponentToken.Meter.barRadius == 0)
        #expect(LAAComponentToken.Transcript.assistantBubble == false)
        #expect(LAAComponentToken.Transcript.bubbleRadius == 18)
        #expect(LAAComponentToken.WorkingStrip.iphone.height == 36 && LAAComponentToken.WorkingStrip.mac.height == 28)
        #expect(LAAComponentToken.WorkingStrip.iphone.hitArea == 44)
        #expect(LAAGlassToken.clusterSpacing == 12)
        #expect(LAAComponentToken.ProviderCard.max == 4 && LAAComponentToken.ProviderCard.columns == 1)
        #expect(LAACanvas.iphone.reading == 17 && LAACanvas.iphone.readingLine == 28)
        #expect(LAACanvas.mac.reading == 16 && LAACanvas.mac.readingLine == 26 && LAACanvas.mac.readingMeasure == 680)
    }

    @Test(arguments: LAAIcon.allCases)
    func iconPathsParseInsideTheBox(_ icon: LAAIcon) {
        for data in [icon.regularPath, icon.fillPath] {
            let bounds = LAASVGPath.parse(data).boundingRect
            #expect(!bounds.isEmpty, "\(icon) empty")
            #expect(bounds.minX >= -1 && bounds.minY >= -1 && bounds.maxX <= 257 && bounds.maxY <= 257, "\(icon) \(bounds)")
        }
    }

    @Test func arcsBecomeCurves() {
        let circle = LAASVGPath.parse("M28,128a100,100,0,1,0,200,0a100,100,0,1,0,-200,0Z").boundingRect
        #expect(abs(circle.minX - 28) < 0.5 && abs(circle.maxX - 228) < 0.5)
        #expect(abs(circle.minY - 28) < 0.5 && abs(circle.maxY - 228) < 0.5)
    }
}

@MainActor struct ThemeStoreTests {
    @Test func storesSelectionInTheAppGroupSuite() {
        let suite = "laa.kit.tests.\(UUID().uuidString)"
        let store = LAAThemeStore(appGroup: suite)
        store.select("ayame")
        #expect(LAAThemeStore.storedThemeID(appGroup: suite) == "ayame")
        #expect(LAAThemeStore(appGroup: suite).themeID == "ayame")
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    /// A choice stored before the 2026-11-26 rename (`iris`) keeps the same colours as `ayame` and is rewritten.
    @Test func renamedIrisSelectionMigratesToAyame() {
        let suite = "laa.kit.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("iris", forKey: LAAThemeStore.defaultsKey)
        #expect(LAAThemeStore.storedThemeID(appGroup: suite) == "ayame")
        #expect(LAAThemeStore(appGroup: suite).themeID == "ayame")
        #expect(defaults.string(forKey: LAAThemeStore.defaultsKey) == "ayame")
        #expect(LAAThemeSets.set(id: "iris") == LAAThemeSets.ayame)
        defaults.removePersistentDomain(forName: suite)
    }
}

struct IconSymbolTests {
    /// Every SF-Symbol-mapped icon draws something when selected: the fill if the system has one, else the
    /// regular symbol (a missing `laptopcomputer.fill` left the selected Mac tab empty).
    @Test func selectedSymbolsResolve() {
        for icon in LAAIcon.allCases where icon.prefersSFSymbol {
            let name = LAAIconImage.symbolName(icon.sfSymbol, selected: true)
            #expect(name == icon.sfSymbol || name == icon.sfSymbol + ".fill")
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(icon) → \(name)")
            #endif
        }
        #expect(LAAIconImage.symbolName("laptopcomputer", selected: true) == "laptopcomputer")
        #expect(LAAIconImage.symbolName("laptopcomputer", selected: false) == "laptopcomputer")
    }
}
