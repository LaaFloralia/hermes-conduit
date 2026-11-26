#if LAA_BUILD
import Foundation
import XCTest
@testable import Conduit

/// Hortensia Wave A1 (2026-11-25): Claude's Fable weekly quota as a separate
/// optional field, the Orca provider cards and the T3 six-row widget.
@MainActor
final class LAAUsageV2ModelTests: XCTestCase {
    private typealias F = LAAUsageFixtures
    private let now = LAAUsageFixtures.now

    private func claude(_ items: [LAAUsageItem]) throws -> LAAUsageItem {
        try XCTUnwrap(items.first { $0.id == "provider.claude.quota" })
    }

    // MARK: Wire model

    func testOldAndNewBridgeItemsDecode() throws {
        // A Bridge before 21ca970b sends no fableWeekly; the item is unchanged.
        let old = try claude(F.items(fable: nil))
        XCTAssertNil(old.detail?.fableWeekly)
        XCTAssertNil(old.fableWeekly(at: now))
        XCTAssertEqual(old.weeklyWindow?.remainingPercent, 49)
        // The live shape of 2026-11-25: Fable 32 beside an ordinary 49.
        let new = try claude(F.items())
        XCTAssertEqual(new.fableWeekly(at: now)?.remainingPercent, 32)
        XCTAssertEqual(new.fableWeekly(at: now)?.label, "Fable")
        XCTAssertEqual(new.detail?.windows?.count, 2, "Fable never joins the ordinary windows")
        XCTAssertEqual(new.weeklyWindow?.remainingPercent, 49)
        XCTAssertEqual(new.ordinaryWindow(minutes: 300)?.remainingPercent, 80)
        XCTAssertEqual(new.value, 49)
    }

    func testAMeasuredZeroFableStaysZero() throws {
        let item = try claude(F.items(fable: F.fable(0.0)))
        XCTAssertEqual(item.fableWeekly(at: now)?.remainingPercent, 0)
        XCTAssertEqual(item.weeklyWindow?.remainingPercent, 49)
    }

    /// Missing, malformed, expired or foreign Fable is unknown, and never
    /// costs the ordinary Claude item its decode or its numbers.
    func testABadFableIsUnknownAndLeavesClaudeIntact() throws {
        let cases: [(String, Any)] = [
            ("string", "broken"),
            ("number", 12),
            ("percent as text", F.fable("32")),
            ("over 100", F.fable(150.0)),
            ("negative", F.fable(-1.0)),
            ("expired", F.fable(20.0, reset: -60)),
            ("unparseable reset", ["id": LAAUsageItem.fableWindowID, "remainingPercent": 20, "resetsAt": "soon"]),
            ("other id", F.fable(20.0, id: "claude-weekly-scoped-other")),
            ("null", NSNull()),
        ]
        for (name, value) in cases {
            let items = try F.items(fable: value)
            let item = try claude(items)
            XCTAssertNil(item.fableWeekly(at: now), name)
            XCTAssertEqual(item.weeklyWindow?.remainingPercent, 49, name)
            XCTAssertEqual(items.count, 10, name)
        }
        // No reset at all is still a reading.
        XCTAssertEqual(try claude(F.items(fable: F.fable(40.0, reset: nil))).fableWeekly(at: now)?.remainingPercent, 40)
    }

    /// The app caches the last items in the App Group; a cached item keeps
    /// its Fable reading, and one cached before this build reads as before.
    func testCachedItemsRoundTrip() throws {
        let items = try F.items()
        let decoded = try JSONDecoder().decode([LAAUsageItem].self, from: JSONEncoder().encode(items))
        XCTAssertEqual(try claude(decoded).fableWeekly(at: now)?.remainingPercent, 32)
        let malformed = try F.items(fable: "broken")
        let again = try JSONDecoder().decode([LAAUsageItem].self, from: JSONEncoder().encode(malformed))
        XCTAssertNil(try claude(again).fableWeekly(at: now))
        XCTAssertEqual(try claude(again).weeklyWindow?.remainingPercent, 49)
    }

    // MARK: Fable never drives the headline, gauge or alerts

