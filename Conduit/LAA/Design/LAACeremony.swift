#if LAA_BUILD
import SwiftUI

/// How much light the glass holds (owner, 2026-11-14 21:45, narrowed at
/// 22:00): a strong model or effort keeps the Liquid Glass, uncoloured, and
/// carries the Thinking orb's fine particles inside it, more of them at the
/// higher step. Standing is told by light, never by hue or an outline: plain
/// glass holds none; polished glass slow particles, a soft top light and a
/// short glint; crystal more and brighter particles, a long glint and the
/// light caught a second time off its floor.
enum LAAFinish: Int, Comparable {
    case plain = 0, polished = 1, crystal = 2
    static func < (lhs: LAAFinish, rhs: LAAFinish) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Mythos is crystal; Fable and Astra polished; every other model plain.
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

/// The movement when an applied value arrives, with the house timing and
/// easing (tokens.json motion).
enum LAACeremony {
    static let base: Double = 0.22
    static let gentle: Double = 0.30
    static let slow: Double = 0.42
    static func duration(effort: String) -> Double {
        switch effort {
        case "low": base
        case "medium": gentle
        case "high", "xhigh", "max", "ultracode": slow
        default: 0
        }
    }
    /// Plain models pass the light in the gentle time, the others in the slow one.
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

/// The glass at one moment: at rest (`elapsed` nil) or that many seconds into
/// the movement that follows an applied change. `time` is the particles'
/// clock in seconds; nil keeps the glass still (Reduce Motion, Low Power
/// Mode): only its standing gloss shows, no particle.
struct LAAGlassLook: Equatable {
    let finish: LAAFinish
    var elapsed: Double? = nil
    var duration: Double = LAACeremony.slow
    var time: Double? = nil

    /// 0...1 through the movement, nil at rest or once it is over.
    var progress: Double? {
        guard let elapsed, duration > 0, elapsed < duration else { return nil }
        return min(1, max(0, elapsed / duration))
    }

    /// How far the standing light has settled: it arrives behind the front.
    var settled: Double { progress.map { LAACeremony.state($0) } ?? 1 }

    /// The front of light across the capsule (0 the leading end, 1 the
    /// trailing), entering and leaving outside the glass. The particles it
    /// passes flare; it draws no band of its own.
    var front: Double? {
        guard let progress else { return nil }
        return -0.2 + 1.4 * LAACeremony.state(progress)
    }

    /// The front's strength: up quickly, gone over its last quarter, the
    /// crystal's the strongest. Plain glass shows none.
    var frontStrength: Double {
        guard let progress else { return 0 }
        let rise = min(1, progress / 0.12)
        let fall = progress < 0.75 ? 1 : max(0, 1 - (progress - 0.75) / 0.25)
        let level: Double = switch finish {
        case .plain: 0.6
        case .polished: 0.85
        case .crystal: 1
        }
        return level * rise * fall
    }

    /// The glass body: on the paper a touch of smoke, so the light in it can
    /// show; on the dark a touch of lift.
    func body(dark: Bool) -> Double {
        let rest: Double = switch finish {
        case .plain: 0
        case .polished: dark ? 0.04 : 0.045
        case .crystal: dark ? 0.07 : 0.085
        }
        return rest * settled
    }

    /// The soft light held along the top.
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
    var glintLength: Double {
        finish == .crystal ? 0.5 : 0.28
    }

    /// Crystal only: the light caught again off the inner floor.
    func counterGlint(dark: Bool) -> Double { finish == .crystal ? (dark ? 0.35 : 0.8) * settled : 0 }

    /// The particles at this moment, for a capsule of `size`.
    func grains(in size: CGSize) -> [LAAGlassParticles.Grain] {
        guard let time else { return [] }
        return LAAGlassParticles.grains(finish: finish, size: size, time: time, front: front,
                                        frontStrength: frontStrength, settled: settled)
    }
}

/// The fine light inside the glass, of the same kind as the Thinking orb's
/// (LAAParticleOrb): short streaks that taper at both ends and round grains,
/// each flaring and fading over a few seconds while it drifts slowly along the
/// capsule, most of them near the rims so the label stays clear. Every grain
/// is a pure function of the moment, so any instant can be drawn and captured.
enum LAAGlassParticles {
    struct Grain: Equatable {
        /// Centre, in points from the capsule's top leading corner.
        var x: Double
        var y: Double
        /// Along the grain's motion; a round grain has length 0.
        var length: Double
        var width: Double
        /// 0...1, before the scheme's own strength.
        var alpha: Double
        /// One of the few brighter grains that carry a soft halo.
        var sparkle: Bool
    }

