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

    var japaneseText: String {
        switch self {
        case .bridge(.networkUnreachable), .bridge(.unavailable): return "Macに接続できません"
        case .bridge(.forbidden): return "利用枠を表示する権限がありません"
        case .bridge(let error): return error.japaneseText
        case .failed: return "利用枠を取得できません"
        }
    }
}

/// Owns one refresh at a time; failed reads retain the last observation.
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
        if LAAWidgetUsageConnection.read() != nil, let saved = widgetStore?.readUsageItems() {
            usage.value = saved
            usage.fetchedAt = saved.compactMap { LAAUsageItem.date($0.observedAt) }.max()
            updatedAt = usage.fetchedAt
        }
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

    /// Work and a pushed Usage screen can own a separate state from the shell.
    /// That screen must fetch, not merely repaint its old observation's age.
    func refreshWhileVisible(bridge: LAABridgeSession,
                             sleep: @MainActor () async throws -> Void = {
                                 #if DEBUG
                                 if ProcessInfo.processInfo.arguments.contains("-LAA_UI_TEST_USAGE_FAST_REFRESH") {
                                     try await Task.sleep(for: .seconds(2)); return
                                 }
                                 #endif
                                 try await Task.sleep(for: .seconds(120))
                             }) async {
        await refreshOnTabOpen(bridge: bridge)
        guard bridge.status == .paired else { return }
        while !Task.isCancelled {
            do { try await sleep() } catch { return }
            guard !Task.isCancelled else { return }
            await refreshAutomatically(bridge: bridge)
        }
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
        // Sharing the existing app credential uses the already entitled App
        // Group's Keychain, never a file or a second pairing.
        if widgetStore != nil {
            try? await bridge.withAuthenticatedClient { _, credentials in
                let connection = LAAWidgetUsageConnection(baseURL: credentials.baseURL,
                                                           deviceID: credentials.deviceID, token: credentials.token)
                if let shared = LAAWidgetUsageConnection.read(), shared != connection {
                    self.usage = .init()
                    self.updatedAt = nil
                    self.publish(nil)
                }
                try LAAWidgetUsageConnection.save(connection)
            }
        }
        await refreshUsage { try await self.loadUsage(bridge) }
        guard bridge.status == .paired else { usage = .init(); updatedAt = nil; publish(nil); return }
        guard !Task.isCancelled, bridge.revision == revision else { return }
        if let error = usage.error, [.bridge(.revoked), .bridge(.unauthorized), .bridge(.forbidden)].contains(error) {
            usage = .init(error: error)
            updatedAt = nil
            publish(nil)
        } else if let items = usage.value {
            if let store = widgetStore {
                do {
                    if try store.updateUsage({ LAAWidgetUsageBuilder.make(items: items,
                                                    receivedAt: usage.fetchedAt ?? Date(), previous: $0) }) {
                        reloadWidgets()
                    }
                } catch { /* Keep the previous observation. */ }
            }
        } else if let previous = widgetStore?.read()?.usage {
            // Preserve the observation for recovery, but immediately mark it
            // stale so a failed fetch can never leave a fresh-looking number.
            publish(WidgetUsageSnapshot(meters: previous.meters.map { $0.lastKnown(label: $0.label) },
                                        checkedAt: previous.checkedAt))
        }
    }

    private func publish(_ snapshot: WidgetUsageSnapshot?) {
        guard let store = widgetStore else { return }
        if snapshot == nil {
            try? LAAWidgetUsageConnection.save(nil)
            try? store.writeUsageItems(nil)
        }
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
                if items[index].availability != "available", var retained = prior, retained.availableValue != nil {
                    retained.retainedReason = items[index].nullReason
                    items[index] = retained
                }
                items[index].freshnessAnchor = LAAUsageItem.date(prior?.observedAt) == LAAUsageItem.date(items[index].observedAt)
                    ? (prior?.freshnessAnchor ?? finished) : finished
            }
            // Missing rows keep their last known reading; retired providers
            // are still filtered by the code-owned display slots.
            let ids = Set(items.map(\.id))
            items += (usage.value ?? []).filter { !ids.contains($0.id) && $0.availableValue != nil }.map {
                var retained = $0; retained.retainedReason = "fetch_failed"; return retained
            }
            usage.apply(.success(items), at: finished)
            try? widgetStore?.writeUsageItems(items)
        case .failure(let error):
            usage.apply(.failure(error), at: finished)
        }
        if case .success = result { updatedAt = finished }
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
            "provider.nanogpt": "https://nano-gpt.com/settings",
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

    /// The owner's display order (2026-11-05), taken from the one slot list the
    /// widget also reads, so a provider is added in one place: Codex, OpenCode,
    /// Claude, nanoGPT, Magnific, GPT API, Claude API, Liquid AI, Venice.
    /// Retired providers (Jev, Google Cloud, Google Flow) are never listed.
    static func consoleGroups(_ items: [LAAUsageItem]) -> [LAAUsageGroup] {
        LAAWidgetUsageBuilder.slots.compactMap { slot -> LAAUsageGroup? in
            let prefix = "provider.\(slot.provider)."
            let reported = items.filter { $0.id.hasPrefix(prefix) && $0.source == "codexbar-usage-proxy" }
            let selected = reported.filter(showsOnScreen)
            guard !selected.isEmpty else {
                // An API group the feed reported keeps its header even when the
                // readings it carries cannot be shown, so the owner still sees
                // the provider and its billing page.
                return reported.isEmpty ? nil
                    : (isAPI(prefix) ? LAAUsageGroup(id: "provider.\(slot.provider)", label: slot.name, items: []) : nil)
            }
            return LAAUsageGroup(id: "provider.\(slot.provider)", label: slot.name, items: selected.sorted { $0.id < $1.id })
        }
    }

    /// The API groups show what is left, never what was spent.
    private static func showsOnScreen(_ item: LAAUsageItem) -> Bool {
        !isAPI(item.id) || item.id.hasSuffix(".balance")
    }

    static func isAPI(_ id: String) -> Bool {
        id.hasPrefix("provider.openai-api.") || id.hasPrefix("provider.claude-api.")
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
                let success: Bool
                if bridge.status == .keychainError {
                    success = await refreshFromPush()
                } else {
                    await state.refreshAndPublish(bridge: bridge)
                    success = bridge.status == .paired && state.usage.error == nil
                }
                task.setTaskCompleted(success: !Task.isCancelled && success)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    /// The existing silent-push receiver can call this after its settings sync.
    /// A locked primary Keychain does not prevent a read with the shared credential.
    static func refreshFromPush() async -> Bool {
        var fetched = false
        _ = await LAAWidgetUsageRefresh.refresh(onSuccessfulFetch: { fetched = true })
        if fetched { WidgetCenter.shared.reloadTimelines(ofKind: ConduitWidgetKind.employee) }
        return fetched
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

#endif
