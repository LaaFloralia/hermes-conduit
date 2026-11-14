#if LAA_BUILD
import SwiftUI

/// How much light the glass holds at rest (owner, 2026-11-14: no colour on
/// selection; keep the Liquid Glass and make it quietly luxurious). Standing
/// is told by light and material, never by hue or an outline: plain glass;
/// polished glass, a touch denser, with a soft light along its top and a short
/// glint under the top edge; crystal glass, denser again, with a long glint
/// and the light caught a second time off its floor, so it reads thicker.
enum LAAFinish: Int, Comparable {
    case plain = 0, polished = 1, crystal = 2
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
        case .mythos: .crystal
        case .fable, .astra: .polished
        case .none: .plain
        }
    }
}

/// One pass of light through the glass when an applied value arrives, with
/// the house timing and easing (tokens.json motion).
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
    /// Plain models pass the light in the gentle time; the polished and the
    /// crystal ones take the slow one, the crystal with its second reflection.
    static func duration(rank: LAAModelRank) -> Double { rank.finish == .plain ? gentle : slow }
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

/// The glass at one moment: at rest (`elapsed` nil) or that many seconds
/// into the pass of light that follows an applied change.
struct LAAGlassLook: Equatable {
    let finish: LAAFinish
    var elapsed: Double? = nil
    var duration: Double = LAACeremony.slow

    /// 0...1 through the pass, nil at rest or once it is over.
    var progress: Double? {
        guard let elapsed, duration > 0, elapsed < duration else { return nil }
        return min(1, max(0, elapsed / duration))
    }

    /// How far the standing light has settled: it arrives behind the pass.
    var settled: Double { progress.map { LAACeremony.state($0) } ?? 1 }

    /// The pass's centre across the capsule (0 the leading end, 1 the
    /// trailing), entering and leaving outside the glass.
    func sweep(lag: Double = 0) -> Double? {
        guard let progress else { return nil }
        return -0.3 + 1.6 * LAACeremony.state(max(0, progress - lag))
    }

    /// The pass's strength: it comes up quickly and fades over its last
    /// quarter. Every value moves, the crystal most.
    var sweepStrength: Double {
        guard let progress else { return 0 }
        let rise = min(1, progress / 0.12)
        let fall = progress < 0.75 ? 1 : max(0, 1 - (progress - 0.75) / 0.25)
        let level: Double = switch finish {
        case .plain: 0.6
        case .polished: 0.8
        case .crystal: 1
        }
        return level * rise * fall
    }

    /// The crystal's second, fainter reflection, a beat behind the first.
    var echoStrength: Double { finish == .crystal ? 0.45 * sweepStrength : 0 }

    /// The glass body: on the paper a touch of smoke, so the light in it can
    /// show; on the dark a touch of lift. Crystal is the denser glass.
    func body(dark: Bool) -> Double {
        let rest: Double = switch finish {
        case .plain: 0
        case .polished: dark ? 0.04 : 0.045
        case .crystal: dark ? 0.07 : 0.085
        }
        return rest * settled
    }

    /// The soft light held along the top at rest.
    func topLight(dark: Bool) -> Double {
        let rest: Double = switch finish {
        case .plain: 0
        case .polished: dark ? 0.10 : 0.7
        case .crystal: dark ? 0.18 : 0.9
        }
        return rest * settled
    }

    /// The glint under the top edge: short on polished glass, long on crystal.
    func glint(dark: Bool) -> Double {
        let rest: Double = switch finish {
        case .plain: 0
        case .polished: dark ? 0.4 : 0.9
        case .crystal: dark ? 0.6 : 1
        }
        return rest * settled
    }

    /// Glint length as a share of the capsule's width.
    var glintLength: Double { finish == .crystal ? 0.5 : 0.28 }

    /// Crystal only: the light caught again off the inner floor, low at the
    /// trailing end, the sign of thick glass.
    func counterGlint(dark: Bool) -> Double { finish == .crystal ? (dark ? 0.35 : 0.8) * settled : 0 }
}

