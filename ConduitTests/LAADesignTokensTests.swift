#if LAA_BUILD
import SwiftUI
import UIKit
import Security
import XCTest
@testable import Conduit

final class LAADesignTokensTests: XCTestCase {
    private func components(_ color: Color, style: UIUserInterfaceStyle,
                            contrast: UIAccessibilityContrast = .normal) -> [Double] {
        let traits = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: style),
            UITraitCollection(accessibilityContrast: contrast)
        ])
        let resolved = UIColor(color).resolvedColor(with: traits)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        XCTAssertTrue(resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        XCTAssertEqual(alpha, 1, accuracy: 0.001)
        return [Double(red), Double(green), Double(blue)]
    }

    private func hex(_ color: Color, style: UIUserInterfaceStyle) -> Int {
        let values = components(color, style: style).map { Int(($0 * 255).rounded()) }
        return (values[0] << 16) | (values[1] << 8) | values[2]
    }

    private func contrast(_ foreground: Color, _ background: Color, style: UIUserInterfaceStyle,
                          accessibility: UIAccessibilityContrast = .normal) -> Double {
        func luminance(_ color: Color) -> Double {
            let channels = components(color, style: style, contrast: accessibility).map {
                $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
        }
        let values = [luminance(foreground), luminance(background)].sorted()
        return (values[1] + 0.05) / (values[0] + 0.05)
    }

    func testSemanticColorsResolveToTheDesignValues() {
        let roles: [(String, Color, Int, Int)] = [
            ("background", LAAColor.background, 0xF6F2E9, 0x0F1B1C),
            ("surface", LAAColor.surface, 0xFFFDF8, 0x172627),
            ("subtleSurface", LAAColor.subtleSurface, 0xEBE6DC, 0x243638),
            ("text", LAAColor.text, 0x213536, 0xECE7DC),
            ("secondaryText", LAAColor.secondaryText, 0x596968, 0xA8B7B4),
            ("link", LAAColor.link, 0x00585E, 0x75C3C3),
            ("separator", LAAColor.separator, 0xD7D5CC, 0x385052),
            ("selectionFill", LAAColor.selectionFill, 0xDFEAE5, 0x294844),
            ("ownBubble", LAAColor.ownBubble, 0x00585E, 0x1E6B70),
            ("ownBubbleText", LAAColor.ownBubbleText, 0xF6F2E9, 0xF6F2E9),
            ("filledButton", LAAColor.filledButton, 0x00585E, 0x1E6B70),
            ("filledButtonText", LAAColor.filledButtonText, 0xF6F2E9, 0xF6F2E9),
            ("filledControl", LAAColor.filledControl, 0x00585E, 0x1E6B70),
            ("filledControlText", LAAColor.filledControlText, 0xF6F2E9, 0xF6F2E9),
            ("attention", LAAColor.attention, 0x6C244C, 0xD49AB6),
            ("decorativeTan", LAAColor.decorativeTan, 0xB99B7A, 0xB99B7A),
            ("ivory", LAAColor.ivory, 0xF6F2E9, 0xF6F2E9),
            ("rimLight", LAAColor.rimLight, 0xB99B7A, 0xFFFDF8)
        ]
        for (name, color, light, dark) in roles {
            XCTAssertEqual(hex(color, style: .light), light, "\(name) light")
            XCTAssertEqual(hex(color, style: .dark), dark, "\(name) dark")
        }
    }

    func testSystemAccentMatchesTheLinkTokenInBothAppearancesAndContrasts() throws {
        let accent = try XCTUnwrap(UIColor(named: "LAAAccent", in: Bundle.main, compatibleWith: nil))
        for style in [UIUserInterfaceStyle.light, .dark] {
            for contrast in [UIAccessibilityContrast.normal, .high] {
                let asset = components(Color(uiColor: accent), style: style, contrast: contrast)
                let token = components(LAAColor.link, style: style, contrast: contrast)
                for (assetChannel, tokenChannel) in zip(asset, token) {
                    XCTAssertEqual(assetChannel, tokenChannel, accuracy: 0.001)
                }
            }
        }
    }

    func testTextAndFilledControlsMeetContrastInBothAppearances() {
        let pairs: [(String, Color, Color, Double)] = [
            ("text/background", LAAColor.text, LAAColor.background, 7),
            ("text/surface", LAAColor.text, LAAColor.surface, 7),
            ("secondary/background", LAAColor.secondaryText, LAAColor.background, 4.5),
            ("secondary/surface", LAAColor.secondaryText, LAAColor.surface, 4.5),
            ("link/background", LAAColor.link, LAAColor.background, 4.5),
            ("own bubble", LAAColor.ownBubbleText, LAAColor.ownBubble, 4.5),
            ("filled button", LAAColor.filledButtonText, LAAColor.filledButton, 4.5),
            ("filled control", LAAColor.filledControlText, LAAColor.filledControl, 4.5)
        ]
        for style in [UIUserInterfaceStyle.light, .dark] {
            // The kit keeps foreground roles in high contrast; edges use text ink.
            for accessibility in [UIAccessibilityContrast.normal, .high] {
                for (name, foreground, background, minimum) in pairs {
                    XCTAssertGreaterThanOrEqual(contrast(foreground, background, style: style, accessibility: accessibility),
                                                minimum, "\(name) \(style) \(accessibility)")
                }
            }
            XCTAssertEqual(components(LAAColor.separator, style: style, contrast: .high),
                           components(LAAColor.text, style: style, contrast: .high), "high-contrast edge \(style)")
            XCTAssertGreaterThan(contrast(LAAColor.separator, LAAColor.background, style: style, accessibility: .high),
                                 contrast(LAAColor.separator, LAAColor.background, style: style), "separator \(style)")
        }
        XCTAssertEqual(contrast(LAAColor.text, LAAColor.background, style: .light), 11.55, accuracy: 0.01)
        XCTAssertEqual(contrast(LAAColor.text, LAAColor.background, style: .dark), 14.27, accuracy: 0.01)
        XCTAssertEqual(contrast(LAAColor.filledControlText, LAAColor.filledControl, style: .light), 7.35, accuracy: 0.01)
        XCTAssertEqual(contrast(LAAColor.filledControlText, LAAColor.filledControl, style: .dark), 5.54, accuracy: 0.01)
    }

    func testModelDisplayHidesRoutesAndKeepsKnownNames() {
        XCTAssertEqual(LAAModelDisplay.name("[\"opencode-go\",\"deepseek-v4.1-flash\"]"), "DeepSeek V4.1 Flash")
        XCTAssertEqual(LAAModelDisplay.name("anthropic/claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(LAAModelDisplay.name("gpt-6.1-sol"), "GPT-6.1 Sol")
        XCTAssertEqual(LAAModelDisplay.name("[\"openai\",\"gpt-6.1-sol\"]", label: "gpt-6.1-sol"), "GPT-6.1 Sol")
        XCTAssertEqual(LAAModelDisplay.name("private/model", label: "Human name"), "Human name")
        XCTAssertEqual(LAAModelDisplay.name("/Users/example/private"), "Other Models")
        XCTAssertEqual(LAAModelDisplay.reasoning("xhigh"), "XHigh")
    }

    func testSpacingAndRadiusValues() {
        XCTAssertEqual([LAASpacing.x1, LAASpacing.x2, LAASpacing.x3, LAASpacing.x4, LAASpacing.x6, LAASpacing.x8], [4, 8, 12, 16, 24, 32])
        XCTAssertEqual([LAARadius.card, LAARadius.bubble, LAARadius.selectionChip, LAARadius.photo, LAARadius.control], [16, 18, 16, 24, 28])
        #if targetEnvironment(macCatalyst)
        let canvasSpacing: [CGFloat] = [24, 24, 32, 28]
        let canvasType: [CGFloat] = [14, 13, 12]
        #else
        let canvasSpacing: [CGFloat] = [16, 16, 44, 44]
        let canvasType: [CGFloat] = [16, 13, 12]
        #endif
        let actualSpacing = [LAASpacing.horizontal, LAASpacing.compactHorizontal, LAASpacing.minimumRowHeight, LAASpacing.minimumTouchTarget]
        let actualType = [LAAType.bodySize, LAAType.secondarySize, LAAType.sectionSize]
        XCTAssertEqual(LAASpacing.section, 32)
        for (actual, expected) in zip(actualSpacing + actualType, canvasSpacing + canvasType) {
            XCTAssertEqual(actual / LAAType.platformScale, expected, accuracy: 0.001)
        }
    }
}

final class LAATabModelTests: XCTestCase {
    func testProductBrandChangesOnlyDisplayCopy() {
        XCTAssertEqual(LAAProductBrand.display("Hermes Conduit"), "LAA")
        XCTAssertEqual(LAAProductBrand.display("Conduit-chan"), "Monet")
        XCTAssertEqual(LAAProductBrand.display("Conduit plugin"), "LAA plugin")
        XCTAssertEqual(LAAProductBrand.display("Conduit · conduit://widget"), "LAA · conduit://widget")
    }

    func testJapaneseOperationsAndEnglishStructureNames() {
        XCTAssertEqual(LAACopy.pairingTitle, "Connect to Mac")
        XCTAssertEqual(LAACopy.pairingAddress, "Address")
        XCTAssertEqual(LAACopy.pairingCode, "Pairing Code")
        XCTAssertEqual(LAACopy.pairingConnect, "Connect")
        XCTAssertEqual([LAACopy.call, LAACopy.callMute, LAACopy.callUnmute, LAACopy.callSpeaker,
                        LAACopy.callChat, LAACopy.callEnd, LAACopy.callAudioRoute],
                       ["電話", "消音", "消音を解除", "スピーカー", "チャット", "終了", "音声の出力先"])
        XCTAssertEqual(LAACopy.bridgeNotPairedBody, "Macに接続してください")
    }

    func testBuiltAppHasHortensiaNameAndPermissionCopy() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "Hortensia")
        let microphone = try XCTUnwrap(info["NSMicrophoneUsageDescription"] as? String)
        XCTAssertFalse(microphone.contains("Conduit"))
        XCTAssertTrue(microphone.contains("voice conversations and foreground wake phrases"))
        let englishURL = try XCTUnwrap(Bundle.main.url(forResource: "en", withExtension: "lproj"))
        let english = try XCTUnwrap(Bundle(url: englishURL))
        XCTAssertEqual(english.localizedString(forKey: "Open Conduit", value: nil, table: nil), "Open LAA")
    }

    func testDisplayOrderNamesSymbolsAndPersistentIdentifiers() {
        XCTAssertEqual(LAATab.destinations.map(\.rawValue), ["chats", "work", "today", "brain", "studio"])
        XCTAssertEqual(LAATab.destinations.map(\.title), ["Chat", "Work", "Today", "Doc", "Studio"])
        XCTAssertEqual(LAATab.destinations.map(\.symbol), ["bubble.left.and.bubble.right", "list.bullet", "calendar", "doc.text", "sparkles.rectangle.stack"])
        XCTAssertEqual(LAATab(rawValue: "source"), .source)
        XCTAssertNil(LAATab(rawValue: "assets"))
        XCTAssertEqual(LAACopy.settings, "Settings")
    }

    func testCallVisibilityFollowsTheVisibleEmployeeScreen() {
        XCTAssertFalse(LAATabBarVisibility.isCovered(legacyCallPresented: false, employeeCallActive: false, employeeCallPresented: false))
        XCTAssertTrue(LAATabBarVisibility.isCovered(legacyCallPresented: true, employeeCallActive: false, employeeCallPresented: false))
        XCTAssertTrue(LAATabBarVisibility.isCovered(legacyCallPresented: true, employeeCallActive: true, employeeCallPresented: true))
        // Employee voice flags stay active after Chat minimises its call screen.
        XCTAssertFalse(LAATabBarVisibility.isCovered(legacyCallPresented: true, employeeCallActive: true, employeeCallPresented: false))
    }

    /// BUS-360: a Work detail that never ran onDisappear must not hide the bar in the other tabs.
    @MainActor
    func testTabBarHidersOnlyHideTheirOwnTab() {
        let visibility = LAATabBarVisibility()
        let detail = UUID(), unscoped = UUID()
        visibility.hide(detail, scope: .work)
        XCTAssertTrue(visibility.isHidden(for: .work))
        XCTAssertFalse(visibility.isHidden(for: .chats))
        XCTAssertFalse(visibility.isHidden(for: .today))
        visibility.hide(unscoped)
        XCTAssertTrue(visibility.isHidden(for: .chats))
        visibility.show(unscoped)
        visibility.show(detail)
        XCTAssertFalse(visibility.isHidden(for: .work))
    }
}
/// Opt-in cleanup for the dedicated live-Bridge simulator only.
final class LAABridgeSimulatorCleanupTests: XCTestCase {
    @MainActor
    func testVerifyOnlyTheExpectedSimulatorCredential() async throws {
        guard let expected = ProcessInfo.processInfo.environment["LAA_REAL_BRIDGE_DEVICE_ID"],
              !expected.isEmpty else {
            throw XCTSkip("Live Bridge verification requires the dedicated simulator device ID.")
        }
        let session = LAABridgeSession()
        XCTAssertEqual(session.deviceID, expected)
        try await session.verify()
        XCTAssertEqual(session.status, .paired)
    }

    func testRemoveOnlyTheExpectedSimulatorCredential() throws {
        guard let expected = ProcessInfo.processInfo.environment["LAA_REAL_BRIDGE_DEVICE_ID"],
              !expected.isEmpty else {
            throw XCTSkip("Live Bridge cleanup requires the dedicated simulator device ID.")
        }
        let credential = try LAABridgeKeychain().read()
        guard credential?.deviceID == expected else {
            XCTFail("The simulator credential did not match the test device; nothing was removed.")
            return
        }
        for service in [LAABridgeKeychain.currentService, LAABridgeKeychain.legacyService] {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: service,
                                        kSecAttrAccount as String: "device"]
            XCTAssertTrue([errSecSuccess, errSecItemNotFound].contains(SecItemDelete(query as CFDictionary)))
        }
        XCTAssertNil(try LAABridgeKeychain().read())
    }
}
#endif
