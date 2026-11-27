#if LAA_BUILD
import SwiftUI

/// The model and its effort as two Liquid Glass capsules side by side, each
/// opening its own menu: the model's face, name and chevron; then the
/// effort's name and chevron (owner, 2026-11-12: one control for both was
/// one too few). Work's session row, the new-session sheet, the task form and
/// Chat's composer all use it, so the four read and press alike.
///
/// The model's name is always whole, beginning with its maker ("Claude Opus
/// 5.5"), never cut or "…" (owner, 2026-11-14): when the row is too narrow
/// the effort moves to the next line (LAAWrapRow). A strong selection holds
/// 「大理石の脈」 inside the glass: the model's colour, marble veins and a slow
/// light, by step (LAASelectionStep, values from tokens.json appSelection).
/// An applied change spreads the veins once from the leading end. Unknown
/// and stale values stay plain.
///
///     LAAModelEffortPickers(model: "claude-opus-5-5", provider: "claude", effort: "xhigh",
///                           identifier: "work.session") { modelRows } effortMenu: { effortRows }
///
/// The menus always open, even when nothing can be chosen: the caller puts
/// the reason in a disabled row (owner, 2026-11-11). Identifiers are
/// `<identifier>.model` and `<identifier>.effort`; VoiceOver reads 「モデル」
/// and 「推論」 as two controls.
struct LAAModelEffortPickers<HarnessMenu: View, ModelMenu: View, EffortMenu: View>: View {
    /// The harness the conversation runs on, shown ahead of the model as its
    /// own capsule and menu (LAAHarnessCapsule); nil leaves it out.
    var harness: LAAHarness? = nil
    var harnessHint: String = "Change Harness"
    /// The wire id ("claude-fable-5-2") or a display name ("Fable 5.2").
    let model: String?
    /// The provider id ("claude", "codex", "dsh"); sets the face's family.
    let provider: String?
    /// The applied effort's wire value ("high", "xhigh", "max").
    let effort: String?
    /// A name to show instead of the one read from `model` (a model table's label).
    var name: String? = nil
    /// False when the values are the last confirmed ones, not the current
    /// setting: the name is prefixed 最終確認, the finish and movement are withheld.
    var current = true
    /// A plum ▲ before the model's name: what runs differs from what was asked for.
    var attention = false
    /// On while a change this control asked for is being applied: 「変更中」
    /// shows, and the value that arrives next (or within a moment after)
    /// moves the capsule once. Pass the applied values, not the chosen ones.
    var changingModel = false
    var changingEffort = false
    /// "work.session" → "work.session.model" and "work.session.effort".
    let identifier: String
    /// Added to the model's spoken value ("、依頼 Fable 5.2").
    var modelValueSuffix: String? = nil
    var modelHint: String = "Change Model"
    var effortHint: String = "Change Effort"
    var harnessMenu: () -> HarnessMenu
    var modelMenu: () -> ModelMenu
    var effortMenu: () -> EffortMenu

    init(harness: LAAHarness?, harnessHint: String = "Change Harness",
         model: String?, provider: String?, effort: String?, name: String? = nil, current: Bool = true,
         attention: Bool = false, changingModel: Bool = false, changingEffort: Bool = false, identifier: String,
         modelValueSuffix: String? = nil, modelHint: String = "Change Model", effortHint: String = "Change Effort",
         @ViewBuilder harnessMenu: @escaping () -> HarnessMenu,
         @ViewBuilder modelMenu: @escaping () -> ModelMenu,
         @ViewBuilder effortMenu: @escaping () -> EffortMenu) {
        self.harness = harness; self.harnessHint = harnessHint
        self.model = model; self.provider = provider; self.effort = effort; self.name = name; self.current = current
        self.attention = attention; self.changingModel = changingModel; self.changingEffort = changingEffort
        self.identifier = identifier; self.modelValueSuffix = modelValueSuffix
        self.modelHint = modelHint; self.effortHint = effortHint
        self.harnessMenu = harnessMenu; self.modelMenu = modelMenu; self.effortMenu = effortMenu
    }

    private var modelText: String {
        LAAModelCapsule.text(model: model, provider: provider, name: name, current: current,
                             missing: LAAModelCapsule.unknownSpokenValue)
    }
    private var effortText: String {
        guard let shown = LAAEffort.name(effort) else { return LAAModelCapsule.unknownSpokenValue }
        return current ? shown : "Last Verified: " + shown
    }

