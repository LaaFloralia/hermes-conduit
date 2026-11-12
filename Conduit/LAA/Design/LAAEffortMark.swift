#if LAA_BUILD
import SwiftUI
import UIKit

/// The effort values and their names, shared by Work and Chat. Rendering
/// only: the wire values ("xhigh") are not changed.
enum LAAEffort {
    static let order = ["low", "medium", "high", "xhigh", "max"]

    static func rank(_ value: String) -> Int { order.firstIndex(of: value) ?? 9 }

    /// XHigh and Max: the two settings that think longest, drawn in the deep
    /// effort colour wherever an effort is shown.
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

/// How hard the model thinks, drawn from the value itself: five rising ticks,
/// filled up to the setting (Low one, Max all five). XHigh and Max fill in
/// the deep-effort gilt; Max adds a small spark above its last tick.
struct LAAEffortMeter: View {
    let effort: String
    var height: CGFloat = 13
    var current = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var level: Int {
        LAAEffort.order.firstIndex(of: effort).map { $0 + 1 } ?? 0
    }
    private var deep: Bool { LAAEffort.isDeep(effort) }
    private var ink: Color {
        guard current else { return LAAColor.secondaryText }
        return deep ? LAAColor.deepEffort : LAAColor.text
    }

    var body: some View {
        let tick = max(2, height * 0.2)
        HStack(alignment: .bottom, spacing: max(1.2, height * 0.11)) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(index < level ? ink : LAAColor.secondaryText.opacity(0.28))
                    .frame(width: tick, height: height * (0.36 + 0.16 * CGFloat(index)))
            }
        }
        .frame(height: height, alignment: .bottom)
        .overlay(alignment: .topTrailing) {
            if effort == "max" && current {
                spark.offset(x: tick * 1.2, y: -height * 0.42)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var spark: some View {
        let glyph = Image(systemName: "sparkle")
            .font(.system(size: height * 0.5, weight: .bold))
            .foregroundStyle(LAAColor.deepEffort)
        if #available(iOS 18.0, *), !reduceMotion {
            glyph.symbolEffect(.breathe.pulse.byLayer, options: .repeat(.periodic(delay: 2.4)))
        } else {
            glyph
        }
    }
}

/// The effort beside the model: the meter and its name. A deep setting takes
/// the gilt and a light that passes over it once when it appears or changes,
/// as a reflection on the glass would; Reduce Motion keeps it still.
struct LAAEffortLabel: View {
    let effort: String
    var current = true
    var meterHeight: CGFloat = 13
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep: CGFloat = -1

    private var deep: Bool { LAAEffort.isDeep(effort) && current }
    private var name: String { LAAEffort.name(effort) ?? effort }

    var body: some View {
        HStack(spacing: 5) {
            LAAEffortMeter(effort: effort, height: meterHeight, current: current)
            Text(verbatim: name)
                .fontWeight(deep ? .semibold : .medium)
                .foregroundStyle(deep ? LAAColor.deepEffort : (current ? LAAColor.text : LAAColor.secondaryText))
                .lineLimit(1)
                .fixedSize()
        }
        .overlay { if deep && !reduceMotion { sheen } }
        .onAppear { play() }
        .onChange(of: effort) { _, _ in play() }
    }

    /// A narrow band of light, masked to the meter and the word, so only the
    /// gilt itself catches it.
    private var sheen: some View {
        GeometryReader { proxy in
            LinearGradient(colors: [.clear, .white.opacity(0.55), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: proxy.size.width * 0.45)
                .offset(x: sweep * proxy.size.width)
                .blendMode(.plusLighter)
        }
        .mask {
            HStack(spacing: 5) {
                LAAEffortMeter(effort: effort, height: meterHeight, current: current)
                Text(verbatim: name).fontWeight(.semibold).lineLimit(1).fixedSize()
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func play() {
        guard deep, !reduceMotion else { return }
        sweep = -0.5
        withAnimation(.easeInOut(duration: 1.1).delay(0.15)) { sweep = 1.1 }
    }
}

/// The effort rows of a menu. The system draws a menu's text in one ink, so a
/// deep setting is told apart by its own coloured mark (a spark for XHigh, two
/// for Max) and a short line under the name.
enum LAAEffortMenu {
    static func icon(_ effort: String) -> Image? {
        let name: String
        switch effort {
        case "xhigh": name = "sparkle"
        case "max": name = "sparkles"
        default: return nil
        }
        let configuration = UIImage.SymbolConfiguration(weight: .semibold)
        guard let symbol = UIImage(systemName: name, withConfiguration: configuration) else { return nil }
        // Original rendering keeps the gilt: a template image takes the menu's ink.
        return Image(uiImage: symbol.withTintColor(UIColor(LAAColor.deepEffort), renderingMode: .alwaysOriginal))
    }

    static func subtitle(_ effort: String) -> String? {
        switch effort {
        case "xhigh": "より深く考える"
        case "max": "最も深く考える"
        default: nil
        }
    }

    /// One effort row: a Toggle, so the system draws the current value's check
    /// at the leading edge and the deep mark keeps the trailing one.
    struct Row: View {
        let effort: String
        let selected: Bool
        var identifier: String? = nil
        let choose: () -> Void

        var body: some View {
            Toggle(isOn: Binding(get: { selected }, set: { on in if on { choose() } })) {
                Label {
                    Text(verbatim: LAAEffort.name(effort) ?? effort)
                    if let subtitle = LAAEffortMenu.subtitle(effort) { Text(verbatim: subtitle) }
                } icon: {
                    if let icon = LAAEffortMenu.icon(effort) { icon }
                }
            }
            .accessibilityIdentifier(identifier ?? "work.session.effort.\(effort)")
        }
    }
}
#endif
