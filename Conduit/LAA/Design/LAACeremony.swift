#if LAA_BUILD
import SwiftUI
import UIKit

/// How far the glass is veined (owner, 2026-11-15, replacing the particles of
/// 11-14): a strong model or effort keeps the Liquid Glass, unpainted, with
/// fine marble cracks inside it, more and brighter at the higher step, and a
/// light drifting slowly along them. Plain glass holds none; polished glass a
/// few veins (Fable, Astra, XHigh); crystal more veins and branches and a
/// brighter light (Mythos, Max, Ultra Code). Each model's colour, pattern
/// and strength sit in LAASelectionStyle; no outline.
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
/// the movement that follows an applied change. `light` is where the slow
/// light rests along the capsule (0 the leading end, 1 the trailing); a still
/// glass (Reduce Motion, Low Power Mode) holds it at `LAAMarble.restLight`.
struct LAAMarbleLook: Equatable {
    let finish: LAAFinish
    var tone: LAAVeinTone = .stone
    var elapsed: Double? = nil
    var duration: Double = LAACeremony.slow
    var light: Double = LAAMarble.restLight

    /// 0...1 through the movement, nil at rest or once it is over.
    var progress: Double? {
        guard let elapsed, duration > 0, elapsed < duration else { return nil }
        return min(1, max(0, elapsed / duration))
    }

    /// The front the veins spread behind (0 the leading end, 1 the trailing),
    /// entering and leaving outside the glass; nil at rest, when every vein shows.
    var front: Double? {
        guard let progress else { return nil }
        return LAAMarble.frontFrom + (LAAMarble.frontTo - LAAMarble.frontFrom) * LAACeremony.state(progress)
    }

    /// Where the light is now: riding the front during the movement.
    var lightAt: Double { front ?? light }

    /// The veins themselves, before the light passes them.
    func veinOpacity(dark: Bool) -> Double {
        min(1, (LAAMarble.tier(finish)?.opacity(dark: dark) ?? 0) * LAASelectionStyle.of(tone).strength)
    }

    /// The veins where the light lies: brightest under the front of an
    /// applied change, then the resting share of it.
    func glowOpacity(dark: Bool) -> Double {
        guard let tier = LAAMarble.tier(finish) else { return 0 }
        return min(1, tier.glow(dark: dark) * LAASelectionStyle.of(tone).strength) * (front == nil ? LAAMarble.restGlowShare : 1)
    }
}

/// Fine cracks inside the glass, as in a dark marble (owner, 2026-11-15):
/// a few angular veins that taper at both ends, hairlines branching off them,
/// laid once for the capsule's size and never redrawn per frame. A soft band
/// of light drifts slowly along them; an applied change spreads them once
/// from the leading end. Every vein is a pure function of the capsule, so any
/// size draws the same and tests can read them.
enum LAAMarble {
    struct Tier: Equatable {
        /// Main veins per 100 pt of capsule width, and the fewest.
        var veinsPer100pt: Double
        var minVeins: Int
        var branchesPerVein: Int
        /// The widest point of a main vein, pt.
        var width: ClosedRange<Double>
        var hairline: ClosedRange<Double>
        var veinDark: Double, veinLight: Double
        var glowDark: Double, glowLight: Double
        /// Seconds for the light to cross the capsule once (it then comes back).
        var drift: Double

        func opacity(dark: Bool) -> Double { dark ? veinDark : veinLight }
        func glow(dark: Bool) -> Double { dark ? glowDark : glowLight }
    }

    /// Fable, Astra and XHigh: a few veins, a soft light.
    static let veined = Tier(veinsPer100pt: 1.3, minVeins: 1, branchesPerVein: 1,
                             width: 0.45...0.75, hairline: 0.3...0.4,
                             veinDark: 0.30, veinLight: 0.26, glowDark: 0.55, glowLight: 0.42, drift: 11)
    /// Mythos, Max and Ultra Code: more veins and branches, a brighter light.
    static let deep = Tier(veinsPer100pt: 2.2, minVeins: 2, branchesPerVein: 2,
                           width: 0.55...0.95, hairline: 0.3...0.45,
                           veinDark: 0.42, veinLight: 0.36, glowDark: 0.85, glowLight: 0.6, drift: 9)

