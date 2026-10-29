#if LAA_BUILD
import SwiftUI

struct LAANotificationPairAllView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var notifications = PushNotificationService.shared
    @ObservedObject private var model = LAANotificationPairAll.shared
    let singlePairing: Bool

    var body: some View {
        LAANotificationPairAllControls(
            model: model,
            dashboardID: appState.activeDashboardID,
            installationID: notifications.installationID,
            canStart: !singlePairing && !notifications.isPairing && !notifications.isWorking
                && !notifications.isProvisioningEncryption
                && notifications.isEnabled && appState.activeDashboardID != nil && appState.dashboardTicketBridge != nil,
            source: { appState.laaNotificationPairSource() },
            displayName: { appState.profileDisplayName($0) }
        )
        .onChange(of: appState.activeDashboardID) { _, id in model.dashboardChanged(to: id) }
    }
}

/// Kept separate so the same controls can be exercised with a fake dashboard
/// without moving a real employee's notifications to the simulator.
struct LAANotificationPairAllControls: View {
    @ObservedObject var model: LAANotificationPairAll
    let dashboardID: UUID?
    let installationID: String?
    let canStart: Bool
    let source: () -> LAANotificationPairAll.Source?
    let displayName: (String) -> String

    var body: some View {
        Button {
            guard let source = source() else { return }
            Task { await model.run(source: source) }
        } label: {
            Label {
                Text(verbatim: model.isRunning ? "設定中…" : "全社員の通知をこのiPhoneへ")
            } icon: { Image(systemName: "person.2.badge.key") }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6).frame(minHeight: 46)
        }
        .disabled(!canStart || model.isRunning)
        .buttonStyle(.borderedProminent)
        .tint(LAAColors.teal)
        .accessibilityIdentifier("notifications.pair-all")

        Text(verbatim: "戻すにはApp Store版Conduitの「設定＞通知」で、対象プロフィールを再ペアリングします。")
            .font(.footnote)
            .foregroundStyle(LAAColors.muted)

        if let error = model.error {
            Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                .font(.footnote)
                .foregroundStyle(LAAColors.plum)
                .accessibilityIdentifier("notifications.pair-all.error")
        }
        ForEach(model.items) { item in
            HStack(alignment: .top, spacing: 8) {
                Text(verbatim: displayName(item.id))
                Spacer(minLength: 8)
                Text(verbatim: statusText(item.status))
                    .foregroundStyle(isFailure(item.status) ? LAAColors.plum : LAAColors.muted)
                    .multilineTextAlignment(.trailing)
            }
            .font(.footnote)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("notifications.pair-all.result.\(item.id)")
        }
        if model.hasFailures {
            Button {
                guard let source = source() else { return }
                Task { await model.run(source: source, retryFailures: true) }
            } label: {
                Label { Text(verbatim: "失敗した社員を再試行") } icon: { Image(systemName: "arrow.clockwise") }
            }
            .disabled(!canStart || model.isRunning || !model.canRetry(dashboardID: dashboardID, installationID: installationID))
            .tint(LAAColors.teal)
            .accessibilityIdentifier("notifications.pair-all.retry")
        }
    }

    private func statusText(_ status: LAANotificationPairAll.Status) -> String {
        switch status {
        case .waiting: return "待機中"
        case .checking: return "確認中"
        case .pairing: return "設定中"
        case .done: return "済"
        case .already: return "既にこのiPhone"
        case .failed(let reason): return "失敗：\(reason)"
        }
    }

    private func isFailure(_ status: LAANotificationPairAll.Status) -> Bool {
        if case .failed = status { return true }
        return false
    }
}
#endif