    func testFableNeverMovesTheWorkGauge() throws {
        let items = try F.items(fable: F.fable(0.0))
        // Codex 66, Claude 49, OpenCode 72: the needle reads 49, not Fable's 0.
        XCTAssertEqual(LAAUsageGauge.lowestWeeklyRemaining(items), 49)
        // Google's accounts stay out of Work's gauge.
        XCTAssertNil(LAAUsageGauge.lowestWeeklyRemaining(try F.decode(Array(F.rows()[3...5]))))
    }

    /// A Bridge that put the scoped window into the ordinary array, even
    /// first and with the same 10 080 minutes, still never answers as Weekly.
    func testAScopedWindowInTheOrdinaryListIsIgnored() throws {
        var rows = F.rows(fable: nil)
        var detail = try XCTUnwrap(rows[2]["detail"] as? [String: Any])
        var windows = try XCTUnwrap(detail["windows"] as? [[String: Any]])
        windows.insert(["id": LAAUsageItem.fableWindowID, "label": "Fable", "remainingPercent": 0,
                        "windowMinutes": 10_080, "resetsAt": F.iso(3600)], at: 0)
        windows.insert(["label": "Weekly", "remainingPercent": 1, "windowMinutes": 10_080, "scoped": true,
                        "resetsAt": F.iso(3600)], at: 0)
        detail["windows"] = windows
        rows[2]["detail"] = detail
        let items = try F.decode(rows)
        let item = try claude(items)
        XCTAssertEqual(item.ordinaryWindows.count, 2)
        XCTAssertEqual(item.weeklyWindow?.remainingPercent, 49)
        XCTAssertEqual(LAAUsageGauge.lowestWeeklyRemaining(items), 49)
        let widget = LAAWidgetUsageBuilder.make(items: items, receivedAt: now)
        XCTAssertEqual(widget.meters.first { $0.id == "provider.claude.quota.weekly" }?.amount, 49)
    }

    // MARK: Widget rows

    func testTheWidgetHoldsSixFixedReadings() throws {
        let usage = LAAWidgetUsageBuilder.make(items: try F.items(), receivedAt: now)
        let rows = LAAWidgetUsageBuilder.widgetMeters(usage)
        XCTAssertEqual(rows.map(\.label), ["Codex 7d", "Claude 5h", "Claude 7d", "Claude Fable", "Google 5h", "Google 7d"])
        XCTAssertEqual(rows.map(\.amount), [66, 80, 49, 32, 83, 75])
        XCTAssertTrue(rows.allSatisfy { $0.available && $0.hasRecordedValue(at: self.now) })
        // Weekly readings come first in the snapshot for an older reader.
        XCTAssertEqual(usage.meters.prefix(3).map(\.id), ["provider.codex.quota.weekly", "provider.claude.quota.weekly",
                                                          "provider.google-ai-pro.quota.weekly"])
        // Fable resets on its own clock.
        XCTAssertEqual(rows[3].resetsAt, now.addingTimeInterval(4 * 86_400))
        XCTAssertEqual(usage.meters.count, 6)
    }

    func testOpenCodeAndTheBalancesLeftTheWidget() {
        XCTAssertEqual(LAAWidgetUsageBuilder.widgetSlots.map(\.provider), ["codex", "claude", "google-ai-pro"])
        XCTAssertFalse(LAAWidgetUsageBuilder.slots.first { $0.provider == "opencode-go" }!.showsInWidget)
        XCTAssertEqual(LAAWidgetUsageBuilder.cardSlots.map(\.name), ["Codex", "Claude", "Google", "Muse"])
        XCTAssertEqual(LAAWidgetUsageBuilder.otherSlots.map(\.provider),
                       ["opencode-go", "magnific", "openai-api", "claude-api", "liquid", "venice", "refuseless"])
        XCTAssertEqual(LAAWidgetUsageBuilder.widgetRows.count, 6)
        XCTAssertEqual(Set(LAAWidgetUsageBuilder.dropOrder), Set(LAAWidgetUsageBuilder.widgetRows.map(\.id)))
    }

