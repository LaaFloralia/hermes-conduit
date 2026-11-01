#if LAA_BUILD
import Foundation
import XCTest
@testable import Conduit

@MainActor
final class LAAUsageWidgetTests: XCTestCase {
    private let now = LAAUsageItem.date("2026-10-31T00:00:00Z")!

    private func item(_ id: String, kind: String = "quota", label: String? = nil, value: Double? = 30,
                      unit: String = "percent", available: Bool = true,
                      observedAt: String? = "2026-10-31T00:00:00Z",
                      windows: [[String: Any]]? = nil, detail extra: [String: Any] = [:]) throws -> LAAUsageItem {
        var detail = extra
        if let windows { detail["windows"] = windows }
        var json: [String: Any] = [
            "id": "provider.\(id).\(kind)", "kind": kind,
            "label": label ?? id, "value": value as Any, "unit": unit,
            "source": "codexbar-usage-proxy", "observedAt": observedAt as Any,
            "availability": available ? "available" : "unavailable",
            "stale": false, "estimated": false, "expired": false,
        ]
        if !detail.isEmpty { json["detail"] = detail }
        return try JSONDecoder().decode(LAAUsageItem.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func unavailable(_ id: String, kind: String = "quota", label: String? = nil) throws -> LAAUsageItem {
        try JSONDecoder().decode(LAAUsageItem.self, from: JSONSerialization.data(withJSONObject: [
            "id": "provider.\(id).\(kind)", "kind": kind, "label": label ?? id,
            "value": NSNull(), "unit": kind == "cost" ? "usd" : "percent",
            "source": "codexbar-usage-proxy", "observedAt": NSNull(), "availability": "unavailable",
            "nullReason": "not_configured", "stale": false, "estimated": false, "expired": false,
        ]))
    }

    private func weekly(_ percent: Double, minutes: Double = 10_080, label: String = "Weekly") -> [String: Any] {
        ["label": label, "remainingPercent": percent, "windowMinutes": minutes, "resetsAt": "2030-01-01T00:00:00Z"]
    }

    func testSevenRowsKeepTheOwnerPriorityOrderAndLabels() throws {
        let items = try [
            item("liquid", kind: "usage", label: "Liquid AI", value: 123, unit: "tokens",
                 detail: ["recordedCostUsd": 1.31]),
            item("claude-api", kind: "cost-month", label: "Claude API", value: 17.25, unit: "usd",
                 detail: ["sourceLag": "typical-5m", "periodTimezone": "UTC"]),
            item("openai-api", kind: "cost-month", label: "GPT API", value: 4.5, unit: "usd",
                 detail: ["sourceLag": "undisclosed", "periodTimezone": "UTC"]),
            item("venice", kind: "balance", label: "Venice", value: 9, unit: "usd"),
            item("claude", windows: [weekly(62)]),
            item("codex", windows: [weekly(35)]),
            item("opencode-go", windows: [weekly(72), weekly(40, minutes: 300, label: "5時間")]),
        ]
        let weekly = AppLocalization.string("Weekly")
        let result = LAAWidgetUsageBuilder.make(items: items, receivedAt: now)
        XCTAssertEqual(result.meters.map(\.label),
                       ["Codex", "OpenCode", "Claude"].map { "\($0) \(weekly)" } + ["Venice", "GPT API", "Claude API", "Liquid AI"])
        XCTAssertEqual(result.meters.map(\.unit), [.percent, .percent, .percent, .usd, .usd, .usd, .usd])
        XCTAssertEqual(result.meters.map(\.amount), [35, 72, 62, 9, 4.5, 17.25, 1.31])
        XCTAssertTrue(result.meters.allSatisfy(\.available))
        XCTAssertEqual(result.checkedAt, now)
    }

    func testWeeklyWindowIsChosenOverALowerFiveHourWindow() throws {
        let items = try [item("codex", windows: [weekly(5, minutes: 300, label: "Session"), weekly(80)])]
        let meter = try XCTUnwrap(LAAWidgetUsageBuilder.make(items: items, receivedAt: now).meters.first)
        XCTAssertEqual(meter.label, "Codex " + AppLocalization.string("Weekly"))
        XCTAssertEqual(meter.amount, 80)
    }

    func testSlotsWithoutAReadingKeepTheirPlaceAndDropTheNumber() throws {
        let items = try [
            item("codex", windows: [weekly(44)]),
            unavailable("opencode-go"),
            unavailable("claude-api", kind: "cost-month"),
            item("openai-api", kind: "cost-month", label: "GPT API", value: 2, unit: "usd",
                 detail: ["sourceLag": "undisclosed"]),                        // no period timezone
            item("claude", observedAt: "2026-10-30T20:00:00Z", windows: [weekly(90)]), // older than the window
        ]
        let result = LAAWidgetUsageBuilder.make(items: items, receivedAt: now)
        let weekly = AppLocalization.string("Weekly")
        XCTAssertEqual(result.meters.map(\.label),
                       ["Codex", "OpenCode", "Claude"].map { "\($0) \(weekly)" } + ["GPT API", "Claude API"])
        XCTAssertEqual(result.meters.map(\.available), [true, false, false, false, false])
        XCTAssertEqual(result.meters.first?.amount, 44)
        XCTAssertEqual(result.checkedAt, now)
    }

    func testRetiredProvidersNeverProduceARow() throws {
        let items = try [
            item("jev", kind: "balance", label: "Jev", value: 3, unit: "usd"),
            item("google-cloud", kind: "balance", label: "Google Cloud", value: 5, unit: "usd"),
            item("google-flow", kind: "credits", label: "Google Flow", value: 0, unit: "credits"),
            item("claude", windows: [weekly(20)]),
        ]
        XCTAssertEqual(LAAWidgetUsageBuilder.make(items: items, receivedAt: now).meters.map(\.label),
                       ["Claude " + AppLocalization.string("Weekly")])
    }

    func testSnapshotCacheSurvivesOtherPublicationsAndCanBeCleared() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetSnapshotStore(directory: directory)
        let summary = LAAWidgetUsageBuilder.make(items: [try item("claude", windows: [weekly(42)])], receivedAt: now)
        XCTAssertTrue(try store.writeUsage(summary))
        let old = WidgetSnapshot(appLanguage: "en", currentWorkspaceID: nil, workspaces: [])
        XCTAssertTrue(try store.write(old))
        XCTAssertEqual(store.read()?.usage, summary)
        XCTAssertTrue(try store.writeUsage(nil))
        XCTAssertNil(store.read()?.usage)
        XCTAssertEqual(store.read()?.appLanguage, "en")
        let encodedOld = Data("{\"schemaVersion\":1,\"appLanguage\":\"ja\",\"workspaces\":[]}".utf8)
        XCTAssertNil(try JSONDecoder().decode(WidgetSnapshot.self, from: encodedOld).usage)
    }

    func testLegacyAndVerifiedMetersKeepTheirCorrectFreshness() throws {
        let observed = now
        let legacy = WidgetUsageMeter(id: "legacy", label: "Claude Weekly", unit: .percent, amount: 0,
            observedAt: observed, freshUntil: nil, resetsAt: nil, stale: false, retained: false)
        XCTAssertFalse(legacy.isPast(at: observed.addingTimeInterval(599)))
        XCTAssertTrue(legacy.isPast(at: observed.addingTimeInterval(600)))
        let verified = WidgetUsageMeter(id: "manual", label: "Claude Weekly", unit: .percent, amount: 20,
            observedAt: observed, freshUntil: nil, resetsAt: nil, stale: false, retained: false, verified: true)
        XCTAssertTrue(verified.isPast(at: observed.addingTimeInterval(1)))
        XCTAssertTrue(verified.isPast(at: observed.addingTimeInterval(-120)))
        let missing = WidgetUsageMeter.missing(id: "gone", label: "Liquid AI")
        XCTAssertTrue(missing.isPast(at: observed))
        XCTAssertNil(missing.remainingPercent)
        let old = Data("""
        {"id":"old","label":"Claude","remainingPercent":20,"observedAt":0,"freshUntil":null,"resetsAt":null,"stale":false,"retained":false}
        """.utf8)
        let decodedOld = try JSONDecoder().decode(WidgetUsageMeter.self, from: old)
        XCTAssertNil(decodedOld.verified)
        XCTAssertEqual(decodedOld.remainingPercent, 20)
        XCTAssertTrue(decodedOld.available)
        let retained = Data("""
        {"id":"old","label":"Claude","remainingPercent":20,"observedAt":0,"freshUntil":null,"resetsAt":null,"stale":false,"retained":true}
        """.utf8)
        let decoded = try JSONDecoder().decode(WidgetUsageMeter.self, from: retained)
        XCTAssertTrue(decoded.stale)
        XCTAssertTrue(decoded.isPast(at: Date(timeIntervalSinceReferenceDate: 1)))
    }

    func testSnapshotContainsOnlySummaryFields() throws {
        let summary = LAAWidgetUsageBuilder.make(items: [
            try item("claude", windows: [weekly(42)]),
            try item("openai-api", kind: "cost-month", label: "GPT API", value: 2, unit: "usd",
                     detail: ["sourceLag": "undisclosed", "periodTimezone": "UTC"]),
        ], receivedAt: now)
        let encoded = try JSONEncoder().encode(summary)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let meters = try XCTUnwrap(json["meters"] as? [[String: Any]])
        XCTAssertEqual(meters.count, 2)
        for meter in meters {
            XCTAssertTrue(Set(meter.keys).isSubset(of: ["id", "label", "unit", "amount", "available", "observedAt",
                                                        "freshUntil", "resetsAt", "stale", "retained", "verified",
                                                        "legacyFreshness"]))
        }
        XCTAssertEqual(meters.map { $0["unit"] as? String }, ["percent", "usd"])
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("http"))
        XCTAssertFalse(text.contains("token"))
    }

