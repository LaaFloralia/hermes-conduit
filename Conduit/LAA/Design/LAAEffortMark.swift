#if LAA_BUILD
import SwiftUI
import UIKit

/// The effort values and their names, shared by Work and Chat. Rendering
/// only: the wire values ("xhigh") are not changed.
enum LAAEffort {
    static let order = ["low", "medium", "high", "xhigh", "max"]

    static func rank(_ value: String) -> Int { order.firstIndex(of: value) ?? 9 }

    /// XHigh and Max: the two settings that think longest, drawn in colour
    /// wherever an effort is shown.
    static func isDeep(_ value: String?) -> Bool { value == "xhigh" || value == "max" }

    /// The effort kept when the model changes: the same one if the new model
    /// has it, else High, else the nearest by rank (the lower on a tie). Nil
    /// only when the new model offers none.
    static func carried(_ effort: String?, into available: [String]) -> String? {
        if let effort, available.contains(effort) { return effort }
        if available.contains("high") { return "high" }
        let target = rank(effort ?? "high") == 9 ? rank("high") : rank(effort ?? "high")
        return available.min { lhs, rhs in
            let left = abs(rank(lhs) - target), right = abs(rank(rhs) - target)
            return left != right ? left < right : rank(lhs) < rank(rhs)
        }
    }

    static func name(_ raw: String?) -> String? {
        switch raw {
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "XHigh"
        case "max": return "Max"
        case let value?: return value.isEmpty ? nil : value
        case nil: return nil
        }
    }
}

/// What the meter and the name look like at one moment: at rest (`elapsed`
/// nil) or that many seconds into the ceremony that follows an applied
/// change. The meter's five ticks come first, then the name's letters, so a
/// light or a colour runs across both as one line, left to right.
///
/// At rest: Low to High in ink; XHigh in gilt; Max in five colours, one per
/// tick, carried on into the letters. In the ceremony the filled ticks rise
/// one after another; High has one teal light pass over its letters; XHigh
/// a lighter gilt passes twice over ticks and letters; Max's colours flow
/// right while a lighter light passes twice over them, then settle exactly
/// on the resting colours.
struct LAAEffortLook {
    let effort: String
    let name: String
    var current = true
    var elapsed: Double? = nil

    private var level: Int { LAAEffort.order.firstIndex(of: effort).map { $0 + 1 } ?? 0 }
    private var cells: Int { 5 + name.count }
    private var live: Bool {
        guard current, let elapsed else { return false }
        return elapsed < LAACeremony.duration(effort: effort)
    }
    private var flow: [Color] { LAACeremonyColor.flow }

    /// Max's colour shift, in cells; a whole number of turns at the end.
    private var shift: Int {
        guard live, effort == "max", let elapsed else { return 0 }
        let turns = flow.count * LAACeremony.maxCycles
        return min(turns, Int(elapsed / (LAACeremony.duration(effort: "max") / Double(turns))))
    }

    /// The cell the passing light is on, if any.
    private var lit: Int? {
        guard live, let elapsed else { return nil }
        switch effort {
        case "high":
            let k = Int(floor((elapsed - LAACeremony.highDelay) / LAACeremony.highStep))
            return (0..<name.count).contains(k) ? 5 + k : nil
        case "xhigh":
            let k = Int(floor((elapsed - LAACeremony.xhighDelay) / LAACeremony.xhighStep))
            return (0..<cells * LAACeremony.xhighPasses).contains(k) ? k % cells : nil
        case "max":
            let step = LAACeremony.duration(effort: "max") / Double(flow.count * LAACeremony.maxCycles)
            let k = Int(elapsed / step)
            return k < cells * 2 ? k % cells : nil
        default:
            return nil
        }
    }

    private func base(_ cell: Int) -> Color {
        guard current else { return LAAColor.secondaryText }
        switch effort {
        case "xhigh": return LAAColor.deepEffort
        case "max":
            let n = flow.count
            return flow[((cell - shift) % n + n) % n]
        default: return LAAColor.text
        }
    }

    private func color(_ cell: Int) -> Color {
        guard cell == lit else { return base(cell) }
        switch effort {
        case "high": return LAAColor.link
        case "xhigh": return LAACeremonyColor.giltLight
        default:
            let n = flow.count
            return LAACeremonyColor.flowLight[((cell - shift) % n + n) % n]
        }
    }

    /// Nil for an unfilled tick.
    func tick(_ index: Int) -> Color? { index < level ? color(index) : nil }