    func testAZeroFableStillLeavesOrdinaryClaudeAlone() throws {
        let rows = LAAWidgetUsageBuilder.widgetMeters(LAAWidgetUsageBuilder.make(items: try F.items(fable: F.fable(0.0)), receivedAt: now))
        XCTAssertEqual(rows.first { $0.id == "provider.claude.quota.fable" }?.amount, 0)
        XCTAssertEqual(rows.first { $0.id == "provider.claude.quota.weekly" }?.amount, 49)
        XCTAssertEqual(LAAUsageBarLevel(remainingPercent: 0), .critical)
    }

    /// Google reads one account, the one in use; none or two in use is
    /// unknown. Accounts are never averaged and no address is carried.
    func testGoogleReadsOnlyTheAccountInUse() throws {
        func google(_ active: [String: Bool]) throws -> [Double?] {
            let rows = LAAWidgetUsageBuilder.widgetMeters(LAAWidgetUsageBuilder.make(items: try F.items(googleActive: active), receivedAt: now))
            return ["provider.google-ai-pro.quota.session", "provider.google-ai-pro.quota.weekly"].map { id in
                rows.first { $0.id == id }?.remainingPercent
            }
        }
        XCTAssertEqual(try google(["sub2": true]), [83, 75])
        XCTAssertEqual(try google(["sub3": true]), [20, 30])
        XCTAssertEqual(try google([:]), [nil, nil], "no account in use")
        XCTAssertEqual(try google(["sub2": true, "sub3": true]), [nil, nil], "ambiguous")
        XCTAssertEqual(try google(["sub4": true]), [nil, nil], "the account in use is not signed in")
        let usage = LAAWidgetUsageBuilder.make(items: try F.items(), receivedAt: now)
        let encoded = String(decoding: try JSONEncoder().encode(usage), as: UTF8.self)
        XCTAssertFalse(encoded.contains("@"))
        XCTAssertFalse(encoded.contains("Sub2"))
    }

    func testOldSnapshotsDecodeAndReprojectOntoTheSixRows() throws {
        // A snapshot the seven-row widget saved (2026-11-24).
        let json = """
        {"meters":[
         {"id":"provider.codex.quota.weekly","label":"Codex","unit":"percent","amount":35,"available":true,"observedAt":785000000,"freshUntil":785000600,"stale":false,"retained":false},
         {"id":"provider.opencode-go.quota.weekly","label":"OpenCode","unit":"percent","amount":72,"available":true,"observedAt":785000000,"stale":false,"retained":false},
         {"id":"provider.claude.quota.weekly","label":"Claude","remainingPercent":12,"stale":false},
         {"id":"provider.magnific.credits","label":"Magnific","unit":"credits","amount":236025,"available":true,"observedAt":785000000,"stale":false,"retained":false,"granted":240000},
         {"id":"provider.venice.balance","label":"Venice","unit":"usd","amount":9,"available":true,"observedAt":785000000,"stale":false,"retained":false}
        ],"checkedAt":785000000}
        """
        let old = try JSONDecoder().decode(WidgetUsageSnapshot.self, from: Data(json.utf8))
        let shown = LAAWidgetUsageBuilder.widgetMeters(old)
        XCTAssertEqual(shown.map(\.id), ["provider.codex.quota.weekly", "provider.claude.quota.weekly"])
        XCTAssertEqual(shown.map(\.amount), [35, 12])
        // The new snapshot reads back unchanged, and the previous widget's
        // filter still finds Codex and Claude in it.
        let new = LAAWidgetUsageBuilder.make(items: try F.items(), receivedAt: now)
        let decoded = try JSONDecoder().decode(WidgetUsageSnapshot.self, from: JSONEncoder().encode(new))
        XCTAssertEqual(decoded, new)
        XCTAssertEqual(new.displayableMeters.map(\.id).prefix(2), ["provider.codex.quota.weekly", "provider.claude.quota.weekly"])
        // An old snapshot as `previous` carries its weekly numbers forward
        // only while a provider gives no fresh answer.
        let carried = LAAWidgetUsageBuilder.make(items: [], receivedAt: now, previous: WidgetUsageSnapshot(meters: [
            WidgetUsageMeter(id: "provider.claude.quota.weekly", label: "Claude", unit: .percent, amount: 12,
                             observedAt: now.addingTimeInterval(-600), freshUntil: now, resetsAt: nil, stale: false, retained: false),
        ], checkedAt: now))
        XCTAssertEqual(carried.meters.map(\.id), ["provider.claude.quota.weekly"])
        XCTAssertEqual(carried.meters.first?.retained, true)
    }

