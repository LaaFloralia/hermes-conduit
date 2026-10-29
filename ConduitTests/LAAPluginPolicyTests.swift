#if LAA_BUILD
import XCTest
@testable import Conduit

@MainActor
final class LAAPluginPolicyTests: XCTestCase {
    func testOldReportedPluginKeepsVersionWithoutAnUpdateNotice() {
        let response: [String: Any] = [
            "ok": true, "version": "0.1.0", "loaded_version": "0.1.0",
            "restart_needed": false, "update_available": true,
            "capabilities": NotifierPluginStatus.usedCapabilities,
        ]
        let status = NotifierPluginStatus(state: NotifierPluginStatus.state(from: response),
                                          runtime: NotifierPluginStatus.runtime(from: response))
        XCTAssertTrue(status.updateAvailable)
        XCTAssertTrue(status.needsAttention)
        XCTAssertEqual(LAAPluginPolicy.summary(status), "0.1.0")
        XCTAssertEqual(LAAPluginPolicy.connection(status, dashboardConnected: true), "Connected")
        XCTAssertEqual(LAAPluginPolicy.connection(status, dashboardConnected: false), "Not connected")
    }

    func testOnlyNotifierIsServerManagedWhenCatalogReportsUpdates() throws {
        let response: [String: Any] = ["entries": [
            ["name": "conduit_push", "installed": true, "update_available": true],
            ["name": "weather", "installed": true, "update_available": true],
        ]]
        let entries = PluginCatalogEntry.list(from: response)
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.allSatisfy(\.updateAvailable))
        XCTAssertTrue(PluginStyle.isServerManaged(name: entries[0].name))
        XCTAssertTrue(PluginStyle.isServerManaged(name: "alias", folderName: "hermes-conduit-notifier"))
        XCTAssertFalse(PluginStyle.isServerManaged(name: entries[1].name))
    }
}
#endif
