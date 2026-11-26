#if LAA_BUILD
import LAAKit
import SwiftUI

typealias LAAOrbState = LAAParticleOrb.State

/// Keeps existing transcript and working-strip callers on the one kit renderer.
struct LAAOrbView: View {
    var state: LAAOrbState
    var level: Double = 0
    var diameter: CGFloat = LAASpace.s32
    var isOnScreen = true
    @Environment(\.laaForceReduceMotion) private var forceStill

    var body: some View {
        let hero = diameter >= LAAIconSize.tab
        // Enlarge the hero drawing without changing the line or sheet's layout.
        LAAParticleOrb(size: hero ? diameter + LAASpace.s4 : diameter, state: state, level: level)
            .frame(width: diameter, height: diameter)
            .environment(\.laaForceReduceMotion, forceStill || !isOnScreen)
    }
}
#endif
