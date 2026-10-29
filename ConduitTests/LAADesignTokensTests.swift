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
            ("decorativeTan", LAAColor.decorativeTan, 0xB99B7A, 0xB99B7A)
        ]
        for (name, color, light, dark) in roles {
            XCTAssertEqual(hex(color, style: .light), light, "\(name) light")
            XCTAssertEqual(hex(color, style: .dark), dark, "\(name) dark")
        }
    }

    func testTextAndFilledControlsMeetContrastInBothAppearances() {
        let pairs: [(String, Color, Color)] = [
            ("text/background", LAAColor.text, LAAColor.background),
            ("text/surface", LAAColor.text, LAAColor.surface),
            ("secondary/background", LAAColor.secondaryText, LAAColor.background),
            ("secondary/surface", LAAColor.secondaryText, LAAColor.surface),
            ("link/background", LAAColor.link, LAAColor.background),
            ("own bubble", LAAColor.ownBubbleText, LAAColor.ownBubble),
            ("filled button", LAAColor.filledButtonText, LAAColor.filledButton),
            ("filled control", LAAColor.filledControlText, LAAColor.filledControl)
        ]
        for style in [UIUserInterfaceStyle.light, .dark] {
            for (name, foreground, background) in pairs {
                XCTAssertGreaterThanOrEqual(contrast(foreground, background, style: style), 4.5, "\(name) \(style)")
            }
            for color in [LAAColor.text, LAAColor.secondaryText, LAAColor.link] {
                XCTAssertGreaterThan(contrast(color, LAAColor.background, style: style, accessibility: .high),
                                     contrast(color, LAAColor.background, style: style), "text \(style)")
            }
            XCTAssertGreaterThan(contrast(LAAColor.separator, LAAColor.background, style: style, accessibility: .high),
                                 contrast(LAAColor.separator, LAAColor.background, style: style), "separator \(style)")
        }
        XCTAssertEqual(contrast(LAAColor.text, LAAColor.background, style: .light), 11.55, accuracy: 0.01)
        XCTAssertEqual(contrast(LAAColor.text, LAAColor.background, style: .dark), 14.27, accuracy: 0.01)
        XCTAssertEqual(contrast(LAAColor.filledControlText, LAAColor.filledControl, style: .light), 7.35, accuracy: 0.01)
        XCTAssertEqual(contrast(LAAColor.filledControlText, LAAColor.filledControl, style: .dark), 5.54, accuracy: 0.01)
    }

    func testSpacingAndRadiusValues() {
        XCTAssertEqual([LAASpacing.x1, LAASpacing.x2, LAASpacing.x3, LAASpacing.x4, LAASpacing.x6, LAASpacing.x8], [4, 8, 12, 16, 24, 32])
        XCTAssertEqual([LAASpacing.horizontal, LAASpacing.compactHorizontal, LAASpacing.section, LAASpacing.minimumRowHeight, LAASpacing.minimumTouchTarget], [24, 16, 32, 56, 44])
        XCTAssertEqual([LAARadius.card, LAARadius.bubble, LAARadius.selectionChip, LAARadius.photo, LAARadius.control], [16, 18, 16, 24, 28])
        XCTAssertEqual([LAAType.bodySize, LAAType.secondarySize, LAAType.sectionSize], [16, 13, 12])
    }
}

final class LAATabModelTests: XCTestCase {
    func testDisplayOrderNamesSymbolsAndPersistentIdentifiers() {
        XCTAssertEqual(LAATab.destinations.map(\.rawValue), ["chats", "work", "brain", "source", "usage"])
        XCTAssertEqual(LAATab.destinations.map(\.title), ["Chats", "Work", "Brain", "Assets", "Usage"])
        XCTAssertEqual(LAATab.destinations.map(\.symbol), ["bubble.left.and.bubble.right", "checklist", "doc.text", "photo.on.rectangle", "gauge.medium"])
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
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "com.laa.conduit.bridge",
                                    kSecAttrAccount as String: "device"]
        XCTAssertEqual(SecItemDelete(query as CFDictionary), errSecSuccess)
        XCTAssertNil(try LAABridgeKeychain().read())
    }
}
#endif