    var body: some View {
        LAAWrapRow {
            if let harness {
                Menu { harnessMenu() } label: { LAAHarnessCapsule(harness: harness, current: current) }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                    .accessibilityLabel(Text(verbatim: "Harness"))
                    .accessibilityValue(Text(verbatim: harness.name))
                    .accessibilityHint(Text(verbatim: harnessHint))
                    .accessibilityIdentifier(identifier + ".harness")
            }
            Menu { modelMenu() } label: {
                LAAModelCapsule(model: model, provider: provider, name: name, current: current,
                                attention: attention, changing: changingModel,
                                showsFace: !(harness?.sharesMark(model: model, provider: provider) ?? false))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "Model"))
            .accessibilityValue(Text(verbatim: modelText + (modelValueSuffix ?? "")))
            .accessibilityHint(Text(verbatim: modelHint))
            .accessibilityIdentifier(identifier + ".model")

            Menu { effortMenu() } label: {
                LAAEffortCapsule(effort: effort, current: current, changing: changingEffort,
                                 tone: LAAModelRank.of(model).tone)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel(Text(verbatim: "Effort"))
            .accessibilityValue(Text(verbatim: effortText))
            .accessibilityHint(Text(verbatim: effortHint))
            .accessibilityIdentifier(identifier + ".effort")
        }
    }
}

extension LAAModelEffortPickers where HarnessMenu == EmptyView {
    /// The pair without a harness capsule (the task form, a project's default).
    init(model: String?, provider: String?, effort: String?, name: String? = nil, current: Bool = true,
         attention: Bool = false, changingModel: Bool = false, changingEffort: Bool = false, identifier: String,
         modelValueSuffix: String? = nil, modelHint: String = "Change Model", effortHint: String = "Change Effort",
         @ViewBuilder modelMenu: @escaping () -> ModelMenu,
         @ViewBuilder effortMenu: @escaping () -> EffortMenu) {
        self.init(harness: nil, model: model, provider: provider, effort: effort, name: name, current: current,
                  attention: attention, changingModel: changingModel, changingEffort: changingEffort,
                  identifier: identifier, modelValueSuffix: modelValueSuffix, modelHint: modelHint,
                  effortHint: effortHint, harnessMenu: { EmptyView() }, modelMenu: modelMenu, effortMenu: effortMenu)
    }
}

/// The harness capsule: the harness's own mark and chevron, the same 36pt
/// glass as the model and effort beside it, so the three read as one row of
/// one control. The phone shows the mark alone (the name is in the menu and
/// read aloud) so the row keeps one line with every model name whole; the
/// Mac, with room, adds the name. Plain glass: the marble finish stays the
/// model's and the effort's (tokens.json appSelection).
struct LAAHarnessCapsule: View {
    let harness: LAAHarness
    var current = true

    #if targetEnvironment(macCatalyst)
    static let showsName = true
    #else
    static let showsName = false
    #endif

    var body: some View {
        if Self.showsName { named } else { round }
    }

    /// The phone: the mark alone in a round glass button the size of the
    /// composer's icon buttons, so the row keeps room for the model and the
    /// effort (the menu's own title names the harness).
    private var round: some View {
        LAAHarnessMark(harness: harness, size: 18)
            .opacity(current ? 1 : 0.6)
            .frame(width: LAAPickerMetrics.height, height: LAAPickerMetrics.height)
            .contentShape(Circle())
            .laaGlassSelection(step: .plain, tone: .stone, seed: 0, motion: .frozen(elapsed: nil, light: nil),
                               cornerRadius: LAAPickerMetrics.radius)
    }

    /// The Mac: the mark, the harness's name and the menu's chevron.
    private var named: some View {
        HStack(spacing: 6) {
            LAAHarnessMark(harness: harness, size: 18)
            Text(verbatim: harness.name)
                .foregroundStyle(LAAColor.text)
                .fontWeight(.semibold)
                .lineLimit(1)
            LAAPickerMetrics.chevronView()
        }
        .fixedSize()
        .laaTextStyle(.secondary)
        .opacity(current ? 1 : 0.6)
        .padding(.leading, (LAAPickerMetrics.height - 18) / 2).padding(.trailing, LAASpacing.x3)
        .frame(minHeight: LAAPickerMetrics.height)
        .contentShape(RoundedRectangle(cornerRadius: LAAPickerMetrics.radius, style: .continuous))
        .laaGlassSelection(step: .plain, tone: .stone, seed: 0, motion: .frozen(elapsed: nil, light: nil),
                           cornerRadius: LAAPickerMetrics.radius)
    }
}

