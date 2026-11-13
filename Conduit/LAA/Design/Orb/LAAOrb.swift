#if LAA_BUILD
import SwiftUI

/// What the agent is really doing. The caller passes the conversation's own
/// state; the orb never invents one.
enum LAAOrbState: Equatable {
    /// Waiting: fewer particles lit, a slow drift.
    case idle
    /// Reasoning, or working with no tool named yet.
    case thinking
    /// A tool is running. Drawn as thinking; the words beside the orb name the tool.
    case tool
    /// Reading a reply aloud or listening. The heart and the shell follow `level`.
    case speaking
}

/// The LAA orb (owner, 2026-11-14): a sphere of white light particles, the
/// working mark of Chat, Work and LAA Voice. `diameter` points across; its
/// glow spills a little past the frame, so lay it out with the diameter.
///
/// Drawn by `LAAParticleOrb.draw`, the one file LAA Voice shares. On paper the
/// light sits inside a deep teal bead, since white light has no ground there.
struct LAAOrbView: View {
    var state: LAAOrbState
    /// 0...1, the loudness of the voice. Read in `.speaking` only.
    var level: Double = 0
    var diameter: CGFloat = 30
    /// False while its row is hidden: nothing is drawn again until it shows.
    var isOnScreen = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LAAOrbCanvas(size: diameter,
                     thinking: state == .idle ? 0 : 1,
                     level: state == .speaking ? min(1, max(0, level.isFinite ? level : 0)) : 0,
                     ground: Self.ground(dark: colorScheme == .dark, diameter: diameter),
                     paused: reduceMotion || !isOnScreen || scenePhase == .background)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: state)
            .frame(width: diameter, height: diameter)
            .accessibilityHidden(true)
    }

    /// Dark: light on the ground, with a faint rim once the orb is large
    /// enough to need an outline. Paper: the teal bead.
    static func ground(dark: Bool, diameter: CGFloat) -> LAAParticleOrb.Ground {
        guard dark else { return .paperBead }
        return diameter >= 120 ? .darkRim : .dark
    }
}

/// The moving drawing. `thinking` and `level` animate, so a change of state
/// fades in over the same particles instead of jumping.
private struct LAAOrbCanvas: View, Animatable {
    var size: CGFloat
    var thinking: Double
    var level: Double
    var ground: LAAParticleOrb.Ground
    var paused: Bool
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceTransparency) private var solid

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(thinking, level) }
        set { thinking = newValue.first; level = newValue.second }
    }

    var body: some View {
        // A small orb holds 20 frames a second; the large one (Voice) the display's.
        TimelineView(.animation(minimumInterval: size <= 48 ? 1.0 / 20 : 1.0 / 60, paused: paused)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, canvas in
                LAAParticleOrb.draw(&context, canvas: canvas, size: size, displayScale: displayScale,
                                    beat: (0.35 * t).truncatingRemainder(dividingBy: 2 * .pi),
                                    wave: (2.2 * t).truncatingRemainder(dividingBy: 2 * .pi),
                                    spin: (0.2 * t).truncatingRemainder(dividingBy: 20 * .pi),
                                    level: level, thinking: thinking, solid: solid, ground: ground)
            }
            .frame(width: size * 1.3, height: size * 1.3)
        }
        .frame(width: size, height: size)
    }
}
#endif
