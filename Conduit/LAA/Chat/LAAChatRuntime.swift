#if LAA_BUILD
import Foundation

/// The model and effort a chat is actually running on, as Hermes reports
/// them for its live agent (`session.info`, a resume's snapshot,
/// `model.update`, a `/reasoning` change): never the profile's configured
/// values. Each value remembers the chat it was reported for, so a chat
/// just opened reads 「不明」 until Hermes answers for it instead of showing
/// the previous chat's (owner, 2026-11-12).
struct LAAChatRuntime: Equatable {
    private(set) var modelSessionID: String?
    private(set) var model: String?
    private(set) var provider: String?
    private(set) var effortSessionID: String?
    private(set) var effort: String?
    private(set) var speedSessionID: String?
    private(set) var speed: ModelSpeed?

    /// Takes what a report carried; a field it left out keeps its value.
    /// An empty value is a report that the chat has none to show.
    mutating func apply(sessionID: String?, model: String?, provider: String?, effort: String?) {
        guard let sessionID, !sessionID.isEmpty else { return }
        // Hermes reports the model with its provider; the provider only
        // picks the model's face, so it never stands without the model.
        if let model {
            modelSessionID = sessionID
            self.model = Self.value(model)
            self.provider = provider.flatMap(Self.value)
        }
        if let effort {
            effortSessionID = sessionID
            self.effort = Self.value(effort)
        }
    }

    /// The speed a report carried (`fast` and its `service_tier`). A report
    /// without `fast` keeps the value.
    mutating func applySpeed(sessionID: String?, fast: Bool?, serviceTier: String?) {
        guard let sessionID, !sessionID.isEmpty, let fast else { return }
        speedSessionID = sessionID
        speed = ModelSpeed(fast: fast, serviceTier: serviceTier ?? "")
    }

    struct Shown: Equatable {
        let model: String?
        let provider: String?
        let effort: String?
        /// Nil until Hermes reports this chat's speed.
        var speed: ModelSpeed? = nil
        /// Whether Hermes reported the model / the effort for this chat at
        /// all: a report of none (empty) reads 不明, no report yet does not.
        var modelReported = false
        var effortReported = false
    }

    /// What the chip shows for the chat on screen; nil reads 「不明」.
    func shown(for sessionIDs: Set<String>) -> Shown {
        let modelKnown = modelSessionID.map(sessionIDs.contains) ?? false
        let effortKnown = effortSessionID.map(sessionIDs.contains) ?? false
        let speedKnown = speedSessionID.map(sessionIDs.contains) ?? false
        return Shown(model: modelKnown ? model : nil,
                     provider: modelKnown ? provider : nil,
                     effort: effortKnown ? effort : nil,
                     speed: speedKnown ? speed : nil,
                     modelReported: modelKnown,
                     effortReported: effortKnown)
    }

    private static func value(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The model and effort Hermes last reported for an employee on a dashboard,
/// kept on the device, so an opening chat (or one still waiting for its
/// `session.info`) shows them as 最終確認 instead of 不明 (D-25). Only values
/// Hermes reported are kept; a field a report left out keeps its value.
enum LAAChatRuntimeCache {
    struct Record: Codable, Equatable {
        var model: String?
        var provider: String?
        var effort: String?
    }

    static let defaultsKey = "laa.chatRuntime.lastConfirmed.v1"
    static let maximumRecords = 40

    private static func key(dashboardID: UUID, profile: String) -> String {
        "\(dashboardID.uuidString)|\(profile)"
    }

    private static func all(_ defaults: UserDefaults) -> [String: Record] {
        guard let data = defaults.data(forKey: defaultsKey),
              let records = try? JSONDecoder().decode([String: Record].self, from: data) else { return [:] }
        return records
    }

    static func last(dashboardID: UUID, profile: String, defaults: UserDefaults = .standard) -> Record? {
        let record = all(defaults)[key(dashboardID: dashboardID, profile: profile)]
        return record?.model == nil && record?.effort == nil ? nil : record
    }

    /// Keeps what `shown` reports for the chat (reported fields only).
    static func record(_ shown: LAAChatRuntime.Shown, dashboardID: UUID, profile: String,
                       defaults: UserDefaults = .standard) {
        guard shown.modelReported || shown.effortReported else { return }
        var records = all(defaults)
        let key = key(dashboardID: dashboardID, profile: profile)
        var record = records[key] ?? Record()
        if shown.modelReported, let model = shown.model {
            record.model = model
            record.provider = shown.provider
        }
        if shown.effortReported, let effort = shown.effort { record.effort = effort }
        guard records[key] != record, record.model != nil || record.effort != nil else { return }
        records[key] = record
        if records.count > maximumRecords {
            // Rarely more than the staff on two dashboards: drop arbitrary
            // others before this one.
            for other in records.keys where other != key && records.count > maximumRecords {
                records[other] = nil
            }
        }
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: defaultsKey) }
    }
}