    static func tier(_ finish: LAAFinish) -> Tier? {
        switch finish {
        case .plain: nil
        case .polished: veined
        case .crystal: deep
        }
    }

    /// Where the still light rests, and how much of its strength it keeps
    /// once the front has passed.
    static let restLight = 0.35
    static let restGlowShare = 0.6
    /// The drifting light's travel and width, as shares of the capsule's width.
    static let lightFrom = 1.2, lightTo = -0.2
    static let lightWidth = 0.6
    /// The front of an applied change.
    static let frontFrom = -0.2, frontTo = 1.2
    static let frontWidth = 0.14
    /// The veins thin out across the label's middle so the name stays clear.
    static let labelShare = 0.4
    /// The light's frame rate while it drifts: slow enough for 24 a second.
    static let driftFrameRate: Float = 24

    /// The pattern's colour before opacity (LAASelectionStyle).
    static func ink(_ tone: LAAVeinTone, dark: Bool) -> UIColor { LAASelectionStyle.of(tone).ink.ui(dark: dark) }

    struct Vein: Equatable {
        /// The crack's centre line, in points from the capsule's top leading corner.
        var spine: [CGPoint]
        /// Its width at each point of the spine.
        var widths: [Double]
        var hairline: Bool
    }

    /// The veins for a capsule of `size`, `seed` telling capsules of one width apart.
    static func veins(finish: LAAFinish, size: CGSize, seed: UInt64) -> [Vein] {
        guard let tier = tier(finish) else { return [] }
        let w = Double(size.width), h = Double(size.height)
        guard w > 4, h > 4 else { return [] }
        let count = max(tier.minVeins, Int((tier.veinsPer100pt * w / 100).rounded()))
        var out: [Vein] = []
        for i in 0..<count {
            let s = seed &+ UInt64(i) &* 0x9E37_79B9
            // Spread the starts along the capsule so the veins do not bunch.
            let slot = (Double(i) + 0.15 + 0.7 * hash(s, 0)) / Double(count)
            let x0 = slot * 0.95 * w
            let y0 = h * (0.1 + 0.8 * hash(s, 1))
            // A shallow course toward the farther end, so each vein crosses the glass.
            let tilt = (hash(s, 2) < 0.5 ? -1.0 : 1.0) * (4 + 12 * hash(s, 3)) * .pi / 180
            let rise = slot > 0.5 ? Double.pi + tilt : tilt
            let length = (0.5 + 0.55 * hash(s, 4)) * w
            let peak = tier.width.lowerBound + (tier.width.upperBound - tier.width.lowerBound) * hash(s, 5)
            let main = crack(from: CGPoint(x: x0, y: y0), angle: rise, length: length, peak: peak,
                             step: 4.5, seed: s &+ 17, rootWidth: nil)
            out.append(main)
            for b in 0..<tier.branchesPerVein {
                let bs = s &+ 1_000 &+ UInt64(b) &* 131
                let at = Int(Double(main.spine.count - 1) * (0.25 + 0.5 * hash(bs, 0)))
                let turn = (hash(bs, 1) < 0.5 ? -1.0 : 1.0) * (25 + 35 * hash(bs, 2)) * .pi / 180
                let hair = tier.hairline.lowerBound + (tier.hairline.upperBound - tier.hairline.lowerBound) * hash(bs, 3)
                out.append(crack(from: main.spine[at], angle: rise + turn, length: (0.12 + 0.2 * hash(bs, 4)) * w,
                                 peak: hair, step: 3.5, seed: bs &+ 7, rootWidth: hair))
            }
        }
        return out
    }

