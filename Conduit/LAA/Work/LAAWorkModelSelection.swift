#if LAA_BUILD
import Foundation

/// The new-session sheet's and the task form's model and effort, chosen
/// apart from the Bridge's profiles (one per model × effort). What is saved
/// stays the profile id, so favourites, the last choice and the request body
/// are unchanged.
enum LAAWorkModelSelection {
    /// One model and the profiles that run it, lowest effort first.
    struct Model: Identifiable, Hashable {
        let provider: String
        let model: String
        let label: String
        let profiles: [LAAWorkSessionOptions.Profile]
        var id: String { provider + "\u{1F}" + model }
        var efforts: [String] { profiles.map(\.effort) }
        var available: Bool { profiles.contains { $0.available != false } }
        var usageNote: String? { profiles.compactMap(\.usageNote).first }
    }

    /// The models in the model table's order, each once.
    static func models(_ options: LAAWorkSessionOptions?) -> [Model] {
        guard let options else { return [] }
        var order: [String] = []
        var byKey: [String: [LAAWorkSessionOptions.Profile]] = [:]
        for item in options.profiles {
            let key = item.provider + "\u{1F}" + item.model
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(item)
        }
        return order.compactMap { key in
            guard let profiles = byKey[key], let first = profiles.first else { return nil }
            return Model(provider: first.provider, model: first.model,
                         label: LAAWorkSessionStyle.displayModel(LAAWorkSessionStyle.shortLabel(first.label)),
                         profiles: profiles.sorted { LAAEffort.rank($0.effort) < LAAEffort.rank($1.effort) })
        }
    }

    static func model(of profileID: String, in options: LAAWorkSessionOptions?) -> Model? {
        models(options).first { $0.profiles.contains { $0.id == profileID } }
    }

    /// The profile after switching to `model`: the same effort when it has
    /// it, else High, else the nearest (LAAEffort.carried).
    static func profile(switchingTo model: Model, from current: LAAWorkSessionOptions.Profile?) -> LAAWorkSessionOptions.Profile? {
        guard let effort = LAAEffort.carried(current?.effort, into: model.efforts) else { return nil }
        return model.profiles.first { $0.effort == effort }
    }

    /// The profile of the same model at `effort`.
    static func profile(effort: String, of profileID: String, in options: LAAWorkSessionOptions?) -> LAAWorkSessionOptions.Profile? {
        model(of: profileID, in: options)?.profiles.first { $0.effort == effort }
    }

    /// Menu sections: one per provider, in the table's order.
    static func providers(_ models: [Model]) -> [(name: String, models: [Model])] {
        var order: [String] = []
        var byProvider: [String: [Model]] = [:]
        for item in models {
            if byProvider[item.provider] == nil { order.append(item.provider) }
            byProvider[item.provider, default: []].append(item)
        }
        return order.map { provider in
            (sectionName(provider, first: byProvider[provider]?.first?.model), byProvider[provider] ?? [])
        }
    }

    /// The heading a provider's models sit under: the route for the paid and
    /// subscription ones (Gemini is Google AI Pro through Antigravity), the
    /// maker otherwise.
    static func sectionName(_ provider: String, first model: String?) -> String {
        switch provider {
        case "dsh-venice": "Venice"
        case "hermes-claude-api", "claude-api": "Claude API"
        case "hermes-openai-api", "pi-openai-api": "GPT API"
        case "antigravity": "Gemini"
        default: LAAModelFace.face(model: model, provider: provider).providerName ?? provider
        }
    }
}
/// The harness selector (owner, 2026-11-26): the harnesses the options'
/// profiles start on, each with only the models it runs. A provider the
/// engine moved (codex → pi) is listed under the harness it moved to; where
/// Fast keeps it on its own (Codex), that harness is listed too, and its
/// models start with Fast on. Nothing is listed that no profile reaches.
extension LAAWorkModelSelection {
    struct HarnessGroup: Identifiable {
        let harness: LAAHarness
        /// Choosing a model here turns Fast on (the harness only Fast reaches).
        let fast: Bool
        let models: [Model]
        var id: String { harness.id + (fast ? "+fast" : "") }
        var metered: Bool { !models.isEmpty && models.allSatisfy(LAAWorkModelSelection.metered) }
    }

