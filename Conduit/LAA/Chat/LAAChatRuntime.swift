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
    }

    /// What the chip shows for the chat on screen; nil reads 「不明」.
    func shown(for sessionIDs: Set<String>) -> Shown {
        let modelKnown = modelSessionID.map(sessionIDs.contains) ?? false
        let effortKnown = effortSessionID.map(sessionIDs.contains) ?? false
        let speedKnown = speedSessionID.map(sessionIDs.contains) ?? false
        return Shown(model: modelKnown ? model : nil,
                     provider: modelKnown ? provider : nil,
                     effort: effortKnown ? effort : nil,
                     speed: speedKnown ? speed : nil)
    }

    private static func value(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

    @MainActor init(client: HermesClient) {
        options = { sessionID in
            let result = try await client.modelOptions(sessionId: sessionID)
            return (result.model, result.provider, result.providers ?? [])
        }
        setModel = { sessionID, model, provider, confirmed in
            try await client.setModel(sessionID, model: model, provider: provider, confirmed: confirmed)
        }
        setReasoning = nil
        setSpeed = { sessionID, speed in try await client.setSpeed(sessionID, speed: speed) }
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
    static let subscriptionExtras = ["claude-fable-5-2", "claude-mythos-5-2"]

    static func isClaudeSubscription(_ provider: ProviderInfo) -> Bool {
        provider.name.hasPrefix("claude-subscription-directsdk")
    }

    static func choices(_ providers: [ProviderInfo], visibility: ModelVisibility,
                        runningModel: String?, runningProvider: String?) -> [Choice] {
        providers.filter { !visibility.hiddenProviders.contains($0.name) }.flatMap { provider in
            let running = runningProvider.map(provider.matches) == true
            let listed = provider.models
                .filter { !visibility.hiddenModels.contains("\(provider.name)\u{1F}\($0.id)") }
                .map { model in
                    Choice(model: model.id, provider: provider.name,
                           providerName: provider.displayName ?? provider.name,
                           label: LAAModelCapsule.readableName(model.id) ?? model.label ?? model.id,
                           reasoning: model.reasoningCapable,
                           current: model.id == runningModel && running)
                }
            guard isClaudeSubscription(provider) else { return listed }
            let named = Set(provider.models.map { $0.id.replacingOccurrences(of: "[1m]", with: "") })
            let extras = subscriptionExtras
                .filter { !named.contains($0) && !visibility.hiddenModels.contains("\(provider.name)\u{1F}\($0)") }
                .map { id in
                    Choice(model: id, provider: provider.name, providerName: provider.displayName ?? provider.name,
                           label: LAAModelCapsule.readableName(id) ?? id, reasoning: true,
                           current: id == runningModel && running)
                }
            return extras + listed
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
    static func efforts(current: String?, model: String? = nil, provider: String? = nil) -> [String] {
        // Hermes agent/reasoning_effort.py CODEX_ASTRA_EFFORTS and the
        // OpenAI Astra model contract: none/minimal are rejected.
        if ["openai-codex", "codex", "openai"].contains(provider ?? ""),
           ["gpt-6-astra", "gpt-6-astra-900k"].contains(model ?? "") {
            return ["low", "medium", "high", "xhigh", "max"]
        }
        guard let current, !current.isEmpty, !LAAEffort.order.contains(current) else { return LAAEffort.order }
        return LAAEffort.order + [current]
    }

    enum Phase: Equatable {
        case idle, loading, failed
        case ready([Choice])
    }

    /// Why the model menu offers nothing, or nil.
    static func modelLock(sessionID: String?, connected: Bool, phase: Phase, switching: Bool) -> String? {
        guard sessionID != nil else { return "会話を始めると変更できます。" }
        guard connected else { return "Hermesに接続していません。" }
        if switching { return "変更中です。" }
        switch phase {
        case .idle, .loading: return "モデルの候補を読み込み中です。"
        case .failed: return "モデルの候補を取得できませんでした。"
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
import UIKit
import Combine

/// The row under the chat field: + at the start, the model · effort · Fast
/// capsules, and Send (or Stop) at the end. When the capsules, with their
/// whole names, leave no room on one line (owner, 2026-11-14: every model
/// name in full, nothing cut), they take a line of their own above + and
/// Send, wrapping there if they must. Three children, in that order.
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
    @State private var fixed: LAAChatFixedRuntime?
    @State private var pending: Pending?

    private struct Pending: Identifiable {
        let choice: LAAChatModelCatalog.Choice
        let message: String
        var id: String { choice.id }
    }

    private var shown: LAAChatRuntime.Shown {
        runtime.shown(for: activeSessionID.map { [$0] } ?? [])
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

    /// The Fast capsule: the fixed one, or what Hermes reported for this chat.
    private var fast: LAAChatFastControl.Display? {
        if let fixed { return fixed.fast }
        return LAAChatFastControl.display(
            speed: shown.speed, capability: capability, sessionID: activeSessionID, connected: connected,
            writable: appState.laaChatModelOperations?.setSpeed != nil, writing: writingSpeed)
    }

    var body: some View {
        // Model, effort and Fast wrap as whole capsules when the names are
        // long (LAAWrapRow); none is ever cut.
        LAAWrapRow {
            if let fixed {
                // Nothing here is Hermes' to change: no menu rows, no writes.
                LAAModelEffortPickers(
                    model: fixed.model, provider: fixed.provider, effort: fixed.effort, name: fixed.name,
                    identifier: "composer.runtime", modelHint: fixed.reason, effortHint: fixed.reason
                ) {
                    LAAMenuReason(text: fixed.reason)
                } effortMenu: {
                    LAAMenuReason(text: fixed.reason)
                }
            } else {
                LAAModelEffortPickers(
                    model: shown.model, provider: shown.provider, effort: shown.effort,
                    changingModel: switching, changingEffort: writingEffort, identifier: "composer.runtime",
                    modelHint: modelLock ?? "この会話のモデルを変更", effortHint: effortLock ?? "この会話の推論の強さを変更"
                ) {
                    modelMenu
                } effortMenu: {
                    effortMenu
                }
            }
            if let fast {
                LAAChatFastCapsule(display: fast, changing: writingSpeed, identifier: "composer.runtime.fast") { changeSpeed($0) }
            }
        }
        .onReceive(appState.$laaChatRuntime.removeDuplicates()) { runtime = $0 }
        .onReceive(appState.$activeSessionId.removeDuplicates()) { activeSessionID = $0 }
        .onReceive(appState.$activeProfile.removeDuplicates()) { fixed = LAAChatFixedRuntime.of(profile: $0) }
        .onReceive(appState.$client.map { $0 != nil }.removeDuplicates()) { connected = $0 || appState.laaChatModelOperations != nil }
        .task(id: "\(activeSessionID ?? "")|\(connected)|\(shown.model ?? "")|\(shown.provider ?? "")|\(fixed != nil)") { await load() }
        .alert(Text(verbatim: "モデルを切り替えますか？"), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
               presenting: pending) { item in
            Button { switchModel(item.choice, confirmed: true) } label: { Text(verbatim: "切り替える") }
            Button(role: .cancel) {} label: { Text(verbatim: LAACopy.cancel) }
        } message: { item in
            Text(verbatim: item.message)
        }
    }

    @ViewBuilder private var modelMenu: some View {
        if let modelLock { LAAMenuReason(text: modelLock) }
        if phase == .failed {
            Button { Task { await load() } } label: {
                Label { Text(verbatim: "読み直す") } icon: { Image(systemName: "arrow.clockwise") }
            }
        }
        ForEach(LAAChatModelCatalog.sections(choices), id: \.name) { section in
            Section(section.name) {
                ForEach(section.choices) { choice in
                    let isCurrent = choice.id == currentChoice?.id
                    Button { switchModel(choice) } label: {
                        if isCurrent {
                            Label { Text(verbatim: choice.label) } icon: { Image(systemName: "checkmark") }
                        } else {
                            LAAModelMenu.Name(label: choice.label, model: choice.model)
                        }
                    }
                    .disabled(modelLock != nil || isCurrent)
                    .accessibilityIdentifier("composer.runtime.model.\(choice.model)")
                }
            }
        }
    }

    @ViewBuilder private var effortMenu: some View {
        if let effortLock { LAAMenuReason(text: effortLock) }
        Section {
            ForEach(LAAChatModelCatalog.efforts(current: shown.effort, model: shown.model, provider: shown.provider), id: \.self) { effort in
                LAAEffortMenu.Row(effort: effort, selected: effort == shown.effort,
                                  identifier: "composer.runtime.effort.\(effort)") { changeEffort(effort) }
                    .disabled(effortLock != nil || effort == shown.effort || !LAAEffort.order.contains(effort))
            }
        }
    }

    @MainActor private func load() async {
        guard fixed == nil, let sessionID = activeSessionID, let operations = appState.laaChatModelOperations else {
            phase = .idle; capability = nil; return
        }
        phase = .loading
        do {
            let result = try await operations.options(sessionID)
            guard !Task.isCancelled, sessionID == appState.activeSessionId else { return }
            capability = LAAChatFastControl.capability(result.providers, model: result.model, provider: result.provider)
            phase = .ready(LAAChatModelCatalog.choices(result.providers, visibility: appState.modelVisibility,
                                                       runningModel: result.model, runningProvider: result.provider))
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
                                                   runningModel: report.model, runningProvider: report.provider))
    }

    private func changeEffort(_ effort: String) {
        guard !writingEffort, let sessionID = appState.activeSessionId else { return }
        writingEffort = true
        Task { @MainActor in
            defer { writingEffort = false }
            if let setReasoning = appState.laaChatModelOperations?.setReasoning {
                do {
                    try await setReasoning(sessionID, effort)
                    appState.laaApplyChatModelReport(sessionID: sessionID, model: nil, provider: nil, effort: effort)
                } catch {
                    notify(UserFacingError.message(for: error), symbol: "exclamationmark.triangle")
                }
            } else if case .failed(let message) = await appState.setReasoningEffort(effort) {
                notify(message, symbol: "exclamationmark.triangle")
            }
        }
    }

    /// Writes the speed for this chat; the capsule changes when Hermes has
    /// accepted it, and a refusal leaves it as it was and says why.
    private func changeSpeed(_ speed: ModelSpeed) {
        guard fixed == nil, !writingSpeed, speed != shown.speed, let sessionID = appState.activeSessionId,
              let setSpeed = appState.laaChatModelOperations?.setSpeed else { return }
        writingSpeed = true
        Task { @MainActor in
            defer { writingSpeed = false }
            do {
                try await setSpeed(sessionID, speed)
                appState.laaApplyChatSpeed(sessionID: sessionID, speed: speed)
            } catch {
                guard appState.activeSessionId == sessionID else { return }
                notify(UserFacingError.message(for: error), symbol: "exclamationmark.triangle")
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
