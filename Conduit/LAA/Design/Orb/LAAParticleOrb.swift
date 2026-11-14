// LAAParticleOrb.swift: the LAA orb, a sphere of light particles (white on dark, ink on paper) (2026-11-14).
//
// One self-contained file, no assets, shared with LAA Voice (which compiles it with
// LAA_ORB_STANDALONE). Seen straight on: a soft band of fine streaks at the edge (0.88...1.0 R), a
// round grainy heart, and between them streaks and a few bright lumps in the upper half. Each
// particle flares and fades while it drifts in or out and a little sideways; its streak lies along
// that motion. Everything is a pure function of the moment's phases, so any instant can be drawn,
// and with the other phases held the pattern repeats every turn of `wave`: every particle lives a
// whole fraction of it. The parameters follow the voice keyboard's orb (size, displayScale, beat,
// wave, spin, level, thinking, solid) so either caller can feed it.
#if LAA_BUILD || LAA_ORB_STANDALONE
import SwiftUI

enum LAAParticleOrb {
    /// The ground under the orb. `dark`: white light that adds, its outline melting into the ground;
    /// `darkRim`: the same with a faint rim (the view picks it from 120 pt up); `paperBead`: on paper,
    /// no bead: the same particles in ink, the heart's cloud in teal, the paper itself as the ground.
    enum Ground { case dark, darkRim, paperBead }

    /// The same particle set at every size: the ball is only scaled, so a small orb looks like the
    /// large one shrunk (its particles average out under the pixels), not like a thinner drawing.
    /// The count is the inside particles; the shell adds two thirds of it. `radiusPx` is kept for
    /// callers that want to step the count down under load.
    static let fullCount = 1500
    static func particleCount(radiusPx: Double) -> Int { fullCount }

