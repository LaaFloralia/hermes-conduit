#if LAA_BUILD
import SwiftUI
import UIKit

/// The effort values and their names, shared by Work and Chat. Rendering
/// only: the wire values ("xhigh") are not changed.
enum LAAEffort {
    static let order = ["low", "medium", "high", "xhigh", "max"]

    static func rank(_ value: String) -> Int { order.firstIndex(of: value) ?? 9 }

    /// XHigh and Max: the two settings that think longest.
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

/// The effort's standing: XHigh carries one metal line on its control's rim,
/// Max two (LAAFinish); Low to High the bare glass.
extension LAAEffort {
    static func finish(_ value: String?) -> LAAFinish {
        switch value {
        case "xhigh": .line
        case "max": .double
        default: .plain
        }
    }
}

/// What the meter looks like at one moment: at rest (`elapsed` nil) or that
/// many seconds into the movement that follows an applied change. In ink at
/// every setting; the number of filled ticks is the setting. In the movement
/// the filled ticks rise one after another on the house `state` curve, all
/// within the control's own movement (LAACeremony).
struct LAAEffortLook {
    let effort: String
    var current = true
    var elapsed: Double? = nil

    var level: Int { LAAEffort.order.firstIndex(of: effort).map { $0 + 1 } ?? 0 }

    private var live: Bool {
        guard current, let elapsed else { return false }
        return elapsed < LAACeremony.duration(effort: effort)
    }

    /// Nil for an unfilled tick.
    func tick(_ index: Int) -> Color? {
        guard index < level else { return nil }
        return current ? LAAColor.text : LAAColor.secondaryText
    }

    /// A filled tick grows from a fifth of its height.
    func tickScale(_ index: Int) -> CGFloat {
        guard live, index < level, let elapsed else { return 1 }
        let rise = LAACeremony.duration(effort: effort) - LAACeremony.riseStagger * Double(max(0, level - 1))
        let p = (elapsed - LAACeremony.riseStagger * Double(index)) / max(rise, 0.01)
        return 0.2 + 0.8 * CGFloat(LAACeremony.state(p))
    }

    /// The rim of the effort's control at this moment.
    var rim: LAARimLook {
        LAARimLook(finish: current ? LAAEffort.finish(effort) : .plain,
                   motion: LAACeremony.motion(effort: effort) ?? .pass(turn: 1),
                   elapsed: current ? elapsed : nil)
    }
}

/// How hard the model thinks, drawn from the value itself: five rising ticks,
/// filled up to the setting (Low one, Max all five), in ink on the rule.
struct LAAEffortMeter: View {
    let effort: String
    var height: CGFloat = 13
    var current = true
    var elapsed: Double? = nil

    var body: some View {
        let look = LAAEffortLook(effort: effort, current: current, elapsed: elapsed)
        let tick = max(2, height * 0.2)
        HStack(alignment: .bottom, spacing: max(1.2, height * 0.11)) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(look.tick(index) ?? LAAColor.separator)
                    .frame(width: tick, height: height * (0.36 + 0.16 * CGFloat(index)))
                    .scaleEffect(x: 1, y: look.tickScale(index), anchor: .bottom)
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// The effort beside the model: the meter and its name, in ink. `elapsed` is
/// set by the effort capsule while its movement plays; everywhere else the
/// label rests.
struct LAAEffortLabel: View {
    let effort: String
    var current = true
    var meterHeight: CGFloat = 13
    var elapsed: Double? = nil

    var body: some View {
        HStack(spacing: 5) {
            LAAEffortMeter(effort: effort, height: meterHeight, current: current, elapsed: elapsed)
            Text(verbatim: LAAEffort.name(effort) ?? effort)
                .fontWeight(.medium)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// The effort rows of a menu. The system draws a menu's text in one ink and
/// does not animate it, so each row carries the meter itself as its small
/// picture at the row's end, and the deep settings a short line under the name.
enum LAAEffortMenu {
    @MainActor
    static func icon(_ effort: String, scheme: ColorScheme, scale: CGFloat) -> Image? {
        guard LAAEffort.order.contains(effort) else { return nil }
        let renderer = ImageRenderer(content: LAAEffortMeter(effort: effort, height: 14)
            .padding(1)
            .environment(\.colorScheme, scheme))
        renderer.scale = scale
        guard let image = renderer.uiImage else { return nil }
        // Original rendering keeps the filled and empty ticks apart: a template image would fill all five.
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