    /// One angular crack: short straight steps, each turning a little from the
    /// last and pulled back to its course, tapering at both ends (a branch only
    /// at its tip, starting from `rootWidth`).
    private static func crack(from start: CGPoint, angle: Double, length: Double, peak: Double, step: Double,
                              seed: UInt64, rootWidth: Double?) -> Vein {
        let n = max(4, Int(length / step))
        var points = [start], widths: [Double] = []
        var heading = angle, p = start
        for k in 1...n {
            heading += (hash(seed, UInt64(k)) - 0.5) * 1.1
            heading += (angle - heading) * 0.35
            p = CGPoint(x: p.x + step * cos(heading), y: p.y + step * sin(heading))
            points.append(p)
        }
        for k in 0...n {
            let t = Double(k) / Double(n)
            let shape = rootWidth == nil ? pow(sin(.pi * t), 0.6) : 1 - t
            let grain = 0.75 + 0.5 * hash(seed &+ 991, UInt64(k))
            widths.append(max(0.08, peak * shape * grain))
        }
        return Vein(spine: points, widths: widths, hairline: rootWidth != nil)
    }

    /// The veins as one filled outline: each spine offset by half its width
    /// on both sides.
    static func path(_ veins: [Vein]) -> CGPath {
        let path = CGMutablePath()
        for vein in veins where vein.spine.count > 1 {
            let pts = vein.spine
            var left: [CGPoint] = [], right: [CGPoint] = []
            for k in pts.indices {
                let a = pts[max(0, k - 1)], b = pts[min(pts.count - 1, k + 1)]
                let dx = b.x - a.x, dy = b.y - a.y
                let len = max(0.0001, sqrt(dx * dx + dy * dy))
                let nx = -dy / len, ny = dx / len, half = vein.widths[k] / 2
                left.append(CGPoint(x: pts[k].x + nx * half, y: pts[k].y + ny * half))
                right.append(CGPoint(x: pts[k].x - nx * half, y: pts[k].y - ny * half))
            }
            path.addLines(between: left + right.reversed())
            path.closeSubpath()
        }
        return path
    }

    /// A stable seed for a capsule's label, so two capsules of one width differ.
    static func seed(_ text: String?) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in (text ?? "").utf8 { h = (h ^ UInt64(byte)) &* 0x100_0000_01B3 }
        return h
    }

    /// A stable pseudo-random number in 0..<1.
    @inline(__always) static func hash(_ a: UInt64, _ b: UInt64) -> Double {
        var z = a &+ b &* 0x9E37_79B9_7F4A_7C15 &+ 0x632B_E59B_D9B4_E019
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }
}

/// The veins are drawn inside the native glass and clipped to it, behind the
/// label: no outline, colour, shadow or movement outside the control.
private struct LAAGlassSelection: ViewModifier {
    let finish: LAAFinish
    let tone: LAAVeinTone
    let seed: UInt64
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
                    .overlay { inside.clipShape(shape) }
            }
        } else {
            content
                .background { inside.clipShape(shape).allowsHitTesting(false).accessibilityHidden(true) }
                .conduitGlassControl(cornerRadius: cornerRadius, tint: .clear, interactive: true)
        }
    }

    /// The model's faint colour through the glass, under its pattern.
    @ViewBuilder private var inside: some View {
        if finish != .plain {
            let style = LAASelectionStyle.of(tone), dark = scheme == .dark
            ZStack {
                shape.fill(Color(uiColor: style.wash.ui(dark: dark))).opacity(style.washOpacity(dark: dark))
                veins
            }
        }
    }

    @ViewBuilder private var veins: some View {
        if finish != .plain {
            switch motion {
            case .live(let start):
                LAAGlassLive(look: .init(finish: finish, tone: tone, duration: duration), seed: seed,
                             start: start, dark: scheme == .dark)
            case .frozen(let elapsed, let light):
                LAAMarbleVeins(look: .init(finish: finish, tone: tone, elapsed: elapsed, duration: duration,
                                           light: light ?? LAAMarble.restLight),
                               seed: seed, dark: scheme == .dark, moves: false, start: nil)
            }
        }
    }
}

