import SwiftUI
import UIKit

/// Send's one-shot burst (BUS-452; the owner's reference, 2026-11-14: the
/// 9-second mark of a clip where Send lights and a grid of squares spreads
/// from it over the field). In LAA Glass: panes of the accent at the glass
/// tint with a 1 pt rim of the glass's rim light, the width of Send's own rim, landing on a 12 pt grid,
/// the button tinted once and its rim light released outward. Short: the panes travel for the slow step (420 ms), fade
/// within a quick step after it, and every layer is gone by `duration`.
/// A bounded compositor animation: no Canvas, display link, blur or offscreen
/// surface.
struct LAASendEffect: UIViewRepresentable {
    var generation: Int
    var color: Color
    /// The glass's rim light (tan on the paper, the light glass in the dark).
    var rim: Color
    var reduceMotion: Bool

    func makeUIView(context: Context) -> LAASendEffectView {
        let view = LAASendEffectView()
        view.generation = generation
        return view
    }
    func updateUIView(_ view: LAASendEffectView, context: Context) {
        guard view.generation != generation else { return }
        view.generation = generation
        guard generation > 0 else { return }
        view.play(color: UIColor(color), rim: UIColor(rim), reduceMotion: reduceMotion)
    }
}

final class LAASendEffectView: UIView, CAAnimationDelegate {
    var generation = 0
    private var burst: CALayer?

