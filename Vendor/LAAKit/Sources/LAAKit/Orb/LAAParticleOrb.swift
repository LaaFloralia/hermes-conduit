import LAATokens
import SwiftUI
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// The shared LAA particle orb for chat, calls and voice input.
public struct LAAParticleOrb: View {
    /// The caller’s activity; the orb does not infer it.
    public enum State: Sendable, Equatable {
        /// The quiet, inward-drifting orb.
        case idle
        /// The fully lit orb while reasoning or producing text.
        case thinking
        /// The thinking appearance while a named tool runs.
        case tool
        /// The fully lit orb responding to microphone level.
        case listening
        /// The fully lit orb responding to playback level.
        case speaking
    }

    /// How to determine whether the host is visible.
    public enum Host: Sendable, Equatable {
        /// Follow SwiftUI scene visibility as well as the caller’s visibility flag.
        case scene
        /// Trust the caller’s visibility flag; on UIKit draw directly into a bitmap for keyboard extensions.
        case keyboardExtension
    }

    private let size: CGFloat
    private let state: State
    private let level: Double
    private let isActive: Bool
    private let isOnScreen: Bool
    private let host: Host
    private let seed: UInt64

    @Environment(\.laaPalette) private var palette
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @LAAReduceMotion private var reduceMotion
    @LAAReduceTransparency private var reduceTransparency
    @State private var appeared = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    /// Sets the diameter in points, activity and optional voice level (0–1); hidden or inactive orbs do not draw.
    public init(size: CGFloat = LAASpace.s32, state: State = .idle, level: Double = 0,
                isActive: Bool = true, isOnScreen: Bool = true, host: Host = .scene, seed: UInt64 = 0) {
        self.size = size.isFinite ? max(0, size) : 0
        self.state = state
        self.level = level
        self.isActive = isActive
        self.isOnScreen = isOnScreen
        self.host = host
        self.seed = seed
    }

    /// Renders only while visible, with a fixed particle frame under Reduce Motion.
    public var body: some View {
        let input = LAAOrbMoment.input(state: state, level: level)
        let face = LAAOrbFace(size: size, scale: displayScale, palette: palette,
                             bloom: !reduceTransparency, host: host, seed: seed)
        ZStack {
            switch LAAOrbPlayback.resolve(size: size, visible: appeared && isOnScreen,
                                          active: isActive, background: host == .scene && scenePhase == .background,
                                          reduceMotion: reduceMotion, lowPower: lowPower) {
            case .hidden:
                Color.clear.frame(width: size, height: size)
            case .still:
                LAAOrbFrame(face: face, moment: .still(state: state)).equatable()
            case .animated(let interval):
                LAAAnimatedOrb(face: face, input: input, interval: interval)
            }
        }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .onAppear {
                lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                appeared = true
            }
            .onDisappear { appeared = false }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
    }
}

enum LAAOrbPlayback: Equatable {
    case hidden, still, animated(interval: Double)

    static func resolve(size: CGFloat, visible: Bool, active: Bool, background: Bool,
                        reduceMotion: Bool, lowPower: Bool) -> Self {
        guard size > 0, visible, active, !background else { return .hidden }
        let compact = size <= LAASpace.s48
        if reduceMotion || (compact && lowPower) { return .still }
        return .animated(interval: compact || lowPower ? 1.0 / 20 : 1.0 / 30)
    }
}

struct LAAOrbMoment: Equatable {
    var beat = 1.05
    var wave = 0.0
    var level = 0.0
    var thinking = 0.0

    static func input(state: LAAParticleOrb.State, level: Double) -> Self {
        let followsVoice = state == .listening || state == .speaking
        return Self(level: followsVoice && level.isFinite ? min(1, max(0, level)) : 0,
                    thinking: state == .idle ? 0 : 1)
    }

    // A live audio meter must not animate the Reduce Motion frame.
    static func still(state: LAAParticleOrb.State) -> Self { input(state: state, level: 0) }
}

// The Voice clock smooths meter and state changes, and clamps gaps after a suspension.
@MainActor final class LAAOrbClock {
    private var last: Date?
    private var moment = LAAOrbMoment()