/// The disabled first row of a menu that says why nothing in it can be
/// chosen, so a tap always answers.
struct LAAMenuReason: View {
    let text: String
    var body: some View {
        Section { Button {} label: { Text(verbatim: text) }.disabled(true) }
    }
}

/// Both capsules share these, so their height, padding, chevron and glass
/// match to the point.
private enum LAAPickerMetrics {
    static let height: CGFloat = 36
    static let radius: CGFloat = 18
    static let chevron = Image(systemName: "chevron.up.chevron.down")

    static func chevronView() -> some View {
        chevron.font(.system(size: 10, weight: .semibold))
            .foregroundStyle(LAAColor.secondaryText)
            .accessibilityHidden(true)
    }
}

/// The model capsule: face, ▲ when it differs from the request, the whole
/// name and the chevron.
struct LAAModelCapsule: View {
    let model: String?
    let provider: String?
    var name: String? = nil
    var current = true
    var attention = false
    var changing = false
    /// Off when the harness capsule beside it already shows the same maker's
    /// mark (Claude Code running Claude, Codex running GPT): one mark, not two.
    var showsFace = true

    static let unknownSpokenValue = "Unknown"

    static func text(model: String?, provider: String?, name: String?, current: Bool,
                     missing: String = LAAShape.unknown) -> String {
        guard let shown = name.map(fullName) ?? displayName(model: model, provider: provider) else { return missing }
        return current ? shown : "Last Verified: " + shown
    }

    @State private var start: Date?

    private var rank: LAAModelRank { current ? LAAModelRank.of(model) : .none }
    private var shown: String { Self.text(model: model, provider: provider, name: name, current: current) }

    var body: some View {
        content(motion: .live(start))
        .laaCeremonyTrigger(value: model, changing: changing,
                            enabled: current && Self.displayName(model: model, provider: provider) != nil,
                            start: $start)
        .task(id: start) {
            guard let started = start else { return }
            try? await Task.sleep(for: .seconds(LAACeremony.duration(rank: rank)))
            if start == started { start = nil }
        }
    }

    /// The capsule held at one moment for a capture: at rest (`elapsed` nil)
    /// or that far into its movement, with the slow light at `light` (0 the
    /// leading end, 1 the trailing; nil: where the still light rests).
    func face(elapsed: Double?, light: Double? = nil) -> some View {
        content(motion: .frozen(elapsed: elapsed, light: light))
    }

    private func content(motion: LAAGlassMotion) -> some View {
        row
            .laaTextStyle(.secondary)
            // The face sits as far from the rim as it is from top and bottom.
            .padding(.leading, showsFace ? (LAAPickerMetrics.height - 22) / 2 : LAASpacing.x3)
            .padding(.trailing, LAASpacing.x3)
            .frame(minHeight: LAAPickerMetrics.height)
            .contentShape(Capsule())
            .laaGlassSelection(step: rank.step, tone: rank.tone, seed: LAAMarble.seed(model), motion: motion,
                               cornerRadius: LAAPickerMetrics.radius)
    }

