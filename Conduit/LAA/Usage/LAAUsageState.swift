#if LAA_BUILD
import Combine
import Foundation

struct LAAUsageSnapshot<Value> {
    var value: Value?
    var fetchedAt: Date?
    var error: LAAUsageProblem?

    mutating func apply(_ result: Result<Value, Error>, at date: Date) {
        switch result {
        case .success(let value):
            self.value = value
            fetchedAt = date
            error = nil
        case .failure(let error):
            self.error = LAAUsageProblem(error)
        }
    }
}

enum LAAUsageProblem: Error, Equatable {
    case bridge(LAABridgeError)
    case dashboardNotConnected, dashboardSignIn, dashboardUnsupported, dashboardFailed

    init(_ error: Error) {
        if let problem = error as? LAAUsageProblem { self = problem }
        else if let problem = error as? LAABridgeError { self = .bridge(problem) }
        else { self = .dashboardFailed }
    }

    var message: String {
        switch self {
        case .bridge(let error): return error.japaneseText
        case .dashboardNotConnected: return AppLocalization.string("Connect to Hermes to see usage.")
        case .dashboardSignIn: return AppLocalization.string("Sign in to this dashboard again to see usage.")
        case .dashboardUnsupported: return AppLocalization.string("This Hermes doesn't report usage. Update Hermes to see it here.")
        case .dashboardFailed: return AppLocalization.string("Couldn't load usage. Pull down to try again.")
        }
    }
}

/// Owns one refresh at a time and keeps each source's last successful snapshot.
@MainActor
final class LAAUsageState: ObservableObject {
    @Published private(set) var usage = LAAUsageSnapshot<[LAAUsageItem]>()
    @Published private(set) var mac = LAAUsageSnapshot<[LAAUsageItem]>()
    @Published private(set) var analytics = LAAUsageSnapshot<[LAADashboardUsageRow]>()
    @Published private(set) var retainedUsageIDs: Set<String> = []
    @Published private(set) var retainedMacIDs: Set<String> = []
    @Published private(set) var updatedAt: Date?
    @Published private(set) var isRefreshing = false
    private var generation = 0
    private var bridgeRevision: Int?
    private var dashboardScope: String?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    @discardableResult
    func selectScope(bridgeRevision revision: Int, dashboardScope scope: String) -> Bool {
        let bridgeChanged = bridgeRevision != nil && bridgeRevision != revision
        let dashboardChanged = dashboardScope != nil && dashboardScope != scope
        bridgeRevision = revision
        dashboardScope = scope
        guard bridgeChanged || dashboardChanged else { return false }
        generation += 1
        if bridgeChanged {
            usage = .init()
            mac = .init()
            retainedUsageIDs = []
            retainedMacIDs = []
            updatedAt = nil
        }
        if dashboardChanged { analytics = .init() }
        return true
    }

