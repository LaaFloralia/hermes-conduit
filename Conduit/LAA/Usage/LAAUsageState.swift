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
    private var isPresented = false
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
        guard active, bridge.status == .paired, (!isPresented || lastRefreshAttempt == nil) else { return }
        let revision = bridge.revision
        let inFlight = isRefreshing ? generation : nil
        await waitUntilIdle()
        guard !Task.isCancelled, (!isPresented || lastRefreshAttempt == nil), bridge.status == .paired, bridge.revision == revision else { return }
        // A refresh already running for this scope also updates the widget.
        if !changed, let inFlight, completedGeneration == inFlight { return }
        await refreshAndPublish(bridge: bridge)
    }

    func setPresented(_ presented: Bool) { isPresented = presented }

    /// Refresh the shared feed even while Usage is visible.
    func refreshAutomatically(bridge: LAABridgeSession) async {
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
        if selectScope(bridgeRevision: bridge.revision) { publish(nil) }
        guard bridge.status == .paired else { publish(nil); return }
        guard !isRefreshing else { return }
        lastRefreshAttempt = attemptedAt ?? Date()
        let revision = bridge.revision
        await refreshUsage { try await self.loadUsage(bridge) }
        guard bridge.status == .paired else { publish(nil); return }
        guard !Task.isCancelled, bridge.revision == revision else { return }
        if let items = usage.value {
            publish(LAAWidgetUsageBuilder.make(items: items, receivedAt: usage.fetchedAt ?? Date(),
                                              previous: widgetStore?.read()?.usage))
        } else if let error = usage.error, [.bridge(.revoked), .bridge(.unauthorized), .bridge(.forbidden)].contains(error) {
            publish(nil)
        } else if let previous = widgetStore?.read()?.usage {
            // Preserve the observation for recovery, but immediately mark it
            // stale so a failed fetch can never leave a fresh-looking number.
            publish(WidgetUsageSnapshot(meters: previous.meters.map { $0.lastKnown(label: $0.label) },
                                        checkedAt: previous.checkedAt))
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

    /// The same code-owned destinations used by Console; feed payloads never
    /// supply a URL that the app can open.
    var serviceURL: URL? {
        let links = [
            "provider.codex": "https://chatgpt.com/codex/cloud/settings/usage",
            "provider.opencode-go": "https://opencode.ai/console",
            "provider.claude": "https://claude.ai/settings/usage",
            "provider.venice": "https://venice.ai/settings/api",
            "provider.magnific": "https://www.magnific.com/user/my-subscriptions",
            "provider.openai-api": "https://platform.openai.com/usage",
            "provider.claude-api": "https://platform.claude.com/settings/billing",
            "provider.liquid": "https://console.liquid.ai/",
        ]
        return links[id].flatMap(URL.init(string:))
    }

    /// Where the owner checks an API balance by hand. Only the two API
    /// providers publish a billing page; every other reading uses serviceURL.
    static func billingURL(for itemID: String) -> URL? {
        switch itemID {
        case "provider.openai-api.balance":
            return URL(string: "https://platform.openai.com/settings/organization/billing/overview")
        case "provider.claude-api.balance":
            return URL(string: "https://platform.claude.com/settings/billing")
        default:
            return nil
        }
    }

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
    /// Claude Weekly, Venice, Magnific, GPT API, Claude API, Liquid AI. Retired
    /// providers (Jev, Google Cloud, Google Flow) are never listed.
    static func consoleGroups(_ items: [LAAUsageItem]) -> [LAAUsageGroup] {
        let ids = ["codex", "opencode-go", "claude", "venice", "magnific", "openai-api", "claude-api", "liquid"]
        let names = ["codex": "Codex Weekly", "claude": "Claude Weekly", "opencode-go": "OpenCode Weekly", "liquid": "Liquid AI"]
        return ids.compactMap { id in
            let prefix = "provider.\(id)."
            let selected = items.filter { $0.id.hasPrefix(prefix) && $0.source == "codexbar-usage-proxy" }
            guard let first = selected.first else { return nil }
            return LAAUsageGroup(id: "provider.\(id)", label: names[id] ?? first.label, items: selected.sorted { left, right in
                let leftOrder = readingOrder(left.id)
                let rightOrder = readingOrder(right.id)
                return leftOrder == rightOrder ? left.id < right.id : leftOrder < rightOrder
            })
        }
    }

    /// Balance first, then today's spend, then the month's. A provider's spend
    /// is a use figure, so it never stands in for the amount left.
    private static func readingOrder(_ id: String) -> Int {
        if id.hasSuffix(".balance") { return 0 }
        if id.hasSuffix("cost-today") { return 1 }
        if id.hasSuffix("cost-month") { return 2 }
        return 3
    }
}

enum LAAWidgetUsageBuilder {
    /// The eight rows the home-screen widget shows, in the owner's priority order.
    struct Slot {
        enum Reading { case weeklyQuota, balance, credits, recordedUsage }
        let provider: String
        let name: String
        let reading: Reading

        var label: String {
            reading == .weeklyQuota ? name + " " + AppLocalization.string("Weekly") : name
        }

        /// A row kept without a reading. The two API balances are always shown
        /// so the owner sees what was not fetched; every other row appears once
        /// its own reading arrives.
        let keepsPlaceWhenMissing: Bool

        /// Only the reading this slot shows may fill it. A snapshot written
        /// before the API rows became balances still holds their month spend
        /// under the same provider; that figure is a use amount, not what is
        /// left, so it is never reused here.
        func owns(_ meterID: String) -> Bool {
            let prefix = "provider.\(provider)."
            switch reading {
            case .weeklyQuota: return meterID.hasPrefix(prefix + "quota")
            case .balance: return meterID == prefix + "balance"
            case .credits: return meterID.hasPrefix(prefix + "credits")
            case .recordedUsage: return meterID.hasPrefix(prefix + "usage")
            }
        }
    }

    static let slots: [Slot] = [
        Slot(provider: "codex", name: "Codex", reading: .weeklyQuota, keepsPlaceWhenMissing: false),
        Slot(provider: "opencode-go", name: "OpenCode", reading: .weeklyQuota, keepsPlaceWhenMissing: false),
        Slot(provider: "claude", name: "Claude", reading: .weeklyQuota, keepsPlaceWhenMissing: false),
        Slot(provider: "venice", name: "Venice", reading: .balance, keepsPlaceWhenMissing: false),
        Slot(provider: "magnific", name: "Magnific", reading: .credits, keepsPlaceWhenMissing: false),
        Slot(provider: "openai-api", name: "GPT API", reading: .balance, keepsPlaceWhenMissing: true),
        Slot(provider: "claude-api", name: "Claude API", reading: .balance, keepsPlaceWhenMissing: true),
        Slot(provider: "liquid", name: "Liquid AI", reading: .recordedUsage, keepsPlaceWhenMissing: false),
    ]

    static func make(items: [LAAUsageItem], receivedAt: Date = Date(), previous: WidgetUsageSnapshot? = nil) -> WidgetUsageSnapshot {
        let feed = items.filter { $0.source == "codexbar-usage-proxy" }
        let meters = slots.compactMap { slot -> WidgetUsageMeter? in
            let current = meter(for: slot, feed: feed, receivedAt: receivedAt)
            if current?.hasRecordedValue(at: receivedAt) == true { return current }
            if let prior = previous?.displayableMeters.first(where: {
                slot.owns($0.id) && $0.hasRecordedValue(at: receivedAt)
            }) { return prior.lastKnown(label: slot.label) }
            return current
        }
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
            // A balance the feed does not carry keeps its row with no number
            // where the slot says so: the owner still sees the provider was not
            // read, and a spend figure never appears in its place.
            guard let item = feed.first(where: { $0.id == "\(prefix)balance" }) else {
                return slot.keepsPlaceWhenMissing ? .missing(id: "\(prefix)balance", label: slot.label) : nil
            }
            guard available(item), item.unit == "usd", let amount = item.value, amount.isFinite else {
                return .missing(id: item.id, label: slot.label)
            }
            return meter(id: item.id, label: slot.label, unit: .usd, amount: amount,
                         item: item, freshUntil: item.detail?.freshUntil, resetsAt: nil, receivedAt: receivedAt)
        case .credits:
            guard let item = feed.first(where: { $0.id == "\(prefix)credits" }) else { return nil }
            guard available(item), item.unit == "credits", let amount = item.value, amount.isFinite, amount >= 0 else {
                return .missing(id: item.id, label: slot.label)
            }
            return meter(id: item.id, label: slot.label, unit: .credits, amount: amount,
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
        ["weekly", "週間", "週次", "週刊", "ウィークリー"].contains(label.lowercased()) || label.hasPrefix("週次")
    }

    /// Display name for one window. A duration the feed reports wins, so a 7-day
    /// pool reads Weekly in every language whatever the proxy calls it.
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
/// labels the last observation when a refresh is delayed.
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
