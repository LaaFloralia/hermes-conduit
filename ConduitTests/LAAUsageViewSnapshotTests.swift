#if LAA_BUILD && DEBUG
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

@MainActor
final class LAAUsageViewSnapshotTests: XCTestCase {
    func testUsageStatesLightAndDark() async throws {
        for name in ["normal", "empty", "error", "offline", "unpaired", "stale", "balance", "extras"] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let state = LAAUsageState()
                if name != "unpaired" {
                    let items = name == "empty" ? try unavailableFixture() : try fixture(stale: name == "stale", balanceOnly: name == "balance", extrasOnly: name == "extras")
                    await state.refreshUsage { items }
                    if name == "error" { await state.refreshUsage { throw LAABridgeError.unavailable } }
                    if name == "offline" { await state.refreshUsage { throw LAABridgeError.networkUnreachable } }
                }
                try capture(state: state, paired: name != "unpaired", style: style,
                            name: "usage-\(name)-\(style == .dark ? "dark" : "light")")
            }
        }
    }

    private func fixture(stale: Bool, balanceOnly: Bool = false, extrasOnly: Bool = false) throws -> [LAAUsageItem] {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let observed = formatter.string(from: now.addingTimeInterval(stale ? -3600 : -60))
        let freshUntil = formatter.string(from: now.addingTimeInterval(stale ? -2400 : 1140))
        let reset = formatter.string(from: now.addingTimeInterval(3600))
        let providers: [(String, String, Double)] = [("claude", "Claude", 62), ("codex", "Codex", 25), ("opencode-go", "OpenCode Go", 90)]
        var json: [[String: Any]] = providers.map { id, label, percent in
            ["id": "provider.\(id).quota", "kind": "quota", "label": label, "value": percent,
             "unit": "percent", "source": "codexbar-usage-proxy", "observedAt": observed,
             "availability": "available", "stale": stale, "estimated": false, "expired": false,
             "detail": ["freshUntil": freshUntil, "windows": [["label": "Session", "remainingPercent": percent, "resetsAt": reset]]]]
        }
        json[0]["detail"] = ["freshUntil": freshUntil,
            "windows": [["label": "Session", "remainingPercent": 62, "resetsAt": reset]],
            "credits": ["remaining": 7, "updatedAt": observed],
            "resetPasses": ["available": false, "remaining": 0, "updatedAt": observed, "expiresAt": reset]]
        let fal: [String: Any] = ["id": "provider.fal.balance", "kind": "balance", "label": "fal", "value": 3.5,
            "unit": "usd", "source": "codexbar-usage-proxy", "observedAt": observed, "availability": "available",
            "stale": false, "estimated": false, "expired": false, "detail": ["sourceKind": "verified", "currency": "USD"]]
        let d1: [String: Any] = ["id": "provider.liquid.usage", "kind": "usage", "label": "Liquid AI", "value": 123,
            "unit": "tokens", "source": "codexbar-usage-proxy", "observedAt": observed, "availability": "available",
            "stale": stale, "estimated": false, "expired": false,
            "detail": ["freshUntil": freshUntil, "recordedCostUsd": 1.31, "recordedRequestCount": 50, "lastRecordedAt": observed,
                       "models": [["inputTokens": 123, "outputTokens": 0]]]]
        if balanceOnly { json = [fal] }
        else if extrasOnly { json = [json[0]] }
        else { json = [d1] + json + [fal] }
        return try JSONDecoder().decode([LAAUsageItem].self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func unavailableFixture() throws -> [LAAUsageItem] {
        let ids = ["claude", "codex", "antigravity", "jev", "google-cloud", "venice", "claude-api", "fal",
                   "gemini", "google-flow", "liquid", "deepseek", "grok-bot", "refuseless", "opencode-go", "magnific"]
        let rows: [[String: Any]] = ids.map { id in
            ["id": "provider.\(id).unavailable", "kind": "quota", "label": id, "value": NSNull(),
             "unit": "percent", "source": "codexbar-usage-proxy", "observedAt": NSNull(),
             "availability": "unavailable", "nullReason": "fetch_failed", "stale": false, "estimated": false, "expired": false]
        }
        return try JSONDecoder().decode([LAAUsageItem].self, from: JSONSerialization.data(withJSONObject: rows))
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
