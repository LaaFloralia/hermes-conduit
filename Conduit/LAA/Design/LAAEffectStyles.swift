#if LAA_BUILD
import UIKit

// The looks Studio hands over, each held in one place so new materials and
// values change only these definitions (owner, 2026-11-15): the strong
// selection's glass reads hq/design/tokens.json `appSelection` (generated
// into LAAAppSelectionTokens.swift), and Send's burst its style below.
// LAA_DESIGN.md and FEATURE_MAP's rulings describe the current values.

/// Whose look a strong selection wears: the stone (a strong effort under any
/// other model), or one model's own colour.
enum LAAVeinTone: Equatable, CaseIterable {
    case stone, mythos, astra, fable, neon

    var tokens: LAAAppSelectionTokens.Model {
        switch self {
        case .stone: LAAAppSelectionTokens.stone
        case .mythos: LAAAppSelectionTokens.mythos
        case .astra: LAAAppSelectionTokens.astra
        case .fable: LAAAppSelectionTokens.fable
        case .neon: LAAAppSelectionTokens.neon
        }
    }
}

extension LAAModelRank {
    var tone: LAAVeinTone {
        switch self {
        case .mythos: .mythos
        case .astra: .astra
        case .fable: .fable
        case .neon: .neon
        case .none: .stone
        }
    }
}

extension LAAAppSelectionTokens.RGB {
    var ui: UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }
}

/// The look of one capsule, worked out from `appSelection.formula`:
/// I = models[tone].strength × steps[step].intensity, every layer's strength
/// following I and capped at 1. Mythos is the strongest, Astra and Fable
/// next; XHigh < Max < Ultra Code; High and below (and other models) plain.
struct LAASelectionStyle: Equatable {
    struct RGB: Equatable {
        var r: Double, g: Double, b: Double
        var color: UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }
    }
    struct Pair: Equatable {
        var dark: RGB, light: RGB
        func ui(dark isDark: Bool) -> UIColor { (isDark ? dark : light).color }
    }

    let tone: LAAVeinTone
    let step: LAASelectionStep

    var model: LAAAppSelectionTokens.Model { tone.tokens }
    var intensity: Double { model.strength * step.tokens.intensity }
    var isPlain: Bool { intensity <= 0 }
    private var capped: Double { min(1, max(0, intensity)) }

    /// glass.bodyOpacity × (0.55 + 0.45 × min(I, 1)) (formula.bodyOpacity).
    func bodyOpacity(dark: Bool) -> Double {
        isPlain ? 0 : LAAAppSelectionTokens.bodyOpacity.value(dark: dark) * (0.55 + 0.45 * capped)
    }
    /// pattern.opacity[layer] × I, capped at 1.
    func veinOpacity(_ layer: LAAAppSelectionTokens.Pair, dark: Bool) -> Double {
        min(1, layer.value(dark: dark) * max(0, intensity))
    }
    /// The hairline layer, further scaled by the step's `hair`.
    func hairOpacity(dark: Bool) -> Double {
        min(1, LAAAppSelectionTokens.hairOpacity.value(dark: dark) * max(0, intensity) * step.tokens.hair)
    }
    /// light.peak × I.
    func lightOpacity(dark: Bool) -> Double { min(1, LAAAppSelectionTokens.lightPeak.value(dark: dark) * max(0, intensity)) }
    /// glass.glowOpacity × I.
    func glowOpacity(dark: Bool) -> Double { min(1, LAAAppSelectionTokens.glowOpacity.value(dark: dark) * max(0, intensity)) }
    /// pattern.tilePt × models.tileScale × steps.tileScale (smaller is denser).
    var tileSize: CGSize {
        let scale = model.tileScale * step.tokens.tileScale
        return CGSize(width: LAAAppSelectionTokens.tilePt.width * scale, height: LAAAppSelectionTokens.tilePt.height * scale)
    }
    /// One crossing of the light: light.secondsPerCrossing × models.speed × steps.speed.
    var crossingSeconds: Double { LAAAppSelectionTokens.secondsPerCrossing * model.speed * step.tokens.speed }
}

