#if LAA_BUILD
import SwiftUI

/// How a value's standing shows on its glass control (owner, 2026-11-14: no
/// colour; keep the Liquid Glass and make it quietly luxurious). Not a hue but
/// the number of fine metal lines on the rim, in the house tan, the colour of
/// rules and figures: none, one, or two like a bezel. The model and effort
/// controls of Chat and Work share it, so a top model and the deepest effort
/// read alike. Studio: 「LAAアプリ｜モデルとeffortの演出 2026.11」.
enum LAAFinish: Int, Comparable {
    case plain = 0, line = 1, double = 2

    static func < (lhs: LAAFinish, rhs: LAAFinish) -> Bool { lhs.rawValue < rhs.rawValue }

    var lines: Int { rawValue }
}

/// A model's standing, read from its id: Mythos above all with two lines,
/// Fable and Astra with one; every other model (and an unknown one) keeps the
/// bare glass. Fable and Astra are told apart by their makers' marks and
/// names, not by a colour.
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
        case .mythos: .double
        case .fable, .astra: .line
        case .none: .plain
        }
    }
}

/// The one movement a control makes when a value it asked for is applied,
/// within the house durations (tokens.json motion: base 220, gentle 300, slow
/// 420 ms) and the `state` curve, and never again until the next one.
///
/// - `breath`: the glass edge brightens once and settles (Low, Medium, an
///   unranked model).
/// - `pass`: a short light runs once round the edge from the leading end, over
///   the top (High).
/// - `trace`: the same light leaves the finish's metal line behind it; a
///   second line follows a beat later for a double finish (XHigh and Max,
///   Fable, Astra and Mythos).
enum LAACeremony {
    enum Motion: Equatable { case breath, pass, trace }

    static let base: Double = 0.22
    static let gentle: Double = 0.30
    static let slow: Double = 0.42

    static func duration(_ motion: Motion) -> Double {
        switch motion {
        case .breath: base
        case .pass: gentle
        case .trace: slow
        }
    }

    static func motion(effort: String) -> Motion? {
        switch effort {
        case "low", "medium": .breath
        case "high": .pass
        case "xhigh", "max": .trace
        default: nil
        }
    }

    static func motion(rank: LAAModelRank) -> Motion { rank == .none ? .breath : .trace }

    static func duration(effort: String) -> Double { motion(effort: effort).map(duration) ?? 0 }
    static func duration(rank: LAAModelRank) -> Double { duration(motion(rank: rank)) }

    /// The light's length, as a share of the rim.
    static let lightLength: Double = 0.14
    /// How long the second line of a double finish waits behind the first.
    static let innerDelay: Double = 0.06
    /// The meter's ticks rise one after another, each in `base`.
    static let riseStagger: Double = 0.04

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

/// What a control's rim shows at one moment: at rest (`elapsed` nil, or the
/// movement over) or that many seconds into its one movement. Shares of the
/// rim run from the leading end's middle, clockwise over the top.
struct LAARimLook: Equatable {
    let finish: LAAFinish
    let motion: LAACeremony.Motion
    var elapsed: Double? = nil

    private var duration: Double { LAACeremony.duration(motion) }

    /// Into the movement, 0...1; nil at rest.
    private var progress: Double? {
        guard let elapsed, elapsed < duration, duration > 0 else { return nil }
        return max(0, elapsed) / duration
    }

    var live: Bool { progress != nil }

    /// Where the light's head is, as a share of the rim (`state` curve).
    var head: Double? {
        guard let progress, motion != .breath else { return nil }
        return LAACeremony.state(progress)
    }

    /// The light's span on the rim, trailing its head.
    var light: ClosedRange<Double>? {
        head.map { max(0, $0 - LAACeremony.lightLength)...$0 }
    }

    /// The light fades in over the first tenth and out over the last fifth.
    var lightOpacity: Double {
        guard let progress, motion != .breath else { return 0 }
        return min(1, progress / 0.1) * min(1, (1 - progress) / 0.2)
    }

