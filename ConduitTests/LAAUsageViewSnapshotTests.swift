#if LAA_BUILD && DEBUG
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

@MainActor
final class LAAUsageViewSnapshotTests: XCTestCase {
    func testUnavailableReasonsAndCodeOwnedServiceLinks() async throws {
        let rows: [[String: Any]] = [
            ["id": "provider.magnific.credits", "kind": "balance", "label": "Magnific", "nullReason": "not_auto"],
            ["id": "provider.openai-api.cost-today", "kind": "cost", "label": "GPT API", "nullReason": "not_configured"],
            ["id": "provider.claude-api.cost-today", "kind": "cost", "label": "Claude API", "nullReason": "freshness_unknown"],
            ["id": "provider.openai-api.balance", "kind": "balance", "label": "GPT API", "nullReason": "not_auto"]
        ].map { row in
            row.merging(["value": NSNull(), "unit": "usd", "source": "codexbar-usage-proxy", "observedAt": NSNull(),
                         "availability": "unavailable", "stale": false, "estimated": false, "expired": false]) { original, _ in original }
        }
        let items = try JSONDecoder().decode([LAAUsageItem].self, from: JSONSerialization.data(withJSONObject: rows))
        XCTAssertEqual(items.map(LAAUsageView.unavailable), ["自動取得なし", "管理者キー未設定", "使用額を確認できません",
                                                             "自動取得なし"])
        XCTAssertEqual(LAAUsageGroup.consoleGroups(items).compactMap(\.serviceURL).map(\.scheme), ["https", "https", "https"])
        XCTAssertNil(LAAUsageGroup(id: "unknown", label: "Unknown", items: []).serviceURL)
        XCTAssertEqual(LAAUsageGroup.billingURL(for: "provider.openai-api.balance")?.host, "platform.openai.com")
        XCTAssertEqual(LAAUsageGroup.billingURL(for: "provider.claude-api.balance")?.host, "platform.claude.com")
        XCTAssertNil(LAAUsageGroup.billingURL(for: "provider.venice.balance"))
        let state = LAAUsageState()
        await state.refreshUsage { items }
        try capture(state: state, paired: true, style: .light, name: "usage-unavailable-reasons-light")
        try capture(state: state, paired: true, style: .dark, name: "usage-unavailable-reasons-dark")
    }

