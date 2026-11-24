#if LAA_BUILD
import Foundation
@testable import Conduit

/// Bridge `GET /v1/usage` items for the v2 Usage tests, shaped like the live
/// feed of 2026-11-25 (Bridge 21ca970b, proxy bb3b029c) with every timestamp
/// relative to `now`.
enum LAAUsageFixtures {
    /// The current second: the Usage screen evaluates freshness against the
    /// wall clock, so the fixture moves with it.
    static let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    static func iso(_ offset: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: now.addingTimeInterval(offset))
    }

    static func window(_ label: String, _ remaining: Double?, minutes: Double?, reset: TimeInterval? = 3600) -> [String: Any] {
        var row: [String: Any] = ["label": label, "remainingPercent": remaining.map { $0 as Any } ?? NSNull()]
        if let minutes { row["windowMinutes"] = minutes }
        row["resetsAt"] = reset.map { iso($0) } ?? NSNull()
        return row
    }

    static func fable(_ remaining: Any, reset: TimeInterval? = 4 * 86_400, id: String = LAAUsageItem.fableWindowID) -> [String: Any] {
        ["id": id, "label": "Fable", "windowMinutes": 10_080, "remainingPercent": remaining,
         "resetsAt": reset.map { iso($0) } ?? NSNull()]
    }

    static func quota(_ provider: String, label: String, windows: [[String: Any]], fable: Any? = nil,
                      available: Bool = true, observed: TimeInterval = -60, group: String? = nil, active: Bool? = nil) -> [String: Any] {
        var detail: [String: Any] = ["windows": windows, "freshUntil": iso(observed + 600)]
        if let fable { detail["fableWeekly"] = fable }
        var row: [String: Any] = [
            "id": "provider.\(provider).quota", "kind": "quota", "label": label, "unit": "percent",
            "source": "codexbar-usage-proxy", "stale": false, "estimated": false, "expired": false,
        ]
        if available {
            let lowest = windows.compactMap { $0["remainingPercent"] as? Double }.min() ?? 0
            row.merge(["value": lowest, "observedAt": iso(observed), "availability": "available", "detail": detail]) { _, new in new }
        } else {
            row.merge(["value": NSNull(), "observedAt": NSNull(), "availability": "unavailable", "nullReason": "fetch_failed"]) { _, new in new }
        }
        if let group { row["group"] = group; row["groupName"] = "Google AI Pro" }
        if let active { row["active"] = active }
        return row
    }

    static func google(_ sub: String, active: Bool, fiveHour: Double?, weekly: Double?, available: Bool = true) -> [String: Any] {
        quota("google-ai-pro-\(sub)", label: "Google \(sub.capitalized)",
              windows: [window("5時間", fiveHour, minutes: 300, reset: 2 * 3600), window("週間", weekly, minutes: 10_080, reset: 3 * 86_400)],
              available: available, group: "google-ai-pro", active: active)
    }

    /// Codex 7d 66, Claude 5h 80 / 7d 49 / Fable `fable`, Google Sub2 (in
    /// use) 83 / 75, Sub3 20 / 30, Sub4 not signed in; OpenCode and a balance.
    static func rows(fable fableValue: Any? = fable(32.0), googleActive: [String: Bool] = ["sub2": true, "sub3": false, "sub4": false]) -> [[String: Any]] {
        [
            quota("codex", label: "Codex", windows: [window("Weekly", 66, minutes: 10_080, reset: 3 * 86_400)]),
            quota("opencode-go", label: "OpenCode", windows: [window("週間", 72, minutes: 10_080)]),
            quota("claude", label: "Claude", windows: [window("Session", 80, minutes: 300, reset: 7200),
                                                       window("Weekly", 49, minutes: 10_080, reset: 4 * 86_400)],
                  fable: fableValue),
            google("sub2", active: googleActive["sub2"] ?? false, fiveHour: 83, weekly: 75),
            google("sub3", active: googleActive["sub3"] ?? false, fiveHour: 20, weekly: 30),
            google("sub4", active: googleActive["sub4"] ?? false, fiveHour: nil, weekly: nil, available: false),
            ["id": "provider.venice.balance", "kind": "balance", "label": "Venice", "value": 0, "unit": "usd",
             "source": "codexbar-usage-proxy", "observedAt": iso(-60), "availability": "available",
             "stale": false, "estimated": false, "expired": false, "detail": ["currency": "USD", "freshUntil": iso(540)]],
        ]
    }

    static func decode(_ rows: [[String: Any]]) throws -> [LAAUsageItem] {
        try JSONDecoder().decode([LAAUsageItem].self, from: JSONSerialization.data(withJSONObject: rows))
    }

    static func items(fable: Any? = fable(32.0), googleActive: [String: Bool] = ["sub2": true, "sub3": false, "sub4": false]) throws -> [LAAUsageItem] {
        try decode(rows(fable: fable, googleActive: googleActive))
    }
}
#endif