    func letter(_ index: Int) -> Color { color(5 + index) }

    /// A filled tick grows from a fifth of its height with the house `pop`.
    func tickScale(_ index: Int) -> CGFloat {
        guard live, index < level, let elapsed else { return 1 }
        let p = (elapsed - LAACeremony.riseStagger * Double(index)) / LAACeremony.rise
        return 0.2 + 0.8 * CGFloat(LAACeremony.pop(p))
    }

    /// The deep settings tint their capsule; the tint swells once in the ceremony.
    var tint: Double {
        guard current, LAAEffort.isDeep(effort) else { return 0 }
        guard live, let elapsed else { return 0.10 }
        return 0.10 + 0.10 * sin(.pi * min(1, elapsed / LAACeremony.duration(effort: effort)))
    }
}

/// How hard the model thinks, drawn from the value itself: five rising ticks,
/// filled up to the setting (Low one, Max all five), in the colours of
/// LAAEffortLook.
struct LAAEffortMeter: View {
    let effort: String
    var height: CGFloat = 13
    var current = true
    var elapsed: Double? = nil

    var body: some View {
        let look = LAAEffortLook(effort: effort, name: LAAEffort.name(effort) ?? effort,
                                 current: current, elapsed: elapsed)
        let tick = max(2, height * 0.2)
        HStack(alignment: .bottom, spacing: max(1.2, height * 0.11)) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(look.tick(index) ?? LAAColor.secondaryText.opacity(0.28))
                    .frame(width: tick, height: height * (0.36 + 0.16 * CGFloat(index)))
                    .scaleEffect(x: 1, y: look.tickScale(index), anchor: .bottom)
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// The effort beside the model: the meter and its name. `elapsed` is set by
/// the effort capsule while its ceremony plays; everywhere else the label
/// rests (XHigh's gilt and Max's five colours stay, without motion).
struct LAAEffortLabel: View {
    let effort: String
    var current = true
    var meterHeight: CGFloat = 13
    var elapsed: Double? = nil

    private var deep: Bool { LAAEffort.isDeep(effort) && current }
    private var name: String { LAAEffort.name(effort) ?? effort }

    var body: some View {
        let look = LAAEffortLook(effort: effort, name: name, current: current, elapsed: elapsed)
        HStack(spacing: 5) {
            LAAEffortMeter(effort: effort, height: meterHeight, current: current, elapsed: elapsed)
            Text.laaLetters(name) { look.letter($0) }
                .fontWeight(deep ? .semibold : .medium)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// The effort rows of a menu. The system draws a menu's text in one ink and
/// does not animate it, so each row carries the meter itself as its picture,
/// in its resting colours (Max's five, XHigh's gilt), and the deep settings
/// a short line under the name.
enum LAAEffortMenu {
    @MainActor
    static func icon(_ effort: String, scheme: ColorScheme, scale: CGFloat) -> Image? {
        guard LAAEffort.order.contains(effort) else { return nil }
        let renderer = ImageRenderer(content: LAAEffortMeter(effort: effort, height: 14)
            .padding(1)
            .environment(\.colorScheme, scheme))
        renderer.scale = scale
        guard let image = renderer.uiImage else { return nil }
        // Original rendering keeps the colours: a template image takes the menu's ink.
        return Image(uiImage: image.withRenderingMode(.alwaysOriginal))
    }

    static func subtitle(_ effort: String) -> String? {
        switch effort {
        case "xhigh": "より深く考える"
        case "max": "最も深く考える"
        default: nil
        }
    }

    /// One effort row: a Toggle, so the system draws the current value's check
    /// at the leading edge and the meter keeps the trailing one.
    struct Row: View {
        let effort: String
        let selected: Bool
        var identifier: String? = nil
        let choose: () -> Void
        @Environment(\.colorScheme) private var scheme
        @Environment(\.displayScale) private var scale

        var body: some View {
            Toggle(isOn: Binding(get: { selected }, set: { on in if on { choose() } })) {
                Label {
                    Text(verbatim: LAAEffort.name(effort) ?? effort)
                    if let subtitle = LAAEffortMenu.subtitle(effort) { Text(verbatim: subtitle) }
                } icon: {
                    if let icon = LAAEffortMenu.icon(effort, scheme: scheme, scale: scale) { icon }
                }
            }
            .accessibilityIdentifier(identifier ?? "work.session.effort.\(effort)")
        }
    }
}
#endif
