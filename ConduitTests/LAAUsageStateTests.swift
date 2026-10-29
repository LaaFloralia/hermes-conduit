#if LAA_BUILD
import Foundation
import XCTest
@testable import Conduit

@MainActor
final class LAAUsageStateTests: XCTestCase {
    private func item(_ json: String) throws -> LAAUsageItem {
        try JSONDecoder().decode(LAAUsageItem.self, from: Data(json.utf8))
    }

    private func quota(_ percentage: String = "62", id: String = "provider.claude.quota") throws -> LAAUsageItem {
        try item("""
        {"id":"\(id)","kind":"quota","label":"Claude","value":\(percentage),"unit":"percent",
         "source":"test","observedAt":"2026-10-29T04:49:23Z","availability":"available",
         "stale":false,"estimated":false,"expired":false,
         "detail":{"windows":[{"label":"Session","remainingPercent":\(percentage),"resetsAt":"2026-11-02T00:00:00Z"}]}}
        """)
    }

    private func unavailable(_ id: String = "provider.claude.quota") throws -> LAAUsageItem {
        try item("""
        {"id":"\(id)","kind":"quota","label":"Claude","value":null,"unit":"percent",
         "source":"test","observedAt":null,"availability":"unavailable","nullReason":"fetch_failed",
         "stale":false,"estimated":false,"expired":false}
        """)
    }

    func testOverviewRequiresARealWindowAndKeepsZeroDistinctFromMissing() throws {
        let now = Date(timeIntervalSince1970: 1_793_318_400)
        let zero = try quota("0")
        XCTAssertEqual(LAAUsageOverview.first(from: [zero], now: now)?.remainingPercent, 0)
        XCTAssertNil(LAAUsageOverview.first(from: [try quota("null")], now: now))
        XCTAssertNil(LAAUsageOverview.first(from: [try quota("101")], now: now))
        XCTAssertNil(LAAUsageOverview.first(from: [try unavailable()], now: now))
        XCTAssertTrue(LAAUsageOverview.first(from: [zero], now: Date.distantFuture)?.expired == true)
    }

    func testDashboardKeepsModelsSeparateAndDoesNotInventValues() throws {
        let models: [String: Any] = ["models": [
            ["provider": "one", "model": "small", "input_tokens": 0, "output_tokens": NSNull(), "actual_cost": 0],
            ["provider": "two", "model": "large", "input_tokens": 50, "output_tokens": 2,
             "actual_cost": 1.25, "estimated_cost": 1.5]
        ] as [[String: Any]]]
        let rows = try LAADashboardUsageRow.parse(usage: [:], models: models)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].inputTokens, 0)
        XCTAssertNil(rows[0].outputTokens)
        XCTAssertNil(rows[0].actualCost) // The server cannot distinguish missing from billed zero.
        XCTAssertNil(rows[0].estimatedCost)
        XCTAssertEqual(rows[1].actualCost, 1.25)
        XCTAssertEqual(rows[1].estimatedCost, 1.5)
        XCTAssertThrowsError(try LAADashboardUsageRow.parse(usage: [:], models: nil))
    }

    func testFailureKeepsValuesAndTheirTimeAndEmptySuccessClearsThem() async throws {
        let state = LAAUsageState()
        let first = try quota()
        let firstTime = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 200)
        await state.refresh(usage: { [first] }, mac: { [first] }, analytics: { [] }, now: { firstTime })
        await state.refresh(usage: { throw LAABridgeError.networkUnreachable },
                            mac: { throw LAABridgeError.unavailable },
                            analytics: { throw LAAUsageProblem.dashboardFailed }, now: { later })
        XCTAssertEqual(state.usage.value?.first?.value, 62)
        XCTAssertEqual(state.usage.fetchedAt, firstTime)
        XCTAssertEqual(state.updatedAt, firstTime)
        XCTAssertEqual(state.usage.error, .bridge(.networkUnreachable))
        XCTAssertEqual(state.mac.error, .bridge(.unavailable))
        XCTAssertEqual(state.analytics.value?.count, 0)
        XCTAssertEqual(state.analytics.fetchedAt, firstTime)
        XCTAssertEqual(state.analytics.error, .dashboardFailed)
        await state.refresh(usage: { [first] }, mac: { [first] },
                            analytics: { throw LAAUsageProblem.dashboardFailed }, now: { later })
        XCTAssertEqual(state.updatedAt, firstTime)
        await state.refresh(usage: { [] }, mac: { [] }, analytics: { [] }, now: { later })
        XCTAssertEqual(state.usage.value?.count, 0)
        XCTAssertNil(state.usage.error)
        XCTAssertEqual(state.updatedAt, later)
    }

    func testFailedItemKeepsPreviousValueAndTime() async throws {
        let state = LAAUsageState()
        let first = try quota()
        let failed = try unavailable()
        let firstTime = Date(timeIntervalSince1970: 100)
        await state.refresh(usage: { [first] }, mac: { [] }, analytics: { [] }, now: { firstTime })
        await state.refresh(usage: { [failed] }, mac: { [] }, analytics: { [] },
                            now: { Date(timeIntervalSince1970: 200) })
        XCTAssertEqual(state.usage.value?.first?.value, 62)
        XCTAssertEqual(state.usage.value?.first?.observedAt, first.observedAt)
        XCTAssertEqual(state.retainedUsageIDs, [first.id])
        XCTAssertEqual(state.usage.fetchedAt, firstTime)
        XCTAssertEqual(state.updatedAt, firstTime)
    }

    func testRefreshDeduplicatesAndScopeChangesWaitForOldRequest() async throws {
        let state = LAAUsageState()
        let started = expectation(description: "first refresh has started")
        var calls = 0
        let first = try quota()
        state.selectScope(bridgeRevision: 0, dashboardScope: "one")
        let inFlight = Task {
            await state.refresh(usage: {
                calls += 1
                started.fulfill()
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return [first]
            },
                                mac: { [] }, analytics: { [] })
        }
        defer { inFlight.cancel() }
        await fulfillment(of: [started], timeout: 10)
        guard state.isRefreshing else { return XCTFail("Refresh did not start") }
        XCTAssertTrue(state.isRefreshing)
        await state.refresh(usage: { calls += 1; return [] }, mac: { [] }, analytics: { [] })
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(state.selectScope(bridgeRevision: 1, dashboardScope: "two"))
        XCTAssertTrue(state.isRefreshing)
        await state.refresh(usage: { calls += 1; return [] }, mac: { [] }, analytics: { [] })
        XCTAssertEqual(calls, 1)
        await inFlight.value
        await state.waitUntilIdle()
        XCTAssertFalse(state.isRefreshing)
        XCTAssertNil(state.usage.value) // The old identity's response cannot cross scopes.
        await state.refresh(usage: { [first] }, mac: { [] }, analytics: { [] })
        XCTAssertEqual(state.usage.value?.first?.value, 62)
    }
}
#endif
