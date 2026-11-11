#if LAA_BUILD
import SwiftUI

/// The running model and its effort on one Liquid Glass capsule: the model's
/// face and name, a hairline, then the effort's meter and name. The name gives
/// way when the row is narrow; the effort always stays whole. XHigh and Max
/// take the deep-effort gilt and its light (LAAEffortLabel).
///
/// Display only, and free of Work's and Chat's types, so the Work follow-up
/// row and the chat's composer show the same thing. Every input may be
/// unknown; an unknown one reads 「不明」, never a guess.
///
///     LAAModelEffortChip(model: "claude-opus-5-5", provider: "claude", effort: "xhigh")
///     LAAModelEffortChip(model: nil, provider: "codex", effort: nil)   // GPT の顔 · 不明 · 不明
///
/// Work wraps it in its menu (`interactive: true` adds the chevron) and passes
/// the name its model table gives (`name:`).
struct LAAModelEffortChip: View {
    /// The wire id ("claude-fable-5-2") or a display name ("Fable 5.2").
    let model: String?
    /// The provider id ("claude", "codex", "dsh"); sets the face's family.
    let provider: String?
    /// The applied effort's wire value ("high", "xhigh", "max").
    let effort: String?
    /// A name to show instead of the one read from `model` (a model table's label).
    var name: String? = nil
    /// False when the values are the last confirmed ones, not the current
    /// setting: the name is prefixed 最終確認 and the gilt is withheld.
    var current = true
    /// Draws the menu chevron, for a chip that opens a menu.
    var interactive = false
    /// A plum ▲ before the name: what runs differs from what was asked for.
    var attention = false
    /// 変更中, while a change is being read back.
    var changing = false

    static let unknown = "不明"

    private var modelText: String {
        let shown = name ?? LAAModelEffortChip.displayName(model: model, provider: provider) ?? Self.unknown
        return current ? shown : "最終確認 " + shown
    }
    private var deep: Bool { LAAEffort.isDeep(effort) && current }

    var body: some View {
        HStack(spacing: 6) {
            LAAModelMark(model: model, provider: provider, size: 22)
            if changing { Text(verbatim: "変更中").font(.caption) }
            if attention {
                // ▲ is the house mark for "check this".
                Image(systemName: "triangle.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(LAAColor.attention)
                    .accessibilityHidden(true)
            }
            Text(verbatim: modelText)
                .fontWeight(.semibold).lineLimit(1).truncationMode(.tail)
                .layoutPriority(-1)
            Rectangle().fill(LAAColor.separator).frame(width: 1, height: 16)
                .accessibilityHidden(true)
            if let effort, LAAEffort.name(effort) != nil {
                LAAEffortLabel(effort: effort, current: current)
                    .padding(.horizontal, deep ? 7 : 0).frame(minHeight: 26)
                    .background { if deep { Capsule().fill(LAAColor.deepEffort.opacity(0.13)) } }
                    .padding(.leading, deep ? -4 : 0)
            } else {
                Text(verbatim: Self.unknown)
                    .foregroundStyle(LAAColor.secondaryText)
                    .lineLimit(1).fixedSize()
            }
            if interactive {
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LAAColor.text)
            }
        }
        .laaTextStyle(.secondary).foregroundStyle(LAAColor.text)
        .padding(.leading, 7).padding(.trailing, LAASpacing.x3).frame(minHeight: 36)
        .contentShape(Capsule())
        .conduitGlassControl(cornerRadius: 18, interactive: interactive)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "モデルと推論"))
        .accessibilityValue(Text(verbatim: modelText + " · " + (LAAEffort.name(effort) ?? Self.unknown)))
    }

    /// A model's name from its wire id: "claude-opus-4-8" → "Opus 4.8",
    /// "gpt-6.1-sol" → "GPT 6.1 Sol"; a name already written for people is
    /// kept. Nil when nothing readable is there.
    static func displayName(model: String?, provider: String?) -> String? {
        guard var raw = model?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        // A routed id: ["opencode-go","deepseek-v4.1-flash"].
        if let data = raw.data(using: .utf8), let route = try? JSONDecoder().decode([String].self, from: data),
           let last = route.last { raw = last }
        if raw.hasPrefix("Claude ") { raw = String(raw.dropFirst("Claude ".count)) }
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
        return LAAModelFace.face(model: raw, provider: provider).providerName
    }
}
#endif
