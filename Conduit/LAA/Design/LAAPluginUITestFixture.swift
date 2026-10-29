#if LAA_BUILD && DEBUG
import SwiftUI

/// Delivers the same plugin reports a dashboard serves, without network access.
@MainActor
enum LAAPluginUITestFixture {
    static let statusReport: [String: Any] = [
        "ok": true, "version": "0.1.0", "loaded_version": "0.1.0",
        "restart_needed": false, "update_available": true,
        "capabilities": NotifierPluginStatus.usedCapabilities,
    ]

    static func seedStatusIfEnabled(_ appState: AppState) {
        let process = ProcessInfo.processInfo
        guard process.environment["CONDUIT_UITEST"] == "1",
              process.arguments.contains("-LAA_UI_TEST_NOTIFIER_UPDATE_AVAILABLE") else { return }
        appState.applyNotifierPluginReport(statusReport)
    }
}

@MainActor
private final class LAAPluginCatalogTestServer: DashboardJSONRequester {
    func requestJSON(path: String, method: String, body: [String: Any]?, timeoutMilliseconds: Int,
                     maxResponseBytes: Int) async throws -> [String: Any] {
        guard method == "GET" else { throw CapabilitiesStoreError.notConnected }
        if path.hasPrefix("/api/dashboard/plugins/hub") {
            return ["plugins": [
                ["name": "conduit_push", "version": "0.1.0", "source": "git", "runtime_status": "enabled",
                 "can_remove": true, "can_update_git": true, "path": "/plugins/hermes-conduit-notifier"],
                ["name": "weather", "version": "1.0.0", "source": "git", "runtime_status": "enabled",
                 "can_remove": true, "can_update_git": true],
            ]]
        }
        if path.hasPrefix("/api/dashboard/plugins/catalog") {
            return ["entries": [
                ["name": "conduit_push", "installed": true, "update_available": true],
                ["name": "weather", "installed": true, "update_available": true],
            ]]
        }
        throw CapabilitiesStoreError.notConnected
    }
}

/// Exercises the real capabilities list and detail views against the fixture.
@MainActor
struct LAAPluginCatalogUITestScreen: View {
    @State private var store: CapabilitiesStore
    private let server: LAAPluginCatalogTestServer

    init() {
        let server = LAAPluginCatalogTestServer()
        let store = CapabilitiesStore()
        store.configure(requester: server, profile: "default")
        self.server = server
        _store = State(initialValue: store)
    }

    var body: some View {
        NavigationStack { CapabilityPluginsTab(store: store, query: "") }
    }
}
#endif
