#if LAA_BUILD
import SwiftUI

/// The model and its effort as two Liquid Glass capsules side by side, each
/// opening its own menu: the model's face, name and chevron; then the
/// effort's meter, name and chevron (owner, 2026-11-12: one control for both
/// was one too few). Work's session row, the new-session sheet, the task form
/// and Chat's composer all use it, so the four read and press alike.
///
/// The model name gives way whole when the row is narrow (the face stays,
/// never "M…"); the effort never does. Standing shows on the glass, not in
/// colour (LAAFinish): Fable, Astra and XHigh carry one fine tan line on the
/// rim, Mythos and Max two. When a value this control asked for is applied,
/// its capsule moves once, briefly (LAACeremony): the edge brightens, or a
/// light runs round the rim, leaving the metal lines behind it for a ranked
/// value. Every value may be unknown, and reads 「不明」, never a guess, and
/// never moves.
///
///     LAAModelEffortPickers(model: "claude-opus-5-5", provider: "claude", effort: "xhigh",
///                           identifier: "work.session") { modelRows } effortMenu: { effortRows }
///
/// The menus always open, even when nothing can be chosen: the caller puts
/// the reason in a disabled row (owner, 2026-11-11). Identifiers are
/// `<identifier>.model` and `<identifier>.effort`; VoiceOver reads 「モデル」
/// and 「推論」 as two controls.
struct LAAModelEffortPickers<ModelMenu: View, EffortMenu: View>: View {
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
    var modelHint: String = "モデルを変更"
    var effortHint: String = "推論の強さを変更"
    @ViewBuilder let modelMenu: () -> ModelMenu
    @ViewBuilder let effortMenu: () -> EffortMenu

    private var modelText: String { LAAModelCapsule.text(model: model, provider: provider, name: name, current: current) }
    private var effortText: String {
        let shown = LAAEffort.name(effort) ?? LAAModelCapsule.unknown
        return current ? shown : "最終確認 " + shown
    }

