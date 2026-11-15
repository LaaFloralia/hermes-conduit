#if LAA_BUILD
import SwiftUI
import UIKit

/// Send's one-shot burst (BUS-452; owner, 2026-11-14 the reference clip's
/// 9-second mark, 2026-11-15 「もう少し派手に…画面右下から大きく」). Send takes the
/// accent, panes of the accent on a grid spread from it over a large part of
/// the screen up and to the left with a soft light under them, Send turns
/// into a lit orb and everything is gone in under a second, where the
/// thinking row carries on. The send itself never waits for it.
/// Every value is `LAASendEffectStyle` (LAAEffectStyles.swift). Plain Core
/// Animation layers: no Canvas, display link, blur or offscreen surface.
struct LAASendEffect: UIViewRepresentable {
    var generation: Int
    var color: Color
    /// The glass's rim light (tan on the paper, the light glass in the dark).
    var rim: Color
    var reduceMotion: Bool
    var style: LAASendEffectStyle = .current

    func makeUIView(context: Context) -> LAASendEffectView {
        let view = LAASendEffectView()
        view.generation = generation
        return view
    }
    func updateUIView(_ view: LAASendEffectView, context: Context) {
        guard view.generation != generation else { return }
        view.generation = generation
        guard generation > 0 else { return }
        view.play(color: UIColor(color), rim: UIColor(rim), reduceMotion: reduceMotion, style: style)
    }
}

