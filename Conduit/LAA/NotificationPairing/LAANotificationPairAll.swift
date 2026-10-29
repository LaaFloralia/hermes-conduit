#if LAA_BUILD
import Combine
import Foundation

/// Owns the whole run, not just an individual relay code. This also keeps the
/// automatic single-profile pairing from starting between two profiles.
@MainActor
final class LAANotificationPairAll: ObservableObject {
    static let shared = LAANotificationPairAll()

    enum Status: Equatable {
        case waiting, checking, pairing, done, already, failed(String)
    }

    struct Item: Identifiable, Equatable {
        let id: String
        var status: Status
    }

    struct Source {
        let dashboardID: UUID
        let installationID: String
        let canStart: @MainActor () -> Bool
        let isCurrent: @MainActor () -> Bool
        let profiles: @MainActor () async throws -> [String]
        let alreadyPaired: @MainActor (String) async throws -> Bool
        let pair: @MainActor (String) async throws -> Void
    }

    enum Failure: Error {
        case invalidProfiles, invalidStatus
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var isRunning = false
    @Published private(set) var error: String?
    private var owner: UUID?
    private var installation: String?
    private var interrupted = false

    var hasFailures: Bool {
        items.contains { if case .failed = $0.status { return true }; return false }
    }

    func canRetry(dashboardID: UUID?, installationID: String?) -> Bool {
        hasFailures && owner == dashboardID && installation == installationID
    }

    /// A switch is sticky even if the user switches back while a request is
    /// still in flight. The in-flight request may have reached its host.
    func dashboardChanged(to id: UUID?) {
        if isRunning && id != owner { interrupted = true }
    }

    func run(source: Source, retryFailures: Bool = false) async {
        guard !isRunning, source.canStart(), source.isCurrent() else { return }
        if retryFailures {
            guard canRetry(dashboardID: source.dashboardID, installationID: source.installationID) else { return }
        } else {
            owner = source.dashboardID
            installation = source.installationID
            items = []
        }
        interrupted = false
        isRunning = true
        error = nil
        defer { isRunning = false }

        if !retryFailures {
            do {
                let names = try await source.profiles()
                guard current(source) else { error = Self.interruptedMessage; return }
                guard !names.isEmpty else { throw Failure.invalidProfiles }
                items = names.map { Item(id: $0, status: .waiting) }
            } catch {
                self.error = current(source) ? Self.reason(error) : Self.interruptedMessage
                return
            }
        }

        for index in items.indices {
            if retryFailures {
                guard case .failed = items[index].status else { continue }
            }
            guard current(source) else { failRemaining(from: index); break }
            items[index].status = .checking
            do {
                let already = try await source.alreadyPaired(items[index].id)
                guard current(source) else { failRemaining(from: index); break }
                if already {
                    items[index].status = .already
                    continue
                }
                items[index].status = .pairing
                try await source.pair(items[index].id)
                guard current(source) else { failRemaining(from: index); break }
                items[index].status = .done
            } catch {
                guard current(source) else { failRemaining(from: index); break }
                items[index].status = .failed(Self.reason(error))
            }
        }
    }

    private func current(_ source: Source) -> Bool {
        !interrupted && !Task.isCancelled && source.isCurrent()
    }

    private func failRemaining(from index: Int) {
        error = Self.interruptedMessage
        for position in index..<items.count {
            switch items[position].status {
            case .waiting, .checking, .pairing, .failed:
                items[position].status = .failed("接続先が変わったため、結果を確認してください。")
            case .done, .already: break
            }
        }
    }

    private static let interruptedMessage = "接続先または通知設定が変わったため中断しました。元の接続先で再試行してください。"

    static func listedProfiles(_ response: [String: Any]) throws -> [String] {
        guard let values = response["profiles"] as? [Any], !values.isEmpty else { throw Failure.invalidProfiles }
        var names: [String] = []
        for value in values {
            let name = (value as? String) ?? ((value as? [String: Any])?["name"] as? String)
            guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure.invalidProfiles
            }
            if !names.contains(name) { names.append(name) }
        }
        if !names.contains("default") { names.insert("default", at: 0) }
        return names
    }

    static func alreadyPaired(_ status: [String: Any], installationID: String) throws -> Bool {
        guard status["ok"] as? Bool == true, let paired = status["paired"] as? Bool else { throw Failure.invalidStatus }
        guard paired else { return false }
        guard let actual = status["installation_id"] as? String, !actual.isEmpty else { throw Failure.invalidStatus }
        return actual == installationID
    }

    private static func reason(_ error: Error) -> String {
        if let failure = error as? Failure {
            switch failure {
            case .invalidProfiles: return "社員一覧を確認できません。接続を確認して再試行してください。"
            case .invalidStatus: return "現在の通知先を確認できません。再試行してください。"
            }
        }
        if let bridge = error as? DashboardTicketBridgeError {
            switch bridge {
            case .notReady, .answeredAfterSwitch: return "ダッシュボードに接続できません。"
            case .signInRequired: return "ダッシュボードに再ログインしてください。"
            case .http(let status, _): return "ダッシュボードが応答しました（HTTP \(status)）。"
            default: return "ダッシュボードで設定を確認できません。"
            }
        }
        if let url = error as? URLError {
            return url.code == .timedOut ? "接続が時間切れになりました。" : "ネットワークに接続できません。"
        }
        return "通知先を設定できませんでした。接続を確認して再試行してください。"
    }
}

extension AppState {
    /// The roster and the pairing status come from the same captured dashboard
    /// and installation. An incomplete status is never treated as unpaired.
    func laaNotificationPairSource() -> LAANotificationPairAll.Source? {
        let notifications = PushNotificationService.shared
        guard notifications.isEnabled, !notifications.isProvisioningEncryption,
              let installationID = notifications.installationID,
              let dashboardID = activeDashboardID, let bridge = dashboardTicketBridge else { return nil }
        let current: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.activeDashboardID == dashboardID && self.dashboardTicketBridge === bridge
                && notifications.isEnabled && notifications.installationID == installationID
        }
        return .init(dashboardID: dashboardID, installationID: installationID, canStart: {
            !notifications.isPairing && !notifications.isWorking && !notifications.isProvisioningEncryption
        }, isCurrent: current, profiles: {
            let response = try await bridge.requestJSON(path: "/api/profiles")
            guard current() else { throw DashboardTicketBridgeError.notReady }
            return try LAANotificationPairAll.listedProfiles(response)
        }, alreadyPaired: { [weak self] profile in
            guard current() else { throw DashboardTicketBridgeError.notReady }
            let status = try await bridge.requestJSON(path: DashboardPath.withProfile(PushNotificationService.e2ePath, profile: profile))
            guard current() else { throw DashboardTicketBridgeError.notReady }
            let already = try LAANotificationPairAll.alreadyPaired(status, installationID: installationID)
            if already, let gatewayID = status["gateway_id"] as? String {
                self?.recordRelayGatewayID(gatewayID, for: dashboardID, profile: profile)
            }
            return already
        }, pair: { [weak self] profile in
            guard let self, current() else { throw DashboardTicketBridgeError.notReady }
            try await self.pairProfileWithThisDevice(profile)
        })
    }
}
#endif