    /// Draws the orb centred in `canvas`. The ball's radius is 0.48 `size` (the orb's frame); its glow
    /// ends by 1.3 radii, so give the canvas 1.3 `size` and let it overflow the frame.
    static func draw(_ ctx: inout GraphicsContext, canvas: CGSize, size: CGFloat, displayScale: CGFloat,
                     beat: Double, wave: Double, spin: Double, level: Double, thinking: Double, solid: Bool,
                     ground: Ground = .dark, count: Int? = nil) {
        let c = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        let R = Double(size) * 0.48
        let px = 1 / Double(displayScale)
        let light = (0.82, 0.89, 1.0)                        // blue-white
        // On paper the light turns into ink, the negative of the dark orb: no disc, no outline, no haze over
        // the body, so the paper shows between the particles and they alone give the ball its form. The
        // streaks are ink (text #213536), the pale grains and the heart accent (#00585E); the ink is denser
        // toward the bottom, the side away from the light. Nothing else changes, and the dark orb is untouched.
        let paper = ground == .paperBead
        let ink = (0.129, 0.208, 0.212), teal = (0.0, 0.345, 0.369)
        let lit: GraphicsContext.BlendMode = paper ? .normal : .plusLighter
        let crisp = paper ? 2.0 : 1.0                        // the sharp streaks: ink needs a little more
        let breath = 1 + 0.20 * sin(wave) + 0.02 * sin(beat) + 0.25 * level
        let activity = 0.55 + 0.45 * thinking                // how many particles are lit
        // Quiet (thinking 0, e.g. replying on another device): the light dims to about 57% and the outer
        // streams and lumps draw in toward the heart and fade. At thinking 1 none of this applies.
        let idle = 1 - max(0, min(1, thinking))
        func color(_ t: (Double, Double, Double), _ a: Double) -> Color {
            Color(red: t.0, green: t.1, blue: t.2).opacity(max(0, min(1, a)))
        }
        func disc(_ r: Double) -> Path {
            Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
        func radial(_ r: Double, _ tint: (Double, Double, Double), _ stops: [(Double, Double)]) {
            ctx.fill(disc(r), with: .radialGradient(Gradient(stops: stops.map {
                .init(color: color(tint, $0.1), location: $0.0) }), center: c, startRadius: 0, endRadius: r))
        }

        // Ground under the light: a solid disc when transparency is reduced (paper keeps no ground).
        if solid && !paper {
            ctx.fill(disc(R * 1.02), with: .color(Color(red: 0.059, green: 0.106, blue: 0.110)))
        }
        if ground == .darkRim {
            ctx.stroke(disc(R * 1.05), with: .linearGradient(Gradient(colors: [
                Color.white.opacity(0.16), Color.white.opacity(0.05), Color.white.opacity(0.09)]),
                startPoint: CGPoint(x: c.x, y: c.y - R), endPoint: CGPoint(x: c.x, y: c.y + R)),
                lineWidth: max(px, 0.008 * R))
        }

        if idle > 0 { ctx.opacity = 1 - 0.35 * idle }
        ctx.blendMode = lit
        // Glow on the dark ground only, gone by 1.3 R. Inside, a haze that falls smoothly from the
        // centre to the edge (no dark moat before the shell), and a soft heart: a cloud, not a dot.
        if !paper {
            radial(R * 1.3, light, [(0.70, 0.07), (0.77, 0.085), (0.81, 0.09), (0.85, 0.075), (0.92, 0.035), (1.0, 0)])
        }
        if !paper {
            radial(R * 1.0, light, [(0, 0.32), (0.3, 0.36), (0.4, 0.25), (0.5, 0.19), (0.6, 0.17), (0.7, 0.16), (0.8, 0.13),
                                    (0.9, 0.07), (0.95, 0.04), (0.98, 0.015), (1, 0)])
        }
        // The heart: a round soft cloud (pale blue only at its edge) and on it a few very soft white
        // lumps close together and drifting, so the blown-out middle is round with a slightly uneven,
        // misty outline (no corners, no dark gaps). Neither blows out alone: the grains and short streaks
        // on top reach white where they pile up, so the middle stays grainy.
        let hb = 1 + 0.04 * sin(wave) + 0.25 * level          // the heart keeps its size and shape
        let heartR = R * (0.36 + 0.03 * level) * hb
        let hk = paper ? 1.4 : 1.0, lk = paper ? 0.7 : 1.0   // on paper: the heart a deeper teal, its lumps lighter
        radial(R * 0.46 * hb, paper ? teal : (0.80, 0.88, 1.0),
               [(0, 0.40), (0.5, 0.36), (0.75, 0.2), (0.9, 0.06), (1, 0)].map { ($0.0, hk * $0.1) })
        for j in 0..<6 {
            let hj = UInt64(900 + j)
            let a = 2 * .pi * hash(hj, 1) + 0.5 * sin(wave + 1.7 * Double(j)) + 0.3 * sin(beat + Double(j))
            let off = R * (j == 0 ? 0 : 0.03 * hash(hj, 2))
            let r = heartR * (0.74 + 0.08 * hash(hj, 3))
            let hc = CGPoint(x: c.x + off * cos(a), y: c.y + off * sin(a))
            ctx.fill(Path(ellipseIn: CGRect(x: hc.x - r, y: hc.y - r, width: 2 * r, height: 2 * r)),
                     with: .radialGradient(Gradient(stops: [(0.0, 0.36), (0.35, 0.30), (0.65, 0.13), (0.85, 0.03), (1.0, 0.0)].map {
                         .init(color: color(paper ? teal : (1.0, 1.0, 1.0), lk * $0.1), location: $0.0) }),
                         center: hc, startRadius: 0, endRadius: r))
        }

        // Particles. Each lives 1/k of the wave's turn, flares and fades while it drifts in or out and a
        // little sideways, then
        // reappears elsewhere. Every one is a streak along its outward motion that tapers to nothing at
        // both ends (motion blur), filled as a lens.
        //   inside (`n`): 1 core cloud (fine grains to 0.4 R, many pale blue), 6 short bright rays from
        //     the heart's edge (0.2...0.47 R), 5 streams (0.3...0.6 R), 3 medium bright streaks all round
        //     (0.4...0.85 R), 4 hairs (very thin long dim streaks);
        //   0 shell (`n` x 2/3): a soft band 0.88...1.0 R, brightest near 0.94 R, lumps and gaps along it;
        //   2 drops (38 big bright lumps with a soft halo, most in six small clusters apart in the upper half, kept off the heart: 0.54...0.8 R).
        // Shell, rain, hairs and drops lie across the view (placed by their seen radius), so the shell
        // is one band at the edge and nothing piles up into a second ring.
        let n = count ?? particleCount(radiusPx: R * Double(displayScale))
        let nShell = n * 2 / 3, nDrops = 38
        let phase = (wave / (2 * .pi)).truncatingRemainder(dividingBy: 1) + (wave < 0 ? 1 : 0)
        let buckets = 6
        var shellP = [Path](repeating: Path(), count: buckets)
        var coreP = [Path](repeating: Path(), count: buckets)
        var rainP = [Path](repeating: Path(), count: buckets)
        var dropP = [Path](repeating: Path(), count: buckets)
        var blueP = [Path](repeating: Path(), count: buckets)        // pale blue grains around the heart
        var haloP = Path()                                          // wide soft light around the big lumps
        let width = 0.0145 * R                              // widest point of a fine streak
        func lens(_ x: Double, _ y: Double, _ ux: Double, _ uy: Double, _ len: Double, _ w0: Double) -> Path {
            // a streak centred on (x, y) along (ux, uy), len long, w wide at the middle, pointed ends; on paper
            // never thinner than half a pixel, or the finest grains vanish at row sizes and leave the heart alone
            let w = paper ? max(w0, 0.5 * px) : w0
            let hx = ux * len / 2, hy = uy * len / 2, nx = -uy * w, ny = ux * w
            var p = Path()
            p.move(to: CGPoint(x: x - hx, y: y - hy))
            p.addQuadCurve(to: CGPoint(x: x + hx, y: y + hy), control: CGPoint(x: x + nx, y: y + ny))
            p.addQuadCurve(to: CGPoint(x: x - hx, y: y - hy), control: CGPoint(x: x - nx, y: y - ny))
            p.closeSubpath()
            return p
        }
        for i in 0..<(n + nShell + nDrops) {
            let m = i % 25
            let kind = i >= n + nShell ? 2 : i >= n ? 0 : (m < 4 ? 3 : m < 5 ? 4 : m < 9 ? 6 : m < 14 ? 5 : 1)
            let k = kind == 0 ? 9 + Int(hash(UInt64(i), 0) * 10)
                  : kind == 2 ? 4 + Int(hash(UInt64(i), 0) * 4) : 13 + Int(hash(UInt64(i), 0) * 14)
            let x = phase * Double(k) + hash(UInt64(i), 1)
            let cyc = Int(x) % k, u = x - floor(x)
            let s = UInt64(i) &* 977 &+ UInt64(cyc) &* 7919
            if kind != 2 && hash(s, 2) > activity { continue }
            let inPlane = kind != 1 && kind != 5 && kind != 6
            // Direction: uniform on the sphere, z toward the viewer (the core cloud and its streams).
            let dz = inPlane ? 0 : 2 * hash(s, 3) - 1
            var phi = 2 * .pi * hash(s, 4)
            let sxy = (1 - dz * dz).squareRoot()
            var ux = cos(phi)
            var uy = sin(phi)
            if kind == 2 && uy > 0 && hash(s, 13) < 0.85 { uy = -uy }   // drops gather in the upper half
            let life = 2.86 / Double(k)
            var rho: Double, len: Double, w: Double, peak: Double, speed: Double, env0: Double
            var shade = 1.0, upW = paper ? -0.45 : 0.35
            switch kind {
            case 0:
                // brightness clumps along the band (the outline stays an exact circle); top brighter
                // bright lumps and dark gaps alternate along the band
                let clump = 0.55 + 0.50 * sin(3 * phi + 1.3 + 0.5 * beat) + 0.35 * sin(7 * phi + 4.1 - 0.8 * beat)
                                 + 0.20 * sin(13 * phi + 2.0 + 1.3 * beat)
                shade = max(0.12, min(1.5, clump)) * (0.35 + 0.85 * hash(s, 12)); upW = paper ? -0.45 : 0.3
                let h5 = hash(s, 5)
                // a wide band 0.88...1.0 R: longer and dimmer inward, brightest near 0.94 R, the outer row dim
                len = 0.04 * (1 + 1.0 * (1 - h5)) * exp(0.35 * gauss(hash(s, 6), hash(s, 7)))
                // on paper the band reaches further in and fades in slowly (0.72...1.0 R, lighter, and lighter
                // still when quiet), so the ink thickens toward the limb like a ball instead of drawing a thin ring
                rho = min((paper ? 0.72 : 0.88) + (paper ? 0.28 : 0.12) * pow(h5, 0.6), 0.997 - len / 2)
                shade *= 0.25 + 0.75 * exp(-pow((rho - 0.94) / (paper ? 0.09 : 0.035), 2))
                if paper { shade *= 1 - 0.5 * idle }
                w = 0.0125 * R
                peak = 1.5 * (1 + 0.6 * level); speed = 0; env0 = pow(sin(.pi * u), 0.8)
            case 1:
                rho = hash(s, 11) < 0.40 ? 0.40 * pow(hash(s, 5), 0.5) : 0.24 + 0.32 * hash(s, 5)
                len = 0.03 * exp(0.4 * gauss(hash(s, 6), hash(s, 7)))
                w = width * 0.75
                peak = 3.0; speed = 0.10 + 0.10 * thinking; env0 = pow(sin(.pi * u), 0.8)
            case 6:
                // short bright streaks unravelling from the heart's edge
                rho = 0.20 + 0.27 * hash(s, 5)
                len = 0.03 + 0.03 * hash(s, 6)
                w = width * 0.55
                peak = 2.6; speed = 0.12 + 0.12 * thinking; env0 = pow(sin(.pi * u), 0.8)
            case 5:
                rho = 0.38 + 0.27 * hash(s, 5)
                len = 0.03 + 0.04 * hash(s, 6)
                w = width * 0.7
                peak = 2.0; speed = 0.12 + 0.12 * thinking; env0 = pow(sin(.pi * u), 0.9)
            case 3:
                // medium bright streaks all round the middle (left and bottom too)
                rho = 0.40 + 0.45 * pow(hash(s, 5), 1.2)
                len = 0.05 + 0.07 * hash(s, 6)
                w = width * 0.8
                peak = 2.7; speed = 0.12 + 0.12 * thinking; env0 = pow(sin(.pi * u), 1.0)
            case 4:
                len = 0.15 + 0.15 * hash(s, 6)
                rho = 0.22 + 0.3 * hash(s, 5) + len / 2
                w = 0.004 * R
                peak = 0.4; speed = 0.15 + 0.15 * thinking; env0 = pow(sin(.pi * u), 1.0)
            default:
                // big bright lumps: most gather in four clusters in the upper half, drifting slowly
                if hash(s, 15) < 0.65 {
                    let j = Int(hash(UInt64(i), 16) * 6)
                    let ca = [-2.65, -2.15, -1.7, -1.25, -0.8, -0.4][j] + 0.08 * sin(beat + Double(j))
                    let cr = [0.62, 0.70, 0.58, 0.68, 0.60, 0.66][j]
                    // spread evenly over the cluster (not piled at its middle), so lumps stay apart
                    let da = 0.50 * (hash(s, 17) - 0.5), dr = 0.16 * (hash(s, 19) - 0.5)
                    let ex = (cr + dr) * cos(ca + da), ey = (cr + dr) * sin(ca + da)
                    rho = min(0.8, max(0.54, (ex * ex + ey * ey).squareRoot())); phi = atan2(ey, ex)
                    ux = cos(phi); uy = sin(phi)
                } else {
                    rho = 0.54 + 0.24 * hash(s, 5)
                }
                len = 0.06 + 0.08 * hash(s, 6)
                w = 0.024 * R * (0.5 + 0.7 * hash(s, 9))
                peak = 2.2; speed = 0.15 + 0.15 * thinking; env0 = pow(sin(.pi * u), 1.3)
            }
            if kind != 0 && hash(s, 30) < 0.5 { speed = -speed }
            rho = rho * sxy + speed * (u - 0.5) * life * sxy
            var gather = 1.0                                // quiet: outer streams and lumps draw in and fade
            if idle > 0 && (kind == 2 || kind == 3 || kind == 4 || kind == 5) {
                rho *= 1 - 0.35 * idle; gather = 1 - 0.5 * idle
            }
            if kind != 0 {
                let vt = (hash(s, 31) - 0.5) * 0.36 * (0.7 + 0.3 * thinking)
                let dphi = vt * (u - 0.5) * life / max(rho, 0.15)
                let cx = cos(dphi), sx = sin(dphi)
                (ux, uy) = (ux * cx - uy * sx, ux * sx + uy * cx)
            }
            let up = -uy * rho                              // screen y grows downward
            let depth = 0.82 + 0.18 * dz                    // the far side a little dimmer
            let env = env0 * peak * (0.65 + 0.35 * hash(s, 8)) * breath * (1 + upW * up) * depth * shade * gather
            // seen length: the outward motion foreshortened (a dot when it moves toward the viewer)
            let seen = max(len * sxy * R, 1.6 * w)
            let p = lens(c.x + ux * rho * R, c.y + uy * rho * R, ux, uy, seen, w)
            let bk = max(0, min(buckets - 1, Int(env * Double(buckets))))
            switch kind {
            case 0: shellP[bk].addPath(p)
            case 1: if hash(s, 14) < 0.42 { blueP[bk].addPath(p) } else { coreP[bk].addPath(p) }
            case 5, 6: coreP[bk].addPath(p)
            case 2:
                // two or three spindles a little apart, so the lump's outline is ragged and melts
                dropP[bk].addPath(p)
                for q in 0..<(hash(s, 21) < 0.5 ? 0 : 1) {
                    let sx = (hash(s, 22 + UInt64(q)) - 0.5) * 0.06 * R, sy = (hash(s, 24 + UInt64(q)) - 0.5) * 0.06 * R
                    let tw = 0.25 * (hash(s, 26 + UInt64(q)) - 0.5)
                    let vx = ux * cos(tw) - uy * sin(tw), vy = ux * sin(tw) + uy * cos(tw)
                    dropP[max(0, bk - 1)].addPath(lens(c.x + ux * rho * R + sx, c.y + uy * rho * R + sy, vx, vy,
                                                       seen * (0.6 + 0.4 * hash(s, 28 + UInt64(q))), w * 0.7))
                }
                if env > 0.35 { haloP.addPath(lens(c.x + ux * rho * R, c.y + uy * rho * R, ux, uy, seen * 1.9, w * 3.2)) }
            default: rainP[bk].addPath(p)
            }
        }
        // Each group is drawn with a slight blur; then again blurred wide to bleed light around the
        // sharp streaks (the reference's brightness comes from this bloom). The shell's bloom is weak,
        // so there is no thick glowing band at the edge.
        func alpha(_ b: Int) -> Double { min(1, 1.8 * (Double(b) + 0.5) / Double(buckets)) }
        // On paper the bloom is a faint teal bleed, so the body between the streaks stays paper.
        let white = paper ? ink : (0.90, 0.95, 1.0), pale = paper ? teal : (0.62, 0.76, 1.0)
        let bloom = paper ? teal : (0.66, 0.79, 1.0), bleed = paper ? 0.1 : 1.0
        // (paths, sharp tint, bloom strength): crisp grains, and a bloom that is weak on the shell
        // (paths, sharp tint, sharp strength, bloom strength); the big lumps are mostly bloom, so they melt
        let groups: [([Path], (Double, Double, Double), Double, Double)] = [
            (shellP, white, paper ? 0.65 : 1, 0.5), (coreP, white, 1, 1.15), (blueP, pale, 1, 1.15), (rainP, white, 1, 1.9),
            (dropP, white, 0.65, 1.8)]
        ctx.drawLayer { l in
            l.blendMode = lit
            l.addFilter(.blur(radius: 0.0065 * R))
            for (paths, tint, ss, _) in groups {
                for b in 0..<buckets { l.fill(paths[b], with: .color(color(tint, crisp * ss * alpha(b)))) }
            }
        }
        ctx.drawLayer { l in
            l.blendMode = lit
            l.addFilter(.blur(radius: 0.035 * R))
            for (paths, _, _, bs) in groups {
                for b in 0..<buckets {
                    l.fill(paths[b], with: .color(color(bloom, bleed * min(1, 1.6 * bs * alpha(b)))))
                }
            }
            l.fill(haloP, with: .color(color(bloom, bleed * 0.30)))
        }
        ctx.blendMode = .normal
        if idle > 0 { ctx.opacity = 1 }
    }

    /// A stable pseudo-random number in 0..<1 for a particle and a field.
    @inline(__always) static func hash(_ a: UInt64, _ b: UInt64) -> Double {
        var z = a &* 0x9E37_79B9_7F4A_7C15 &+ b &* 0xBF58_476D_1CE4_E5B9 &+ 0x94D0_49BB_1331_11EB
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    /// A normal sample from two uniforms (Box-Muller).
    @inline(__always) static func gauss(_ u1: Double, _ u2: Double) -> Double {
        sqrt(-2 * log(max(u1, 1e-9))) * cos(2 * .pi * u2)
    }
}

/// The orb as a view: a TimelineView drives the phases (20 fps at keyboard size, else display rate).
struct LAAParticleOrbView: View {
    var size: CGFloat
    var level: Double = 0
    var thinking: Double = 1
    var ground: LAAParticleOrb.Ground = .dark
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceTransparency) private var solid
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: size <= 48 ? 1.0 / 20 : 1.0 / 60, paused: reduceMotion)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, canvas in
                LAAParticleOrb.draw(&ctx, canvas: canvas, size: size, displayScale: displayScale,
                                    beat: (0.35 * t).truncatingRemainder(dividingBy: 2 * .pi),
                                    wave: (2.2 * t).truncatingRemainder(dividingBy: 2 * .pi),
                                    spin: (0.2 * t).truncatingRemainder(dividingBy: 20 * .pi),
                                    level: level, thinking: thinking, solid: solid,
                                    ground: ground == .dark && size >= 120 ? .darkRim : ground,
                                    count: size >= 120 ? 1000 : nil)
            }
            .frame(width: size * 1.3, height: size * 1.3)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
#endif
