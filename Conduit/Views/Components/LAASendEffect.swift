import SwiftUI
import UIKit

/// A bounded, one-shot compositor animation. No Canvas, display link or offscreen blur surfaces.
struct LAASendEffect: UIViewRepresentable {
    var generation: Int
    var color: Color
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
        view.play(color: UIColor(color), reduceMotion: reduceMotion)
    }
}

final class LAASendEffectView: UIView, CAAnimationDelegate {
    var generation = 0
    private var burst: CALayer?
    static let duration: CFTimeInterval = 0.82

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        clipsToBounds = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func play(color: UIColor, reduceMotion: Bool) {
        clearBurst()
        let tint = color.resolvedColor(with: traitCollection).cgColor
        let root = CALayer()
        root.position = CGPoint(x: bounds.midX, y: bounds.midY)
        layer.addSublayer(root)
        burst = root
        let core = CAShapeLayer()
        core.path = UIBezierPath(ovalIn: CGRect(x: -18, y: -18, width: 36, height: 36)).cgPath
        core.fillColor = tint
        core.opacity = 0
        root.addSublayer(core)
        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [0, 0.65, 0.28, 0]
        flash.keyTimes = [0, 0.14, 0.5, 1]
        flash.duration = Self.duration
        core.add(flash, forKey: "color")
        if !reduceMotion {
            let count = ProcessInfo.processInfo.isLowPowerModeEnabled ? 8 : 20
            for index in 0..<count {
                let square = CALayer()
                let side = CGFloat(4 + index % 3 * 2)
                square.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                square.backgroundColor = tint
                square.opacity = 0
                root.addSublayer(square)
                // Fan upwards into the input field; never change the input's layout or hit targets.
                let angle = Double.pi * (1.05 + Double(index) / Double(count - 1) * 0.9)
                let distance = CGFloat(32 + index % 4 * 12)
                let start = CGPoint(x: cos(angle) * 14, y: sin(angle) * 14)
                let end = CGPoint(x: cos(angle) * distance, y: sin(angle) * distance)
                let travel = CABasicAnimation(keyPath: "position")
                travel.fromValue = NSValue(cgPoint: start)
                travel.toValue = NSValue(cgPoint: end)
                travel.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.9, 0.3, 1)
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0, 0.8, 0.45, 0]
                fade.keyTimes = [0, 0.18, 0.5, 1]
                let shrink = CABasicAnimation(keyPath: "transform.scale")
                shrink.fromValue = 1
                shrink.toValue = 0.35
                let group = CAAnimationGroup()
                group.animations = [travel, fade, shrink]
                group.duration = Self.duration - 0.12
                group.beginTime = CACurrentMediaTime() + Double(index % 3) * 0.04
                square.add(group, forKey: "send")
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