/// Send's burst (BUS-452). The owner's reference is the clip's 24–25.5 s
/// (owner, 2026-11-15 11時, replacing 5.8–9 s): Send lights in the clip's
/// blue (#3487F8; 「参考元と同じく色は蒼にして」), and small blue squares with a
/// soft light bleed up and to the left of it to about five times its size,
/// then everything is gone within about half a second (「ちょっとでかくなり
/// すぎたのでもう少し抑え目に」, after the 10時 「画面右下から大きく」). Every value
/// the burst reads is here, so a new look is a change of these numbers only.
/// Times are seconds from the tap; lengths are points; the origin is Send's
/// center and y grows downward, so the field lies at negative x and y.
struct LAASendEffectStyle {
    /// Where the burst starts, from Send's center.
    var originOffset = CGSize.zero
    /// How far up and to the left of Send the panes reach, before the window
    /// edge caps it.
    var reach = CGSize(width: 190, height: 140)
    /// The fan they spread over, in degrees: 0 straight left, 90 straight up.
    var fan: ClosedRange<Double> = -14...104
    /// The grid every pane lands on.
    var grid: CGFloat = 4
    /// Panes: how many, and in Low Power Mode.
    var paneCount = 30
    var lowPowerPaneCount = 10
    /// Pane sides, nearer panes taking the smaller ones.
    var paneSides: [CGFloat] = [4, 8, 8, 12, 16]
    var paneCorner: CGFloat = 2
    /// The accent's opacity in a pane at its nearest and farthest, light then
    /// dark; a far pane is fainter, as if out of focus.
    var paneTint = (near: 0.85, far: 0.30)
    var paneTintDark = (near: 0.90, far: 0.35)
    /// The 1 pt rim of the glass's rim light on every other pane.
    var paneRim: CGFloat = 1
    /// The soft light that spreads with the panes (a radial gradient, no blur).
    var bloomRadius: CGFloat = 120
    var bloomOpacity = 0.45
    var bloomOpacityDark = 0.55
    /// Send's own glass: the accent it takes, then the orb it turns into.
    var buttonSide: CGFloat = 36
    var litOpacity = 1
    var orbScale: CGFloat = 1.25
    /// The colour; nil is the app's accent (LAAColor.link).
    var color: LAASelectionStyle.Pair? = .init(dark: Self.clipBlue, light: Self.clipBlue)
    /// The clip's blue, #3487F8.
    static let clipBlue = LAASelectionStyle.RGB(r: 52.0 / 255, g: 135.0 / 255, b: 248.0 / 255)

    /// Steps: Send takes the colour (`lit`), the panes leave Send (from
    /// `spreadStart`, each `travel` long, the farthest `stagger` later), Send
    /// becomes an orb (`orbStart`…`duration`) and everything is gone by
    /// `duration`, when the thinking row carries on.
    var lit: CFTimeInterval = 0.08
    var spreadStart: CFTimeInterval = 0.04
    var travel: CFTimeInterval = 0.30
    var stagger: CFTimeInterval = 0.08
    var orbStart: CFTimeInterval = 0.24
    var duration: CFTimeInterval = 0.56
    /// LAA's state curve, cubic-bezier(.25,.9,.3,1).
    var curve: [Float] = [0.25, 0.9, 0.3, 1]

    static let current = LAASendEffectStyle()

    func tint(dark: Bool) -> (near: Double, far: Double) { dark ? paneTintDark : paneTint }
    func bloom(dark: Bool) -> Double { dark ? bloomOpacityDark : bloomOpacity }

    struct Pane: Equatable { var end: CGPoint; var side: CGFloat; var reach: Double }

    /// The panes for a field this far from Send (capped by the window), the
    /// nearest first, each on its own grid square outside Send's glass.
    /// A pure function of the style: the same send always draws the same.
    func panes(limit: CGSize? = nil) -> [Pane] {
        let width = min(reach.width, limit?.width ?? reach.width)
        let height = min(reach.height, limit?.height ?? reach.height)
        var seed: UInt64 = 0x5EED_1A55
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        var taken = Set<String>()
        var found: [Pane] = []
        var tries = 0
        while found.count < paneCount, tries < paneCount * 40 {
            tries += 1
            // Denser near Send, thinning toward the edge of the field.
            let r = 0.12 + 0.88 * pow(next(), 0.8)
            let angle = (fan.lowerBound + (fan.upperBound - fan.lowerBound) * next()) * .pi / 180
            let x = (-cos(angle) * r * width / grid).rounded() * grid
            let y = (-sin(angle) * r * height / grid).rounded() * grid
            let key = "\(Int(x)),\(Int(y))"
            guard hypot(x, y) > buttonSide, !taken.contains(key) else { continue }
            let index = min(paneSides.count - 1, Int(r * Double(paneSides.count)))
            let side = paneSides[index]
            // Neighbours never sit on top of each other.
            guard !found.contains(where: { abs($0.end.x - x) < ($0.side + side) / 2 && abs($0.end.y - y) < ($0.side + side) / 2 }) else { continue }
            taken.insert(key)
            found.append(Pane(end: CGPoint(x: x, y: y), side: side, reach: r))
        }
        return found.sorted { $0.reach < $1.reach }
    }
}

#endif