/// What drives the glass: the running light (`live`, with the start of the
/// movement after an applied change), or one held moment for a capture
/// (`light` nil: where the still light rests).
enum LAAGlassMotion: Equatable {
    case live(Date?)
    case frozen(elapsed: Double?, light: Double?)
}

/// The running glass. The light drifts only while it can be seen and moving
/// is allowed; off screen, in the background, with Reduce Motion and in Low
/// Power Mode the veins stay still with the light at rest.
private struct LAAGlassLive: View {
    let look: LAAMarbleLook
    let seed: UInt64
    let start: Date?
    let dark: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var onScreen = false

    var body: some View {
        LAAMarbleVeins(look: look, seed: seed, dark: dark,
                       moves: !reduceMotion && !lowPower && onScreen && scenePhase != .background,
                       start: reduceMotion ? nil : start)
            .onAppear { onScreen = true }
            .onDisappear { onScreen = false }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
    }
}

/// The veins as Core Animation layers: the outline is built once per size,
/// and the drift and the front are layer animations the render server runs,
/// so a resting capsule costs the app's main thread nothing per frame.
private struct LAAMarbleVeins: UIViewRepresentable {
    let look: LAAMarbleLook
    let seed: UInt64
    let dark: Bool
    let moves: Bool
    let start: Date?

    func makeUIView(context: Context) -> LAAMarbleView {
        let view = LAAMarbleView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: LAAMarbleView, context: Context) {
        view.apply(.init(look: look, seed: seed, dark: dark, moves: moves, start: start))
    }
}

final class LAAMarbleView: UIView {
    struct Config: Equatable {
        var look: LAAMarbleLook
        var seed: UInt64
        var dark: Bool
        var moves: Bool
        var start: Date?
    }

    private var config: Config?
    private var builtFor: (CGSize, LAAFinish, UInt64)?
    private var playedStart: Date?
    /// The width the drift was laid for; nil while the light is still.
    private var driftWidth: CGFloat?
    /// Thins the veins across the label's middle (static).
    private let labelMask = CAGradientLayer()
    /// Spreads the veins behind the front of an applied change.
    private let spread = CALayer()
    private let spreadMask = CAGradientLayer()
    private let veins = CAShapeLayer()
    /// The veins again, brighter, seen only through the drifting band.
    private let glow = CALayer()
    private let glowVeins = CAShapeLayer()
    private let glowHalo = CAShapeLayer()
    private let band = CAGradientLayer()
    /// The pattern as an image (LAASelectionStyle.Pattern.texture), and again under the light.
    private let texture = CALayer()
    private let glowTexture = CALayer()

    private static let driftKey = "laa.marble.drift"
    private static let frontKeys = ["laa.marble.front", "laa.marble.frontLight", "laa.marble.frontGlow"]