    /// A route billed per use: what the Bridge marks, else (an older Bridge)
    /// the paid providers LAAHarness knows.
    static func metered(_ profile: LAAWorkSessionOptions.Profile) -> Bool {
        profile.metered ?? LAAHarness.metered(workProvider: profile.provider)
    }
    static func metered(_ model: Model) -> Bool {
        !model.profiles.isEmpty && model.profiles.allSatisfy(metered)
    }

    /// The harness a model's sessions start on without Fast.
    static func harness(of model: Model) -> LAAHarness? {
        model.profiles.first.flatMap { LAAHarness.work($0) }
    }

    /// The harness Fast moves a model's sessions to, when it is another one.
    static func fastHarness(of model: Model) -> LAAHarness? {
        model.profiles.first { $0.fast && $0.fastHarness != nil }.flatMap { LAAHarness.work($0, fast: true) }
    }

    static func harnesses(_ models: [Model]) -> [HarnessGroup] {
        var order: [String] = []
        var groups: [String: (harness: LAAHarness, fast: Bool, models: [Model])] = [:]
        func add(_ harness: LAAHarness?, fast: Bool, _ model: Model) {
            guard let harness else { return }
            let key = harness.id + (fast ? "+fast" : "")
            if groups[key] == nil { order.append(key); groups[key] = (harness, fast, []) }
            groups[key]?.models.append(model)
        }
        for model in models { add(harness(of: model), fast: false, model) }
        for model in models { add(fastHarness(of: model), fast: true, model) }
        return order.compactMap { key in groups[key].map { HarnessGroup(harness: $0.harness, fast: $0.fast, models: $0.models) } }
    }

    /// The picker's sections (D-23, D-33): the harnesses the Bridge's model
    /// table names, in its order, each holding the `models` it lists there,
    /// so DSH's Orchestrator and Worker are two sections though they start
    /// the same profiles. A Bridge without the picker, a Fast-only harness
    /// and a model the picker does not place fall back to the profiles' own
    /// harnesses (`harnesses(_:)`).
    static func harnesses(_ models: [Model], picker options: LAAWorkSessionOptions?) -> [HarnessGroup] {
        guard let rows = options?.models, let heads = options?.harnesses, !rows.isEmpty, !heads.isEmpty else {
            return harnesses(models)
        }
        let byID = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [HarnessGroup] = []
        for head in heads.sorted(by: { $0.order < $1.order }) {
            guard let found = LAAHarness.work(head.id) else { continue }
            var seen = Set<String>()
            let members = rows.filter { $0.harnessId == head.id && ($0.surfaces?.contains("session") ?? true) }
                .compactMap { byID[$0.provider + "\u{1F}" + $0.model] }
                .filter { seen.insert($0.id).inserted }
            guard !members.isEmpty else { continue }
            out.append(HarnessGroup(harness: LAAHarness(kind: found.kind, raw: found.raw, title: head.name),
                                    fast: false, models: members))
        }
        let placed = Set(out.flatMap { $0.models.map(\.id) })
        let fallback = harnesses(models)
        out += fallback.filter(\.fast)
        out += harnesses(models.filter { !placed.contains($0.id) }).filter { !$0.fast }
        return out
    }

    /// The group a profile (with Fast as chosen) runs in.
    static func group(of profileID: String, fast: Bool, in groups: [HarnessGroup]) -> HarnessGroup? {
        let wantsFast = fast && groups.contains { $0.fast && $0.models.contains { $0.profiles.contains { $0.id == profileID && $0.fast } } }
        return groups.first { group in
            group.fast == wantsFast && group.models.contains { $0.profiles.contains { $0.id == profileID } }
        }
    }
}

/// Share launch catalogs across Work surfaces. Never persist credentials or
/// replace a selection while the catalog refreshes.
@MainActor enum LAAWorkOptionsStore {
    private struct Entry {
        let value: LAAWorkSessionOptions
        let fetchedAt: Date
    }
    private static var entries: [String: Entry] = [:]
    private static var loads: [String: Task<LAAWorkSessionOptions, Error>] = [:]

