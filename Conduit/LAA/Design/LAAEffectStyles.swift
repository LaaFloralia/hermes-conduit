#if LAA_BUILD
import UIKit

// The looks Studio hands over, each held in one place so new materials and
// values change only these definitions (owner, 2026-11-15): the strong
// selection's glass per model, and Send's burst. LAA_DESIGN.md and
// FEATURE_MAP's rulings describe the current values.

/// Whose look a strong selection wears: the stone's near-white (a strong
/// effort under any other model), or one model's own colour.
enum LAAVeinTone: Equatable, CaseIterable { case stone, mythos, astra, fable }

extension LAAModelRank {
    var tone: LAAVeinTone {
        switch self {
        case .mythos: .mythos
        case .astra: .astra
        case .fable: .fable
        case .none: .stone
        }
    }
}

/// The look of a strong selection, per model, held in this one place (owner,
/// 2026-11-15 09時): colour, pattern and strength. Mythos leans violet, Astra
/// blue, Fable orange; the stone stays near-white. These are interim values:
/// the final materials come from Studio (through Monet) and replace the table
/// below, nothing else. A still glass (Reduce Motion, Low Power Mode, off
/// screen) shows the same look with the light at rest.
struct LAASelectionStyle: Equatable {
    struct RGB: Equatable {
        var r: Double, g: Double, b: Double
        var color: UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }
    }
    struct Pair: Equatable {
        var dark: RGB, light: RGB
        func ui(dark isDark: Bool) -> UIColor { (isDark ? dark : light).color }
    }
    enum Pattern: Equatable {
        /// The drawn marble veins (LAAMarble).
        case veins
        /// An image in the asset catalogue, filling the glass behind the
        /// label in place of the veins (the veins again while it is missing).
        case texture(String)
    }

    /// The pattern's colour, before opacity.
    var ink: Pair
    /// A faint wash of the model's colour through the glass, and how much.
    var wash: Pair
    var washDark: Double, washLight: Double
    var pattern: Pattern = .veins
    /// Scales the pattern's and the light's opacity (1 the tier's own).
    var strength: Double = 1

    func washOpacity(dark: Bool) -> Double { dark ? washDark : washLight }

    static func of(_ tone: LAAVeinTone) -> LAASelectionStyle {
        switch tone {
        case .stone:
            .init(ink: .init(dark: .init(r: 0.93, g: 0.91, b: 0.86), light: .init(r: 0.45, g: 0.47, b: 0.47)),
                  wash: .init(dark: .init(r: 0.93, g: 0.91, b: 0.86), light: .init(r: 0.45, g: 0.47, b: 0.47)),
                  washDark: 0, washLight: 0)
        case .mythos:
            .init(ink: .init(dark: .init(r: 0.87, g: 0.82, b: 0.97), light: .init(r: 0.50, g: 0.43, b: 0.63)),
                  wash: .init(dark: .init(r: 0.56, g: 0.44, b: 0.88), light: .init(r: 0.55, g: 0.44, b: 0.85)),
                  washDark: 0.12, washLight: 0.08)
        case .astra:
            .init(ink: .init(dark: .init(r: 0.80, g: 0.88, b: 0.98), light: .init(r: 0.33, g: 0.45, b: 0.62)),
                  wash: .init(dark: .init(r: 0.36, g: 0.56, b: 0.94), light: .init(r: 0.34, g: 0.54, b: 0.90)),
                  washDark: 0.12, washLight: 0.08)
        case .fable:
            .init(ink: .init(dark: .init(r: 0.99, g: 0.86, b: 0.73), light: .init(r: 0.62, g: 0.42, b: 0.28)),
                  wash: .init(dark: .init(r: 0.95, g: 0.56, b: 0.27), light: .init(r: 0.93, g: 0.55, b: 0.28)),
                  washDark: 0.12, washLight: 0.08)
        }
    }
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
