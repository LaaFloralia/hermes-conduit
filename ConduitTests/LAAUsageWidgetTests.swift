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

    func testTheOwnerPriorityOrderAndLabels() throws {
        let items = try [
            item("liquid", kind: "usage", label: "Liquid AI", value: 123, unit: "tokens",
                 detail: ["recordedCostUsd": 1.31]),
            item("claude-api", kind: "cost-month", label: "Claude API", value: 17.25, unit: "usd",
                 detail: ["sourceLag": "typical-5m", "periodTimezone": "UTC"]),
            item("claude-api", kind: "balance", label: "Claude API", value: 42.5, unit: "usd"),
            item("openai-api", kind: "cost-month", label: "GPT API", value: 0.96, unit: "usd",
                 detail: ["sourceLag": "undisclosed", "periodTimezone": "UTC"]),
            item("openai-api", kind: "balance", label: "GPT API", value: 21.8, unit: "usd"),
            item("venice", kind: "balance", label: "Venice", value: 9, unit: "usd"),
            item("magnific", kind: "credits", label: "Magnific", value: 2100, unit: "credits"),
            item("claude", windows: [weekly(62)]),
            item("codex", windows: [weekly(35)]),
            item("opencode-go", windows: [weekly(72), weekly(40, minutes: 300, label: "5時間")]),
        ]
        let result = LAAWidgetUsageBuilder.make(items: items, receivedAt: now)
        // Liquid AI stays on the screen; the widget shows the eight above it.
        XCTAssertEqual(result.meters.map(\.label),
                       ["Codex", "OpenCode", "Claude", "Magnific", "GPT API", "Claude API", "Venice"])
        XCTAssertEqual(result.meters.map(\.unit), [.percent, .percent, .percent, .credits, .usd, .usd, .usd])
        XCTAssertEqual(result.meters.map(\.amount), [35, 72, 62, 2100, 21.8, 42.5, 9])
        XCTAssertTrue(result.meters.allSatisfy(\.available))
        XCTAssertEqual(result.checkedAt, now)
        // The API rows are the amount left, never the month's spend.
        XCTAssertEqual(result.meters.filter { $0.id.hasPrefix("provider.openai-api.") }.map(\.id), ["provider.openai-api.balance"])
        XCTAssertEqual(result.meters.filter { $0.id.hasPrefix("provider.claude-api.") }.map(\.id), ["provider.claude-api.balance"])
    }

    func testAPIProviderShowsItsBalanceAndNotItsMonthSpend() throws {
        let items = try [
            item("openai-api", kind: "cost-month", label: "GPT API", value: 0.96, unit: "usd",
                 detail: ["sourceLag": "undisclosed", "periodTimezone": "UTC"]),
            item("openai-api", kind: "balance", label: "GPT API", value: 21.8, unit: "usd"),
            unavailable("claude-api", kind: "balance", label: "Claude API"),
        ]
        let api = LAAWidgetUsageBuilder.make(items: items, receivedAt: now).meters.filter { $0.label.hasSuffix("API") }
        XCTAssertEqual(api.map(\.id), ["provider.openai-api.balance", "provider.claude-api.balance"])
        XCTAssertEqual(api.map(\.available), [true, false])
        XCTAssertEqual(api.map(\.amount), [21.8, 0])
    }

    func testABillingPageBalanceShowsBelowZeroWithItsDate() throws {
        let unpaid = try item("claude-api", kind: "balance", label: "Claude API", value: -0.19, unit: "usd",
                              observedAt: "2026-10-01T00:00:00Z", detail: ["sourceKind": "verified"])
        let meter = try XCTUnwrap(LAAWidgetUsageBuilder.make(items: [unpaid], receivedAt: now).meters
            .first { $0.id == "provider.claude-api.balance" })
        XCTAssertEqual(meter.amount, -0.19)
        XCTAssertEqual(meter.verified, true)
        XCTAssertTrue(meter.hasRecordedValue(at: now))
        XCTAssertFalse(meter.isPast(at: now))
    }

    func testAYenBalanceNeverFillsADollarRow() throws {
        let yen = try item("claude-api", kind: "balance", label: "Claude API", value: 3000, unit: "jpy",
                           detail: ["currency": "JPY"])
        XCTAssertEqual(LAAWidgetUsageBuilder.make(items: [yen], receivedAt: now).meters
            .first { $0.id == "provider.claude-api.balance" }?.available, false)
    }

    func testALegacyCostSnapshotIsNotDrawnAsABalance() throws {
        let legacy = WidgetUsageSnapshot(meters: [
            WidgetUsageMeter(id: "provider.openai-api.cost-month", label: "GPT API", unit: .usd, amount: 0.96,
                             observedAt: now, freshUntil: now.addingTimeInterval(600), resetsAt: nil,
                             stale: false, retained: false),
        ], checkedAt: now)
        XCTAssertTrue(legacy.displayableMeters.isEmpty)
        XCTAssertEqual(LAAWidgetUsageBuilder.make(items: [], receivedAt: now, previous: legacy).meters.map(\.available), [false, false])
    }

    func testWeeklyWindowIsChosenOverALowerFiveHourWindow() throws {
        let items = try [item("codex", windows: [weekly(5, minutes: 300, label: "Session"), weekly(80)])]
        let meter = try XCTUnwrap(LAAWidgetUsageBuilder.make(items: items, receivedAt: now).meters.first)
        XCTAssertEqual(meter.label, "Codex")
        XCTAssertEqual(meter.amount, 80)
    }

    func testSlotsWithoutAReadingKeepTheirPlaceAndDropTheNumber() throws {
        let items = try [
            item("codex", windows: [weekly(44)]),
            unavailable("opencode-go"),
            unavailable("claude-api", kind: "balance"),
            item("openai-api", kind: "balance", label: "GPT API", value: 2, unit: "usd"),
            item("claude", observedAt: "2026-10-30T20:00:00Z", windows: [weekly(90)]), // older than the window
        ]
        let result = LAAWidgetUsageBuilder.make(items: items, receivedAt: now)
        XCTAssertEqual(result.meters.map(\.label),
                       ["Codex", "OpenCode", "Claude", "GPT API", "Claude API"])
        XCTAssertEqual(result.meters.map(\.id), ["provider.codex.quota.weekly", "provider.opencode-go.quota.weekly",
            "provider.claude.quota.weekly", "provider.openai-api.balance", "provider.claude-api.balance"])
        XCTAssertEqual(result.meters.map(\.available), [true, false, false, true, false])
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
        // The API rows stay listed when their balance cannot be read.
        XCTAssertEqual(LAAWidgetUsageBuilder.make(items: items, receivedAt: now).meters.map(\.label),
                       ["Claude", "GPT API", "Claude API"])
    }

    func testLastKnownValuesSurviveMissingRowsWithoutChangingTheirTime() throws {
        let original = LAAWidgetUsageBuilder.make(items: [
            try item("claude", windows: [weekly(42)]),
            try item("magnific", kind: "credits", value: 236025, unit: "credits")
        ], receivedAt: now)
        let later = now.addingTimeInterval(3600)
        let retained = LAAWidgetUsageBuilder.make(items: [try unavailable("claude")], receivedAt: later, previous: original)
        XCTAssertEqual(retained.meters.filter(\.available).map(\.amount), [42, 236025])
        XCTAssertEqual(retained.meters.filter(\.available).map(\.observedAt), [now, now])
        XCTAssertTrue(retained.meters.filter(\.available).allSatisfy { $0.hasRecordedValue(at: later) && $0.isPast(at: later) })
        XCTAssertEqual(retained.checkedAt, now)
        let replaced = LAAWidgetUsageBuilder.make(items: [try item("claude", windows: [weekly(0)])], receivedAt: now, previous: retained)
        XCTAssertEqual(replaced.meters.first?.amount, 0)
        XCTAssertEqual(replaced.meters.first?.retained, false)
        let missing = WidgetUsageMeter.missing(id: "provider.claude.quota", label: "Claude Weekly")
        XCTAssertFalse(missing.hasRecordedValue(at: later))
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
            try item("openai-api", kind: "balance", label: "GPT API", value: 21.8, unit: "usd"),
            try unavailable("claude-api", kind: "balance", label: "Claude API"),
        ], receivedAt: now)
        let encoded = try JSONEncoder().encode(summary)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let meters = try XCTUnwrap(json["meters"] as? [[String: Any]])
        XCTAssertEqual(meters.count, 3)
        for meter in meters {
            XCTAssertTrue(Set(meter.keys).isSubset(of: ["id", "label", "unit", "amount", "available", "observedAt",
                                                        "freshUntil", "resetsAt", "stale", "retained", "verified",
                                                        "legacyFreshness"]))
        }
        XCTAssertEqual(meters.map { $0["unit"] as? String }, ["percent", "usd", "percent"])
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
        XCTAssertEqual(LAAUsageGroup.consoleGroups(items).map(\.id), ["provider.codex", "provider.claude", "provider.magnific",
            "provider.venice"])
        XCTAssertEqual(LAAUsageGroup.consoleGroups(items).first?.label, "Codex")
        let liquid = try item("liquid", kind: "usage", label: "Liquid AI", value: 1, unit: "tokens")
        XCTAssertEqual(LAAUsageGroup.consoleGroups([liquid]).map(\.label), ["Liquid AI"])
        XCTAssertEqual(LAAUsageGroup.consoleGroups([try item("opencode-go", label: "OpenCode Go")]).map(\.label), ["OpenCode"])
        let widget = LAAWidgetUsageBuilder.make(items: items, receivedAt: now)
        XCTAssertEqual(widget.meters.map(\.label),
                       ["Codex", "Claude", "GPT API", "Claude API"])
        XCTAssertTrue(widget.meters.allSatisfy { !$0.available })
        XCTAssertEqual(WidgetUsageSnapshot(meters: widget.meters, checkedAt: nil).displayableMeters.count, widget.meters.count)
        let retired = ["jev", "google-cloud", "google-flow", "fal", "antigravity"]
        XCTAssertFalse(widget.meters.contains { meter in retired.contains { meter.id.contains($0) } })
    }

    func testMagnificUnavailableAndCreditSnapshotRoundTrip() throws {
        let missing = try unavailable("magnific", kind: "credits", label: "Magnific")
        let absent = LAAWidgetUsageBuilder.make(items: [missing], receivedAt: now)
        XCTAssertEqual(absent.meters.first?.label, "Magnific")
        XCTAssertEqual(absent.meters.first?.available, false)
        let fresh = LAAWidgetUsageBuilder.make(items: [try item("magnific", kind: "credits", value: 1234, unit: "credits")], receivedAt: now)
        let decoded = try JSONDecoder().decode(WidgetUsageSnapshot.self, from: JSONEncoder().encode(fresh))
        XCTAssertEqual(decoded.displayableMeters.first?.unit, .credits)
        XCTAssertEqual(decoded.displayableMeters.first?.amount, 1234)
    }

    func testWindowNamesAreOneWording() throws {
        func window(_ label: String, _ minutes: Double?) throws -> LAAUsageItem.Window {
            try JSONDecoder().decode(LAAUsageItem.Window.self, from: JSONSerialization.data(withJSONObject: [
                "label": label, "remainingPercent": 50,
                "windowMinutes": minutes.map { $0 as Any } ?? NSNull(),
            ]))
        }
        XCTAssertEqual(LAAUsageLabel.window(try window("週間", 10_080)), "週間")
        XCTAssertEqual(LAAUsageLabel.window(try window("Weekly", 10_080)), "週間")
        XCTAssertEqual(LAAUsageLabel.window(try window("週次プール", nil)), "週間")
        XCTAssertEqual(LAAUsageLabel.window(try window("月間", 43_200)), AppLocalization.string("Monthly"))
        XCTAssertEqual(LAAUsageLabel.window(try window("Session", 300)), "Session")
        XCTAssertEqual(LAAUsageLabel.window(try window("Claude/GPT", nil)), "Claude/GPT")
    }
}
#endif
