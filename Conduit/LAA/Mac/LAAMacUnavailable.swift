#if LAA_BUILD && targetEnvironment(macCatalyst)
import SwiftUI

extension LAACopy {
    static let macScanTitle = "Paste Code"
    static let macScanReason = "QR scanning is unavailable on Mac. Paste the code or address instead."
    static let macScanField = "Code or address"
    static let macScanContinue = "Continue"
    static let macScanCancel = "Cancel"
    static let macScanInvalid = "That code isn't a dashboard address."
}

/// The phone's camera scanner is unavailable on Catalyst. Keep its existing
/// sign-in parser and offer an editable field for pasted codes instead.
struct DashboardCodeScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var invalid = false
    let onScan: (String) -> Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: LAASpacing.x4) {
                Text(LAACopy.macScanReason)
                    .laaTextStyle(.body)
                    .foregroundStyle(LAAColor.text)
                TextField(LAACopy.macScanField, text: $value)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("scan.paste")
                    .onSubmit(submit)
                if invalid {
                    Text(LAACopy.macScanInvalid)
                        .laaTextStyle(.secondary)
                        .foregroundStyle(LAAColor.attention)
                }
                Button(LAACopy.macScanContinue, action: submit)
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
            .padding(LAASpacing.horizontal)
            .background(LAAColor.background)
            .navigationTitle(LAACopy.macScanTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LAACopy.macScanCancel) { dismiss() }
                }
            }
        }
    }

    private func submit() {
        invalid = !onScan(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// macOS does not support ActivityKit. No activity can exist on this device.
@MainActor
final class LiveTurnActivities {
    static let shared = LiveTurnActivities()
    nonisolated static let enabledDefaultsKey = "conduit.liveActivities.enabled"
    nonisolated static let registryAbsenceSpan: TimeInterval = 8

    func adoptExisting() {}
    func endAll() {}
    func turnSubmitting(sessionIDs: Set<String>) {}
    func turnStarted(sessionIDs: Set<String>, primaryID: String, linkID: String? = nil, title: String, profile: String?, profileName: String? = nil, glowHex: String? = nil, dashboardID: String? = nil) {}
    func observe(_ event: StreamEvent, sessionID: String) {}
    func reconcile(liveSessionIDs: Set<String>, profile: String, dashboardID: String?, now: Date = Date()) -> Bool { false }
    func endTurns(ofDashboard dashboardID: String?, keepingThoseOnRelay: Bool = false) {}
    nonisolated static func sessionIDs(linkedTo id: String, profile: String, dashboardID: String?) -> [String] { [] }
}
#endif