/// What the model and effort capsules show (D-25): Hermes' live report as
/// soon as there is one; until then the last confirmed values (最終確認);
/// with neither, 確認中… while the chat is still being reached and
/// 未確認, with its reason in the menu, once it can't be. A report
/// of none stays 不明.
enum LAAChatRuntimeDisplay {
    struct Value: Equatable {
        var model: String?
        var provider: String?
        var effort: String?
        var current: Bool
        var placeholder: String?
        /// Why nothing current can be shown, for the menus (LAAMenuReason).
        var reason: String?
    }

    enum Wait: Equatable {
        /// Connected and answered: what's missing was simply not reported.
        case settled
        /// Still connecting or reading.
        case checking
        /// Can't be read now, and why.
        case unavailable(String)
    }

    static func resolve(live: LAAChatRuntime.Shown, lastConfirmed: LAAChatRuntimeCache.Record?, wait: Wait) -> Value {
        let reason: String?
        let placeholder: String?
        switch wait {
        case .settled: reason = nil; placeholder = nil
        case .checking: reason = nil; placeholder = LAAModelCapsule.checking
        case .unavailable(let why): reason = why; placeholder = LAAModelCapsule.unavailable
        }
        if live.modelReported || live.effortReported {
            return Value(model: live.model, provider: live.provider, effort: live.effort, current: true,
                         placeholder: live.modelReported && live.effortReported ? nil : placeholder, reason: nil)
        }
        if let lastConfirmed {
            return Value(model: lastConfirmed.model, provider: lastConfirmed.provider, effort: lastConfirmed.effort,
                         current: false, placeholder: placeholder, reason: reason)
        }
        return Value(model: nil, provider: nil, effort: nil, current: true, placeholder: placeholder, reason: reason)
    }
}

/// How the chat's pickers reach Hermes: `model.options` for the live
/// agent's model and the choices, and session-scoped `config.set` for a
/// switch (`--session`, so the profile's config.yaml is left alone).
struct LAAChatModelOperations {
    typealias Options = (model: String?, provider: String?, providers: [ProviderInfo])
    var options: @MainActor (_ sessionID: String) async throws -> Options
    var setModel: @MainActor (_ sessionID: String, _ model: String, _ provider: String, _ confirmed: Bool) async throws -> ModelSwitchOutcome
    /// Nil sends the effort through `AppState.setReasoningEffort`.
    var setReasoning: (@MainActor (_ sessionID: String, _ effort: String) async throws -> Void)?
    /// Session-scoped `/fast`. Nil when the speed cannot be written.
    var setSpeed: (@MainActor (_ sessionID: String, _ speed: ModelSpeed) async throws -> Void)?

    init(options: @escaping @MainActor (String) async throws -> Options,
         setModel: @escaping @MainActor (String, String, String, Bool) async throws -> ModelSwitchOutcome,
         setReasoning: (@MainActor (String, String) async throws -> Void)? = nil,
         setSpeed: (@MainActor (String, ModelSpeed) async throws -> Void)? = nil) {
        self.options = options; self.setModel = setModel; self.setReasoning = setReasoning; self.setSpeed = setSpeed
    }

    @MainActor init(runtime: any ChatRuntime, conversationID: String,
                    setSpeed: @escaping @MainActor (ModelSpeed) async throws -> Void) {
        options = { _ in
            let result = try await runtime.capabilities(conversationID: conversationID)
            return (result.model, result.provider, result.models)
        }
        setModel = { _, model, provider, confirmed in
            let result = try await runtime.set(conversationID: conversationID, model: model, provider: provider,
                                               effort: nil, confirmed: confirmed)
            return .init(model: result.model ?? model, confirmRequired: result.confirmRequired,
                         confirmMessage: result.confirmation ?? "", deferred: result.deferred)
        }
        setReasoning = { _, effort in
            _ = try await runtime.set(conversationID: conversationID, model: nil, provider: nil,
                                      effort: effort, confirmed: false)
        }
        self.setSpeed = { _, speed in try await setSpeed(speed) }
    }
}

/// The chat pickers' choices, from what `model.options` returns for the
/// chat's agent, minus what the Model sheet hides.
enum LAAChatModelCatalog {
    struct Choice: Hashable, Identifiable {
        let model: String
        let provider: String
        let providerName: String
        let label: String
        let reasoning: Bool
        let current: Bool
        var id: String { provider + "\u{1F}" + model }
    }

    /// Models LAA runs on the Claude subscription that the Claude CLI's own
    /// picker (where Hermes reads this provider's list) does not name yet.
    /// Hermes takes them by id, so they are offered ahead of the listed ones.
    /// Fable left the lineup and Mythos took its part (owner, 2026-11-23).
    static let subscriptionExtras = ["claude-mythos-5-2"]

    static func isClaudeSubscription(_ provider: ProviderInfo) -> Bool {
        provider.name.hasPrefix("claude-subscription-directsdk")
    }

    /// Never offered here (C2, 2026-11-23): GPT's `-900k` variants, even of
    /// the newest name, and an uncensored model outside the uncensored
    /// Monet's own chat (laa-dsh lists one for every profile).
    static func offered(_ id: String, uncensoredProfile: Bool) -> Bool {
        let key = LAAChatModelAllowList.key(id)
        if key.hasSuffix("-900k") { return false }
        if key.contains("uncensored") { return uncensoredProfile }
        return true
    }