/// The light is drawn inside the native glass and clipped to it, behind the
/// label: no outline, colour, shadow or movement outside the control.
private struct LAAGlassSelection: ViewModifier {
    let look: LAAGlassLook
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var still: LAAGlassLook { reduceMotion ? .init(finish: look.finish) : look }
    private var dark: Bool { scheme == .dark }
    private var shape: RoundedRectangle { .init(cornerRadius: cornerRadius, style: .continuous) }

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background {
                shape.fill(LAAColor.surface)
                    .overlay { light.clipShape(shape) }
            }
        } else {
            content
                .background { light.clipShape(shape).allowsHitTesting(false).accessibilityHidden(true) }
                .conduitGlassControl(cornerRadius: cornerRadius, tint: .clear, interactive: true)
        }
    }

    private var light: some View {
        LAAGlassLight(look: still, dark: dark)
    }
}

/// What the glass holds: its body, the soft top light and the glints, and,
/// while a value arrives, the pass of light (two for the crystal).
private struct LAAGlassLight: View {
    let look: LAAGlassLook
    let dark: Bool

    /// The light: the light surface on the paper, the paper ink on the dark.
    private var glassLight: Color { dark ? LAAColor.text : LAAColor.surface }
    /// The glass's own shade: ink on the paper, the dark ground on the dark.
    private var shade: Color { dark ? LAAColor.background : LAAColor.text }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                if look.finish != .plain {
                    Rectangle().fill((dark ? glassLight : shade).opacity(look.body(dark: dark)))
                    LinearGradient(stops: [.init(color: glassLight.opacity(look.topLight(dark: dark)), location: 0),
                                           .init(color: glassLight.opacity(0), location: 0.5)],
                                   startPoint: .top, endPoint: .bottom)
                    glint(look.glint(dark: dark), from: 0.14, length: look.glintLength, y: 2.5, size: size)
                }
                if look.finish == .crystal {
                    glint(look.counterGlint(dark: dark), from: 0.64, length: 0.2, y: size.height - 4, size: size)
                }
                if let at = look.sweep() {
                    pass(at: at, strength: look.sweepStrength, size: size)
                }
                if let at = look.sweep(lag: 0.16), look.echoStrength > 0 {
                    pass(at: at, strength: look.echoStrength, size: size, narrow: true)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
    }

    /// A fine line of light that fades at both ends.
    private func glint(_ strength: Double, from: Double, length: Double, y: CGFloat, size: CGSize) -> some View {
        Capsule()
            .fill(LinearGradient(stops: [.init(color: glassLight.opacity(0), location: 0),
                                         .init(color: glassLight.opacity(strength), location: 0.4),
                                         .init(color: glassLight.opacity(0), location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(width: size.width * length, height: 1.5)
            .offset(x: size.width * from, y: y)
    }

    /// A slanted band of light across the glass. On the paper it is framed by
    /// a touch of shade, as a reflection on polished glass over a light ground.
    private func pass(at x: Double, strength: Double, size: CGSize, narrow: Bool = false) -> some View {
        let width = size.width * (narrow ? 0.12 : 0.22)
        let core = (dark ? 0.5 : 1) * strength
        let edge = (dark ? 0 : 0.08) * strength
        return Rectangle()
            .fill(LinearGradient(stops: [.init(color: shade.opacity(0), location: 0),
                                         .init(color: shade.opacity(edge), location: 0.22),
                                         .init(color: glassLight.opacity(core), location: 0.5),
                                         .init(color: shade.opacity(edge), location: 0.78),
                                         .init(color: shade.opacity(0), location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(width: width, height: size.height * 2)
            .rotationEffect(.degrees(16))
            .position(x: size.width * x, y: size.height / 2)
    }
}

extension View {
    func laaGlassSelection(finish: LAAFinish, elapsed: Double?, duration: Double = LAACeremony.slow,
                           cornerRadius: CGFloat) -> some View {
        modifier(LAAGlassSelection(look: .init(finish: finish, elapsed: elapsed, duration: duration),
                                   cornerRadius: cornerRadius))
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
