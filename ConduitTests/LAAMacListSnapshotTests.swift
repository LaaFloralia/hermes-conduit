#if LAA_BUILD && LAA_WIDGET_TEST && DEBUG && targetEnvironment(macCatalyst)
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// The Mac's Chat list and AI Usage, light and dark (2026-11-26, owner):
/// Chat has no Contractors section even though the host still lists the
/// former contractors' profiles, and Usage carries the Muse card.
@MainActor
final class LAAMacListSnapshotTests: XCTestCase {
    func testChatListHasNoContractorsLightAndDark() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let screen = NavigationStack { LAAChatsFixtureView() }
                .environment(\.laaDesktop, true)
                .environment(\.locale, Locale(identifier: "ja_JP"))
                .preferredColorScheme(style == .dark ? .dark : .light)
            try draw(screen, size: CGSize(width: 420, height: 820), style: style,
                     name: "mac-chats-\(style == .dark ? "dark" : "light")")
        }
    }

    func testUsageShowsTheMuseCardLightAndDark() async throws {
        let key = "laa.usage.expandedGroups"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set("provider.muse", forKey: key)
        let items = try LAAUsageFixtures.items()
        for style in [UIUserInterfaceStyle.light, .dark] {
            let state = LAAUsageState(widgetStore: nil)
            await state.refreshUsage({ items }, now: { LAAUsageFixtures.now })
            let bridge = LAABridgeSession(statusForTesting: .paired)
            let screen = NavigationStack { LAAUsageView(snapshotState: state) }.environmentObject(bridge)
                .environment(\.laaDesktop, true)
                .environment(\.locale, Locale(identifier: "ja_JP"))
                .preferredColorScheme(style == .dark ? .dark : .light)
            try draw(screen, size: CGSize(width: 900, height: 1100), style: style,
                     name: "mac-usage-muse-\(style == .dark ? "dark" : "light")")
        }
    }

    private func draw<Content: View>(_ view: Content, size: CGSize, style: UIUserInterfaceStyle, name: String) throws {
        let host = UIHostingController(rootView: view)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let previous = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let scene = try XCTUnwrap(previous?.windowScene ?? scenes.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.traitOverrides.userInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
