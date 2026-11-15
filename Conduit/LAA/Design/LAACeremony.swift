#if LAA_BUILD
import SwiftUI
import UIKit

/// Policy A 「大理石の脈」 (owner, 2026-11-15; Studio work 499ec898, rev 12):
/// a strong selection keeps the Liquid Glass and, inside it, takes the
/// model's colour as a thick glass body, a marble vein behind it and a light
/// crossing it slowly. Every value (colour, vein strength, light, glow, tile
/// scale, speed) comes from hq/design/tokens.json `appSelection`, generated
/// into LAAAppSelectionTokens.swift; nothing here holds a look of its own.
/// The marble is for the model and effort capsules only. No outline.
enum LAASelectionStep: Equatable {
    /// Every other model, and Low to High: the plain Liquid Glass.
    case plain
    /// Mythos, Astra and Fable on the model capsule.
    case model
    case xhigh, max, ultracode

    var tokens: LAAAppSelectionTokens.Step {
        switch self {
        case .plain: LAAAppSelectionTokens.plainStep
        case .model: LAAAppSelectionTokens.modelStep
        case .xhigh: LAAAppSelectionTokens.xhighStep
        case .max: LAAAppSelectionTokens.maxStep
        case .ultracode: LAAAppSelectionTokens.ultracodeStep
        }
    }
}

/// Mythos, Fable and Astra wear the model step; every other model is plain.
enum LAAModelRank: Equatable {
    case mythos, fable, astra, none
    static func of(_ model: String?) -> LAAModelRank {
        let raw = (model ?? "").lowercased()
        if raw.contains("mythos") { return .mythos }
        if raw.contains("fable") { return .fable }
        if raw.contains("astra") { return .astra }
        return .none
    }
    var step: LAASelectionStep { self == .none ? .plain : .model }
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
    static func duration(rank: LAAModelRank) -> Double { rank.step == .plain ? gentle : slow }
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
/// glass (Reduce Motion, Low Power Mode, off screen) holds it at
/// `appSelection.light.restPosition`.
struct LAAMarbleLook: Equatable {
    let step: LAASelectionStep
    var tone: LAAVeinTone = .stone
    var elapsed: Double? = nil
    var duration: Double = LAAAppSelectionTokens.selectionSeconds
    var light: Double = LAAMarble.restLight

    var style: LAASelectionStyle { .init(tone: tone, step: step) }

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

    /// The main vein, before the light passes it.
    func veinOpacity(dark: Bool) -> Double { style.veinOpacity(LAAAppSelectionTokens.mainOpacity, dark: dark) }
    /// The light on the veins at its peak.
    func glowOpacity(dark: Bool) -> Double { style.lightOpacity(dark: dark) }
}

/// The marble's shared numbers, read from `appSelection`.
enum LAAMarble {
    static var restLight: Double { LAAAppSelectionTokens.restPosition }
    static var lightFrom: Double { LAAAppSelectionTokens.travel.from }
    static var lightTo: Double { LAAAppSelectionTokens.travel.to }
    static var frontFrom: Double { LAAAppSelectionTokens.frontFrom }
    static var frontTo: Double { LAAAppSelectionTokens.frontTo }
    static var driftFrameRate: Float { LAAAppSelectionTokens.maxFrameRate }

    /// The pattern's colour before opacity.
    static func ink(_ tone: LAAVeinTone, dark: Bool) -> UIColor { tone.tokens.ink.value(dark: dark).ui }

    /// A stable seed for a capsule's label, so two capsules side by side
    /// show different parts of the marble.
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

    /// Where the seed shifts the tile: 0 to 1 tile across and down.
    static func offset(seed: UInt64, tile: CGSize) -> CGPoint {
        CGPoint(x: hash(seed, 0) * tile.width, y: hash(seed, 1) * tile.height)
    }

