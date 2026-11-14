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
            (provider == "hermes-claude-api" ? "Claude API" :
                (LAAModelFace.face(model: byProvider[provider]?.first?.model, provider: provider).providerName ?? provider),
             byProvider[provider] ?? [])
        }
    }
}
#endif
