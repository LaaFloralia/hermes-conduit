#if LAA_BUILD
import SwiftUI

/// The execution harness a conversation actually runs on, chosen beside the
/// model (owner, 2026-11-26): the harness first, then only the models it can
/// run. Nothing here is a list of what is available: Work's harnesses come
/// from the Bridge's session options (the engine names each profile's
/// harness), Chat's from the providers Hermes lists for the chat's agent.
/// This type only names and draws them.
struct LAAHarness: Hashable, Identifiable {
    enum Kind: String, Hashable {
        case claudeCode, codex, pi, antigravity, dsh, hermes, muse, dots, echo, other
    }

    let kind: Kind
    /// The wire value it was read from, kept for `other` only (its name).
    let raw: String

    var id: String { kind == .other ? "other:" + raw : kind.rawValue }

    /// The product's own name, never translated.
    var name: String {
        switch kind {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .pi: "Pi"
        case .antigravity: "Antigravity"
        case .dsh: "DSH"
        case .hermes: "Hermes"
        case .muse: "Muse"
        case .dots: "Dots"
        case .echo: "Echo"
        case .other: raw
        }
    }

    // MARK: Work

    /// A Work harness id (the engine's catalog key) as a harness. The paid
    /// routes are the same harness on an API key (`claude-api` is Claude
    /// Code, `pi-openai-api` is Pi); the Bridge's older Hermes API routes run
    /// Hermes' own ACP.
    static func work(_ id: String?) -> LAAHarness? {
        guard let id = id?.trimmingCharacters(in: .whitespaces).lowercased(), !id.isEmpty else { return nil }
        let kind: Kind = switch id {
        case "claude", "claude-api": .claudeCode
        case "codex": .codex
        case "pi", "pi-openai-api": .pi
        case "antigravity": .antigravity
        case "dsh", "dsh-venice", "dsh-refuseless": .dsh
        case "hermes-claude-api", "hermes-openai-api": .hermes
        case "muse": .muse
        case "dots": .dots
        // The lab lane's isolated engine runs only its built-in Echo (`lab`).
        case "echo", "lab": .echo
        default: .other
        }
        return LAAHarness(kind: kind, raw: id)
    }

    /// The harness a new session on `profile` starts on: the engine's move
    /// (codex → pi) when the Bridge names it, Fast's own harness when Fast is
    /// on and the moved one has no Fast, else the provider itself.
    static func work(_ profile: LAAWorkSessionOptions.Profile, fast: Bool = false) -> LAAHarness? {
        if fast, profile.fast, let fastHarness = profile.fastHarness { return work(fastHarness) }
        return work(profile.harness ?? profile.provider)
    }

    /// A route billed per use, for a Bridge that does not mark it
    /// (`metered`, LAAWorkModelSelection.metered). Offered only by hand and
    /// labelled so.
    static func metered(workProvider id: String) -> Bool {
        ["claude-api", "pi-openai-api", "hermes-claude-api", "hermes-openai-api", "dsh-venice", "dsh-refuseless"]
            .contains(id.lowercased())
    }

    // MARK: Chat

    /// What runs a Hermes provider's turns (hq/logs/refuseless-route-20261126.md
    /// §1): Hermes keeps the conversation either way; `laa-agy` hands each
    /// turn to Antigravity (`agy acp`), the Claude subscription plugin to
    /// Claude Code through the Agent SDK, `laa-dsh` and Monet (uncensored)
    /// to DSH, the Muse and Dots bridges (`custom:laa-muse`,
    /// `custom:laa-dots`) to those agents. Every other row (`openai-codex` is
    /// Hermes' own Codex route to the ChatGPT plan, the API routes) is Hermes
    /// itself, so it is labelled Hermes, never Codex.
    static func chat(_ provider: ProviderInfo) -> LAAHarness {
        chat(provider: provider.name, aliases: [provider.displayName ?? ""] + provider.aliases)
    }

