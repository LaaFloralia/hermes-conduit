#if LAA_BUILD
import BackgroundTasks
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
            self.value = nil
            self.fetchedAt = nil
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

/// Owns one refresh at a time; a failed refresh clears its previous values.
@MainActor
final class LAAUsageState: ObservableObject {
    @Published private(set) var usage = LAAUsageSnapshot<[LAAUsageItem]>()
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
        guard bridge.status == .paired else { publish(nil); return }
        guard !isRefreshing else { return }
        lastRefreshAttempt = attemptedAt ?? Date()
        let revision = bridge.revision
        await refreshUsage { try await self.loadUsage(bridge) }
        guard bridge.status == .paired else { publish(nil); return }
        guard !Task.isCancelled, bridge.revision == revision else { return }
        if let items = usage.value {
            publish(LAAWidgetUsageBuilder.make(items: items, receivedAt: usage.fetchedAt ?? Date()))
        } else {
            publish(nil)
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
        switch result {
        case .success(var items):
            var previous: [String: LAAUsageItem] = [:]
            for item in usage.value ?? [] { previous[item.id] = item }
            for index in items.indices {
                let prior = previous[items[index].id]
                items[index].freshnessAnchor = LAAUsageItem.date(prior?.observedAt) == LAAUsageItem.date(items[index].observedAt)
                    ? (prior?.freshnessAnchor ?? finished) : finished
            }
            usage.apply(.success(items), at: finished)
        case .failure(let error):
            usage.apply(.failure(error), at: finished)
        }
        if case .success = result { updatedAt = finished } else { updatedAt = nil }
        completedGeneration = mine
    }

    private static func capture<T>(_ load: @MainActor () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await load()) }
        catch { return .failure(error) }
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

    /// The owner's display order (2026-11-01): Codex Weekly, OpenCode Weekly,
    /// Claude Weekly, Venice, GPT API, Claude API, Liquid AI, then the rest. Retired
    /// providers (Jev, Google Cloud, Google Flow) are never listed.
    static func consoleGroups(_ items: [LAAUsageItem]) -> [LAAUsageGroup] {
        let ids = ["codex", "opencode-go", "claude", "venice", "openai-api", "claude-api", "liquid",
                   "antigravity", "magnific", "grok-bot"]
        let names = ["opencode-go": "OpenCode", "liquid": "Liquid AI"]
        return ids.compactMap { id in
            let prefix = "provider.\(id)."
            let selected = items.filter { $0.id.hasPrefix(prefix) && $0.source == "codexbar-usage-proxy" }
            guard let first = selected.first else { return nil }
            return LAAUsageGroup(id: "provider.\(id)", label: names[id] ?? first.label, items: selected)
        }
    }
}

enum LAAWidgetUsageBuilder {
    /// The seven rows the home-screen widget shows, in the owner's priority order.
    struct Slot {
        enum Reading { case weeklyQuota, balance, monthCost, recordedUsage }
        let provider: String
        let name: String
        let reading: Reading

        var label: String {
            reading == .weeklyQuota ? name + " " + AppLocalization.string("Weekly") : name
        }
    }

    static let slots: [Slot] = [
        Slot(provider: "codex", name: "Codex", reading: .weeklyQuota),
        Slot(provider: "opencode-go", name: "OpenCode", reading: .weeklyQuota),
        Slot(provider: "claude", name: "Claude", reading: .weeklyQuota),
        Slot(provider: "venice", name: "Venice", reading: .balance),
        Slot(provider: "openai-api", name: "GPT API", reading: .monthCost),
        Slot(provider: "claude-api", name: "Claude API", reading: .monthCost),
        Slot(provider: "liquid", name: "Liquid AI", reading: .recordedUsage),
    ]

    static func make(items: [LAAUsageItem], receivedAt: Date = Date()) -> WidgetUsageSnapshot {
        let feed = items.filter { $0.source == "codexbar-usage-proxy" }
        let meters = slots.compactMap { meter(for: $0, feed: feed, receivedAt: receivedAt) }
        // The feed can be cached even when the app has just contacted Bridge.
        // Only show a confirmation time if all displayed readings have one.
        let observations = meters.filter(\.available).compactMap(\.observedAt)
        let checkedAt = observations.isEmpty ? nil : observations.min()
        return WidgetUsageSnapshot(meters: meters, checkedAt: checkedAt)
    }