    /// The motion steps of the LAA design tokens: quick 120 ms, slow 420 ms.
    static let quick: CFTimeInterval = 0.12
    static let slow: CFTimeInterval = 0.42
    /// The panes leave in three waves this far apart.
    static let stagger: CFTimeInterval = 0.04
    /// Everything is removed by then.
    static let duration: CFTimeInterval = slow + quick + 2 * stagger
    /// The grid the panes settle on: one 12 pt step of the spacing scale.
    static let cell: CGFloat = 12
    /// Where each pane lands, in grid steps from Send's center (y up is
    /// negative): over the field to the left and above, since Send sits at
    /// the composer's trailing end. Nearest first; Low Power Mode keeps the
    /// first six.
    static let cells: [(x: Int, y: Int)] = [
        (-2, -1), (0, -2), (-1, -2), (2, -1), (-3, 0), (-3, -2),
        (-1, -3), (1, -3), (-5, -1), (-4, -3), (-2, -4), (0, -5),
    ]
    static let lowPowerPaneCount = 6
    /// The glass tint and the stronger tint of a lit control (`appSelection`
    /// tinted and intense opacities), light then dark.
    static func tint(dark: Bool) -> (glass: Float, lit: Float) { dark ? (0.26, 0.46) : (0.16, 0.30) }
    /// LAA's state curve, cubic-bezier(.25,.9,.3,1).
    private static let state = CAMediaTimingFunction(controlPoints: 0.25, 0.9, 0.3, 1)

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        clipsToBounds = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func play(color: UIColor, rim: UIColor, reduceMotion: Bool) {
        clearBurst()
        let dark = traitCollection.userInterfaceStyle == .dark
        let accent = color.resolvedColor(with: traitCollection)
        let light = rim.resolvedColor(with: traitCollection)
        let tint = Self.tint(dark: dark)
                let now = CACurrentMediaTime()

        let root = CALayer()
        root.position = CGPoint(x: bounds.midX, y: bounds.midY)
        layer.addSublayer(root)
        burst = root

        // Send takes the accent once: the only change Reduce Motion keeps.
        let core = CAShapeLayer()
        core.path = UIBezierPath(ovalIn: CGRect(x: -18, y: -18, width: 36, height: 36)).cgPath
        core.fillColor = accent.cgColor
        core.opacity = 0
        root.addSublayer(core)
        let lit = CAKeyframeAnimation(keyPath: "opacity")
        lit.values = [0, tint.lit, 0]
        lit.keyTimes = [0, NSNumber(value: Self.quick / Self.slow), 1]
        lit.duration = Self.slow
        core.add(lit, forKey: "lit")

        if !reduceMotion {
            // The rim light leaves the button's glass edge once.
            let ring = CAShapeLayer()
            ring.path = UIBezierPath(ovalIn: CGRect(x: -18, y: -18, width: 36, height: 36)).cgPath
            ring.fillColor = nil
            ring.strokeColor = light.cgColor
            ring.lineWidth = 1
            ring.opacity = 0
            root.addSublayer(ring)
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 1
            grow.toValue = 1.9
            grow.duration = Self.slow
            grow.timingFunction = Self.state
            let glow = CAKeyframeAnimation(keyPath: "opacity")
            glow.values = [0, 0.9, 0]
            glow.keyTimes = [0, 0.25, 1]
            glow.duration = Self.slow
            let release = CAAnimationGroup()
            release.animations = [grow, glow]
            release.duration = Self.slow
            ring.add(release, forKey: "release")

            let cells = ProcessInfo.processInfo.isLowPowerModeEnabled ? Array(Self.cells.prefix(Self.lowPowerPaneCount)) : Self.cells
            for (index, cell) in cells.enumerated() {
                let pane = CALayer()
                let side: CGFloat = index % 4 == 1 ? 2 * Self.cell : Self.cell
                pane.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                pane.cornerRadius = 4
                pane.cornerCurve = .continuous
                pane.backgroundColor = accent.withAlphaComponent(CGFloat(tint.glass)).cgColor
                pane.borderColor = light.cgColor
                pane.borderWidth = 1
                // Each pane leaves Send for its own square of a grid over
                // the field; the nearer ones first, so the grid spreads out.
                // It rests there (the model value) while it fades.
                let end = CGPoint(x: CGFloat(cell.x) * Self.cell, y: CGFloat(cell.y) * Self.cell)
                pane.position = end
                pane.opacity = 0
                root.addSublayer(pane)
                let reach = hypot(Double(cell.x), Double(cell.y))
                let travel = CABasicAnimation(keyPath: "position")
                travel.fromValue = NSValue(cgPoint: CGPoint(x: end.x * 0.2, y: end.y * 0.2))
                travel.toValue = NSValue(cgPoint: end)
                travel.duration = Self.slow
                travel.timingFunction = Self.state
                let size = CAKeyframeAnimation(keyPath: "transform.scale")
                size.values = [0.55, 1, 0.9]
                size.keyTimes = [0, 0.45, 1]
                size.duration = Self.slow + Self.quick
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0, 1, 0.75, 0]
                fade.keyTimes = [0, 0.2, 0.6, 1]
                fade.duration = Self.slow + Self.quick
                let group = CAAnimationGroup()
                group.animations = [travel, size, fade]
                group.duration = Self.slow + Self.quick
                group.beginTime = now + min(2, max(0, (reach - 2) / 1.5)) * Self.stagger
                group.fillMode = .backwards
                pane.add(group, forKey: "send")
            }
        }
        let lifetime = CABasicAnimation(keyPath: "opacity")
        lifetime.fromValue = 1
        lifetime.toValue = 1
        lifetime.duration = Self.duration
        lifetime.delegate = self
        root.add(lifetime, forKey: "lifetime")
    }

    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        guard flag else { return }
        clearBurst()
    }
    private func clearBurst() {
        let previous = burst
        burst = nil
        previous?.removeAllAnimations()
        previous?.removeFromSuperlayer()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        burst?.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { clearBurst() }
    }
}

/// The real activity label, revealed once; its full accessible text stays available throughout.
struct LAASendThinkingLabel: View {
    let text: String
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var revealed = false
    @State private var sweep = false

    var body: some View {
        Text(text)
            .mask(alignment: .leading) {
                if !active || reduceMotion || typeSize.isAccessibilitySize {
                    Rectangle()
                } else {
                    HStack(spacing: 0) {
                        ForEach(Array(text.enumerated()), id: \.offset) { index, letter in
                            Text(String(letter))
                                .opacity(revealed ? 1 : 0)
                                .animation(.easeOut(duration: 0.12).delay(Double(index) * min(0.04, 0.58 / Double(max(1, text.count - 1)))), value: revealed)
                        }
                    }
                }
            }
            .overlay {
                if active && !reduceMotion && !typeSize.isAccessibilitySize {
                    GeometryReader { bounds in
                        Rectangle().fill(Color.conduitAccent.opacity(0.5))
                            .frame(width: 12)
                            .offset(x: sweep ? bounds.size.width + 12 : -12)
                            .animation(.linear(duration: 0.42).delay(0.3), value: sweep)
                    }
                    .mask(Text(text))
                    .allowsHitTesting(false)
                }
            }
            .onAppear { revealed = true; sweep = true }
            .accessibilityLabel(text)
    }
}
