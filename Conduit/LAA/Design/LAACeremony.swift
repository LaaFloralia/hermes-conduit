#if LAA_BUILD
import SwiftUI

/// Colour lives inside the glass. The owner replaced the old metal outlines
/// with a violet wash on 2026-11-14; Mythos and Max carry the deepest tint.
enum LAAFinish: Int, Comparable {
    case plain = 0, tinted = 1, intense = 2
    static func < (lhs: LAAFinish, rhs: LAAFinish) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum LAAModelRank: Equatable {
    case mythos, fable, astra, none
    static func of(_ model: String?) -> LAAModelRank {
        let raw = (model ?? "").lowercased()
        if raw.contains("mythos") { return .mythos }
        if raw.contains("fable") { return .fable }
        if raw.contains("astra") { return .astra }
        return .none
    }
    var finish: LAAFinish {
        switch self {
        case .mythos: .intense
        case .fable, .astra: .tinted
        case .none: .plain
        }
    }
}

/// A single spreading wash on selection, with the house timing and easing.
enum LAACeremony {
    static let base: Double = 0.22
    static let gentle: Double = 0.30
    static let slow: Double = 0.42
    static let riseStagger: Double = 0.04
    static func duration(effort: String) -> Double {
        switch effort {
        case "low": base
        case "medium": gentle
        case "high", "xhigh", "max", "ultracode": slow
        default: 0
        }
    }
    static func duration(rank: LAAModelRank) -> Double { slow }
    /// The house `state` curve (tokens.json motion.easing).
    static func state(_ x: Double) -> Double { bezier(x, 0.25, 0.9, 0.3, 1) }

    private static func bezier(_ t: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        let t = min(1, max(0, t))
        var u = t
        for _ in 0..<8 {
            let x = 3 * x1 * u * (1 - u) * (1 - u) + 3 * x2 * u * u * (1 - u) + u * u * u - t
            let d = 3 * x1 * (1 - u) * (1 - u) + 6 * (x2 - x1) * u * (1 - u) + 3 * (1 - x2) * u * u
            if abs(d) < 1e-6 { break }
            u = min(1, max(0, u - x / d))
        }
        return 3 * y1 * u * (1 - u) * (1 - u) + 3 * y2 * u * u * (1 - u) + u * u * u
    }
}

struct LAALiquidLook: Equatable {
    let finish: LAAFinish
    var elapsed: Double? = nil

    var progress: Double? {
        guard let elapsed, elapsed < LAACeremony.slow else { return nil }
        return min(1, max(0, elapsed / LAACeremony.slow))
    }
    var bloom: Double { progress.map { sin(.pi * $0) } ?? 0 }
    var spread: Double { progress.map { 0.12 + 1.88 * LAACeremony.state($0) } ?? 2 }
    func opacity(dark: Bool) -> Double {
        let strength: Double = switch finish {
        case .plain: 0
        case .tinted: dark ? 0.26 : 0.16
        case .intense: dark ? 0.46 : 0.30
        }
        return strength + (finish == .plain ? 0 : 0.10 * bloom)
    }
    static func violet(dark: Bool) -> Color {
        dark ? Color(red: 0.66, green: 0.48, blue: 0.95)
             : Color(red: 0.49, green: 0.30, blue: 0.78)
    }
}

/// The wash is behind the label and clipped inside the native glass. There
/// is no drawn outline, pattern, shadow or animation outside the control.
private struct LAALiquidSelection: ViewModifier {
    let look: LAALiquidLook
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var still: LAALiquidLook { reduceMotion ? .init(finish: look.finish) : look }
    private var dark: Bool { scheme == .dark }
    private var violet: Color { LAALiquidLook.violet(dark: dark) }
    private var shape: RoundedRectangle { .init(cornerRadius: cornerRadius, style: .continuous) }

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background {
                shape.fill(LAAColor.surface)
                    .overlay { shape.fill(violet.opacity(still.opacity(dark: dark))) }
            }
        } else {
            content
                .background { wash.clipShape(shape).allowsHitTesting(false).accessibilityHidden(true) }
                .conduitGlassControl(cornerRadius: cornerRadius,
                                     tint: violet.opacity(still.opacity(dark: dark)), interactive: true)
        }
    }

    private var wash: some View {
        GeometryReader { proxy in
            if still.finish != .plain {
                // A broad pool of colour swells from the leading edge, then
                // settles into the tint. It never traverses the rim.
                RadialGradient(colors: [violet.opacity(0.32 * still.bloom), .clear],
                               center: .init(x: 0.18, y: 0.7), startRadius: 0,
                               endRadius: max(1, proxy.size.width * still.spread))
            }
        }
    }
}

extension View {
    func laaLiquidSelection(finish: LAAFinish, elapsed: Double?, cornerRadius: CGFloat) -> some View {
        modifier(LAALiquidSelection(look: .init(finish: finish, elapsed: elapsed), cornerRadius: cornerRadius))
    }
}

/// Starts a ceremony when an applied value arrives, never for a value only
/// chosen. The capsules get no event of their own, so the change itself is
/// the trigger, and only one this control asked for: the value must change
/// while `changing` is on or within a short grace after it ends. Opening
/// another session or chat, which swaps the value without a request, stays
/// still. Unknown values, last-confirmed values and Reduce Motion never
/// start one: the new face simply shows.
struct LAACeremonyTrigger<Value: Equatable>: ViewModifier {
    let value: Value
    let changing: Bool
    let enabled: Bool
    @Binding var start: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pending = false
    @State private var graceUntil: Date = .distantPast

    /// How long after "変更中" ends an arriving value still counts as the answer.
    static var grace: TimeInterval { 3 }

    func body(content: Content) -> some View {
        content
            .onChange(of: changing) { _, now in
                if now {
                    pending = false
                } else {
                    graceUntil = Date().addingTimeInterval(Self.grace)
                    if pending { pending = false; play() }
                }
            }
            .onChange(of: value) { old, new in
                guard old != new else { return }
                if changing { pending = true; return }
                if Date() < graceUntil { graceUntil = .distantPast; play() }
            }
    }

    private func play() {
        guard enabled, !reduceMotion else { return }
        start = Date()
    }
}

extension View {
    func laaCeremonyTrigger<Value: Equatable>(value: Value, changing: Bool, enabled: Bool,
                                              start: Binding<Date?>) -> some View {
        modifier(LAACeremonyTrigger(value: value, changing: changing, enabled: enabled, start: start))
    }
}
#endif