    private var row: some View {
        // The whole name on one line; only a row narrower than the name
        // itself (never at the phone's width) wraps it at a space, never "…".
        HStack(spacing: 6) {
            if showsFace { LAAModelMark(model: model, provider: provider, size: 22) }
            if changing { Text(verbatim: "Changing").laaTextStyle(.note).foregroundStyle(LAAColor.text).fixedSize() }
            if attention {
                // ▲ is the house mark for "check this".
                Image(systemName: "triangle.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(LAAColor.attention)
                    .accessibilityHidden(true)
            }
            Text(verbatim: shown)
                .foregroundStyle(shown == LAAShape.unknown ? LAAColor.secondaryText : LAAColor.text)
                .accessibilityHidden(shown == LAAShape.unknown)
                .fontWeight(.semibold)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            LAAPickerMetrics.chevronView()
        }
    }

    /// The capsule's name from a wire id, whole and beginning with its maker:
    /// "claude-opus-4-8" → "Claude Opus 4.8", "gpt-6.1-sol" → "GPT 6.1 Sol";
    /// a name already written for people is kept. Nil when nothing readable
    /// is there.
    static func displayName(model: String?, provider: String?) -> String? {
        guard let raw = model?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return readableName(raw).map(fullName) ?? LAAModelFace.face(model: raw, provider: provider).providerName
    }

    /// A Claude model's short name with its maker in front ("Opus 5.5" →
    /// "Claude Opus 5.5"); any other name as it is ("GPT 6 Astra").
    static func fullName(_ name: String) -> String {
        guard let first = name.split(separator: " ").first,
              ["Opus", "Sonnet", "Haiku", "Fable", "Mythos"].contains(String(first)) else { return name }
        return "Claude " + name
    }

    /// The short name read from the id itself (a menu row under its
    /// provider's heading), without falling back to the provider's: nil for
    /// an id it cannot read ("laa-monet-local").
    static func readableName(_ value: String) -> String? {
        var raw = value.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        // A routed id: ["opencode-go","deepseek-v4.1-flash"].
        if let data = raw.data(using: .utf8), let route = try? JSONDecoder().decode([String].self, from: data),
           let last = route.last { raw = last }
        // A paid API route names its route before the id: "openai-api:gpt-5.5", "anthropic:claude-opus-5-5".
        for route in ["openai-api:", "openai:", "anthropic:", "google:", "gemini:"] where raw.lowercased().hasPrefix(route) {
            raw = String(raw.dropFirst(route.count))
        }
        if raw.hasPrefix("Claude ") { raw = String(raw.dropFirst("Claude ".count)) }
        // The 1M-context route of the same model: "claude-opus-5-5[1m]".
        if raw.hasSuffix("[1m]") { raw = String(raw.dropLast("[1m]".count)) }
        let lower = raw.lowercased()
        if let match = lower.firstMatch(of: #/^claude-(opus|sonnet|haiku|fable|mythos)-(\d+)(?:-(\d{1,2}))?(?:-\d{8})?$/#) {
            return "\(match.1.capitalized) \(match.2)" + (match.3.map { ".\($0)" } ?? "")
        }
        if let match = lower.firstMatch(of: #/^gpt-([\d.]+)-([a-z]+)$/#) {
            return "GPT \(match.1) \(match.2.capitalized)"
        }
        // GPT API ids: "gpt-5.5", "gpt-5.4-mini", "gpt-4o"; and the o-series, "o3", "o4-mini".
        if let match = lower.firstMatch(of: #/^gpt-([\da-z.]+)((?:-[a-z][a-z0-9]*)*)$/#) {
            let words = match.2.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }
            return (["GPT", String(match.1)] + words).joined(separator: " ")
        }
        if let match = lower.firstMatch(of: #/^(o\d+)((?:-[a-z]+)*)$/#) {
            let words = match.2.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }
            return ([String(match.1)] + words).joined(separator: " ")
        }
        // "gemini-4-neon" → "Gemini 4 Neon"; an effort suffix ("-high") is the effort's, not the name's.
        if let match = lower.firstMatch(of: #/^gemini-([\d.]+)((?:-[a-z]+)*?)(?:-(?:low|medium|high|xhigh|max))?$/#) {
            let words = match.2.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }
            return (["Gemini", String(match.1)] + words).joined(separator: " ")
        }
        if lower.hasPrefix("deepseek") {
            // "deepseek-v4.1-flash" → "DeepSeek V4.1 Flash", each word as written.
            let words = raw.dropFirst("deepseek".count).split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }
            return (["DeepSeek"] + words).joined(separator: " ")
        }
        // Already a display name ("Opus 5.5", "GPT-6 Astra").
        if raw.contains(" ") && !raw.contains("/") && !raw.contains("[") { return raw }
        return nil
    }
}

/// The effort capsule: its name, or a hollow mark, and the chevron, with no meter
/// beside it (owner, 2026-11-14). XHigh and above hold marble veins inside
/// the glass; after a requested change they spread across it once
/// (LAAMarbleLook).
struct LAAEffortCapsule: View {
    let effort: String?
    var current = true
    var changing = false
    /// The model's colour and strength, so the pair wears one look (LAASelectionStyle).
    var tone: LAAVeinTone = .stone
    @State private var start: Date?

