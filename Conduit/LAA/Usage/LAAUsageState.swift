#if LAA_BUILD
import Combine
import Foundation
import WidgetKit

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
    case failed

    init(_ error: Error) {
        if let problem = error as? LAAUsageProblem { self = problem }
        else if let problem = error as? LAABridgeError { self = .bridge(problem) }
        else { self = .failed }
    }

    var message: String {
        switch self {
        case .bridge(let error): return error.japaneseText
        case .failed: return AppLocalization.string("Couldn't load usage. Pull down to try again.")
        }
    }
}

/// Owns one refresh at a time and keeps each source's last successful snapshot.
@MainActor
final class LAAUsageState: ObservableObject {
    @Published private(set) var usage = LAAUsageSnapshot<[LAAUsageItem]>()
    @Published private(set) var retainedUsageIDs: Set<String> = []
    @Published private(set) var updatedAt: Date?
    @Published private(set) var isRefreshing = false
    private var generation = 0
    private var completedGeneration: Int?
    private var bridgeRevision: Int?
    private var lastRefreshAttempt: Date?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private let widgetStore: WidgetSnapshotStore?
    private let reloadWidgets: @MainActor () -> Void
    private let loadUsage: @MainActor (LAABridgeSession) async throws -> [LAAUsageItem]

    init(widgetStore: WidgetSnapshotStore? = WidgetSnapshotStore.production,
         reloadWidgets: @escaping @MainActor () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: ConduitWidgetKind.employee) },
         loader: (@MainActor (LAABridgeSession) async throws -> [LAAUsageItem])? = nil) {
        self.widgetStore = widgetStore
        self.reloadWidgets = reloadWidgets
        self.loadUsage = loader ?? { try await Self.loadPages(bridge: $0) }
    }

    /// The shell owns this state so widgets update even if Usage is never opened.
    func synchronize(bridge: LAABridgeSession, active: Bool) async {
        let changed = selectScope(bridgeRevision: bridge.revision)
        if changed || bridge.status != .paired { publish(nil) }
        guard active, bridge.status == .paired else { return }
        let revision = bridge.revision
        let inFlight = isRefreshing ? generation : nil
        await waitUntilIdle()
        guard !Task.isCancelled, bridge.status == .paired, bridge.revision == revision else { return }
        // A refresh already running for this scope also updates the widget.
        if !changed, let inFlight, completedGeneration == inFlight { return }
        await refreshAndPublish(bridge: bridge)
    }

    /// Opening Usage refreshes after a quiet interval; explicit refresh bypasses it.
    func refreshOnTabOpen(bridge: LAABridgeSession, now: () -> Date = Date.init,
                          minimumInterval: TimeInterval = 60) async {
        let changed = selectScope(bridgeRevision: bridge.revision)
        if changed || bridge.status != .paired { publish(nil) }
        guard bridge.status == .paired else { return }
        let revision = bridge.revision
        await waitUntilIdle()
        guard !Task.isCancelled, bridge.status == .paired, bridge.revision == revision else { return }
        let current = now()
        if let lastRefreshAttempt {
            let elapsed = current.timeIntervalSince(lastRefreshAttempt)
            if elapsed >= 0 && elapsed < minimumInterval { return }
        }
        await refreshAndPublish(bridge: bridge, attemptedAt: current)
    }

    func refreshAndPublish(bridge: LAABridgeSession, attemptedAt: Date? = nil) async {
        guard bridge.status == .paired, !isRefreshing else { return }
        lastRefreshAttempt = attemptedAt ?? Date()
        let revision = bridge.revision
        await refreshUsage { try await self.loadUsage(bridge) }
        guard !Task.isCancelled, bridge.status == .paired, bridge.revision == revision else { return }
        if let items = usage.value {
            publish(LAAWidgetUsageBuilder.make(items: items, retained: retainedUsageIDs,
                                              failed: usage.error != nil, checkedAt: usage.fetchedAt))
        } else if usage.error != nil, let old = widgetStore?.read()?.usage {
            let meters = old.meters.map { meter in
                WidgetUsageMeter(id: meter.id, label: meter.label, remainingPercent: meter.remainingPercent,
                                 observedAt: meter.observedAt, freshUntil: meter.freshUntil, resetsAt: meter.resetsAt,
                                 stale: meter.stale, retained: true, verified: meter.verified == true,
                                 legacyFreshness: meter.legacyFreshness == true)
            }
            publish(WidgetUsageSnapshot(meters: meters, checkedAt: old.checkedAt, hasOtherUsage: old.hasOtherUsage == true))
        }
    }

    private func publish(_ snapshot: WidgetUsageSnapshot?) {
        guard let store = widgetStore else { return }
        do { if try store.writeUsage(snapshot) { reloadWidgets() } }
        catch { /* Keep the last valid widget snapshot. */ }
    }

    private static func loadPages(bridge: LAABridgeSession) async throws -> [LAAUsageItem] {
        var items: [LAAUsageItem] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            var parts = URLComponents(); parts.path = "/v1/usage"
            if let cursor { parts.queryItems = [URLQueryItem(name: "cursor", value: cursor)] }
            guard let route = parts.string else { throw LAABridgeError.invalidResponse }
            let page: LAAUsagePage = try await bridge.read(route)
            items.append(contentsOf: page.items)
            cursor = page.nextCursor
            if let cursor, !seen.insert(cursor).inserted || seen.count > 100 { throw LAABridgeError.invalidResponse }
        } while cursor != nil
        return items
    }

    @discardableResult
    func selectScope(bridgeRevision revision: Int) -> Bool {
        let bridgeChanged = bridgeRevision != nil && bridgeRevision != revision
        bridgeRevision = revision
        guard bridgeChanged else { return false }
        generation += 1
        completedGeneration = nil
        lastRefreshAttempt = nil
        usage = .init()
        retainedUsageIDs = []
        updatedAt = nil
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
        completedGeneration = mine
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
                     checkedAt _: Date?) -> WidgetUsageSnapshot {
        let visible = LAAUsageGroup.consoleGroups(items).flatMap(\.items)
        let meters = visible.flatMap { item -> [WidgetUsageMeter] in
            guard item.kind == "quota", item.availability == "available" else { return [] }
            return (item.detail?.windows ?? []).enumerated().compactMap { index, window in
                guard let value = window.remainingPercent, value.isFinite, (0...100).contains(value) else { return nil }
                let observed = LAAUsageItem.date(item.observedAt)
                let verified = item.detail?.sourceKind == "verified"
                let rawDeadline = item.detail?.freshUntil
                let deadline = rawDeadline == nil && !verified
                    ? observed?.addingTimeInterval(20 * 60) : LAAUsageItem.date(rawDeadline)
                return WidgetUsageMeter(id: "\(item.id).\(index)", label: "\(item.label) · \(window.label)",
                    remainingPercent: value, observedAt: observed, freshUntil: deadline,
                    resetsAt: LAAUsageItem.date(window.resetsAt),
                    stale: item.stale || (rawDeadline != nil && deadline == nil),
                    retained: failed || retained.contains(item.id), verified: verified,
                    legacyFreshness: rawDeadline == nil && !verified)
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
        let otherUsage = visible.filter { $0.availability == "available" && $0.kind != "quota" }
        let otherObservations = otherUsage.compactMap { LAAUsageItem.date($0.observedAt) }
        let oldestOther = otherObservations.count == otherUsage.count ? otherObservations.min() : nil
        return WidgetUsageSnapshot(meters: selected, checkedAt: selected.isEmpty ? oldestOther : oldestObservation,
                                   hasOtherUsage: !otherUsage.isEmpty)
    }
}

#endif
