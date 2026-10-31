#if LAA_BUILD && DEBUG
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

@MainActor
final class LAAUsageViewSnapshotTests: XCTestCase {
    func testUsageStatesLightAndDark() async throws {
        for name in ["normal", "empty", "error", "offline", "unpaired", "stale"] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let state = LAAUsageState()
                if name != "unpaired" {
                    let items = name == "empty" ? [] : try fixture(stale: name == "stale")
                    await state.refreshUsage { items }
                    if name == "error" { await state.refreshUsage { throw LAABridgeError.unavailable } }
                    if name == "offline" { await state.refreshUsage { throw LAABridgeError.networkUnreachable } }
                }
                try capture(state: state, paired: name != "unpaired", style: style,
                            name: "usage-\(name)-\(style == .dark ? "dark" : "light")")
            }
        }
    }

    private func fixture(stale: Bool) throws -> [LAAUsageItem] {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let observed = formatter.string(from: now.addingTimeInterval(stale ? -3600 : -60))
        let freshUntil = formatter.string(from: now.addingTimeInterval(stale ? -2400 : 1140))
        let reset = formatter.string(from: now.addingTimeInterval(3600))
        let providers: [(String, String, Double)] = [("claude", "Claude", 62), ("codex", "Codex", 25), ("opencode-go", "OpenCode Go", 90)]
        let json: [[String: Any]] = providers.map { id, label, percent in
            ["id": "provider.\(id).quota", "kind": "quota", "label": label, "value": percent,
             "unit": "percent", "source": "codexbar-usage-proxy", "observedAt": observed,
             "availability": "available", "stale": stale, "estimated": false, "expired": false,
             "detail": ["freshUntil": freshUntil, "windows": [["label": "Session", "remainingPercent": percent, "resetsAt": reset]]]]
        }
        return try JSONDecoder().decode([LAAUsageItem].self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func capture(state: LAAUsageState, paired: Bool, style: UIUserInterfaceStyle, name: String) throws {
        let bridge = LAABridgeSession(statusForTesting: paired ? .paired : .unpaired)
        let screen = LAAUsageView(snapshotState: state).environmentObject(bridge)
            .environment(\.locale, Locale(identifier: "ja_JP"))
            .preferredColorScheme(style == .dark ? .dark : .light)
        let host = UIHostingController(rootView: screen)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let previous = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let scene = try XCTUnwrap(previous?.windowScene ?? scenes.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 440, height: 956)
        window.traitOverrides.horizontalSizeClass = .compact
        window.traitOverrides.verticalSizeClass = .regular
        window.traitOverrides.userInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        XCTAssertEqual(image.cgImage?.width, 440)
        XCTAssertEqual(image.cgImage?.height, 956)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