    func advance(to date: Date, input: LAAOrbMoment) -> LAAOrbMoment {
        guard let last else {
            self.last = date
            moment = input
            return moment
        }
        let step = min(0.1, max(0, date.timeIntervalSince(last)))
        self.last = date
        moment.level += (input.level - moment.level) * (1 - exp(-step * (input.level > moment.level ? 14 : 4.5)))
        moment.thinking += (input.thinking - moment.thinking) * (1 - exp(-step * 3.5))
        moment.beat = (moment.beat + step * 0.35 * (1 + 0.6 * moment.level)).truncatingRemainder(dividingBy: 2 * .pi)
        moment.wave = (moment.wave + step * 2.2).truncatingRemainder(dividingBy: 2 * .pi)
        return moment
    }
}

private struct LAAAnimatedOrb: View {
    let face: LAAOrbFace
    let input: LAAOrbMoment
    let interval: Double
    // The timeline alone invalidates the drawing; the clock has no observable properties.
    @State private var clock = LAAOrbClock()

    var body: some View {
        TimelineView(.animation(minimumInterval: interval)) { timeline in
            LAAOrbFrame(face: face, moment: clock.advance(to: timeline.date, input: input)).equatable()
        }
    }
}

// A faster metering producer can update the input between ticks without redrawing the same frame.
private struct LAAOrbFrame: View, Equatable {
    let face: LAAOrbFace
    let moment: LAAOrbMoment

    var body: some View {
        drawing
            .frame(width: face.size * 1.3, height: face.size * 1.3)
            .frame(width: face.size, height: face.size)
    }

    @ViewBuilder private var drawing: some View {
        #if canImport(UIKit) && !os(watchOS)
        if face.host == .keyboardExtension {
            LAAOrbBitmap(face: face, moment: moment)
        } else {
            canvas
        }
        #else
        canvas
        #endif
    }

    private var canvas: some View {
        Canvas { context, canvas in
            face.field(canvas: canvas, moment: moment).draw(&context, palette: face.palette, bloom: face.bloom)
        }
    }
}

private struct LAAOrbFace: Equatable {
    let size: CGFloat
    let scale: CGFloat
    let palette: LAAPalette
    let bloom: Bool
    let host: LAAParticleOrb.Host
    let seed: UInt64

    func field(canvas: CGSize, moment: LAAOrbMoment) -> LAAOrbParticleField {
        .frame(canvas: canvas, size: size, displayScale: scale, moment: moment, paper: !palette.isDark, seed: seed)
    }
}

#if canImport(UIKit) && !os(watchOS)
// Canvas filter surfaces can disappear inside keyboard extensions. Feed their ordinary bitmap the same field.
private struct LAAOrbBitmap: UIViewRepresentable {
    let face: LAAOrbFace
    let moment: LAAOrbMoment

    func makeUIView(context: Context) -> RasterView {
        let view = RasterView()
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        view.contentMode = .redraw
        return view
    }

    func updateUIView(_ view: RasterView, context: Context) {
        view.frameData = self
        view.contentScaleFactor = face.scale
        view.setNeedsDisplay()
    }

    final class RasterView: UIView {
        var frameData: LAAOrbBitmap?

        override func draw(_ rect: CGRect) {
            guard let data = frameData, let context = UIGraphicsGetCurrentContext(), !bounds.isEmpty else { return }
            let face = data.face
            let field = face.field(canvas: bounds.size, moment: data.moment)
            let palette = face.palette
            func rgba(_ color: LAARGB, alpha: Double) -> CGColor {
                CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: alpha)
            }
            context.setAlpha(field.opacity)
            context.setBlendMode(field.paper ? .normal : .plusLighter)
            for group in field.groups {
                context.saveGState()
                if face.bloom {
                    let color = field.paper ? palette.raw.accent : palette.raw.text
                    context.setShadow(offset: .zero, blur: 0.035 * field.radius,
                                      color: rgba(color, alpha: field.paper ? 0.12 : min(1, 0.5 * group.bloom)))
                }
                let tint = group.isAccent ? palette.raw.accent : palette.raw.text
                for (bucket, path) in group.paths.enumerated() {
                    let crisp = field.paper ? 2.0 : 1.0
                    let opacity = min(1, crisp * group.sharp * LAAOrbParticleField.alpha(bucket))
                    context.setFillColor(rgba(tint, alpha: opacity))
                    context.addPath(path.cgPath)
                    context.fillPath()
                }
                context.restoreGState()
            }
        }
    }
}
#endif