    /// Particles per 100 pt of capsule width at rest.
    static func density(_ finish: LAAFinish) -> Double {
        switch finish {
        case .plain: 0
        case .polished: 12
        case .crystal: 18
        }
    }

    /// How bright the particles burn at rest.
    static func brightness(_ finish: LAAFinish) -> Double {
        switch finish {
        case .plain: 0
        case .polished: 0.8
        case .crystal: 1
        }
    }

    /// The short burst of grains the front carries across polished and crystal glass.
    static let frontDensity: Double = 9

    static func grains(finish: LAAFinish, size: CGSize, time: Double, front: Double?,
                       frontStrength: Double, settled: Double) -> [Grain] {
        let w = Double(size.width), h = Double(size.height)
        guard w > 1, h > 1 else { return [] }
        let resting = Int((density(finish) * w / 100).rounded())
        // Plain glass holds no particle, not even in the front (owner, 2026-11-14 22:00).
        let burst = front == nil || finish == .plain ? 0 : Int((frontDensity * w / 100).rounded())
        let shine = brightness(finish) * settled
        var out: [Grain] = []
        out.reserveCapacity(resting + burst)
        for i in 0..<(resting + burst) {
            let isBurst = i >= resting
            let id = UInt64(i) &+ (isBurst ? 50_000 : 0)
            // Each grain lives 3.2...5.6 s, then comes back elsewhere.
            let life = 3.2 + 2.4 * hash(id, 0)
            let clock = time / life + hash(id, 1)
            let cycle = floor(clock), u = clock - cycle
            let s = id &* 977 &+ UInt64(max(0, cycle)) &* 7919
            // Drift slowly toward the trailing end, a little up or down.
            let speed = 3 + 5 * hash(s, 3)
            var x = hash(s, 2) * w + speed * (u - 0.5) * life
            // The grains keep to the bands along the top and bottom rims,
            // where the glass catches light, clear of the label between them.
            let lane = hash(s, 4) < 0.55 ? 0.08 + 0.15 * hash(s, 5) : 0.77 + 0.15 * hash(s, 5)
            let y = h * lane + 0.6 * sin(2 * .pi * (u + hash(s, 6)))
            // Flare and fade (the orb's envelope), dimmer toward the ends.
            var alpha = pow(sin(.pi * u), 0.8) * (0.55 + 0.45 * hash(s, 7))
            if isBurst {
                // The burst lives only around the front.
                x = hash(s, 2) * w
                alpha = 0.9 * (0.6 + 0.4 * hash(s, 7))
            }
            let sparkle = hash(s, 8) < (isBurst ? 0.25 : 0.12)
            let edge = min(x, w - x)
            alpha *= min(1, max(0, edge / (h * 0.5)))
            if let front {
                let d = (x - front * w) / (0.14 * w)
                let near = exp(-d * d)
                alpha = isBurst ? alpha * frontStrength * near : alpha * shine * (1 + 2.2 * frontStrength * near)
            } else {
                alpha *= shine
            }
            guard alpha > 0.01 else { continue }
            let round = hash(s, 9) < 0.45 || sparkle
            out.append(Grain(x: x, y: y,
                             length: round ? 0 : 1.2 + 1.4 * hash(s, 10),
                             width: round ? (sparkle ? 0.8 : 0.5) + 0.25 * hash(s, 11) : 0.4 + 0.15 * hash(s, 11),
                             alpha: min(1, alpha), sparkle: sparkle))
        }
        return out
    }

    /// A stable pseudo-random number in 0..<1 (the orb's own hash).
    @inline(__always) static func hash(_ a: UInt64, _ b: UInt64) -> Double { LAAParticleOrb.hash(a, b) }
}

/// The light is drawn inside the native glass and clipped to it, behind the
/// label: no outline, colour, shadow or movement outside the control.
private struct LAAGlassSelection: ViewModifier {
    let finish: LAAFinish
    let motion: LAAGlassMotion
    let duration: Double
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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