    func testUsageWidgetRoutePersistsUntilShellCanConsumeIt() throws {
        let suite = "LAAUsageWidgetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppState(defaults: defaults, loadSavedConnection: false)
        let link = try XCTUnwrap(WidgetLaunchLink(action: .usage, workspace: nil, reference: nil))
        XCTAssertFalse(app.laaWidgetUsagePending)
        XCTAssertTrue(app.routeWidgetLaunchURL(link.url))
        XCTAssertTrue(app.laaWidgetUsagePending)
        XCTAssertFalse(app.routeWidgetLaunchURL(try XCTUnwrap(URL(string: "https://example.invalid/"))))
    }

    func testOnlyThePriorityProvidersAreListedInTheAppAndTheWidget() throws {
        let items = try [unavailable("fal"), unavailable("venice"), unavailable("jev"), unavailable("google-cloud"),
                         unavailable("google-flow"), unavailable("magnific", label: "Magnific"),
                         unavailable("antigravity"), unavailable("codex"), unavailable("claude")]
        XCTAssertEqual(LAAUsageGroup.consoleGroups(items).map(\.id), ["provider.codex", "provider.claude", "provider.venice",
            "provider.antigravity", "provider.magnific"])
        XCTAssertEqual(LAAUsageGroup.consoleGroups(items).first?.label, "Codex")
        let liquid = try item("liquid", kind: "usage", label: "Liquid AI", value: 1, unit: "tokens")
        XCTAssertEqual(LAAUsageGroup.consoleGroups([liquid]).map(\.label), ["Liquid AI"])
        XCTAssertEqual(LAAUsageGroup.consoleGroups([try item("opencode-go", label: "OpenCode Go")]).map(\.label), ["OpenCode"])
        XCTAssertEqual(LAAWidgetUsageBuilder.make(items: items, receivedAt: now).meters.count, 0)
    }

    func testWindowNamesAreOneWording() throws {
        func window(_ label: String, _ minutes: Double?) throws -> LAAUsageItem.Window {
            try JSONDecoder().decode(LAAUsageItem.Window.self, from: JSONSerialization.data(withJSONObject: [
                "label": label, "remainingPercent": 50,
                "windowMinutes": minutes.map { $0 as Any } ?? NSNull(),
            ]))
        }
        XCTAssertEqual(LAAUsageLabel.window(try window("週間", 10_080)), AppLocalization.string("Weekly"))
        XCTAssertEqual(LAAUsageLabel.window(try window("Weekly", 10_080)), AppLocalization.string("Weekly"))
        XCTAssertEqual(LAAUsageLabel.window(try window("週次プール", nil)), AppLocalization.string("Weekly"))
        XCTAssertEqual(LAAUsageLabel.window(try window("月間", 43_200)), AppLocalization.string("Monthly"))
        XCTAssertEqual(LAAUsageLabel.window(try window("Session", 300)), "Session")
        XCTAssertEqual(LAAUsageLabel.window(try window("Claude/GPT", nil)), "Claude/GPT")
    }
}
#endif
