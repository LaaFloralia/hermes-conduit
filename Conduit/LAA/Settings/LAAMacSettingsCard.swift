#if LAA_BUILD
import SwiftUI

/// Pairing and reachability are separate: saved credentials alone do not
/// mean the Mac is online. Only a successful Bridge verification does.
enum LAAMacConnectionState: Equatable {
    enum Probe: Equatable { case checking, connected, offline, failed }
    case checking, connected, offline, notPaired, rePairRequired, keychainError, failed

    static func current(session: LAABridgeSession.Status, probe: Probe) -> Self {
        switch session {
        case .unpaired: return .notPaired
        case .revoked, .unauthorized: return .rePairRequired
        case .keychainError: return .keychainError
        case .paired:
            switch probe {
            case .checking: return .checking
            case .connected: return .connected
            case .offline: return .offline
            case .failed: return .failed
            }
        }
    }

    var label: String {
        switch self {
        case .checking: return LAACopy.macChecking
        case .connected: return LAACopy.macConnected
        case .offline: return LAACopy.macOffline
        case .notPaired: return LAACopy.macNotPaired
        case .rePairRequired: return LAACopy.macRePairRequired
        case .keychainError: return LAACopy.macKeychainError
        case .failed: return LAACopy.macConnectionError
        }
    }
}

struct LAAMacSettingsCard: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @State private var probe: LAAMacConnectionState.Probe = .checking
    @State private var showPairing = false
    @State private var refreshCount = 0

    private var status: LAAMacConnectionState {
        .current(session: bridge.status, probe: probe)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            HStack(spacing: LAASpacing.x3) {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(LAAColor.link)
                Text(verbatim: LAACopy.mac)
                    .laaTextStyle(.body)
                    .foregroundStyle(LAAColor.text)
                Spacer()
                Text(verbatim: status.label)
                    .laaTextStyle(.secondary)
                    .foregroundStyle(status == .keychainError || status == .failed ? LAAColor.attention : LAAColor.secondaryText)
                    .accessibilityIdentifier("laa.settings.mac.status")
            }
            if status == .keychainError {
                Text(verbatim: LAABridgeError.keychain.japaneseText)
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            } else if status == .rePairRequired {
                Text(verbatim: LAABridgeError.revoked.japaneseText)
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
            HStack(spacing: LAASpacing.x4) {
                Button { showPairing = true } label: {
                    Text(verbatim: LAACopy.macRePair).frame(minHeight: LAASpacing.minimumTouchTarget).contentShape(Rectangle())
                }
                    .accessibilityIdentifier("laa.settings.mac.repair")
                if bridge.status == .paired {
                    Button { refreshCount += 1 } label: {
                        Text(verbatim: LAACopy.macRefresh).frame(minHeight: LAASpacing.minimumTouchTarget).contentShape(Rectangle())
                    }
                        .accessibilityIdentifier("laa.settings.mac.refresh")
                }
            }
            .laaTextStyle(.body)
            .foregroundStyle(LAAColor.link)
            .frame(minHeight: LAASpacing.minimumTouchTarget, alignment: .leading)
        }
        .padding(LAASpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
        .sheet(isPresented: $showPairing) { LAAPairingView().environmentObject(bridge) }
        .task(id: "\(bridge.revision)-\(refreshCount)") { await verify() }
    }

    private func verify() async {
        guard bridge.status == .paired else { return }
        let revision = bridge.revision
        probe = .checking
        do {
            try await bridge.verify()
            guard !Task.isCancelled, bridge.revision == revision else { return }
            probe = .connected
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, bridge.revision == revision else { return }
            probe = (error as? LAABridgeError) == .networkUnreachable ? .offline : .failed
        }
    }
}
#endif