    /// When Claude answers without Fable, the old Fable number is not kept;
    /// when Claude does not answer, its last readings are kept, marked past.
    func testRetentionOnlyCoversAnUnansweredProvider() throws {
        let first = LAAWidgetUsageBuilder.make(items: try F.items(), receivedAt: now)
        let later = now.addingTimeInterval(60)
        let noFable = LAAWidgetUsageBuilder.make(items: try F.items(fable: nil), receivedAt: later, previous: first)
        let fable = try XCTUnwrap(noFable.meters.first { $0.id == "provider.claude.quota.fable" })
        XCTAssertFalse(fable.available)
        var rows = F.rows()
        rows[2] = F.quota("claude", label: "Claude", windows: [], available: false)
        let failed = LAAWidgetUsageBuilder.make(items: try F.decode(rows), receivedAt: later, previous: first)
        let kept = failed.meters.filter { $0.id.hasPrefix("provider.claude.") }
        XCTAssertEqual(kept.map(\.amount).sorted(), [32, 49, 80])
        XCTAssertTrue(kept.allSatisfy(\.retained))
    }

    func testBarThresholds() {
        XCTAssertEqual([nil, 100, 25, 24.9, 10, 9.99, 0].map(LAAUsageBarLevel.init(remainingPercent:)),
                       [.unknown, .normal, .normal, .caution, .caution, .critical, .critical])
        XCTAssertEqual(LAAUsageBarLevel(remainingPercent: .nan), .unknown)
    }

    // MARK: Cards

    func testCardWindows() throws {
        let items = try F.items()
        let codex = LAAUsageCardModel.windows(provider: "codex", item: LAAUsageCardModel.item("codex", in: items), now: now)
        XCTAssertEqual(codex.map(\.label), ["7d"], "only the windows Codex reports")
        let claude = LAAUsageCardModel.windows(provider: "claude", item: LAAUsageCardModel.item("claude", in: items), now: now)
        XCTAssertEqual(claude.map(\.label), ["5h", "7d", "Fable"])
        XCTAssertEqual(claude.map(\.remainingPercent), [80, 49, 32])
        let noFable = LAAUsageCardModel.windows(provider: "claude", item: LAAUsageCardModel.item("claude", in: try F.items(fable: nil)), now: now)
        XCTAssertEqual(noFable.map(\.remainingPercent), [80, 49, nil], "Fable keeps its place, unknown")
        let missing = LAAUsageCardModel.windows(provider: "codex", item: nil, now: now)
        XCTAssertEqual(missing.map(\.label), ["5h", "7d"])
        XCTAssertTrue(missing.allSatisfy { $0.remainingPercent == nil && $0.resetsAt == nil })
        // Past its reset a window is unknown, not its old share.
        let afterReset = LAAUsageCardModel.windows(provider: "claude", item: LAAUsageCardModel.item("claude", in: items),
                                                   now: now.addingTimeInterval(7300))
        XCTAssertNil(afterReset[0].remainingPercent)
        XCTAssertEqual(afterReset[1].remainingPercent, 49)
        let accounts = LAAUsageCardModel.accounts(items)
        XCTAssertEqual(accounts.map(LAAUsageCardModel.accountName), ["Sub2", "Sub3", "Sub4"])
        let active = try XCTUnwrap(LAAWidgetUsageBuilder.activeAccount(accounts))
        XCTAssertEqual(LAAUsageCardModel.windows(provider: "google-ai-pro", item: active, now: now).map(\.remainingPercent), [83, 75])
        XCTAssertEqual(LAAUsageCardModel.windows(provider: "google-ai-pro", item: accounts[2], now: now).map(\.remainingPercent), [nil, nil])
    }