    func waitUntilIdle() async {
        guard isRefreshing else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    /// The Usage tab reads only the proxy projection, not the Hermes dashboard.
    func refreshUsage(
        _ load: @escaping @MainActor () async throws -> [LAAUsageItem],
        now: @escaping () -> Date = Date.init
    ) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        generation += 1
        let mine = generation
        defer {
            isRefreshing = false
            let waiters = idleWaiters
            idleWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        let result = await Self.capture(load)
        guard mine == generation, !Task.isCancelled else { return }
        let finished = now()
        Self.apply(result, to: &usage, retainedIDs: &retainedUsageIDs, at: finished)
        if case .success = result, retainedUsageIDs.isEmpty { updatedAt = finished }
    }

    func refresh(
        usage loadUsage: @escaping @MainActor () async throws -> [LAAUsageItem],
        mac loadMac: @escaping @MainActor () async throws -> [LAAUsageItem],
        analytics loadAnalytics: @escaping @MainActor () async throws -> [LAADashboardUsageRow],
        now: @escaping () -> Date = Date.init
    ) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        generation += 1
        let mine = generation
        defer {
            isRefreshing = false
            let waiters = idleWaiters
            idleWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        async let usageResult = Self.capture(loadUsage)
        async let macResult = Self.capture(loadMac)
        async let analyticsResult = Self.capture(loadAnalytics)
        let (newUsage, newMac, newAnalytics) = await (usageResult, macResult, analyticsResult)
        guard mine == generation, !Task.isCancelled else { return }
        let finishedAt = now()
        Self.apply(newUsage, to: &usage, retainedIDs: &retainedUsageIDs, at: finishedAt)
        Self.apply(newMac, to: &mac, retainedIDs: &retainedMacIDs, at: finishedAt)
        analytics.apply(newAnalytics, at: finishedAt)
        let analyticsKeptPrevious: Bool
        if case .failure = newAnalytics { analyticsKeptPrevious = analytics.value != nil }
        else { analyticsKeptPrevious = false }
        if case .success = newUsage, case .success = newMac,
           retainedUsageIDs.isEmpty, retainedMacIDs.isEmpty, !analyticsKeptPrevious { updatedAt = finishedAt }
    }

    private static func capture<T>(_ load: @MainActor () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await load()) }
        catch { return .failure(error) }
    }

    private static func apply(_ result: Result<[LAAUsageItem], Error>,
                       to snapshot: inout LAAUsageSnapshot<[LAAUsageItem]>,
                       retainedIDs: inout Set<String>, at date: Date) {
        guard case .success(let items) = result else { snapshot.apply(result, at: date); return }
        let old = Dictionary((snapshot.value ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var retained = Set<String>()
        let displayed = items.map { item in
            guard item.availability == "unavailable", let reason = item.nullReason,
                  ["fetch_failed", "auth_required"].contains(reason),
                  let previous = old[item.id], previous.availability == "available" else { return item }
            retained.insert(item.id)
            return previous
        }
        let previousTime = snapshot.fetchedAt
        snapshot.apply(.success(displayed), at: date)
        if !retained.isEmpty { snapshot.fetchedAt = previousTime }
        retainedIDs = retained
    }
}

struct LAAUsageGroup: Identifiable {
    let id: String
    let label: String
    var items: [LAAUsageItem]

    static func groups(_ items: [LAAUsageItem]) -> [LAAUsageGroup] {
        var result: [LAAUsageGroup] = []
        var indexes: [String: Int] = [:]
        for item in items {
            let parts = item.id.split(separator: ".")
            // Only group a service when the Bridge explicitly gives its identity.
            let key = parts.count >= 3 && (parts[0] == "provider" || parts[0] == "profile")
                ? "\(parts[0]).\(parts[1])" : item.id
            if let index = indexes[key] { result[index].items.append(item) }
            else {
                indexes[key] = result.count
                result.append(.init(id: key, label: item.label, items: [item]))
            }
        }
        return result
    }

    /// Match the Console's visible provider order; do not add Hermes profiles.
    static func consoleGroups(_ items: [LAAUsageItem]) -> [LAAUsageGroup] {
        let ids = ["liquid", "claude", "codex", "opencode-go", "magnific", "fal"]
        return ids.compactMap { id in
            let prefix = "provider.\(id)."
            let selected = items.filter { $0.id.hasPrefix(prefix) && $0.source == "codexbar-usage-proxy" }
            guard let first = selected.first else { return nil }
            return LAAUsageGroup(id: "provider.\(id)", label: id == "liquid" ? "D1" : first.label, items: selected)
        }
    }
}

enum LAAWidgetUsageBuilder {
    static func make(items: [LAAUsageItem], retained: Set<String>, failed: Bool,
                     checkedAt: Date?) -> WidgetUsageSnapshot {
        let meters = LAAUsageGroup.consoleGroups(items).flatMap(\.items).flatMap { item -> [WidgetUsageMeter] in
            guard item.kind == "quota", item.availability == "available" else { return [] }
            return (item.detail?.windows ?? []).enumerated().compactMap { index, window in
                guard let value = window.remainingPercent, value.isFinite, (0...100).contains(value) else { return nil }
                return WidgetUsageMeter(id: "\(item.id).\(index)", label: "\(item.label) · \(window.label)",
                    remainingPercent: value, observedAt: LAAUsageItem.date(item.observedAt),
                    freshUntil: LAAUsageItem.date(item.detail?.freshUntil),
                    resetsAt: LAAUsageItem.date(window.resetsAt), stale: item.stale,
                    retained: failed || retained.contains(item.id))
            }
        }.sorted {
            if $0.remainingPercent != $1.remainingPercent { return $0.remainingPercent < $1.remainingPercent }
            return $0.id < $1.id
        }
        let selected = Array(meters.prefix(3))
        // The feed can be cached even when the app has just contacted Bridge.
        // Only show a confirmation time if all displayed meters have one.
        let observations = selected.compactMap(\.observedAt)
        let oldestObservation = observations.count == selected.count ? observations.min() : nil
        return WidgetUsageSnapshot(meters: selected, checkedAt: selected.isEmpty ? checkedAt : oldestObservation)
    }
}

struct LAAUsageOverview {
    let itemID: String
    let label: String
    let window: String
    let remainingPercent: Double
    let resetsAt: Date?
    let observedAt: Date?
    let stale: Bool
    let expired: Bool

    static func first(from items: [LAAUsageItem], now: Date = Date()) -> LAAUsageOverview? {
        for item in items where item.kind == "quota" && item.availability == "available" {
            for window in item.detail?.windows ?? [] {
                guard let remaining = window.remainingPercent, remaining.isFinite,
                      (0...100).contains(remaining) else { continue }
                let reset = LAAUsageItem.date(window.resetsAt)
                return .init(itemID: item.id, label: item.label, window: window.label, remainingPercent: remaining,
                             resetsAt: reset, observedAt: LAAUsageItem.date(item.observedAt),
                             stale: item.stale, expired: item.isExpired(now: now) || (reset.map { $0 < now } ?? false))
            }
        }
        return nil
    }
}
#endif
