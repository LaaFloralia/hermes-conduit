#if LAA_BUILD
import Foundation
import XCTest
@testable import Conduit

@MainActor
final class LAAUsageStateTests: XCTestCase {
    private func item(_ json: String) throws -> LAAUsageItem {
        try JSONDecoder().decode(LAAUsageItem.self, from: Data(json.utf8))
    }

    private func quota(_ percentage: Int = 62) throws -> LAAUsageItem {
        try item("""
        {"id":"provider.claude.quota","kind":"quota","label":"Claude","value":\(percentage),"unit":"percent",
         "source":"codexbar-usage-proxy","observedAt":"\(ISO8601DateFormatter().string(from: Date()))","availability":"available",
         "stale":false,"estimated":false,"expired":false,
         "detail":{"windows":[{"label":"Weekly","windowMinutes":10080,"remainingPercent":\(percentage),"resetsAt":"2099-11-02T00:00:00Z"}]}}
        """)
    }

    private func unavailable() throws -> LAAUsageItem {
        try item("""
        {"id":"provider.claude.quota","kind":"quota","label":"Claude","value":null,"unit":"percent",
         "source":"codexbar-usage-proxy","observedAt":null,"availability":"unavailable","nullReason":"fetch_failed",
         "stale":false,"estimated":false,"expired":false}
        """)
    }