    /// Muse (2026-11-26): the three Free accounts the harness switches
    /// between, each with its weekly allowance; an unread or signed-out
    /// account reads unknown, never 0, and the widget keeps its six rows.
    func testMuseCardShowsEachAccountsWeeklyFreeAllowance() throws {
        let items = try F.items()
        let muse = LAAUsageCardModel.accounts(items, group: "muse")
        XCTAssertEqual(muse.map(LAAUsageCardModel.accountName), ["Muse1", "Muse2", "Muse3"])
        XCTAssertEqual(LAAUsageCardModel.accounts(items).map(LAAUsageCardModel.accountName), ["Sub2", "Sub3", "Sub4"],
                       "Google's accounts stay Google's")
        let active = try XCTUnwrap(LAAWidgetUsageBuilder.activeAccount(muse))
        XCTAssertEqual(active.label, "Muse1")
        let shown = LAAUsageCardModel.windows(provider: "muse", item: active, now: now)
        XCTAssertEqual(shown.map(\.label), ["7d"])
        XCTAssertEqual(shown.map(\.remainingPercent), [94])
        XCTAssertNil(shown[0].resetsAt, "Muse names a day, not a time: no reset is made up")
        for account in muse.dropFirst() {
            XCTAssertEqual(LAAUsageCardModel.windows(provider: "muse", item: account, now: now).map(\.remainingPercent), [nil])
        }
        XCTAssertEqual(muse[2].nullReason, "auth_required")
        XCTAssertTrue(LAAUsageGroup.isAccountGroup("provider.muse"))
        XCTAssertFalse(LAAWidgetUsageBuilder.widgetSlots.contains { $0.provider == "muse" })
        XCTAssertNil(LAAUsageGauge.lowestWeeklyRemaining(muse), "Muse does not move Work's gauge")
    }

    func testResetText() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let base = LAAUsageItem.date("2026-11-25T00:00:00Z")! // 09:00 JST
        XCTAssertEqual(LAAUsageResetText.full(base.addingTimeInterval(9 * 3600), now: base, calendar: calendar), "18:00")
        XCTAssertEqual(LAAUsageResetText.full(base.addingTimeInterval(3 * 86_400), now: base, calendar: calendar), "11/28 9:00")
        XCTAssertEqual(LAAUsageResetText.short(base.addingTimeInterval(20 * 3600), now: base, calendar: calendar), "5:00")
        XCTAssertEqual(LAAUsageResetText.short(base.addingTimeInterval(3 * 86_400), now: base, calendar: calendar), "11/28")
    }

    // MARK: Banned copy

    static let banned = ["取得できません", "最終取得", "に戻る"]

    func testNoBannedCopyInAnyUsageText() throws {
        var texts = ["not_configured", "not_auto", "freshness_unknown", "fetch_failed", "unsupported", "auth_required", nil, "x"]
            .flatMap { [LAAUsageView.unavailableReason($0), LAAUsageView.unavailableReason($0, kind: "cost")] }
        texts += [LAAUsageProblem.failed, .bridge(.unavailable), .bridge(.networkUnreachable), .bridge(.forbidden),
                  .bridge(.unauthorized), .bridge(.revoked)].map(\.japaneseText)
        texts += [LAACopy.Usage.noAutomaticBalance, LAACopy.Usage.billingReading, LAACopy.Usage.noBalanceLeft,
                  LAACopy.Usage.others, LAACopy.Usage.accounts, LAACopy.Usage.updated, LAACopy.notFetched]
        let reset = now.addingTimeInterval(3600)
        texts += [LAAUsageResetText.full(reset, now: now), LAAUsageResetText.short(reset, now: now)]
        for text in texts { for word in Self.banned { XCTAssertFalse(text.contains(word), "\(text) contains \(word)") } }
    }

    /// The Usage sources this lane owns carry none of the banned words.
    func testNoBannedCopyInTheUsageSources() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = ["Conduit/LAA/Usage/LAAUsageView.swift", "Conduit/LAA/Usage/LAAUsageCards.swift",
                     "Conduit/LAA/Usage/LAAUsageState.swift", "Conduit/LAA/Usage/LAAUsageModels.swift",
                     "Shared/Widgets/LAAWidgetUsageBuilder.swift", "Shared/Widgets/LAAUsageReading.swift",
                     "ConduitWidgets/LAA/LAAEmployeeWidgetViews.swift"]
        for file in files {
            guard let text = try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8) else {
                throw XCTSkip("sources are not readable from this test host")
            }
            for word in Self.banned { XCTAssertFalse(text.contains(word), "\(file) contains \(word)") }
        }
    }
}
#endif
