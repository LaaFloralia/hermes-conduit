import XCTest
@testable import Conduit

@MainActor
final class LAANotificationPairAllTests: XCTestCase {
    #if LAA_BUILD
    private final class FakeDashboardRelay {
        let id = UUID()
        let installation = "test-phone"
        var current = true
        var ready = true
        var names = ["default", "laa-cmo", "laa-cto"]
        var already: Set<String> = []
        var failOnce: Set<String> = []
        var events: [String] = []
        var activeClaims = 0
        var maximumClaims = 0
        var onClaim: ((String) -> Void)?

        func source() -> LAANotificationPairAll.Source {
            .init(dashboardID: id, installationID: installation, canStart: { self.ready }, isCurrent: { self.current }, profiles: {
                self.events.append("roster")
                return self.names
            }, alreadyPaired: { name in
                self.events.append("check:\(name)")
                await Task.yield()
                return self.already.contains(name)
            }, pair: { name in
                self.activeClaims += 1
                self.maximumClaims = max(self.maximumClaims, self.activeClaims)
                self.events.append("claim:\(name)")
                defer { self.activeClaims -= 1 }
                await Task.yield()
                self.onClaim?(name)
                if self.failOnce.remove(name) != nil { throw URLError(.notConnectedToInternet) }
            })
        }
    }

    func testSequentialClaimsAndSkipAlreadyPaired() async {
        let fake = FakeDashboardRelay()
        fake.already = ["default"]
        let model = LAANotificationPairAll()
        await model.run(source: fake.source())
        XCTAssertEqual(fake.events, ["roster", "check:default", "check:laa-cmo", "claim:laa-cmo", "check:laa-cto", "claim:laa-cto"])
        XCTAssertEqual(fake.maximumClaims, 1)
        XCTAssertEqual(model.items.map(\.status), [.already, .done, .done])
    }

    func testPartialFailureContinuesAndRetryRechecksOnlyFailures() async {
        let fake = FakeDashboardRelay()
        fake.failOnce = ["laa-cmo"]
        let model = LAANotificationPairAll()
        await model.run(source: fake.source())
        XCTAssertEqual(model.items[0].status, .done)
        XCTAssertEqual(model.items[2].status, .done)
        XCTAssertTrue(model.hasFailures)
        fake.events = []
        await model.run(source: fake.source(), retryFailures: true)
        XCTAssertEqual(fake.events, ["check:laa-cmo", "claim:laa-cmo"])
        XCTAssertEqual(model.items.map(\.status), [.done, .done, .done])
    }

    func testRetrySkipsAProfileThatPairedAfterTheFailure() async {
        let fake = FakeDashboardRelay()
        fake.failOnce = ["laa-cmo"]
        let model = LAANotificationPairAll()
        await model.run(source: fake.source())
        fake.already = ["laa-cmo"]
        fake.events = []
        await model.run(source: fake.source(), retryFailures: true)
        XCTAssertEqual(fake.events, ["check:laa-cmo"])
        XCTAssertEqual(model.items[1].status, .already)
    }

    func testDashboardSwitchDuringClaimStopsEvenIfSwitchedBack() async {
        let fake = FakeDashboardRelay()
        let model = LAANotificationPairAll()
        fake.onClaim = { _ in
            model.dashboardChanged(to: UUID())
            model.dashboardChanged(to: fake.id)
        }
        await model.run(source: fake.source())
        XCTAssertEqual(fake.events, ["roster", "check:default", "claim:default"])
        XCTAssertTrue(model.hasFailures)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.isRunning)
    }

    func testIncompleteRosterOrPairingStatusFailsClosed() throws {
        XCTAssertThrowsError(try LAANotificationPairAll.listedProfiles(["profiles": []]))
        XCTAssertThrowsError(try LAANotificationPairAll.listedProfiles(["profiles": ["default", [:]]]))
        XCTAssertEqual(try LAANotificationPairAll.listedProfiles(["profiles": [["name": "laa-cmo"]]]), ["default", "laa-cmo"])
        XCTAssertThrowsError(try LAANotificationPairAll.alreadyPaired(["paired": false], installationID: "test-phone"))
        XCTAssertThrowsError(try LAANotificationPairAll.alreadyPaired(["ok": true, "paired": true], installationID: "test-phone"))
        XCTAssertTrue(try LAANotificationPairAll.alreadyPaired(["ok": true, "paired": true, "installation_id": "test-phone"], installationID: "test-phone"))
        XCTAssertFalse(try LAANotificationPairAll.alreadyPaired(["ok": true, "paired": true, "installation_id": "other-phone"], installationID: "test-phone"))
    }

    func testEmptyRosterDoesNotClaimAnything() async {
        let fake = FakeDashboardRelay()
        fake.names = []
        let model = LAANotificationPairAll()
        await model.run(source: fake.source())
        XCTAssertEqual(fake.events, ["roster"])
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNotNil(model.error)
    }

    func testBusyRelayDoesNotStart() async {
        let fake = FakeDashboardRelay()
        fake.ready = false
        let model = LAANotificationPairAll()
        await model.run(source: fake.source())
        XCTAssertTrue(fake.events.isEmpty)
        XCTAssertFalse(model.isRunning)
    }
    #else
    func testOnlyAvailableInLAABuild() throws { throw XCTSkip("LAA build only") }
    #endif
}