    func testRefreshFailureClearsValuesAndUnavailableSuccessDoesNotRestoreThem() async throws {
        let state = LAAUsageState()
        let first = try quota()
        let firstTime = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 200)
        await state.refreshUsage({ [first] }, now: { firstTime })
        XCTAssertEqual(state.usage.value?.first?.value, 62)
        XCTAssertEqual(state.updatedAt, firstTime)
        await state.refreshUsage({ throw LAABridgeError.networkUnreachable }, now: { later })
        XCTAssertNil(state.usage.value)
        XCTAssertNil(state.usage.fetchedAt)
        XCTAssertNil(state.updatedAt)
        XCTAssertEqual(state.usage.error, .bridge(.networkUnreachable))
        await state.refreshUsage({ [try self.unavailable()] }, now: { later })
        XCTAssertNil(state.usage.value?.first?.value)
        XCTAssertEqual(state.usage.fetchedAt, later)
        XCTAssertEqual(state.updatedAt, later)
        await state.refreshUsage({ [] }, now: { later })
        XCTAssertEqual(state.usage.value?.count, 0)
        XCTAssertNil(state.usage.error)
        XCTAssertEqual(state.updatedAt, later)
    }

    func testRefreshUsageDeduplicatesAndOldScopeCannotPublish() async throws {
        let state = LAAUsageState()
        let started = expectation(description: "first refresh started")
        var calls = 0
        let first = try quota()
        state.selectScope(bridgeRevision: 0)
        let inFlight = Task {
            await state.refreshUsage {
                calls += 1
                started.fulfill()
                try await Task.sleep(nanoseconds: 300_000_000)
                return [first]
            }
        }
        defer { inFlight.cancel() }
        await fulfillment(of: [started], timeout: 10)
        await state.refreshUsage { calls += 1; return [] }
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(state.selectScope(bridgeRevision: 1))
        await inFlight.value
        await state.waitUntilIdle()
        XCTAssertNil(state.usage.value)
        await state.refreshUsage { [first] }
        XCTAssertEqual(state.usage.value?.first?.value, 62)
    }

    func testShellLifecycleRefreshesWidgetWithoutOpeningUsageAndClearsOnUnpair() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetSnapshotStore(directory: directory)
        let reading = try quota()
        let bridge = LAABridgeSession(statusForTesting: .paired)
        var calls = 0
        var reloads = 0
        let state = LAAUsageState(widgetStore: store, reloadWidgets: { reloads += 1 }, loader: { _ in
            calls += 1
            return [reading]
        })
        await state.synchronize(bridge: bridge, active: false)
        XCTAssertEqual(calls, 0)
        await state.synchronize(bridge: bridge, active: true)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.read()?.usage?.meters.first?.remainingPercent, 62)
        XCTAssertEqual(reloads, 1)
        await state.synchronize(bridge: bridge, active: true)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(reloads, 1) // The same snapshot does not reload WidgetKit twice.
        await state.synchronize(bridge: LAABridgeSession(statusForTesting: .unpaired), active: true)
        XCTAssertNil(store.read()?.usage)
        XCTAssertEqual(calls, 2)
    }

    func testFailedRefreshClearsWidgetSnapshotAndReloads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetSnapshotStore(directory: directory)
        let reading = try quota()
        let bridge = LAABridgeSession(statusForTesting: .paired)
        var fail = false
        var reloads = 0
        let state = LAAUsageState(widgetStore: store, reloadWidgets: { reloads += 1 }, loader: { _ in
            if fail { throw LAABridgeError.networkUnreachable }
            return [reading]
        })
        await state.refreshAndPublish(bridge: bridge)
        XCTAssertEqual(store.read()?.usage?.meters.first?.remainingPercent, 62)
        fail = true
        await state.refreshAndPublish(bridge: bridge)
        XCTAssertNil(state.usage.value)
        XCTAssertNil(store.read()?.usage)
        XCTAssertEqual(reloads, 2)
    }

    func testOpeningUsageThrottlesAttemptsButManualRefreshBypassesInterval() async {
        let bridge = LAABridgeSession(statusForTesting: .paired)
        var current = Date(timeIntervalSince1970: 1_000)
        var calls = 0
        var fail = false
        let state = LAAUsageState(widgetStore: nil, loader: { _ in
            calls += 1
            if fail { throw LAABridgeError.networkUnreachable }
            return []
        })
        await state.refreshOnTabOpen(bridge: bridge, now: { current })
        XCTAssertEqual(calls, 1)
        current.addTimeInterval(59)
        await state.refreshOnTabOpen(bridge: bridge, now: { current })
        XCTAssertEqual(calls, 1)
        current.addTimeInterval(1)
        await state.refreshOnTabOpen(bridge: bridge, now: { current })
        XCTAssertEqual(calls, 2)
        current.addTimeInterval(1)
        await state.refreshAndPublish(bridge: bridge, attemptedAt: current)
        XCTAssertEqual(calls, 3)
        current.addTimeInterval(59)
        await state.refreshOnTabOpen(bridge: bridge, now: { current })
        XCTAssertEqual(calls, 3)
        current.addTimeInterval(1)
        fail = true
        await state.refreshOnTabOpen(bridge: bridge, now: { current })
        XCTAssertEqual(calls, 4)
        current.addTimeInterval(1)
        await state.refreshOnTabOpen(bridge: bridge, now: { current })
        XCTAssertEqual(calls, 4)
        state.selectScope(bridgeRevision: 99)
        fail = false
        await state.refreshOnTabOpen(bridge: bridge, now: { current })
        XCTAssertEqual(calls, 5)
        await state.refreshOnTabOpen(bridge: LAABridgeSession(statusForTesting: .unpaired), now: { current })
        XCTAssertEqual(calls, 5)
        await state.refreshOnTabOpen(bridge: bridge, now: { current }, minimumInterval: 0)
        XCTAssertEqual(calls, 6)
    }

    func testTabRefreshAndShellStartupShareAnInFlightRequest() async {
        let bridge = LAABridgeSession(statusForTesting: .paired)
        let started = expectation(description: "tab refresh started")
        var calls = 0
        let state = LAAUsageState(widgetStore: nil, loader: { _ in
            calls += 1
            started.fulfill()
            try await Task.sleep(nanoseconds: 300_000_000)
            return []
        })
        let tabRefresh = Task { await state.refreshOnTabOpen(bridge: bridge) }
        await fulfillment(of: [started], timeout: 10)
        await state.synchronize(bridge: bridge, active: true)
        await tabRefresh.value
        XCTAssertEqual(calls, 1)
    }

    func testLegacyFreshnessAndVerifiedSources() throws {
        let reading = try quota()
        let at = try XCTUnwrap(LAAUsageItem.date("2026-10-31T00:09:59Z"))
        let deadline = try XCTUnwrap(LAAUsageItem.date("2026-10-31T00:10:00Z"))
        let later = try XCTUnwrap(LAAUsageItem.date("2026-10-31T00:20:00Z"))
        XCTAssertFalse(LAAUsageFreshness.isStale(reading, at: at))
        XCTAssertTrue(LAAUsageFreshness.isStale(reading, at: deadline))
        XCTAssertTrue(LAAUsageFreshness.isStale(reading, at: later))
        let observed = try XCTUnwrap(LAAUsageItem.date(reading.observedAt))
        XCTAssertFalse(LAAUsageFreshness.isStale(reading, at: observed.addingTimeInterval(-120)))
        XCTAssertTrue(LAAUsageFreshness.isStale(reading, at: observed.addingTimeInterval(-121)))
        let verified = try item("""
        {"id":"provider.magnific.credits","kind":"balance","label":"Magnific","value":1,"unit":"usd",
         "source":"codexbar-usage-proxy","observedAt":"2026-10-31T00:00:00Z","availability":"available",
         "stale":false,"estimated":false,"expired":false,"detail":{"sourceKind":"verified"}}
        """)
        XCTAssertTrue(LAAUsageFreshness.isStale(verified, at: at))
        XCTAssertTrue(LAAUsageFreshness.isStale(verified, at: at.addingTimeInterval(-3600)))
    }

    func testRepeatedFutureDatedLegacyReadingDoesNotExtendDeadline() async throws {
        let reading = try quota()
        let observed = try XCTUnwrap(LAAUsageItem.date(reading.observedAt))
        let firstReceipt = observed.addingTimeInterval(-120)
        let secondReceipt = observed.addingTimeInterval(-60)
        let state = LAAUsageState(widgetStore: nil)
        await state.refreshUsage({ [reading] }, now: { firstReceipt })
        await state.refreshUsage({ [reading] }, now: { secondReceipt })
        let cached = try XCTUnwrap(state.usage.value?.first)
        XCTAssertEqual(cached.freshnessAnchor, firstReceipt)
        XCTAssertFalse(LAAUsageFreshness.isStale(cached, at: firstReceipt.addingTimeInterval(599)))
        XCTAssertTrue(LAAUsageFreshness.isStale(cached, at: firstReceipt.addingTimeInterval(600)))
        let widget = LAAWidgetUsageBuilder.make(items: [cached], receivedAt: secondReceipt)
        XCTAssertEqual(widget.meters.first?.freshUntil, firstReceipt.addingTimeInterval(600))
    }

    func testWindowExpirationAndExtraCreditFreshnessAreIndependent() throws {
        let reading = try item("""
        {"id":"provider.claude.quota","kind":"quota","label":"Claude","value":0,"unit":"percent",
         "source":"codexbar-usage-proxy","observedAt":"2026-10-31T00:00:00Z","availability":"available",
         "stale":false,"estimated":false,"expired":true,
         "detail":{"windows":[{"label":"Session","remainingPercent":0,"resetsAt":"2026-10-31T00:05:00Z"},
                               {"label":"Weekly","remainingPercent":80,"resetsAt":"2026-11-02T00:00:00Z"}],
                   "credits":{"remaining":10,"updatedAt":"2026-10-30T20:00:00Z"}}}
        """)
        let now = try XCTUnwrap(LAAUsageItem.date("2026-10-31T00:09:00Z"))
        let windows = try XCTUnwrap(reading.detail?.windows)
        XCTAssertTrue(LAAUsageFreshness.windowExpired(windows[0], at: now))
        XCTAssertFalse(LAAUsageFreshness.windowExpired(windows[1], at: now))
        XCTAssertFalse(LAAUsageFreshness.isStale(reading, at: now))
        XCTAssertTrue(LAAUsageFreshness.extraNeedsAttention(reading, at: now))
    }
}
#endif