    override init(frame: CGRect) {
        super.init(frame: frame)
        let opaque = UIColor.black.cgColor, clear = UIColor.clear.cgColor
        let thin = UIColor.black.withAlphaComponent(LAAMarble.labelShare).cgColor
        labelMask.colors = [opaque, opaque, thin, opaque, opaque]
        labelMask.locations = [0, 0.26, 0.5, 0.74, 1]
        layer.mask = labelMask
        spreadMask.startPoint = CGPoint(x: 0, y: 0.5); spreadMask.endPoint = CGPoint(x: 1, y: 0.5)
        spreadMask.colors = [opaque, opaque, clear, clear]
        band.startPoint = CGPoint(x: 0, y: 0.5); band.endPoint = CGPoint(x: 1, y: 0.5)
        band.colors = [clear, opaque, clear]
        band.locations = [0, 0.5, 1]
        glowHalo.fillColor = nil
        glowHalo.lineJoin = .round
        for l in [texture, glowTexture] {
            l.contentsGravity = .resizeAspectFill
            l.masksToBounds = true
        }
        layer.addSublayer(spread)
        spread.addSublayer(texture)
        spread.addSublayer(veins)
        spread.addSublayer(glow)
        glow.addSublayer(glowTexture)
        glow.addSublayer(glowHalo)
        glow.addSublayer(glowVeins)
        glow.mask = band
        NotificationCenter.default.addObserver(self, selector: #selector(resume),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(_ next: Config) {
        let previous = config
        config = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if previous?.look.finish != next.look.finish || previous?.seed != next.seed
            || previous?.look.tone != next.look.tone { builtFor = nil }
        layoutLayers()
        paint(next)
        place(next)
        if previous?.moves != next.moves || previous?.look.finish != next.look.finish || driftWidth != bounds.width {
            drift(next)
        }
        if next.moves, let start = next.start, start != playedStart {
            playedStart = start
            let elapsed = Date().timeIntervalSince(start)
            if elapsed < next.look.duration { playFront(elapsed: max(0, elapsed), config: next) }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutLayers()
        if let config { place(config) }
        CATransaction.commit()
        if let config, driftWidth != bounds.width { drift(config) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop() } else if let config { drift(config) }
    }

    @objc private func resume() { if let config, window != nil { drift(config) } }

    private func layoutLayers() {
        let size = bounds.size
        for l in [labelMask, spread, veins, glow, glowVeins, glowHalo, texture, glowTexture] as [CALayer] { l.frame = bounds }
        guard let config, size.width > 1, size.height > 1 else { return }
        if let built = builtFor, built.0 == size, built.1 == config.look.finish, built.2 == config.seed { return }
        builtFor = (size, config.look.finish, config.seed)
        let image = Self.textureImage(config.look.tone)
        texture.contents = image?.cgImage
        glowTexture.contents = image?.cgImage
        // A texture takes the veins' place; without one the veins are drawn.
        let path = image == nil ? LAAMarble.path(LAAMarble.veins(finish: config.look.finish, size: size, seed: config.seed)) : nil
        veins.path = path
        glowVeins.path = path
        glowHalo.path = path
    }

    private static func textureImage(_ tone: LAAVeinTone) -> UIImage? {
        guard case .texture(let name) = LAASelectionStyle.of(tone).pattern else { return nil }
        return UIImage(named: name)
    }

    private func paint(_ config: Config) {
        let ink = LAAMarble.ink(config.look.tone, dark: config.dark)
        veins.fillColor = ink.withAlphaComponent(config.look.veinOpacity(dark: config.dark)).cgColor
        texture.opacity = Float(config.look.veinOpacity(dark: config.dark))
        let peak = min(1, (LAAMarble.tier(config.look.finish)?.glow(dark: config.dark) ?? 0)
                       * LAASelectionStyle.of(config.look.tone).strength)
        glowTexture.opacity = Float(peak)
        glowVeins.fillColor = ink.withAlphaComponent(peak).cgColor
        // On the dark the light also blooms a little round each vein; on the
        // paper the vein only sharpens.
        glowHalo.strokeColor = config.dark ? ink.withAlphaComponent(0.22 * peak).cgColor : nil
        glowHalo.lineWidth = config.dark ? 1.6 : 0
    }

    /// The held state: the spread, the band and the light's strength for this moment.
    private func place(_ config: Config) {
        let w = bounds.width, h = bounds.height
        guard w > 1 else { return }
        let edge = LAAMarble.frontWidth / 2 / 4
        spreadMask.locations = [0, NSNumber(value: 0.5 - edge), NSNumber(value: 0.5 + edge), 1]
        spreadMask.bounds = CGRect(x: 0, y: 0, width: 4 * w, height: h)
        if let front = config.look.front {
            spreadMask.position = CGPoint(x: front * w, y: h / 2)
            spread.mask = spreadMask
        } else if spreadMask.animation(forKey: Self.frontKeys[0]) == nil {
            // At rest every vein shows; a front still running keeps its mask.
            spread.mask = nil
        }
        band.bounds = CGRect(x: 0, y: 0, width: LAAMarble.lightWidth * w, height: h)
        band.position = CGPoint(x: config.look.lightAt * w, y: h / 2)
        let peak = min(1, (LAAMarble.tier(config.look.finish)?.glow(dark: config.dark) ?? 0)
                       * LAASelectionStyle.of(config.look.tone).strength)
        glow.opacity = Float(peak > 0 ? config.look.glowOpacity(dark: config.dark) / peak : 0)
    }

    /// The front of an applied change: the veins spread from the leading end
    /// with the light riding at the front, the light then easing to its rest.
    private func playFront(elapsed: Double, config: Config) {
        let w = bounds.width, h = bounds.height
        guard w > 1 else { return }
        let curve = CAMediaTimingFunction(controlPoints: 0.25, 0.9, 0.3, 1)
        let from = LAAMarble.frontFrom * w, to = LAAMarble.frontTo * w
        func run(_ key: String, _ path: String, _ a: Any, _ b: Any, on target: CALayer) {
            let anim = CABasicAnimation(keyPath: path)
            anim.fromValue = a; anim.toValue = b
            anim.duration = config.look.duration
            anim.timingFunction = curve
            anim.timeOffset = elapsed
            target.add(anim, forKey: key)
        }
        spreadMask.bounds = CGRect(x: 0, y: 0, width: 4 * w, height: h)
        spreadMask.position = CGPoint(x: 1.5 * w, y: h / 2)
        spread.mask = spreadMask
        run(Self.frontKeys[0], "position.x", from, to, on: spreadMask)
        run(Self.frontKeys[1], "position.x", from, to, on: band)
        run(Self.frontKeys[2], "opacity", 1.0, LAAMarble.restGlowShare, on: glow)
        // The drift takes over where the front leaves the light.
        drift(config, after: config.look.duration - elapsed)
    }

    /// The slow light: across the capsule and back, at 24 frames a second at
    /// most, run by the render server. Removed while the glass is still.
    private func drift(_ config: Config, after delay: Double = 0) {
        band.removeAnimation(forKey: Self.driftKey)
        driftWidth = nil
        let w = bounds.width
        guard config.moves, window != nil, w > 1, let tier = LAAMarble.tier(config.look.finish) else { return }
        driftWidth = w
        let anim = CABasicAnimation(keyPath: "position.x")
        anim.fromValue = LAAMarble.lightFrom * w
        anim.toValue = LAAMarble.lightTo * w
        anim.duration = tier.drift
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        anim.isRemovedOnCompletion = false
        // No backward fill: until it begins, the front's own movement holds the band.
        anim.beginTime = band.convertTime(CACurrentMediaTime(), from: nil) + max(0, delay)
        anim.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: LAAMarble.driftFrameRate,
                                                        preferred: LAAMarble.driftFrameRate)
        band.add(anim, forKey: Self.driftKey)
    }

    private func stop() {
        driftWidth = nil
        band.removeAllAnimations()
        spreadMask.removeAllAnimations()
        glow.removeAllAnimations()
        if let config { place(config) }
    }
}

extension View {
    func laaGlassSelection(finish: LAAFinish, tone: LAAVeinTone = .stone, seed: UInt64 = 0,
                           motion: LAAGlassMotion, duration: Double = LAACeremony.slow,
                           cornerRadius: CGFloat) -> some View {
        modifier(LAAGlassSelection(finish: finish, tone: tone, seed: seed, motion: motion,
                                   duration: duration, cornerRadius: cornerRadius))
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
