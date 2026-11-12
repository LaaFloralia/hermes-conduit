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

    struct Shown: Equatable {
        let model: String?
        let provider: String?
        let effort: String?
    }

    /// What the chip shows for the chat on screen; nil reads 「不明」.
    func shown(for sessionIDs: Set<String>) -> Shown {
        let modelKnown = modelSessionID.map(sessionIDs.contains) ?? false
        let effortKnown = effortSessionID.map(sessionIDs.contains) ?? false
        return Shown(model: modelKnown ? model : nil,
                     provider: modelKnown ? provider : nil,
                     effort: effortKnown ? effort : nil)
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

    init(options: @escaping @MainActor (String) async throws -> Options,
         setModel: @escaping @MainActor (String, String, String, Bool) async throws -> ModelSwitchOutcome,
         setReasoning: (@MainActor (String, String) async throws -> Void)? = nil) {
        self.options = options; self.setModel = setModel; self.setReasoning = setReasoning
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

    static func choices(_ providers: [ProviderInfo], visibility: ModelVisibility,
                        runningModel: String?, runningProvider: String?) -> [Choice] {
        providers.filter { !visibility.hiddenProviders.contains($0.name) }.flatMap { provider in
            provider.models
                .filter { !visibility.hiddenModels.contains("\(provider.name)\u{1F}\($0.id)") }
                .map { model in
                    Choice(model: model.id, provider: provider.name,
                           providerName: provider.displayName ?? provider.name,
                           label: LAAModelCapsule.readableName(model.id) ?? model.label ?? model.id,
                           reasoning: model.reasoningCapable,
                           current: model.id == runningModel && runningProvider.map(provider.matches) == true)
                }
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
    static func efforts(current: String?) -> [String] {
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

    var body: some View {
        LAAModelEffortPickers(
            model: shown.model, provider: shown.provider, effort: shown.effort,
            changingModel: switching, changingEffort: writingEffort, identifier: "composer.runtime",
            modelHint: modelLock ?? "この会話のモデルを変更", effortHint: effortLock ?? "この会話の推論の強さを変更"
        ) {
            modelMenu
        } effortMenu: {
            effortMenu
        }
        .onReceive(appState.$laaChatRuntime.removeDuplicates()) { runtime = $0 }
        .onReceive(appState.$activeSessionId.removeDuplicates()) { activeSessionID = $0 }
        .onReceive(appState.$client.map { $0 != nil }.removeDuplicates()) { connected = $0 || appState.laaChatModelOperations != nil }
        .task(id: "\(activeSessionID ?? "")|\(connected)") { await load() }
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
                            Text(verbatim: choice.label)
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
            ForEach(LAAChatModelCatalog.efforts(current: shown.effort), id: \.self) { effort in
                LAAEffortMenu.Row(effort: effort, selected: effort == shown.effort,
                                  identifier: "composer.runtime.effort.\(effort)") { changeEffort(effort) }
                    .disabled(effortLock != nil || effort == shown.effort || !LAAEffort.order.contains(effort))
            }
        }
    }

    @MainActor private func load() async {
        guard let sessionID = activeSessionID, let operations = appState.laaChatModelOperations else {
            phase = .idle; return
        }
        phase = .loading
        do {
            let result = try await operations.options(sessionID)
            guard sessionID == appState.activeSessionId else { return }
            phase = .ready(LAAChatModelCatalog.choices(result.providers, visibility: appState.modelVisibility,
                                                       runningModel: result.model, runningProvider: result.provider))
        } catch {
            guard sessionID == appState.activeSessionId else { return }
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

    /// Shown above the composer, where a returned message's notice goes.
    @MainActor private func notify(_ message: String, symbol: String) {
        appState.composerNotice = message
        appState.composerNoticeSystemImage = symbol
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}
#endif