    static func chat(provider name: String, aliases: [String] = []) -> LAAHarness {
        let names = ([name] + aliases).map { $0.lowercased().replacingOccurrences(of: "custom:", with: "") }
        if names.contains(where: { $0.hasPrefix("claude-subscription-directsdk") }) {
            return LAAHarness(kind: .claudeCode, raw: name)
        }
        if names.contains(where: { $0 == "laa-agy" || $0.hasPrefix("laa-agy-") }) {
            return LAAHarness(kind: .antigravity, raw: name)
        }
        if names.contains(where: { ["laa-dsh", "laa-monet-uncensored"].contains($0) }) {
            return LAAHarness(kind: .dsh, raw: name)
        }
        if names.contains("laa-muse") { return LAAHarness(kind: .muse, raw: name) }
        if names.contains("laa-dots") { return LAAHarness(kind: .dots, raw: name) }
        return LAAHarness(kind: .hermes, raw: name)
    }

    /// Hermes' rows billed per use: LAA's two API routes (2026-11-23) and
    /// Refuseless behind Monet (uncensored) (2026-11-25).
    static func metered(chatProvider name: String) -> Bool {
        ["gpt-api", "claude-api", "laa-monet-uncensored"].contains(name.lowercased().replacingOccurrences(of: "custom:", with: ""))
    }

    /// The harness's mark is the model's maker's own (Claude Code running
    /// Claude, Codex running GPT), so the model capsule beside it leaves its
    /// face out rather than show the same mark twice.
    func sharesMark(model: String?, provider: String?) -> Bool {
        switch (kind, LAAModelFace.face(model: model, provider: provider)) {
        case (.claudeCode, .claude): true
        case (.codex, .gpt): LAAModelMark.hasOpenAIMark
        default: false
        }
    }

    /// Distinct harnesses in first-seen order.
    static func ordered(_ items: [LAAHarness]) -> [LAAHarness] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }
}

/// A harness's mark, bare (no disc, so it never reads as a second model
/// face): the maker's own mark as issued, original colours, never recoloured
/// or reshaped (docs/laa/HARNESS-ASSETS.md). A harness whose maker publishes
/// no mark has a neutral badge, its initial in a hairline ring.
struct LAAHarnessMark: View {
    let harness: LAAHarness?
    var size: CGFloat = 18

    var body: some View {
        Group {
            switch harness?.kind {
            case .claudeCode: issued("LAAClaudeMark", scale: 0.92)
            case .codex where LAAModelMark.hasOpenAIMark: issued("LAAOpenAIMark", scale: 0.92)
            case .pi: issued("LAAPiMark", scale: 1.0)
            case .antigravity: issued("LAAAntigravityMark", scale: 1.0)
            default: badge
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func issued(_ asset: String, scale: CGFloat) -> some View {
        Image(asset)
            .renderingMode(.original)
            .resizable().scaledToFit()
            .frame(width: size * scale, height: size * scale)
    }

    private var badge: some View {
        Text(verbatim: String((harness?.name ?? "?").prefix(1)))
            .font(.system(size: max(12, size * 0.62), weight: .semibold))
            .foregroundStyle(LAAColor.secondaryText)
            .frame(width: size, height: size)
            .overlay { Circle().strokeBorder(LAAColor.separator, lineWidth: 1) }
    }
}

/// One model row under its harness's heading in the harness menu: the
/// model's name, with the route under it where the harness has more than one
/// (Hermes' Codex plan and its API key) or the route is billed per use;
/// checked when it is what runs now. One level, no submenu: the harness is
/// the heading, so harness and model are picked with one tap (a nested menu
/// at the composer did not open on iOS, 2026-11-26).
struct LAAHarnessModelRow: View {
    let title: String
    var route: String? = nil
    let current: Bool
    let pick: () -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { current }, set: { if $0 { pick() } })) {
            Text(verbatim: title)
            if let route { Text(verbatim: route) }
        }
    }
}
#endif
