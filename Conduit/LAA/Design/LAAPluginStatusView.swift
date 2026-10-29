#if LAA_BUILD
import SwiftUI

/// The host owns updates for this plugin; its iOS presentation is read-only.
enum LAAPluginPolicy {
    private static let notifierNames: Set<String> = ["conduit_push", "hermes-conduit-notifier"]

    static func isNotifier(name: String, folderName: String? = nil) -> Bool {
        notifierNames.contains(name) || folderName.map(notifierNames.contains) == true
    }

    static func summary(_ status: NotifierPluginStatus) -> String {
        switch status.state {
        case .unknown: return LAACopy.pluginNotChecked
        case .predatesCapabilities: return LAACopy.pluginUnavailable
        case .reported: return status.runningVersion ?? "—"
        }
    }

    static func connection(_ status: NotifierPluginStatus, dashboardConnected: Bool) -> String {
        guard dashboardConnected else { return LAACopy.pluginNotConnected }
        switch status.state {
        case .unknown: return LAACopy.pluginChecking
        case .predatesCapabilities: return LAACopy.pluginUnavailable
        case .reported: return LAACopy.pluginConnected
        }
    }
}

struct LAAPluginStatusView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let status = appState.notifierPlugin
        SettingsDetailContainer {
            ConduitSettingsSection(title: LAACopy.plugin, symbol: "puzzlepiece.extension", tint: LAAColor.link) {
                if appState.savedDashboardRegistry.dashboards.count > 1,
                   let label = appState.savedDashboardRegistry.activeDashboardLabel {
                    SettingsMetricRow(label: LAACopy.pluginDashboard, value: label, lineLimit: 1)
                }
                SettingsMetricRow(label: LAACopy.pluginVersion, value: status.runningVersion ?? "—")
                    .accessibilityIdentifier("settings.plugin.version")
                SettingsMetricRow(label: LAACopy.pluginConnection,
                                  value: LAAPluginPolicy.connection(status, dashboardConnected: appState.isConnected))
                    .accessibilityIdentifier("settings.plugin.connection")
            }
        }
        .navigationTitle(Text(verbatim: LAACopy.plugin))
        .task(id: appState.activeDashboardID) { await appState.refreshNotifierPluginStatus() }
    }
}
#endif