    private var known: String? { effort.flatMap { LAAEffort.name($0) == nil ? nil : $0 } }
    // Ultra Code is a ranked finish without adding a sixth general effort.
    var ranked: String? { known.flatMap { LAAEffort.order.contains($0) || $0 == "ultracode" ? $0 : nil } }

    var body: some View {
        content(motion: current ? .live(start) : .frozen(elapsed: nil, light: nil))
        .laaCeremonyTrigger(value: effort, changing: changing, enabled: current && ranked != nil, start: $start)
        .task(id: start) {
            guard let started = start, let ranked else { return }
            try? await Task.sleep(for: .seconds(LAACeremony.duration(effort: ranked)))
            if start == started { start = nil }
        }
    }

    /// The capsule held at one moment for a capture (LAAModelCapsule.face).
    func capsule(elapsed: Double?, light: Double? = nil) -> some View {
        content(motion: .frozen(elapsed: current ? elapsed : nil, light: light))
    }

    private func content(motion: LAAGlassMotion) -> some View {
        HStack(spacing: 6) {
            if changing { Text(verbatim: "Changing").laaTextStyle(.note) }
            if let known {
                LAAEffortLabel(effort: known, current: current)
            } else {
                Text(verbatim: LAAShape.unknown)
                    .foregroundStyle(LAAColor.secondaryText)
                    .accessibilityHidden(true)
            }
            LAAPickerMetrics.chevronView()
        }
        .lineLimit(1).fixedSize()
        .laaTextStyle(.secondary).foregroundStyle(LAAColor.text)
        .padding(.leading, LAASpacing.x3).padding(.trailing, LAASpacing.x3)
        .frame(minHeight: LAAPickerMetrics.height)
        .contentShape(Capsule())
        .laaGlassSelection(step: current ? LAAEffort.step(ranked) : .plain, tone: tone,
                           seed: LAAMarble.seed(ranked), motion: motion,
                           cornerRadius: LAAPickerMetrics.radius)
    }
}

/// Children at their ideal widths, left to right, moving whole to the next
/// line when the row is full: the model and effort capsules (and Chat's Fast)
/// wrap instead of cutting a name. A child wider than the row alone gets the
/// row's width. Each line is centred on its tallest child.
struct LAAWrapRow: Layout {
    var spacing: CGFloat = LAASpacing.x2
    var lineSpacing: CGFloat = LAASpacing.x2

    /// The line each width falls on, for an `available` width (nil: one line).
    static func lines(_ widths: [CGFloat], available: CGFloat?, spacing: CGFloat) -> [Int] {
        var line = 0, x: CGFloat = 0, out: [Int] = []
        for (index, width) in widths.enumerated() {
            if index > 0, let available, x + spacing + width > available + 0.5 { line += 1; x = 0 }
            else if index > 0 { x += spacing }
            out.append(line)
            x += width
        }
        return out
    }

    private func frames(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        let available = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let sizes = subviews.map { subview -> CGSize in
            let ideal = subview.sizeThatFits(.unspecified)
            guard let available, ideal.width > available + 0.5 else { return ideal }
            return subview.sizeThatFits(ProposedViewSize(width: available, height: nil))
        }
        let line = Self.lines(sizes.map(\.width), available: available, spacing: spacing)
        var frames: [CGRect] = [], y: CGFloat = 0, width: CGFloat = 0
        for current in Set(line).sorted() {
            let members = line.indices.filter { line[$0] == current }
            let height = members.map { sizes[$0].height }.max() ?? 0
            var x: CGFloat = 0
            for index in members {
                if x > 0 { x += spacing }
                frames.append(CGRect(x: x, y: y + (height - sizes[index].height) / 2,
                                     width: sizes[index].width, height: sizes[index].height))
                x += sizes[index].width
            }
            width = max(width, x)
            y += height + lineSpacing
        }
        return (frames, CGSize(width: width, height: max(0, y - lineSpacing)))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        frames(proposal, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = frames(ProposedViewSize(width: bounds.width, height: bounds.height), subviews).frames
        for (subview, frame) in zip(subviews, placed) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}
#endif