    func testUsageStatesLightAndDark() async throws {
        for name in ["normal", "empty", "error", "offline", "unpaired", "stale", "balance", "extras", "cost"] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let state = LAAUsageState()
                if name != "unpaired" {
                    let items = name == "empty" ? try unavailableFixture() : try fixture(stale: name == "stale", balanceOnly: name == "balance", extrasOnly: name == "extras", costOnly: name == "cost")
                    await state.refreshUsage { items }
                    if name == "error" { await state.refreshUsage { throw LAABridgeError.unavailable } }
                    if name == "offline" { await state.refreshUsage { throw LAABridgeError.networkUnreachable } }
                }
                try capture(state: state, paired: name != "unpaired", style: style,
                            name: "usage-\(name)-\(style == .dark ? "dark" : "light")")
            }
        }
    }

    /// The threshold tick used to be a laid-out sibling of the track, so a row
    /// with a mark was taller than one without. It is drawn over the track now.
    func testMeterHeightIsTheSameWithAndWithoutATick() {
        for tick in [nil, 0.35, 0.9] as [Double?] {
            let host = UIHostingController(rootView: LAAUsageMeter(fraction: 0.6, tick: tick).frame(width: 240))
            host.view.frame = CGRect(x: 0, y: 0, width: 240, height: 60)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            let measured = host.view.systemLayoutSizeFitting(
                CGSize(width: 240, height: UIView.layoutFittingCompressedSize.height)).height
            XCTAssertEqual(measured, LAAUsageMeter.totalHeight, accuracy: 0.5,
                           "tick \(String(describing: tick)) changed the meter's height")
        }
        XCTAssertEqual(LAAUsageMeter.totalHeight, LAAUsageMeter.height + 2 * 3,
                       "the 8pt track keeps 3pt above and below for the 14pt tick")
    }

    func testCapacityStatesLightAndDark() async throws {
        for name in ["normal", "warning", "critical", "stale", "unavailable"] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let state = LAAUsageState()
                let items = try fixture(stale: false) + capacityFixture(name)
                await state.refreshUsage { items }
                try capture(state: state, paired: true, style: style,
                            name: "usage-capacity-\(name)-\(style == .dark ? "dark" : "light")")
            }
        }
    }

    private func capacityFixture(_ name: String) throws -> [LAAUsageItem] {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let gib = 1_073_741_824.0
        let stale = name == "stale"
        let observed = formatter.string(from: now.addingTimeInterval(stale ? -3600 : -5))
        let freshUntil = formatter.string(from: now.addingTimeInterval(stale ? -3000 : 595))
        let ssdFree = name == "critical" ? 30 * gib : name == "warning" ? 60 * gib : 100 * gib
        let ssdStatus = name == "critical" ? "critical" : name == "warning" ? "warning" : "normal"
        let readings: [(String, String, Double, Double, String, Double?, Double?)] = [
            ("capacity.mac-mini.memory", "memory", 24 * gib, 6 * gib, "unknown", nil, nil),
            ("capacity.mac-mini.ssd", "ssd", 460 * gib, ssdFree, ssdStatus, 80 * gib, 40 * gib),
            ("capacity.google-drive", "google-storage", 30 * gib, 28 * gib, "normal", 3 * gib, 0.6 * gib),
            ("capacity.macbook.memory", "memory", 16 * gib, 4 * gib, "unknown", nil, nil),
            ("capacity.macbook.ssd", "ssd", 460 * gib, 312 * gib, "normal", 80 * gib, 40 * gib),
        ]
        var rows: [[String: Any]] = readings.map { id, type, total, free, status, warning, critical in
            name == "unavailable"
                ? ["id": id, "kind": "capacity", "label": id, "value": NSNull(), "unit": "bytes", "source": "filesystem",
                   "observedAt": NSNull(), "availability": "unavailable", "nullReason": "fetch_failed",
                   "stale": false, "estimated": false, "expired": false]
                : ["id": id, "kind": "capacity", "label": id, "value": total - free, "unit": "bytes", "source": "filesystem",
                   "observedAt": observed, "availability": "available", "stale": stale, "estimated": false, "expired": false,
                   "detail": ["totalBytes": total, "availableBytes": free, "freshUntil": freshUntil, "resourceType": type,
                              "status": status, "warningFreeBytes": (warning as Any?) ?? NSNull(), "criticalFreeBytes": (critical as Any?) ?? NSNull()]]
        }
        rows += ["capacity.icloud"].map { id in
            ["id": id, "kind": "capacity", "label": id, "value": NSNull(), "unit": "bytes", "source": "unsupported",
             "observedAt": NSNull(), "availability": "unavailable", "nullReason": "unsupported",
             "stale": false, "estimated": false, "expired": false]
        }
        return try JSONDecoder().decode([LAAUsageItem].self, from: JSONSerialization.data(withJSONObject: rows))
    }

    private func fixture(stale: Bool, balanceOnly: Bool = false, extrasOnly: Bool = false, costOnly: Bool = false) throws -> [LAAUsageItem] {
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
             "detail": ["freshUntil": freshUntil, "windows": [["label": "週間", "windowMinutes": 10080, "remainingPercent": percent, "resetsAt": reset]]]]
        }
        json[0]["detail"] = ["freshUntil": freshUntil,
            "windows": [["label": "Weekly", "windowMinutes": 10080, "remainingPercent": 62, "resetsAt": reset]],
            "credits": ["remaining": 7, "updatedAt": observed]]
        let balance: [String: Any] = ["id": "provider.magnific.credits", "kind": "balance", "label": "Magnific", "value": 236025,
            "unit": "credits", "source": "codexbar-usage-proxy", "observedAt": observed, "availability": "available",
            "stale": stale, "estimated": false, "expired": false, "detail": ["freshUntil": freshUntil, "creditUnit": "AI credits"]]
        let venice: [String: Any] = ["id": "provider.venice.balance", "kind": "balance", "label": "Venice", "value": 14.5,
            "unit": "usd", "source": "codexbar-usage-proxy", "observedAt": observed, "availability": "available",
            "stale": stale, "estimated": false, "expired": false, "detail": ["freshUntil": freshUntil, "currency": "USD"]]
        let apiBalances: [[String: Any]] = [("openai-api", "GPT API", 21.8), ("claude-api", "Claude API", 42.5)].map { id, label, amount in
            ["id": "provider.\(id).balance", "kind": "balance", "label": label, "value": amount,
             "unit": "usd", "source": "codexbar-usage-proxy", "observedAt": observed, "availability": "available",
             "stale": stale, "estimated": false, "expired": false,
             "detail": ["freshUntil": freshUntil, "currency": "USD"]] as [String: Any]
        }
        let costs: [[String: Any]] = [("claude-api", "Claude API", "typical-5m"), ("openai-api", "GPT API", "undisclosed")].flatMap { id, label, lag in
            ["today", "month"].map { period in
                ["id": "provider.\(id).cost-\(period)", "kind": "cost", "label": label, "value": period == "today" ? 1.23 : 17.25,
                 "unit": "usd", "source": "codexbar-usage-proxy", "observedAt": observed, "availability": "available",
                 "stale": stale, "estimated": false, "expired": false,
                 "detail": ["freshUntil": freshUntil, "sourceLag": lag, "periodTimezone": "UTC"]] as [String: Any]
            }
        }
        let d1: [String: Any] = ["id": "provider.liquid.usage", "kind": "usage", "label": "Liquid AI", "value": 123,
            "unit": "tokens", "source": "codexbar-usage-proxy", "observedAt": observed, "availability": "available",
            "stale": stale, "estimated": false, "expired": false,
            "detail": ["freshUntil": freshUntil, "recordedCostUsd": 1.31, "recordedRequestCount": 50, "lastRecordedAt": observed,
                       "models": [["inputTokens": 123, "outputTokens": 0]]]]
        if costOnly { json = costs }
        else if balanceOnly { json = [venice, balance] }
        else if extrasOnly { json = [json[0]] }
        else { json = [d1] + json + [venice, balance] + apiBalances + costs }
        return try JSONDecoder().decode([LAAUsageItem].self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func unavailableFixture() throws -> [LAAUsageItem] {
        let ids = ["claude", "codex", "antigravity", "claude-api", "openai-api", "magnific",
                   "liquid", "deepseek", "grok-bot", "refuseless", "opencode-go"]
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