    private static func meter(for slot: Slot, feed: [LAAUsageItem], receivedAt: Date) -> WidgetUsageMeter? {
        let prefix = "provider.\(slot.provider)."
        let available = { (item: LAAUsageItem) in
            item.availability == "available" && !LAAUsageFreshness.isPast(item, at: receivedAt)
        }
        switch slot.reading {
        case .weeklyQuota:
            guard let item = feed.first(where: { $0.id.hasPrefix(prefix) && $0.kind == "quota" }) else { return nil }
            let window = weeklyWindow(item.detail?.windows ?? [])
            guard available(item), let window,
                  let remaining = window.remainingPercent, remaining.isFinite, (0...100).contains(remaining) else {
                return .missing(id: "\(item.id).weekly", label: slot.label)
            }
            return meter(id: "\(item.id).weekly", label: slot.label, unit: .percent, amount: remaining,
                         item: item, freshUntil: item.detail?.freshUntil,
                         resetsAt: LAAUsageItem.date(window.resetsAt), receivedAt: receivedAt)
        case .balance:
            guard let item = feed.first(where: { $0.id == "\(prefix)balance" }) else { return nil }
            guard available(item), let amount = item.value, amount.isFinite else {
                return .missing(id: item.id, label: slot.label)
            }
            return meter(id: item.id, label: slot.label, unit: .usd, amount: amount,
                         item: item, freshUntil: item.detail?.freshUntil, resetsAt: nil, receivedAt: receivedAt)
        case .monthCost:
            guard let item = feed.first(where: { $0.id == "\(prefix)cost-month" }) else { return nil }
            guard available(item), let amount = item.value, amount.isFinite else {
                return .missing(id: item.id, label: slot.label)
            }
            return meter(id: item.id, label: slot.label, unit: .usd, amount: amount,
                         item: item, freshUntil: item.detail?.freshUntil, resetsAt: nil, receivedAt: receivedAt)
        case .recordedUsage:
            guard let item = feed.first(where: { $0.id.hasPrefix(prefix) && $0.kind == "usage" }) else { return nil }
            guard available(item), let amount = item.detail?.recordedCostUsd, amount.isFinite else {
                return .missing(id: item.id, label: slot.label)
            }
            return meter(id: item.id, label: slot.label, unit: .usd, amount: amount,
                         item: item, freshUntil: item.detail?.freshUntil, resetsAt: nil, receivedAt: receivedAt)
        }
    }

    /// The window the owner means by "Weekly": the 7-day quota when the feed
    /// names its duration, otherwise the window the feed itself calls Weekly.
    private static func weeklyWindow(_ windows: [LAAUsageItem.Window]) -> LAAUsageItem.Window? {
        windows.first { window in
            if let minutes = window.windowMinutes { return minutes == 10_080 }
            return LAAUsageLabel.isWeekly(window.label)
        }
    }

    private static func meter(id: String, label: String, unit: WidgetUsageMeter.Unit, amount: Double,
                              item: LAAUsageItem, freshUntil: String?, resetsAt: Date?,
                              receivedAt: Date) -> WidgetUsageMeter {
        let observed = LAAUsageItem.date(item.observedAt)
        let verified = item.detail?.sourceKind == "verified"
        let upstreamDeadline = LAAUsageItem.date(freshUntil)
        let limit = observed.map { min($0, item.freshnessAnchor ?? receivedAt, receivedAt).addingTimeInterval(10 * 60) }
        let deadline: Date?
        if freshUntil == nil {
            deadline = verified ? nil : limit
        } else {
            deadline = upstreamDeadline.flatMap { upstream in limit.map { min($0, upstream) } }
        }
        return WidgetUsageMeter(id: id, label: label, unit: unit, amount: amount,
                                observedAt: observed, freshUntil: deadline, resetsAt: resetsAt,
                                stale: item.stale || (freshUntil != nil && deadline == nil),
                                retained: false, verified: verified,
                                legacyFreshness: freshUntil == nil && !verified)
    }
}

/// One naming rule for the quota windows, shared by the app list and the widget.
enum LAAUsageLabel {
    static func isWeekly(_ label: String) -> Bool {
        ["weekly", "週間", "週次", "週刊", "ウィークリー"].contains(label.lowercased())
    }

    /// Display name for one window. A duration the feed reports wins, so a 7-day
    /// pool reads Weekly (ウィークリー in Japanese) whatever the proxy calls it.
    static func window(_ window: LAAUsageItem.Window) -> String {
        if let minutes = window.windowMinutes {
            if minutes == 10_080 { return AppLocalization.string("Weekly") }
            if minutes == 43_200 { return AppLocalization.string("Monthly") }
        }
        if isWeekly(window.label) { return AppLocalization.string("Weekly") }
        if ["monthly", "月間", "マンスリー"].contains(window.label.lowercased()) {
            return AppLocalization.string("Monthly")
        }
        return window.label
    }
}


/// The OS decides when a background refresh runs; the widget timeline still
/// removes numbers at their own expiry if a refresh is delayed.
@MainActor
enum LAAUsageBackground {
    private static let identifier = "com.laa-inc.laa.usage-refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let work = Task { @MainActor in
                schedule()
                let bridge = LAABridgeSession()
                let state = LAAUsageState()
                await state.refreshAndPublish(bridge: bridge)
                task.setTaskCompleted(success: !Task.isCancelled && bridge.status == .paired && state.usage.error == nil)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

#endif