final class LAASendEffectView: UIView, CAAnimationDelegate {
    var generation = 0
    /// The burst playing now, if any.
    private(set) var burst: CALayer?
    /// When the burst playing now started, in media time.
    private(set) var startedAt: CFTimeInterval = 0

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        clipsToBounds = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The burst draws on the window's own layer, above the transcript and
    /// the composer, so no container clips the field it spreads over; on
    /// this view's layer when there is no window.
    func play(color: UIColor, rim: UIColor, reduceMotion: Bool, style: LAASendEffectStyle = .current,
              lowPower: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled) {
        clearBurst()
        let dark = traitCollection.userInterfaceStyle == .dark
        let accent = style.color?.ui(dark: dark) ?? color.resolvedColor(with: traitCollection)
        let light = rim.resolvedColor(with: traitCollection)
        let curve = CAMediaTimingFunction(controlPoints: style.curve[0], style.curve[1], style.curve[2], style.curve[3])
        let now = CACurrentMediaTime()
        startedAt = now
        let total = style.duration
        func at(_ time: CFTimeInterval) -> NSNumber { NSNumber(value: min(1, max(0, time / total))) }

        let center = CGPoint(x: bounds.midX + style.originOffset.width, y: bounds.midY + style.originOffset.height)
        let host: CALayer
        let origin: CGPoint
        var limit: CGSize? = nil
        if let window {
            host = window.layer
            origin = convert(center, to: window)
            limit = CGSize(width: max(0, origin.x - 8), height: max(0, origin.y - window.safeAreaInsets.top))
        } else {
            host = layer
            origin = center
        }
        let root = CALayer()
        root.position = origin
        root.zPosition = 1000
        host.addSublayer(root)
        burst = root

        // Send takes the accent: the only change Reduce Motion keeps.
        let side = style.buttonSide
        let core = CAShapeLayer()
        core.path = UIBezierPath(ovalIn: CGRect(x: -side / 2, y: -side / 2, width: side, height: side)).cgPath
        core.fillColor = accent.cgColor
        core.opacity = 0
        root.addSublayer(core)
        let lit = CAKeyframeAnimation(keyPath: "opacity")
        lit.values = [0, style.litOpacity, style.litOpacity, 0]
        lit.keyTimes = [0, at(style.lit), at(style.orbStart), 1]
        lit.duration = total
        lit.beginTime = now
        core.add(lit, forKey: "lit")

        if !reduceMotion {
            // The soft light spreading under the panes.
            let bloom = CAGradientLayer()
            bloom.type = .radial
            bloom.colors = [accent.withAlphaComponent(1).cgColor, accent.withAlphaComponent(0.45).cgColor, accent.withAlphaComponent(0).cgColor]
            bloom.locations = [0, 0.4, 1]
            bloom.startPoint = CGPoint(x: 0.5, y: 0.5)
            bloom.endPoint = CGPoint(x: 1, y: 1)
            bloom.bounds = CGRect(x: 0, y: 0, width: 2 * style.bloomRadius, height: 2 * style.bloomRadius)
            bloom.opacity = 0
            root.insertSublayer(bloom, at: 0)
            let bloomFade = CAKeyframeAnimation(keyPath: "opacity")
            let strength = style.bloom(dark: dark)
            bloomFade.values = [0, strength, strength * 0.7, 0]
            bloomFade.keyTimes = [0, at(style.spreadStart + style.travel * 0.5), at(style.orbStart + 0.12), 1]
            bloomFade.duration = total
            let bloomGrow = CABasicAnimation(keyPath: "transform.scale")
            bloomGrow.fromValue = 0.12
            bloomGrow.toValue = 1
            bloomGrow.duration = style.spreadStart + style.travel
            bloomGrow.timingFunction = curve
            let bloomGroup = CAAnimationGroup()
            bloomGroup.animations = [bloomFade, bloomGrow]
            bloomGroup.duration = total
            bloomGroup.beginTime = now
            bloom.add(bloomGroup, forKey: "bloom")

            // The rim light leaves Send's glass edge once.
            let ring = CAShapeLayer()
            ring.path = core.path
            ring.fillColor = nil
            ring.strokeColor = accent.cgColor
            ring.lineWidth = style.paneRim
            ring.opacity = 0
            root.addSublayer(ring)
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 1
            grow.toValue = 3
            grow.duration = style.travel
            grow.timingFunction = curve
            let glow = CAKeyframeAnimation(keyPath: "opacity")
            glow.values = [0, 0.9, 0]
            glow.keyTimes = [0, 0.25, 1]
            glow.duration = style.travel
            let release = CAAnimationGroup()
            release.animations = [grow, glow]
            release.duration = style.travel
            release.beginTime = now + style.spreadStart
            release.fillMode = .backwards
            ring.add(release, forKey: "release")

            // Send turns into a lit orb as the panes settle.
            let orb = CAGradientLayer()
            orb.type = .radial
            orb.colors = [UIColor.white.withAlphaComponent(0.9).cgColor, accent.cgColor, accent.withAlphaComponent(0).cgColor]
            orb.locations = [0, 0.55, 1]
            orb.startPoint = CGPoint(x: 0.5, y: 0.5)
            orb.endPoint = CGPoint(x: 1, y: 1)
            orb.bounds = CGRect(x: 0, y: 0, width: side * 1.6, height: side * 1.6)
            orb.opacity = 0
            root.addSublayer(orb)
            let orbFade = CAKeyframeAnimation(keyPath: "opacity")
            orbFade.values = [0, 0, 1, 0]
            orbFade.keyTimes = [0, at(style.orbStart), at(style.orbStart + 0.18), 1]
            orbFade.duration = total
            let orbGrow = CAKeyframeAnimation(keyPath: "transform.scale")
            orbGrow.values = [0.7, 0.7, style.orbScale, style.orbScale * 1.08]
            orbGrow.keyTimes = orbFade.keyTimes
            orbGrow.duration = total
            let orbGroup = CAAnimationGroup()
            orbGroup.animations = [orbFade, orbGrow]
            orbGroup.duration = total
            orbGroup.beginTime = now
            orb.add(orbGroup, forKey: "orb")

            let all = style.panes(limit: limit)
            let panes = lowPower ? Array(all.prefix(style.lowPowerPaneCount)) : all
            let tint = style.tint(dark: dark)
            for (index, spec) in panes.enumerated() {
                let pane = CALayer()
                pane.bounds = CGRect(x: 0, y: 0, width: spec.side, height: spec.side)
                pane.cornerRadius = style.paneCorner
                pane.cornerCurve = .continuous
                let alpha = tint.near + (tint.far - tint.near) * spec.reach
                pane.backgroundColor = accent.withAlphaComponent(CGFloat(alpha)).cgColor
                if index % 2 == 0 {
                    pane.borderColor = light.withAlphaComponent(CGFloat(0.4 + 0.6 * (1 - spec.reach))).cgColor
                    pane.borderWidth = style.paneRim
                }
                // Each pane leaves Send for its own grid square and rests
                // there (the model value) while it fades.
                pane.position = spec.end
                pane.opacity = 0
                root.addSublayer(pane)
                let delay = style.spreadStart + spec.reach * style.stagger
                let life = total - delay
                let travel = CABasicAnimation(keyPath: "position")
                travel.fromValue = NSValue(cgPoint: CGPoint(x: spec.end.x * 0.15, y: spec.end.y * 0.15))
                travel.toValue = NSValue(cgPoint: spec.end)
                travel.duration = style.travel
                travel.timingFunction = curve
                let size = CAKeyframeAnimation(keyPath: "transform.scale")
                size.values = [0.4, 1, 0.92]
                size.keyTimes = [0, NSNumber(value: style.travel / life), 1]
                size.duration = life
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0, 1, 0.8, 0]
                fade.keyTimes = [0, 0.18, NSNumber(value: style.travel / life), 1]
                fade.duration = life
                let group = CAAnimationGroup()
                group.animations = [travel, size, fade]
                group.duration = life
                group.beginTime = now + delay
                group.fillMode = .backwards
                pane.add(group, forKey: "send")
            }
        }
        let lifetime = CABasicAnimation(keyPath: "opacity")
        lifetime.fromValue = 1
        lifetime.toValue = 1
        lifetime.duration = total
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
#endif