    /// Muse and Dots are no Chat model: they ran only for the contractors,
    /// who left Chat on 2026-11-26 (owner, 2026-11-23 and 11-26).
    static func isDedicated(model: String, provider: ProviderInfo) -> Bool {
        let model = model.lowercased()
        return ["muse", "dots"].contains(model) || ["custom:laa-muse", "custom:laa-dots", "laa-muse", "laa-dots"].contains { provider.matches($0) }
    }

    /// Hermes' providers for Gemini and the Claude API, as LAA names them
    /// (2026-11-23; GPT API left with GPT on 2026-11-28, D-42).
    static let routeNames = ["laa-agy": "Gemini", "claude-api": "Claude API"]

    /// The menu heading for a provider: LAA's name for those routes,
    /// Hermes' own name otherwise.
    static func sectionName(_ provider: ProviderInfo) -> String {
        routeNames.first { provider.matches($0.key) }?.value ?? provider.displayName ?? provider.name
    }

    /// `allowed` is LAA's lineup (LAAChatModelAllowList): Hermes lists every
    /// model its routes know, old ones included, and cannot be narrowed, so
    /// a model the lineup does not name is left out here. The chat's running
    /// model always stays, so a chat on an old one carries on. Nil shows
    /// Hermes' list as it is.
    static func choices(_ providers: [ProviderInfo], visibility: ModelVisibility,
                        runningModel: String?, runningProvider: String?,
                        allowed: LAAChatModelAllowList? = nil, profile: String? = nil) -> [Choice] {
        // Without a profile (nothing open) the uncensored rule has no chat to apply to.
        let uncensoredProfile = profile.map { LAAStaff(profile: $0) == .monetUncensored } ?? true
        return providers.filter { !visibility.hiddenProviders.contains($0.name) }.flatMap { provider in
            let running = runningProvider.map(provider.matches) == true
            let listed = provider.models
                .filter { !visibility.hiddenModels.contains("\(provider.name)\u{1F}\($0.id)") }
                .filter { !isDedicated(model: $0.id, provider: provider) || ($0.id == runningModel && running) }
                .filter { allowed?.allows($0.id) != false || ($0.id == runningModel && running) }
                .filter { offered($0.id, uncensoredProfile: uncensoredProfile) || ($0.id == runningModel && running) }
                .map { model in
                    Choice(model: model.id, provider: provider.name,
                           providerName: sectionName(provider),
                           label: LAAModelCapsule.readableName(model.id) ?? model.label ?? model.id,
                           reasoning: model.reasoningCapable,
                           current: model.id == runningModel && running)
                }
            guard isClaudeSubscription(provider) else { return listed }
            let named = Set(provider.models.map { $0.id.replacingOccurrences(of: "[1m]", with: "") })
            let extras = subscriptionExtras
                .filter { !named.contains($0) && !visibility.hiddenModels.contains("\(provider.name)\u{1F}\($0)") }
                .filter { allowed?.allows($0) != false || ($0 == runningModel && running) }
                .map { id in
                    Choice(model: id, provider: provider.name, providerName: sectionName(provider),
                           label: LAAModelCapsule.readableName(id) ?? id, reasoning: true,
                           current: id == runningModel && running)
                }
            return extras + listed
        }
    }

    /// True for a section of LAA's API routes (billed per use).
    static func meteredSection(_ choices: [Choice]) -> Bool {
        !choices.isEmpty && choices.allSatisfy { LAAHarness.metered(chatProvider: $0.provider) }
    }

    /// The harness a choice's turns run on (LAAHarness.chat).
    static func harness(of choice: Choice) -> LAAHarness { LAAHarness.chat(provider: choice.provider) }

    /// The harnesses the chat can switch to, in Hermes' order, each with
    /// only its own choices: what Hermes lists for this chat's agent, after
    /// the lineup and the hidden models. A harness with nothing left is not
    /// listed.
    static func harnesses(_ choices: [Choice]) -> [(harness: LAAHarness, choices: [Choice])] {
        LAAHarness.ordered(choices.map(harness(of:))).map { item in
            (item, choices.filter { harness(of: $0).id == item.id })
        }
    }

    /// Sections for the menu, one per provider in Hermes' order.
    static func sections(_ choices: [Choice]) -> [(name: String, choices: [Choice])] {
        var order: [String] = []
        var byProvider: [String: [Choice]] = [:]
        for item in choices {
            if byProvider[item.provider] == nil { order.append(item.provider) }
            byProvider[item.provider, default: []].append(item)
        }
        return order.map { (byProvider[$0]?.first?.providerName ?? $0, byProvider[$0] ?? []) }
    }