    static func read(_ bridge: LAABridgeSession, force: Bool = false) async throws -> LAAWorkSessionOptions {
        let key = "\(bridge.address)|\(bridge.deviceID ?? "")|\(bridge.revision)"
        if !force, let entry = entries[key], Date().timeIntervalSince(entry.fetchedAt) < 60 {
            return entry.value
        }
        if let load = loads[key] { return try await load.value }
        let load = Task<LAAWorkSessionOptions, Error> {
            try await bridge.read("/v1/session-options?catalogOnly=true")
        }
        loads[key] = load
        defer { loads[key] = nil }
        let value = try await load.value
        guard key == "\(bridge.address)|\(bridge.deviceID ?? "")|\(bridge.revision)" else {
            throw CancellationError()
        }
        entries = [key: Entry(value: value, fetchedAt: Date())]
        // Chat's model menus offer the same lineup (LAAChatModelAllowList).
        LAAChatModelAllowList.record(value)
        return value
    }
}
#endif
#if LAA_BUILD
import SwiftUI

/// The model menu in Work (D-21 E2): one section per harness, headed by its
/// mark and name, the running harness first, holding the models that harness
/// runs, so the harness and the model are picked with one tap; the running
/// model is checked. A row on another harness says the conversation hands
/// over (`handsOver`); a paid route says so under the model's name; a model
/// that cannot be chosen says why; a harness reached only with Fast says that
/// in its heading.
struct LAAWorkHarnessMenu: View {
    let groups: [LAAWorkModelSelection.HarnessGroup]
    let current: LAAWorkModelSelection.HarnessGroup?
    let chosen: LAAWorkModelSelection.Model?
    let identifier: String
    var lock: String? = nil
    /// True where picking a model of another harness hands the conversation
    /// over (a running session); false where nothing is running yet.
    var handsOver = false
    var disabled: (LAAWorkModelSelection.Model) -> Bool = { !$0.available }
    let pick: (LAAWorkModelSelection.HarnessGroup, LAAWorkModelSelection.Model) -> Void

    static func ordered(_ groups: [LAAWorkModelSelection.HarnessGroup],
                        current: LAAWorkModelSelection.HarnessGroup?) -> [LAAWorkModelSelection.HarnessGroup] {
        guard let current, let index = groups.firstIndex(where: { $0.id == current.id }) else { return groups }
        var out = groups
        out.insert(out.remove(at: index), at: 0)
        return out
    }

    var body: some View {
        if let lock { LAAMenuReason(text: lock) }
        if groups.isEmpty { LAAMenuReason(text: "None available") }
        ForEach(Self.ordered(groups, current: current)) { group in
            let sections = LAAWorkModelSelection.providers(group.models)
            let other = handsOver && current != nil && group.id != current?.id
            Section {
                LAAHarnessHeading(harness: group.harness, suffix: group.fast ? " · Fast" : nil)
                ForEach(sections, id: \.name) { section in
                    ForEach(section.models) { model in
                        let metered = LAAWorkModelSelection.metered(model)
                        let reason = model.available ? nil : (model.profiles.compactMap(\.unavailableReason).first ?? "Unavailable")
                        let notes = [sections.count > 1 || metered ? section.name + (metered ? " · Metered" : "") : nil,
                                     other ? "Hands over" : nil, reason].compactMap { $0 }
                        let isCurrent = group.id == current?.id && model.id == chosen?.id
                        LAAHarnessModelRow(title: model.label, route: notes.isEmpty ? nil : notes.joined(separator: " · "),
                                           current: isCurrent) { pick(group, model) }
                            .disabled(lock != nil || isCurrent || disabled(model))
                            .accessibilityIdentifier("\(identifier).\(group.id).\(model.provider).\(model.model)")
                    }
                    if let note = section.models.compactMap(\.usageNote).first {
                        ForEach(note.split(separator: "\n").map(String.init), id: \.self) { LAAMenuReason(text: $0) }
                    }
                }
            }
        }
    }
}
#endif