    var body: some View {
        HStack(spacing: LAASpacing.x2) {
            Menu { modelMenu() } label: {
                LAAModelCapsule(model: model, provider: provider, name: name, current: current,
                                attention: attention, changing: changingModel)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .layoutPriority(-1)
            .accessibilityLabel(Text(verbatim: "モデル"))
            .accessibilityValue(Text(verbatim: modelText + (modelValueSuffix ?? "")))
            .accessibilityHint(Text(verbatim: modelHint))
            .accessibilityIdentifier(identifier + ".model")

            Menu { effortMenu() } label: {
                LAAEffortCapsule(effort: effort, current: current, changing: changingEffort)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel(Text(verbatim: "推論"))
            .accessibilityValue(Text(verbatim: effortText))
            .accessibilityHint(Text(verbatim: effortHint))
            .accessibilityIdentifier(identifier + ".effort")
        }
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

/// The model capsule: face, ▲ when it differs from the request, the name
/// (whole or none) and the chevron.
struct LAAModelCapsule: View {
    let model: String?
    let provider: String?
    var name: String? = nil
    var current = true
    var attention = false
    var changing = false

    static let unknown = "不明"

    static func text(model: String?, provider: String?, name: String?, current: Bool) -> String {
        let shown = name ?? displayName(model: model, provider: provider) ?? unknown
        return current ? shown : "最終確認 " + shown
    }

    @State private var start: Date?

    private var rank: LAAModelRank { current ? LAAModelRank.of(model) : .none }
    private var shown: String { Self.text(model: model, provider: provider, name: name, current: current) }

    var body: some View {
        TimelineView(.animation(paused: start == nil)) { context in
            face(elapsed: start.map { context.date.timeIntervalSince($0) })
        }
        .laaCeremonyTrigger(value: model, changing: changing,
                            enabled: current && Self.displayName(model: model, provider: provider) != nil,
                            start: $start)
        .task(id: start) {
            guard let started = start else { return }
            try? await Task.sleep(for: .seconds(LAACeremony.duration(rank: rank)))
            if start == started { start = nil }
        }
    }

    /// The capsule at rest (`elapsed` nil) or that far into its movement: the
    /// glass with its finish's metal lines, and the light of the one movement.
    /// Internal so a capture can hold a moment of it.
    func face(elapsed: Double?) -> some View {
        row
            .laaTextStyle(.secondary)
            // The face sits as far from the rim as it is from top and bottom.
            .padding(.leading, (LAAPickerMetrics.height - 22) / 2).padding(.trailing, LAASpacing.x3)
            .frame(minHeight: LAAPickerMetrics.height)
            .contentShape(Capsule())
            .conduitGlassControl(cornerRadius: LAAPickerMetrics.radius, interactive: true)
            .overlay {
                LAARimFinish(look: LAARimLook(finish: rank.finish, motion: LAACeremony.motion(rank: rank),
                                              elapsed: elapsed),
                             cornerRadius: LAAPickerMetrics.radius)
            }
    }

    private var row: some View {
        // The whole name or none: in a narrow row the capsule is the face
        // and the chevron, never "M…", and it shrinks to them, leaving no
        // gap. VoiceOver still reads the name.
        LAANameOrNoneRow(spacing: 6) {
            LAAModelMark(model: model, provider: provider, size: 22)
            if changing { Text(verbatim: "変更中").font(.caption).foregroundStyle(LAAColor.text).fixedSize() }
            if attention {
                // ▲ is the house mark for "check this".
                Image(systemName: "triangle.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(LAAColor.attention)
                    .accessibilityHidden(true)
            }
            Text(verbatim: shown)
                .foregroundStyle(LAAColor.text)
                .fontWeight(.semibold).lineLimit(1).fixedSize()
                // Takes the width it is given and clips, so left out it draws nothing.
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).clipped()
                .layoutValue(key: LAAGivesWay.self, value: true)
            LAAPickerMetrics.chevronView()
        }
    }

    /// A model's name from its wire id: "claude-opus-4-8" → "Opus 4.8",
    /// "gpt-6.1-sol" → "GPT 6.1 Sol"; a name already written for people is
    /// kept. Nil when nothing readable is there.
    static func displayName(model: String?, provider: String?) -> String? {
        guard let raw = model?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return readableName(raw) ?? LAAModelFace.face(model: raw, provider: provider).providerName
    }

    /// The name read from the id itself, without falling back to the
    /// provider's: nil for an id it cannot read ("laa-monet-local").
    static func readableName(_ value: String) -> String? {
        var raw = value.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        // A routed id: ["opencode-go","deepseek-v4.1-flash"].
        if let data = raw.data(using: .utf8), let route = try? JSONDecoder().decode([String].self, from: data),
           let last = route.last { raw = last }
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
        if lower.hasPrefix("deepseek") { return "DeepSeek V4.1 Flash" }
        // Already a display name ("Opus 5.5", "GPT-6 Astra").
        if raw.contains(" ") && !raw.contains("/") && !raw.contains("[") { return raw }
        return nil
    }
}

/// The effort capsule: the meter and its name, or 「不明」, and the chevron.
/// XHigh and Max carry their metal lines on the rim; when an effort this
/// control asked for is applied, the meter's ticks rise and the rim moves once
/// (LAAEffortLook).
struct LAAEffortCapsule: View {
    let effort: String?
    var current = true
    var changing = false
    @State private var start: Date?

    private var known: String? { effort.flatMap { LAAEffort.name($0) == nil ? nil : $0 } }
    private var ranked: String? { known.flatMap { LAAEffort.order.contains($0) ? $0 : nil } }

    var body: some View {
        TimelineView(.animation(paused: start == nil)) { context in
            capsule(elapsed: start.map { context.date.timeIntervalSince($0) })
        }
        .laaCeremonyTrigger(value: effort, changing: changing, enabled: current && ranked != nil, start: $start)
        .task(id: start) {
            guard let started = start, let ranked else { return }
            try? await Task.sleep(for: .seconds(LAACeremony.duration(effort: ranked)))
            if start == started { start = nil }
        }
    }

    /// The capsule at rest (`elapsed` nil) or that far into its movement.
    /// Internal so a capture can hold a moment of it.
    func capsule(elapsed: Double?) -> some View {
        HStack(spacing: 6) {
            if changing { Text(verbatim: "変更中").font(.caption) }
            if let known {
                LAAEffortLabel(effort: known, current: current, elapsed: elapsed)
            } else {
                Text(verbatim: LAAModelCapsule.unknown).foregroundStyle(LAAColor.secondaryText)
            }
            LAAPickerMetrics.chevronView()
        }
        .lineLimit(1).fixedSize()
        .laaTextStyle(.secondary).foregroundStyle(LAAColor.text)
        .padding(.leading, LAASpacing.x3).padding(.trailing, LAASpacing.x3)
        .frame(minHeight: LAAPickerMetrics.height)
        .contentShape(Capsule())
        .conduitGlassControl(cornerRadius: LAAPickerMetrics.radius, interactive: true)
        .overlay {
            if let ranked {
                LAARimFinish(look: LAAEffortLook(effort: ranked, current: current, elapsed: elapsed).rim,
                             cornerRadius: LAAPickerMetrics.radius)
            }
        }
    }
}

/// Marks the one child of LAANameOrNoneRow that gives way.
private struct LAAGivesWay: LayoutValueKey {
    static let defaultValue = false
}

/// A row of children at their ideal widths; when the offer is narrower than
/// all of them, the one marked LAAGivesWay is left out whole and the row is
/// that much narrower. One measurement per offer, so it settles in one pass.
private struct LAANameOrNoneRow: Layout {
    var spacing: CGFloat

    private func shown(_ proposal: ProposedViewSize, _ subviews: Subviews) -> [Bool] {
        let widths = subviews.map { $0.sizeThatFits(.unspecified).width }
        let full = widths.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1))
        // The offer comes back rounded to the pixel, a hair under the ideal.
        let fits = proposal.width.map { $0 + 1 >= full } ?? true
        return subviews.map { fits || !$0[LAAGivesWay.self] }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let visible = zip(subviews, shown(proposal, subviews)).filter(\.1).map { $0.0.sizeThatFits(.unspecified) }
        let width = visible.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, visible.count - 1))
        return CGSize(width: width, height: visible.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, visible) in zip(subviews, shown(proposal, subviews)) {
            guard visible else {
                subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: .zero)
                continue
            }
            let size = subview.sizeThatFits(.unspecified)
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(size))
            x += size.width + spacing
        }
    }
}
#endif