    /// The efforts offered: Low to Max, and a level Hermes reports outside
    /// them ("minimal"), listed to be read.
    static func efforts(current: String?, model: String? = nil, provider: String? = nil,
                        table: LAAChatModelAllowList? = nil) -> [String] {
        // The model table's range when the Bridge gave one (D-21 E6).
        if let listed = table?.efforts(for: model) { return listed }
        // Gemini 4 through Antigravity: Low to XHigh (agy's thinking levels).
        if (model ?? "").lowercased().contains("gemini") {
            let gemini = ["low", "medium", "high", "xhigh"]
            guard let current, !current.isEmpty, !gemini.contains(current) else { return gemini }
            return gemini + [current]
        }
        guard let current, !current.isEmpty, !LAAEffort.order.contains(current) else { return LAAEffort.order }
        return LAAEffort.order + [current]
    }

    enum Phase: Equatable {
        case idle, loading, failed
        case ready([Choice])
    }
}

/// LAA's model lineup for Chat: the models the Work catalog names (the
/// Bridge's session options, which come from the engine's catalog.json:
/// the latest of each tier, owner 2026-11-23). It is the one source; the
/// app holds no list of its own. Ids are compared without their route
/// ("openai-api:", "anthropic:", a JSON route's last element), the 1M
/// context mark, a date or an effort suffix, so Hermes' and Work's ids for
/// the same model meet. The last list read is kept on the device for when
/// the Bridge cannot be read; with none, Chat shows Hermes' list unfiltered.
struct LAAChatModelAllowList: Equatable, Codable {
    let keys: Set<String>
    /// The efforts the model table offers each Chat model, by `key` (D-23):
    /// Chat's effort menu shows these and no list of its own. Nil from an
    /// older Bridge or copy.
    var efforts: [String: [String]]? = nil

    init(keys: Set<String>, efforts: [String: [String]]? = nil) { self.keys = keys; self.efforts = efforts }

    init?(options: LAAWorkSessionOptions) {
        let ids = options.profiles.map(\.model) + (options.switchProfiles ?? []).map(\.model)
            + (options.efforts ?? []).map(\.model)
        let keys = Set(ids.map(Self.key).filter { !$0.isEmpty })
        guard !keys.isEmpty else { return nil }
        self.keys = keys
        var efforts: [String: [String]] = [:]
        for row in options.chat?.models ?? [] {
            if let list = row.efforts, !list.isEmpty { efforts[Self.key(row.chatModel)] = list }
        }
        self.efforts = efforts.isEmpty ? nil : efforts
    }

    /// The table's efforts for a Chat model, in LAA's order, or nil.
    func efforts(for model: String?) -> [String]? {
        guard let model, let list = efforts?[Self.key(model)] ?? efforts?[Self.withoutEffort(Self.key(model))] else { return nil }
        return list.sorted { LAAEffort.rank($0) < LAAEffort.rank($1) }
    }

    func allows(_ id: String) -> Bool {
        let key = Self.key(id)
        return keys.contains(key) || keys.contains(Self.withoutEffort(key))
    }

    /// One model's id in a form every route shares.
    static func key(_ id: String) -> String {
        var raw = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if raw.hasPrefix("["), let data = raw.data(using: .utf8),
           let route = try? JSONDecoder().decode([String].self, from: data), let last = route.last {
            raw = last.lowercased()
        }
        if let bracket = raw.firstIndex(of: "[") { raw = String(raw[..<bracket]) }
        if let colon = raw.lastIndex(of: ":") { raw = String(raw[raw.index(after: colon)...]) }
        if let slash = raw.lastIndex(of: "/") { raw = String(raw[raw.index(after: slash)...]) }
        raw = raw.replacingOccurrences(of: ".", with: "-")
        if let date = raw.firstMatch(of: #/-\d{8}$/#) { raw.removeSubrange(date.range) }
        return raw
    }

    private static func withoutEffort(_ key: String) -> String {
        guard let suffix = key.firstMatch(of: #/-(?:low|medium|high|xhigh|max)$/#) else { return key }
        var trimmed = key
        trimmed.removeSubrange(suffix.range)
        return trimmed
    }

    // MARK: The device's copy

    static let storageKey = "laa.chat.modelAllowList"
    @MainActor private static var memory: LAAChatModelAllowList?
    @MainActor private static weak var bridge: LAABridgeSession?

    /// The lineup Chat filters with now: the last one read, or nil.
    @MainActor static func current(_ defaults: UserDefaults = .standard) -> LAAChatModelAllowList? {
        if let memory { return memory }
        guard let data = defaults.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode(Self.self, from: data), !saved.keys.isEmpty else { return nil }
        memory = saved
        return saved
    }

    /// Keeps the lineup a Work catalog read returned.
    @MainActor static func record(_ options: LAAWorkSessionOptions, defaults: UserDefaults = .standard) {
        guard let list = LAAChatModelAllowList(options: options) else { return }
        memory = list
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: storageKey) }
    }

    /// Reads the Work catalog (shared with Work's screens, so at most one
    /// read a minute) and keeps its lineup. Without a bridge given, the last
    /// one Chat was shown with is used.
    @MainActor static func refresh(_ given: LAABridgeSession? = nil) async {
        if let given { bridge = given }
        guard let bridge, bridge.status == .paired else { return }
        _ = try? await LAAWorkOptionsStore.read(bridge)
    }