    /// The label band: the veins drop to `labelBandMiddle` from the name's
    /// middle through the chevron, and to `labelBandChevron` under the
    /// chevron itself (design review 2026-11-15: a vein crossing ⌃⌄ read as
    /// 「◇–」). Locations and opacities across the capsule's `width`.
    static func labelBand(width: CGFloat) -> (locations: [Double], opacities: [Double]) {
        let t = LAAAppSelectionTokens.self
        let s = t.labelBandStops
        guard width > 1, s.count == 5 else { return (s, [1, 1, t.labelBandMiddle, 1, 1]) }
        let middle = s[2]
        let from = min(1, max(middle, Double((width - t.labelBandChevronSpanPt.from) / width)))
        let to = min(1, max(from, Double((width - t.labelBandChevronSpanPt.to) / width)))
        return ([s[0], s[1], middle, from, to, s[4]],
                [1, 1, t.labelBandMiddle, t.labelBandChevron, t.labelBandChevron, 1])
    }
}

/// The marble is drawn inside the native glass and clipped to it, behind the
/// label: no outline, and nothing outside the control but the still glow.
private struct LAAGlassSelection: ViewModifier {
    let step: LAASelectionStep
    let tone: LAAVeinTone
    let seed: UInt64
    let motion: LAAGlassMotion
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: RoundedRectangle { .init(cornerRadius: cornerRadius, style: .continuous) }
    private var style: LAASelectionStyle { .init(tone: tone, step: step) }

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
                .background { glow }
        }
    }

    /// The still glow outside the glass (a shadow with its own path).
    @ViewBuilder private var glow: some View {
        if !style.isPlain {
            let dark = scheme == .dark
            LAASelectionGlow(color: style.model.glow.ui, opacity: style.glowOpacity(dark: dark),
                             cornerRadius: cornerRadius)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    /// Layers, back to front: the body's colour, the veins with their light
    /// and the sheen, the top gloss, then the depth and the rim light.
    @ViewBuilder private var inside: some View {
        if !style.isPlain {
            let dark = scheme == .dark, t = LAAAppSelectionTokens.self
            ZStack {
                shape.fill(LinearGradient(colors: [Color(uiColor: style.model.bodyTop.value(dark: dark).ui),
                                                   Color(uiColor: style.model.bodyBottom.value(dark: dark).ui)],
                                          startPoint: .top, endPoint: .bottom))
                    .opacity(style.bodyOpacity(dark: dark))
                veins
                GeometryReader { geo in
                    let inset = t.topGlossInsetPt, h = geo.size.height
                    EllipticalGradient(colors: [Color.white.opacity(t.topGloss.value(dark: dark)), Color.white.opacity(0)],
                                       center: .top, startRadiusFraction: 0, endRadiusFraction: 1)
                        .frame(width: max(0, geo.size.width - 2 * inset), height: max(0, 2 * t.topGlossHeightRatio * h))
                        .frame(width: geo.size.width, height: max(0, t.topGlossHeightRatio * h), alignment: .top)
                        .clipped()
                        .offset(y: inset)
                    // The depth: the inner shade along the bottom.
                    LinearGradient(stops: [.init(color: .black.opacity(0), location: max(0, 1 - t.bottomDepthRadiusPt / max(1, h))),
                                           .init(color: .black.opacity(t.bottomDepth.value(dark: dark)), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                // The rim light: the top's inner point only, never all round.
                shape.strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(t.rimLight.value(dark: dark)), location: 0),
                                                          .init(color: .white.opacity(0), location: 0.12)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
        }
    }

    @ViewBuilder private var veins: some View {
        switch motion {
        case .live(let start):
            LAAGlassLive(look: .init(step: step, tone: tone), seed: seed, start: start, dark: scheme == .dark)
        case .frozen(let elapsed, let light):
            LAAMarbleVeins(look: .init(step: step, tone: tone, elapsed: elapsed, light: light ?? LAAMarble.restLight),
                           seed: seed, dark: scheme == .dark, moves: false, start: nil)
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

/// The running glass. The light crosses only while it can be seen and moving
/// is allowed; off screen, in the background, with Reduce Motion, Reduce
/// Transparency and in Low Power Mode the colour and veins stay and the light
/// rests.
private struct LAAGlassLive: View {
    let look: LAAMarbleLook
    let seed: UInt64
    let start: Date?
    let dark: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scenePhase
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var onScreen = false

    var body: some View {
        LAAMarbleVeins(look: look, seed: seed, dark: dark,
                       moves: !reduceMotion && !reduceTransparency && !lowPower && onScreen && scenePhase != .background,
                       start: reduceMotion ? nil : start)
            .onAppear { onScreen = true }
            .onDisappear { onScreen = false }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
    }
}

/// The glow: a layer shadow with its own path, so it is drawn without an
/// offscreen pass and never moves.
private struct LAASelectionGlow: UIViewRepresentable {
    let color: UIColor
    let opacity: Double
    let cornerRadius: CGFloat

    func makeUIView(context: Context) -> GlowView {
        let view = GlowView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: GlowView, context: Context) {
        view.cornerRadius = cornerRadius
        view.layer.shadowColor = color.cgColor
        view.layer.shadowOpacity = Float(opacity)
        view.layer.shadowRadius = LAAAppSelectionTokens.glowRadiusPt
        view.layer.shadowOffset = CGSize(width: 0, height: LAAAppSelectionTokens.glowOffsetPt)
        view.setNeedsLayout()
    }

    final class GlowView: UIView {
        var cornerRadius: CGFloat = 0
        override func layoutSubviews() {
            super.layoutSubviews()
            layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: cornerRadius).cgPath
        }
    }
}

/// The veins and their light as Core Animation layers: the tinted tiles are
/// made once per tone, scale and appearance, and the light's crossing and
/// the front are layer animations the render server runs, so a resting
/// capsule costs the app's main thread nothing per frame.
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

    private typealias T = LAAAppSelectionTokens

    private var config: Config?
    private var builtFor: Config?
    private var builtSize: CGSize = .zero
    private var playedStart: Date?
    /// The width the crossing was laid for; nil while the light is still.
    private var driftWidth: CGFloat?
    /// Spreads the veins behind the front of an applied change.
    private let spread = CALayer()
    private let spreadMask = CAGradientLayer()
    /// The veins (cloud, main, hair), held still and rasterized, under the label band.
    private let veinBox = CALayer()
    private let veinMask = CAGradientLayer()
    private let cloud = CALayer(), main = CALayer(), hair = CALayer()
    /// The same veins in the light's colour, seen only through the moving band.
    private let glow = CALayer()
    private let glowBox = CALayer()
    private let glowMask = CAGradientLayer()
    private let glowMain = CALayer(), glowHair = CALayer()
    private let band = CAGradientLayer()
    /// The wide sheen over the whole face, moving with the band.
    private let sheen = CAGradientLayer()

    private static let driftKey = "laa.marble.drift"
    private static let frontKeys = ["laa.marble.front", "laa.marble.frontLight", "laa.marble.frontSheen"]
    /// Tinted, scaled tiles, made once each.
    private static var tiles: [String: UIImage] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        let opaque = UIColor.black.cgColor, clear = UIColor.clear.cgColor
        spreadMask.startPoint = CGPoint(x: 0, y: 0.5); spreadMask.endPoint = CGPoint(x: 1, y: 0.5)
        spreadMask.colors = [opaque, opaque, clear, clear]
        for mask in [veinMask, glowMask] {
            mask.startPoint = CGPoint(x: 0, y: 0.5); mask.endPoint = CGPoint(x: 1, y: 0.5)
        }
        band.startPoint = CGPoint(x: 0, y: 0.5); band.endPoint = CGPoint(x: 1, y: 0.5)
        let shoulder = UIColor.black.withAlphaComponent(T.bandShoulderShare).cgColor
        band.colors = [clear, shoulder, opaque, shoulder, clear]
        let half = T.bandShoulderAt / 2
        band.locations = [0, NSNumber(value: 0.5 - half), 0.5, NSNumber(value: 0.5 + half), 1]
        // The sheen's band runs at `sheenAngleDeg` (CSS degrees: 90 is left to right).
        let radians = T.sheenAngleDeg * .pi / 180
        let dx = sin(radians) / 2, dy = -cos(radians) / 2
        sheen.startPoint = CGPoint(x: 0.5 - dx, y: 0.5 - dy)
        sheen.endPoint = CGPoint(x: 0.5 + dx, y: 0.5 + dy)
        sheen.locations = [0, 0.5, 1]
        layer.addSublayer(spread)
        spread.addSublayer(veinBox)
        veinBox.mask = veinMask
        for l in [cloud, main, hair] { veinBox.addSublayer(l) }
        spread.addSublayer(glow)
        glow.addSublayer(glowBox)
        glowBox.mask = glowMask
        for l in [glowMain, glowHair] { glowBox.addSublayer(l) }
        glow.mask = band
        layer.addSublayer(sheen)
        for box in [veinBox, glowBox] { box.shouldRasterize = true }
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
        layoutLayers()
        place(next)
        if previous?.moves != next.moves || previous?.look.step != next.look.step
            || previous?.look.tone != next.look.tone || driftWidth != bounds.width {
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
        let scale = window?.screen.scale ?? traitCollection.displayScale
        for box in [veinBox, glowBox] { box.rasterizationScale = scale }
        if window == nil { stop() } else if let config { drift(config) }
    }

    @objc private func resume() { if let config, window != nil { drift(config) } }

    private func layoutLayers() {
        let size = bounds.size
        for l in [spread, veinBox, veinMask, glow, glowBox, glowMask] as [CALayer] { l.frame = bounds }
        guard let config, size.width > 1, size.height > 1 else { return }
        if builtSize == size, let built = builtFor, built.look.step == config.look.step,
           built.look.tone == config.look.tone, built.dark == config.dark, built.seed == config.seed { return }
        builtFor = config
        builtSize = size
        let style = config.look.style, dark = config.dark
        let tile = style.tileSize
        let shift = LAAMarble.offset(seed: config.seed, tile: tile)
        let ink = style.model.ink.value(dark: dark).ui, light = style.model.lightColor.value(dark: dark).ui
        let paint: [(CALayer, String, UIColor)] = [
            (cloud, T.assetCloud, ink), (main, T.assetMain, ink), (hair, T.assetHair, ink),
            (glowMain, T.assetMain, light), (glowHair, T.assetHair, light),
        ]
        for (target, asset, color) in paint {
            target.frame = CGRect(x: -shift.x, y: -shift.y, width: size.width + tile.width, height: size.height + tile.height)
            target.backgroundColor = Self.tile(asset, color: color, size: tile).map { UIColor(patternImage: $0).cgColor }
        }
        cloud.opacity = Float(style.veinOpacity(T.cloudOpacity, dark: dark))
        main.opacity = Float(style.veinOpacity(T.mainOpacity, dark: dark))
        hair.opacity = Float(style.hairOpacity(dark: dark))
        let mainShare = max(0.0001, T.mainOpacity.value(dark: dark))
        glowMain.opacity = 1
        glowHair.opacity = Float(min(1, T.hairOpacity.value(dark: dark) / mainShare * style.step.tokens.hair))
        let band = LAAMarble.labelBand(width: size.width)
        for mask in [veinMask, glowMask] {
            mask.locations = band.locations.map { NSNumber(value: $0) }
            mask.colors = band.opacities.map { UIColor.black.withAlphaComponent($0).cgColor }
        }
        let sheenOpacity = T.sheen.value(dark: dark) * min(1, style.intensity)
        let white = UIColor.white
        sheen.colors = [white.withAlphaComponent(0).cgColor, white.withAlphaComponent(sheenOpacity).cgColor,
                        white.withAlphaComponent(0).cgColor]
    }

    /// One tile of the template asset, tinted and scaled, at the screen's scale.
    private static func tile(_ asset: String, color: UIColor, size: CGSize) -> UIImage? {
        let key = "\(asset)|\(color.description)|\(size.width)x\(size.height)"
        if let made = tiles[key] { return made }
        guard let image = UIImage(named: asset), size.width >= 1, size.height >= 1 else { return nil }
        let tinted = image.withTintColor(color, renderingMode: .alwaysOriginal)
        let made = UIGraphicsImageRenderer(size: size).image { _ in tinted.draw(in: CGRect(origin: .zero, size: size)) }
        tiles[key] = made
        return made
    }

    /// The held state: the spread, and the band and sheen for this moment.
    private func place(_ config: Config) {
        let w = bounds.width, h = bounds.height
        guard w > 1 else { return }
        let edge = T.frontWidthRatio / 2 / 4
        spreadMask.locations = [0, NSNumber(value: 0.5 - edge), NSNumber(value: 0.5 + edge), 1]
        spreadMask.bounds = CGRect(x: 0, y: 0, width: 4 * w, height: h)
        if let front = config.look.front {
            spreadMask.position = CGPoint(x: front * w, y: h / 2)
            spread.mask = spreadMask
        } else if spreadMask.animation(forKey: Self.frontKeys[0]) == nil {
            // At rest every vein shows; a front still running keeps its mask.
            spread.mask = nil
        }
        band.bounds = CGRect(x: 0, y: 0, width: T.bandWidthRatio * w, height: h)
        sheen.bounds = CGRect(x: 0, y: 0, width: T.sheenWidthRatio * w, height: h)
        if band.animation(forKey: Self.driftKey) == nil, band.animation(forKey: Self.frontKeys[1]) == nil {
            band.position = CGPoint(x: config.look.lightAt * w, y: h / 2)
            sheen.position = band.position
        }
        glow.opacity = Float(config.look.glowOpacity(dark: config.dark))
    }

    /// The front of an applied change: the veins spread from the leading end
    /// with the light riding at the front, then the crossing takes over.
    private func playFront(elapsed: Double, config: Config) {
        let w = bounds.width, h = bounds.height
        guard w > 1 else { return }
        let curve = CAMediaTimingFunction(controlPoints: 0.25, 0.9, 0.3, 1)
        let from = T.frontFrom * w, to = T.frontTo * w
        func run(_ key: String, on target: CALayer) {
            let anim = CABasicAnimation(keyPath: "position.x")
            anim.fromValue = from; anim.toValue = to
            anim.duration = config.look.duration
            anim.timingFunction = curve
            anim.timeOffset = elapsed
            target.add(anim, forKey: key)
        }
        spreadMask.bounds = CGRect(x: 0, y: 0, width: 4 * w, height: h)
        spreadMask.position = CGPoint(x: 1.5 * w, y: h / 2)
        spread.mask = spreadMask
        run(Self.frontKeys[0], on: spreadMask)
        run(Self.frontKeys[1], on: band)
        run(Self.frontKeys[2], on: sheen)
        drift(config, after: config.look.duration - elapsed)
    }

    /// The slow light: across the capsule and back on the render server, at
    /// `maxFrameRate` at most. Removed while the glass is still.
    private func drift(_ config: Config, after delay: Double = 0) {
        band.removeAnimation(forKey: Self.driftKey)
        sheen.removeAnimation(forKey: Self.driftKey)
        driftWidth = nil
        let w = bounds.width, h = bounds.height
        if !config.moves || window == nil || w <= 1 || config.look.style.isPlain {
            band.position = CGPoint(x: config.look.lightAt * w, y: h / 2)
            sheen.position = band.position
            return
        }
        driftWidth = w
        let anim = CABasicAnimation(keyPath: "position.x")
        anim.fromValue = T.travel.from * w
        anim.toValue = T.travel.to * w
        anim.duration = config.look.style.crossingSeconds
        anim.autoreverses = T.autoreverse
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        anim.isRemovedOnCompletion = false
        // No backward fill: until it begins, the front's own movement holds the band.
        anim.beginTime = band.convertTime(CACurrentMediaTime(), from: nil) + max(0, delay)
        anim.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: T.maxFrameRate, preferred: T.maxFrameRate)
        band.add(anim, forKey: Self.driftKey)
        sheen.add(anim, forKey: Self.driftKey)
    }

    private func stop() {
        driftWidth = nil
        for l in [band, sheen, spreadMask, glow] as [CALayer] { l.removeAllAnimations() }
        if let config { place(config) }
    }
}

extension View {
    func laaGlassSelection(step: LAASelectionStep, tone: LAAVeinTone = .stone, seed: UInt64 = 0,
                           motion: LAAGlassMotion, cornerRadius: CGFloat) -> some View {
        modifier(LAAGlassSelection(step: step, tone: tone, seed: seed, motion: motion, cornerRadius: cornerRadius))
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
