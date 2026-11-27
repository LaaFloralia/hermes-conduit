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
        case claudeCode, codex, pi, antigravity, dsh, dshOrchestrator, hermes, muse, dots, echo, other
    }

    let kind: Kind
    /// The wire value it was read from: the name of an `other`, and which
    /// DSH it is (`dsh-worker`, `dsh-refuseless`).
    let raw: String
    /// The name the Bridge's model table gives it (D-23 `harnesses[].name`),
    /// shown in place of the built-in one.
    var title: String? = nil

    init(kind: Kind, raw: String, title: String? = nil) {
        self.kind = kind; self.raw = raw; self.title = title?.isEmpty == false ? title : nil
    }

    /// DSH runs as two harnesses (D-33): the Orchestrator on Refuseless
    /// (uncensored) and the Worker on OpenCode Go, each its own section.
    var id: String { kind == .other ? "other:" + raw : kind.rawValue }

    /// The product's own name, never translated.
    var name: String {
        if let title { return title }
        switch kind {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .pi: "Pi"
        case .antigravity: "Antigravity"
        case .dsh: "DSH Worker"
        case .dshOrchestrator: "DSH Orchestrator"
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
        // D-33: the Orchestrator is DSH on Refuseless (uncensored), the
        // Worker DSH on OpenCode Go; the picker names each by its own id.
        case "dsh-refuseless", "dsh-orchestrator": .dshOrchestrator
        case "dsh", "dsh-worker", "dsh-venice": .dsh
        case "hermes", "hermes-claude-api", "hermes-openai-api": .hermes
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
        if names.contains("laa-monet-uncensored") { return LAAHarness(kind: .dshOrchestrator, raw: name) }
        if names.contains("laa-dsh") { return LAAHarness(kind: .dsh, raw: name) }
        if names.contains("laa-muse") { return LAAHarness(kind: .muse, raw: name) }
        if names.contains("laa-dots") { return LAAHarness(kind: .dots, raw: name) }
        return LAAHarness(kind: .hermes, raw: name)
    }

    /// Hermes' rows billed per use: LAA's two API routes (2026-11-23) and
    /// Refuseless behind Monet (uncensored) (2026-11-25).
    static func metered(chatProvider name: String) -> Bool {
        ["gpt-api", "claude-api", "laa-monet-uncensored"].contains(name.lowercased().replacingOccurrences(of: "custom:", with: ""))
    }

    /// Distinct harnesses in first-seen order.
    static func ordered(_ items: [LAAHarness]) -> [LAAHarness] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }
}

/// A harness's mark: the maker's own mark as issued, original colours, never
/// recoloured or reshaped (docs/laa/HARNESS-ASSETS.md). It stands for the
/// model wherever a model is shown (D-21 E3): the model capsule, Work's rows
/// and transcripts. LAA's own DSH keeps its badge, the initial in a hairline
/// ring; the Orchestrator's badge alone sits on purple (the Mythos colour of
/// tokens.json appSelection, D-21 E5).
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
            case .hermes: issued("LAAHermesMark", scale: 1.0)
            case .dshOrchestrator: orchestrator
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

    @Environment(\.colorScheme) private var scheme

    /// The mark as an image a menu can draw (menus take no custom views),
    /// at the original colours, one per harness and appearance.
    @MainActor static func menuImage(_ harness: LAAHarness, dark: Bool) -> Image {
        let key = harness.id + (dark ? "|dark" : "|light")
        if let cached = menuImages[key] { return cached }
        let renderer = ImageRenderer(content: LAAHarnessMark(harness: harness, size: 18)
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 3
        guard let image = renderer.uiImage?.withRenderingMode(.alwaysOriginal) else { return Image(systemName: "circle") }
        let made = Image(uiImage: image).renderingMode(.original)
        menuImages[key] = made
        return made
    }
    @MainActor private static var menuImages: [String: Image] = [:]

    private var orchestrator: some View {
        let tone = LAAAppSelectionTokens.mythos
        let fill = scheme == .dark ? tone.bodyTop.dark : tone.ink.light
        return Text(verbatim: "D")
            .font(.system(size: max(10, size * 0.58), weight: .semibold))
            .foregroundStyle(Color(red: tone.lightColor.dark.r, green: tone.lightColor.dark.g, blue: tone.lightColor.dark.b))
            .frame(width: size, height: size)
            .background(Circle().fill(Color(red: fill.r, green: fill.g, blue: fill.b)))
    }

    private var badge: some View {
        Text(verbatim: String((harness?.name ?? "?").prefix(1)))
            .font(.system(size: max(12, size * 0.62), weight: .semibold))
            .foregroundStyle(LAAColor.secondaryText)
            .frame(width: size, height: size)
            .overlay { Circle().strokeBorder(LAAColor.separator, lineWidth: 1) }
    }
}

/// One model row under its harness's heading in the model menu: the
/// maker's official mark (Claude's Spark, OpenAI's Blossom, DeepSeek's
/// whale; none where the maker's mark is not in the app), the model's name,
/// and a note under it (the route, "Hands over", why it cannot be chosen);
/// checked when it is what runs now. The harness is the heading and the
/// maker the row's mark, so DSH and DeepSeek never read as one (D-33 追記8).
/// One level, no submenu (a nested menu at the composer did not open on
/// iOS, 2026-11-26).
struct LAAHarnessModelRow: View {
    let title: String
    var route: String? = nil
    var model: String? = nil
    var provider: String? = nil
    let current: Bool
    let pick: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Toggle(isOn: Binding(get: { current }, set: { if $0 { pick() } })) {
            if let mark = LAAModelMark.officialMenuImage(model: model, provider: provider, dark: scheme == .dark) {
                Label { Text(verbatim: title) } icon: { mark }
            } else {
                Text(verbatim: title)
            }
            if let route { Text(verbatim: route) }
        }
    }
}

extension LAAModelMark {
    /// The maker's mark as a menu image, only for makers whose official mark
    /// the app carries (Claude, OpenAI, DeepSeek); nil for the rest.
    @MainActor static func officialMenuImage(model: String?, provider: String?, dark: Bool) -> Image? {
        let face = LAAModelFace.face(model: model, provider: provider)
        switch face {
        case .claude, .deepSeek: break
        case .gpt where hasOpenAIMark: break
        default: return nil
        }
        let key = "\(face)" + (dark ? "|dark" : "|light")
        if let cached = officialImages[key] { return cached }
        let renderer = ImageRenderer(content: LAAModelMark(model: model, provider: provider, size: 18)
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 3
        guard let image = renderer.uiImage?.withRenderingMode(.alwaysOriginal) else { return nil }
        let made = Image(uiImage: image).renderingMode(.original)
        officialImages[key] = made
        return made
    }
    @MainActor private static var officialImages: [String: Image] = [:]
}
#endif