    #if DEBUG
    @MainActor static func resetForTesting() { memory = nil; bridge = nil }
    #endif
}

extension LAAChatModelCatalog {

    /// Why the model menu offers nothing, or nil.
    static func modelLock(sessionID: String?, connected: Bool, phase: Phase, switching: Bool) -> String? {
        guard sessionID != nil else { return "会話を始めると変更できます。" }
        guard connected else { return "Hermesに接続していません。" }
        if switching { return "変更中です。" }
        switch phase {
        case .idle, .loading: return "モデルの一覧を準備中です。"
        case .failed: return "モデルの一覧を読み取れませんでした。"
        case .ready(let choices):
            if choices.isEmpty { return "選べるモデルがありません。" }
            if choices.count == 1 { return "この社員で選べるモデルはこれだけです。" }
            return nil
        }
    }

    /// Why the effort menu offers nothing, or nil.
    static func effortLock(sessionID: String?, connected: Bool, current: Choice?, writing: Bool) -> String? {
        guard sessionID != nil else { return "会話を始めると変更できます。" }
        guard connected else { return "Hermesに接続していません。" }
        if writing { return "変更中です。" }
        if current?.reasoning == false { return "このモデルは推論の強さを変えられません。" }
        return nil
    }
}

import SwiftUI

/// LAA owner copy is selected solely from ChatRuntime's machine result.
enum LAAChatRuntimeCopy {
    /// The same words as the model menu's lock for a failed read.
    static let modelsUnavailableReason = "モデルの一覧を読み取れませんでした。"
    static let retryDraftReady = "入力欄に戻しました。実行済みの操作を確かめてから送信してください。"

    static func compactionNotice(_ result: ContextCompactResult) -> String? {
        switch result.status {
        case .compacted:
            if let before = result.beforeTokens, let after = result.afterTokens { return "圧縮しました（\(before)→\(after)）" }
            return "圧縮しました。"
        case .nothingToCompact:
            let fixed = result.fixedTokens.map(String.init) ?? "不明"
            let recent = result.recentTokens.map(String.init) ?? "不明"
            return "圧縮できる部分がありません（固定 \(fixed)・直近 \(recent)）"
        case .inProgress: return nil
        case .failed: return failureNotice(result.failure ?? .init(.internal))
        }
    }

    static func failureNotice(_ failure: ChatRuntimeFailure) -> String {
        switch failure.code {
        case .quotaExhausted:
            if let retryAt = failure.retryAt {
                let localTime = retryAt.formatted(.dateTime.month().day().hour().minute().locale(Locale(identifier: "ja_JP")))
                return "利用上限に達しました。再開：\(localTime)"
            }
            return "利用上限に達しました。再開時刻は不明です。"
        case .modelUnavailable: return "選択中のモデルは利用できません。"
        case .interrupted: return "処理を中断しました。実行済みの操作がないか確認してください。"
        case .timeout: return "応答を確認できませんでした。"
        case .contextOverflow: return "会話がモデルの上限を超えました。"
        case .toolFailed: return "操作を完了できませんでした。"
        case .runtimeUnavailable: return "接続できませんでした。"
        case .rejected: return "現在の状態では受け付けられません。"
        case .internal: return "処理を完了できませんでした。実行済みの操作がないか確認してください。"
        }
    }
}
import UIKit
import Combine

/// The row under the chat field: + at the start, the model · effort · Fast
/// capsules, and Send (or Stop) at the end. When the capsules, with their
/// whole names, leave no room on one line (owner, 2026-11-14: every model
/// name in full, nothing cut), they take a line of their own above + and
/// Send, wrapping there if they must. On the Mac a narrow column first lets
/// the harness show only its mark to keep one line. Three children, in that order.
struct LAAComposerControlsRow: Layout {
    var spacing: CGFloat = LAASpacing.x2

    /// True when + , the capsules and Send fit one line of `available` points
    /// with at least a spacing of room between the capsules and Send.
    static func oneLine(lead: CGFloat, middle: CGFloat, trail: CGFloat, available: CGFloat?, spacing: CGFloat) -> Bool {
        guard let available else { return true }
        return lead + middle + trail + 3 * spacing <= available + 0.5
    }

    private struct Arrangement {
        var frames: [CGRect]
        var size: CGSize
    }