    /// How brightly the whole edge is lit in a breath: up and back once.
    var breath: Double {
        guard let progress, motion == .breath else { return 0 }
        return sin(.pi * progress)
    }

    /// How much of the outer metal line is drawn: all of it at rest; in a
    /// trace, as far as the light has gone.
    var outer: Double {
        guard finish.lines >= 1 else { return 0 }
        guard let head, motion == .trace else { return 1 }
        return head
    }

    /// The inner line of a double finish, a beat behind the outer one and
    /// done by the end of the movement.
    var inner: Double {
        guard finish.lines >= 2 else { return 0 }
        guard live, motion == .trace, let elapsed else { return 1 }
        let span = duration - LAACeremony.innerDelay
        return LAACeremony.state((elapsed - LAACeremony.innerDelay) / span)
    }
}

/// The rim of a control's glass as a path that starts at the leading end's
/// middle and runs clockwise over the top, so a trim of it is a known stretch
/// of the rim on any OS. The same rounded rectangle as `conduitGlassControl`,
/// which is a capsule at the controls' height.
struct LAARimPath: Shape {
    var cornerRadius: CGFloat
    var inset: CGFloat

    func path(in rect: CGRect) -> Path {
        let r0 = rect.insetBy(dx: inset, dy: inset)
        guard r0.width > 0, r0.height > 0 else { return Path() }
        let radius = max(0, min(cornerRadius - inset, r0.height / 2, r0.width / 2))
        var path = Path()
        path.move(to: CGPoint(x: r0.minX, y: r0.midY))
        path.addLine(to: CGPoint(x: r0.minX, y: r0.minY + radius))
        path.addArc(center: CGPoint(x: r0.minX + radius, y: r0.minY + radius), radius: radius,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: r0.maxX - radius, y: r0.minY))
        path.addArc(center: CGPoint(x: r0.maxX - radius, y: r0.minY + radius), radius: radius,
                    startAngle: .degrees(270), endAngle: .degrees(360), clockwise: false)
        path.addLine(to: CGPoint(x: r0.maxX, y: r0.maxY - radius))
        path.addArc(center: CGPoint(x: r0.maxX - radius, y: r0.maxY - radius), radius: radius,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: r0.minX + radius, y: r0.maxY))
        path.addArc(center: CGPoint(x: r0.minX + radius, y: r0.maxY - radius), radius: radius,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// The metal lines and the passing light, laid over a control's glass. Lines
/// are 1 pt in the house tan, the outer one on the glass edge and the inner
/// one a spacing step (4 pt) inside it; the light is the paper white of the
/// glass at the icon stroke (1.5 pt), the same light that circles Send's rim.
struct LAARimFinish: View {
    let look: LAARimLook
    var cornerRadius: CGFloat = 18

    static let innerInset: CGFloat = LAASpacing.x1
    static let lightWidth: CGFloat = 1.5
    static let breathPeak: Double = 0.5

    var body: some View {
        ZStack {
            if look.breath > 0 {
                // Half strength at its peak: a breath, not a flash.
                LAARimPath(cornerRadius: cornerRadius, inset: 0.5)
                    .stroke(LAAColor.glassLight.opacity(Self.breathPeak * look.breath), lineWidth: 1)
            }
            if look.outer > 0 {
                LAARimPath(cornerRadius: cornerRadius, inset: 0.5)
                    .trim(from: 0, to: look.outer)
                    .stroke(LAAColor.decorativeTan, lineWidth: 1)
            }
            if look.inner > 0 {
                LAARimPath(cornerRadius: cornerRadius, inset: Self.innerInset + 0.5)
                    .trim(from: 0, to: look.inner)
                    .stroke(LAAColor.decorativeTan, lineWidth: 1)
            }
            if let light = look.light, look.lightOpacity > 0 {
                LAARimPath(cornerRadius: cornerRadius, inset: 0.5)
                    .trim(from: light.lowerBound, to: light.upperBound)
                    .stroke(LAAColor.glassLight.opacity(look.lightOpacity),
                            style: StrokeStyle(lineWidth: Self.lightWidth, lineCap: .round))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