    @ViewBuilder private var light: some View {
        switch motion {
        case .live(let start):
            LAAGlassLive(finish: finish, start: start, duration: duration, dark: scheme == .dark)
        case .frozen(let elapsed, let time):
            LAAGlassLight(look: .init(finish: finish, elapsed: elapsed, duration: duration, time: time),
                          dark: scheme == .dark)
        }
    }
}

/// What drives the glass: the running clock (`live`, with the start of the
/// movement after an applied change), or one held moment for a capture.
enum LAAGlassMotion: Equatable {
    case live(Date?)
    case frozen(elapsed: Double?, time: Double?)
}

/// The running glass. Its clock ticks only while the particles can be seen
/// and moving is allowed: 24 frames a second at rest, the display's rate for
/// the short movement after a change. It stops off screen, in the
/// background, with Reduce Motion and in Low Power Mode, where the glass
/// keeps its still gloss and no particle.
private struct LAAGlassLive: View {
    let finish: LAAFinish
    let start: Date?
    let duration: Double
    let dark: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var onScreen = false

    private var moves: Bool { !reduceMotion && !lowPower }
    private var moving: Bool { moves && start != nil }

    var body: some View {
        let paused = !moves || !onScreen || scenePhase == .background || finish == .plain
        TimelineView(.animation(minimumInterval: moving ? nil : 1.0 / 24, paused: paused)) { context in
            let clock = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 86_400)
            LAAGlassLight(look: .init(finish: finish, elapsed: moving ? start.map { context.date.timeIntervalSince($0) } : nil,
                                      duration: duration, time: moves ? clock : nil),
                          dark: dark)
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }
}

/// What the glass holds: its body, the soft top light and the glints, and the
/// particles (LAAGlassParticles).
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
                if look.time != nil {
                    LAAGlassGrains(grains: look.grains(in: size), dark: dark)
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
}

/// The particles, drawn as the orb draws its own: on the dark, blue-white
/// light that adds, with a soft bloom; on the paper, the orb's teal, crisp,
/// with a faint teal bleed (ink read as dust on the light glass).
private struct LAAGlassGrains: View {
    let grains: [LAAGlassParticles.Grain]
    let dark: Bool

    /// The orb's light and bloom on the dark (LAAParticleOrb).
    private static let light = Color(red: 0.82, green: 0.89, blue: 1.0)
    private static let bloom = Color(red: 0.66, green: 0.79, blue: 1.0)

    var body: some View {
        Canvas { context, _ in
            let ink = dark ? Self.light : LAAColor.ownBubble
            let glow = dark ? Self.bloom : LAAColor.ownBubble
            let strength = dark ? 0.95 : 0.6
            context.blendMode = dark ? .plusLighter : .normal
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 1.2))
                for g in grains where g.sparkle {
                    let r = 2.2 * g.width + 0.6
                    layer.fill(Path(ellipseIn: CGRect(x: g.x - r, y: g.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(glow.opacity((dark ? 0.45 : 0.12) * g.alpha)))
                }
            }
            for g in grains {
                context.fill(shape(g), with: .color(ink.opacity(strength * g.alpha)))
            }
        }
        .allowsHitTesting(false)
    }

    /// A streak along the drift that tapers to nothing at both ends, or a round grain.
    private func shape(_ g: LAAGlassParticles.Grain) -> Path {
        guard g.length > 0 else {
            return Path(ellipseIn: CGRect(x: g.x - g.width, y: g.y - g.width, width: 2 * g.width, height: 2 * g.width))
        }
        let half = g.length / 2
        var p = Path()
        p.move(to: CGPoint(x: g.x - half, y: g.y))
        p.addQuadCurve(to: CGPoint(x: g.x + half, y: g.y), control: CGPoint(x: g.x, y: g.y - g.width))
        p.addQuadCurve(to: CGPoint(x: g.x - half, y: g.y), control: CGPoint(x: g.x, y: g.y + g.width))
        p.closeSubpath()
        return p
    }
}

extension View {
    func laaGlassSelection(finish: LAAFinish, motion: LAAGlassMotion, duration: Double = LAACeremony.slow,
                           cornerRadius: CGFloat) -> some View {
        modifier(LAAGlassSelection(finish: finish, motion: motion, duration: duration, cornerRadius: cornerRadius))
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