    private func arrange(_ proposal: ProposedViewSize, _ subviews: Subviews) -> Arrangement {
        guard subviews.count == 3 else {
            return Arrangement(frames: subviews.map { CGRect(origin: .zero, size: $0.sizeThatFits(.unspecified)) }, size: .zero)
        }
        let available = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let lead = subviews[0].sizeThatFits(.unspecified), trail = subviews[2].sizeThatFits(.unspecified)
        let ideal = subviews[1].sizeThatFits(.unspecified)
        if Self.oneLine(lead: lead.width, middle: ideal.width, trail: trail.width, available: available, spacing: spacing) {
            let height = max(lead.height, ideal.height, trail.height)
            let width = available ?? (lead.width + ideal.width + trail.width + 3 * spacing)
            return Arrangement(frames: [
                CGRect(x: 0, y: (height - lead.height) / 2, width: lead.width, height: lead.height),
                CGRect(x: lead.width + spacing, y: (height - ideal.height) / 2, width: ideal.width, height: ideal.height),
                CGRect(x: width - trail.width, y: (height - trail.height) / 2, width: trail.width, height: trail.height),
            ], size: CGSize(width: width, height: height))
        }
        #if targetEnvironment(macCatalyst)
        // A narrow Mac column: the capsules may still keep one line between
        // + and Send once the harness shows only its mark (LAAModelEffortPickers).
        if let available {
            let room = available - lead.width - trail.width - 3 * spacing
            let fitted = subviews[1].sizeThatFits(ProposedViewSize(width: max(0, room), height: nil))
            if room > 0, fitted.width <= room + 0.5, fitted.height <= ideal.height + 0.5 {
                let height = max(lead.height, fitted.height, trail.height)
                return Arrangement(frames: [
                    CGRect(x: 0, y: (height - lead.height) / 2, width: lead.width, height: lead.height),
                    CGRect(x: lead.width + spacing, y: (height - fitted.height) / 2, width: fitted.width, height: fitted.height),
                    CGRect(x: available - trail.width, y: (height - trail.height) / 2, width: trail.width, height: trail.height),
                ], size: CGSize(width: available, height: height))
            }
        }
        #endif
        let width = available ?? ideal.width
        let middle = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let actions = max(lead.height, trail.height)
        let top = middle.height + spacing
        return Arrangement(frames: [
            CGRect(x: 0, y: top + (actions - lead.height) / 2, width: lead.width, height: lead.height),
            CGRect(x: 0, y: 0, width: middle.width, height: middle.height),
            CGRect(x: width - trail.width, y: top + (actions - trail.height) / 2, width: trail.width, height: trail.height),
        ], size: CGSize(width: width, height: top + actions))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(ProposedViewSize(width: bounds.width, height: nil), subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}

/// The chat composer's model and effort: the shared two capsules
/// (LAAModelEffortPickers), each opening its own menu. What they show is
/// what Hermes reports for the chat's agent; a choice is sent to Hermes for
/// this chat only, and the capsules change when Hermes reports it, never
/// before. They listen to the few values they need rather than the whole
/// AppState, so a streaming reply does not redraw the composer row.
struct LAAChatModelPickers: View {
    let appState: AppState
    @State private var runtime = LAAChatRuntime()
    @State private var activeSessionID: String?
    @State private var connected = false
    @State private var phase: LAAChatModelCatalog.Phase = .idle
    @State private var switching = false
    @State private var writingEffort = false
    @State private var writingSpeed = false
    @State private var capability: ModelSpeedCapability?
    @State private var pending: Pending?

    private struct Pending: Identifiable {
        let choice: LAAChatModelCatalog.Choice
        let message: String
        var id: String { choice.id }
    }

    @State private var lastConfirmed: LAAChatRuntimeCache.Record?
    private var shown: LAAChatRuntime.Shown {
        runtime.shown(for: activeSessionID.map { [$0] } ?? [])
    }
    /// What the capsules show: the live report, else the last confirmed
    /// values, else why nothing is there yet (LAAChatRuntimeDisplay).
    private var display: LAAChatRuntimeDisplay.Value {
        LAAChatRuntimeDisplay.resolve(live: shown, lastConfirmed: lastConfirmed, wait: wait)
    }
    private var wait: LAAChatRuntimeDisplay.Wait {
        if phase == .failed { return .unavailable(LAAChatRuntimeCopy.modelsUnavailableReason) }
        if !connected {
            return appState.isRecoveringConnection ? .checking : .unavailable(appState.laaConnectionStallReason)
        }
        return phase == .loading || phase == .idle ? .checking : .settled
    }
    private func readLastConfirmed() {
        lastConfirmed = appState.activeDashboardID.flatMap {
            LAAChatRuntimeCache.last(dashboardID: $0, profile: appState.activeProfile)
        }
    }
    private var choices: [LAAChatModelCatalog.Choice] {
        if case .ready(let items) = phase { return items }
        return []
    }
    private var currentChoice: LAAChatModelCatalog.Choice? {
        choices.first { $0.model == shown.model && $0.provider == shown.provider } ?? choices.first(where: \.current)
    }
    private var modelLock: String? {
        LAAChatModelCatalog.modelLock(sessionID: activeSessionID, connected: connected, phase: phase, switching: switching)
    }
    private var effortLock: String? {
        LAAChatModelCatalog.effortLock(sessionID: activeSessionID, connected: connected,
                                       current: currentChoice, writing: writingEffort)
    }

    /// The Fast capsule: what Hermes reported for this chat.
    private var fast: LAAChatFastControl.Display? {
        LAAChatFastControl.display(
            speed: shown.speed, capability: capability, sessionID: activeSessionID, connected: connected,
            writable: appState.laaChatModelOperations?.setSpeed != nil, writing: writingSpeed)
    }

    var body: some View {
        // Model, effort and Fast wrap as whole capsules when the names are
        // long (LAAWrapRow); none is ever cut.
        LAAWrapRow {
            LAAModelEffortPickers(
                harness: harness,
                model: display.model, provider: display.provider, effort: display.effort, current: display.current,
                changingModel: switching, changingEffort: writingEffort, effortFixed: effortChoices.count == 1,
                identifier: "composer.runtime",
                modelHint: modelLock ?? "この会話のモデルを変更", effortHint: effortLock ?? "この会話の推論の強さを変更",
                placeholder: display.placeholder
            ) {
                modelMenu
            } effortMenu: {
                effortMenu
            }
            if let fast {
                LAAChatFastCapsule(display: fast, changing: writingSpeed, identifier: "composer.runtime.fast") { changeSpeed($0) }
            }
        }
        .onReceive(appState.$laaChatRuntime.removeDuplicates()) { runtime = $0; readLastConfirmed() }
        .onReceive(appState.$activeSessionId.removeDuplicates()) { activeSessionID = $0; readLastConfirmed() }
        .onReceive(appState.$client.map { $0 != nil }.removeDuplicates()) { connected = $0 || appState.laaChatModelOperations != nil }
        .task(id: "\(activeSessionID ?? "")|\(connected)|\(shown.model ?? "")|\(shown.provider ?? "")") { await load() }
        .alert(Text(verbatim: "モデルを切り替えますか？"), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
               presenting: pending) { item in
            Button { switchModel(item.choice, confirmed: true) } label: { Text(verbatim: "切り替える") }
            Button(role: .cancel) {} label: { Text(verbatim: LAACopy.cancel) }
        } message: { item in
            Text(verbatim: item.message)
        }
    }

    /// The harness this chat's turns run on now: the one Hermes reports the
    /// chat's provider under. Nil until Hermes has said.
    private var harness: LAAHarness? {
        if let currentChoice { return LAAChatModelCatalog.harness(of: currentChoice) }
        return shown.provider.map { LAAHarness.chat(provider: $0) }
    }
    /// One section per harness (D-21 E2), headed by its mark and name, the
    /// running harness first, holding only its own models. Picking one on
    /// another harness hands the conversation over through Hermes, so its
    /// row says so.
    private var harnessGroups: [(harness: LAAHarness, choices: [LAAChatModelCatalog.Choice])] {
        let groups = LAAChatModelCatalog.harnesses(choices)
        guard let harness, let index = groups.firstIndex(where: { $0.harness.id == harness.id }) else { return groups }
        var out = groups
        out.insert(out.remove(at: index), at: 0)
        return out
    }

    @ViewBuilder private var modelMenu: some View {
        if let modelLock { LAAMenuReason(text: modelLock) }
        if let reason = display.reason, reason != modelLock { LAAMenuReason(text: reason) }
        if !connected, display.reason != nil {
            Button { Task { await appState.reconnect() } } label: {
                Label { Text(verbatim: "接続を再試行") } icon: { Image(systemName: "arrow.clockwise") }
            }
        }
        if phase == .failed {
            Button { Task { await load() } } label: {
                Label { Text(verbatim: "読み直す") } icon: { Image(systemName: "arrow.clockwise") }
            }
        }
        ForEach(harnessGroups, id: \.harness.id) { group in
            let sections = LAAChatModelCatalog.sections(group.choices)
            let other = harness != nil && group.harness.id != harness?.id
            Section {
                LAAHarnessHeading(harness: group.harness)
                ForEach(sections, id: \.name) { section in
                    let route = sections.count > 1 || LAAChatModelCatalog.meteredSection(section.choices)
                        ? sectionTitle(section) : nil
                    ForEach(section.choices) { choice in
                        let isCurrent = choice.id == currentChoice?.id
                        let note = [route, other ? "Hands over" : nil].compactMap { $0 }
                        LAAHarnessModelRow(title: choice.label, route: note.isEmpty ? nil : note.joined(separator: " · "),
                                           model: choice.model, provider: choice.provider,
                                           current: isCurrent) { switchModel(choice) }
                            .disabled(modelLock != nil || isCurrent)
                            .accessibilityIdentifier("composer.runtime.harness.\(group.harness.id).\(choice.model)")
                    }
                }
            }
        }
    }

    /// A metered route's heading says so (LAAHarness.metered).
    private func sectionTitle(_ section: (name: String, choices: [LAAChatModelCatalog.Choice])) -> String {
        LAAChatModelCatalog.meteredSection(section.choices) ? section.name + " · Metered" : section.name
    }

    private var effortChoices: [String] {
        LAAChatModelCatalog.efforts(current: shown.effort, model: shown.model, provider: shown.provider,
                                    table: LAAChatModelAllowList.current())
    }

    @ViewBuilder private var effortMenu: some View {
        if let effortLock { LAAMenuReason(text: effortLock) }
        if let reason = display.reason, reason != effortLock { LAAMenuReason(text: reason) }
        Section {
            ForEach(effortChoices, id: \.self) { effort in
                LAAEffortMenu.Row(effort: effort, selected: effort == shown.effort,
                                  identifier: "composer.runtime.effort.\(effort)") { changeEffort(effort) }
                    .disabled(effortLock != nil || effort == shown.effort || !LAAEffort.order.contains(effort))
            }
        }
    }

    @MainActor private func load() async {
        guard let sessionID = activeSessionID else {
            phase = .idle; capability = nil; return
        }
        guard let operations = appState.laaChatModelOperations else {
            // A transport can exist before the chat runtime binds. Do not
            // issue a runtime-only model read, or leave a permanent spinner.
            phase = connected ? .failed : .idle; capability = nil; return
        }
        phase = .loading
        // The lineup is read beside Hermes' list, never in its way: this
        // load filters with the one kept, the next with the fresh one.
        Task { await LAAChatModelAllowList.refresh() }
        do {
            let result = try await operations.options(sessionID)
            guard !Task.isCancelled, sessionID == appState.activeSessionId else { return }
            capability = LAAChatFastControl.capability(result.providers, model: result.model, provider: result.provider)
            phase = .ready(LAAChatModelCatalog.choices(result.providers, visibility: appState.modelVisibility,
                                                       runningModel: result.model, runningProvider: result.provider,
                                                       allowed: LAAChatModelAllowList.current(),
                                                       profile: appState.activeProfile))
        } catch {
            guard !Task.isCancelled, sessionID == appState.activeSessionId else { return }
            phase = .failed
        }
    }

    /// The same flow as the Model sheet (runModelPickerSwitch): a guarded
    /// pick asks first; a deferred one says when it lands. On success the
    /// capsule follows Hermes' own read-back of the chat's agent.
    private func switchModel(_ choice: LAAChatModelCatalog.Choice, confirmed: Bool = false) {
        guard !switching, let sessionID = appState.activeSessionId,
              let operations = appState.laaChatModelOperations else { return }
        switching = true
        Task { @MainActor in
            defer { switching = false }
            let result = await runModelPickerSwitch(to: choice.model, confirmed: confirmed) { confirmed in
                try await operations.setModel(sessionID, choice.model, choice.provider, confirmed)
            }
            guard appState.activeSessionId == sessionID else { return }
            switch result {
            case .switched(_, let deferred):
                if deferred { notify("この返信が終わると\(choice.label)に切り替わります。", symbol: "clock") }
                await readBack(operations, sessionID: sessionID)
            case .needsConfirmation(let message):
                pending = Pending(choice: choice, message: message)
            case .failed(let message):
                notify(message, symbol: "exclamationmark.triangle")
            }
        }
    }

    @MainActor private func readBack(_ operations: LAAChatModelOperations, sessionID: String) async {
        guard let report = try? await operations.options(sessionID), sessionID == appState.activeSessionId else { return }
        appState.laaApplyChatModelReport(sessionID: sessionID, model: report.model, provider: report.provider, effort: nil)
        capability = LAAChatFastControl.capability(report.providers, model: report.model, provider: report.provider)
        phase = .ready(LAAChatModelCatalog.choices(report.providers, visibility: appState.modelVisibility,
                                                   runningModel: report.model, runningProvider: report.provider,
                                                   allowed: LAAChatModelAllowList.current(),
                                                   profile: appState.activeProfile))
    }

    private func changeEffort(_ effort: String) {
        guard !writingEffort, let sessionID = appState.activeSessionId else { return }
        writingEffort = true
        Task { @MainActor in
            defer { writingEffort = false }
            guard appState.activeSessionId == sessionID else { return }
            if let setReasoning = appState.laaChatModelOperations?.setReasoning {
                do {
                    try await setReasoning(sessionID, effort)
                    appState.laaApplyChatModelReport(sessionID: sessionID, model: nil, provider: nil, effort: effort)
                } catch {
                    notify((error as? ChatRuntimeFailure ?? .init(.internal)).localizedDescription, symbol: "exclamationmark.triangle")
                }
            } else if case .failed(let message) = await appState.setReasoningEffort(effort) {
                notify(message, symbol: "exclamationmark.triangle")
            }
        }
    }

    /// Writes the speed for this chat; the capsule changes when Hermes has
    /// accepted it, and a refusal leaves it as it was and says why.
    private func changeSpeed(_ speed: ModelSpeed) {
        guard !writingSpeed, speed != shown.speed, let sessionID = appState.activeSessionId,
              let setSpeed = appState.laaChatModelOperations?.setSpeed else { return }
        writingSpeed = true
        Task { @MainActor in
            defer { writingSpeed = false }
            do {
                try await setSpeed(sessionID, speed)
                appState.laaApplyChatSpeed(sessionID: sessionID, speed: speed)
            } catch {
                guard appState.activeSessionId == sessionID else { return }
                notify((error as? ChatRuntimeFailure ?? .init(.internal)).localizedDescription, symbol: "exclamationmark.triangle")
            }
        }
    }

    /// Shown above the composer, where a returned message's notice goes.
    @MainActor private func notify(_ message: String, symbol: String) {
        appState.composerNotice = message
        appState.composerNoticeSystemImage = symbol
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}
#endif
