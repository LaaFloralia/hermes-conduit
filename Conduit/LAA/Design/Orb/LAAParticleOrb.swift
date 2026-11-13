// LAAParticleOrb.swift: the LAA orb drawn as a sphere of light particles (prototype, 2026-11-14).
//
// One self-contained file, no assets. Every particle has a place in 3D and is seen straight on
// (orthographic): a shell of fine, soft points on the sphere (0.92...1.0 R), a dense cluster of fine
// dots at the centre (0...0.4 R), and a few large bright drops between them (0.4...0.8 R). Each one
// moves straight outward; its streak is that velocity seen on screen, so it is a dot when it moves
// toward the viewer and longest when it moves across. Light is a little stronger at the top.
// Everything is a pure function of the moment's phases, so any instant can be drawn and the pattern
// repeats exactly every turn of `wave` (2.2 rad/s, 2.86 s): every particle lives a whole fraction of it.
// The parameters follow the voice keyboard's orb (size, displayScale, beat, wave, spin, level,
// thinking, solid) so either caller can feed it.
#if LAA_BUILD || LAA_ORB_STANDALONE
import SwiftUI

enum LAAParticleOrb {
    /// The ground under the orb. `dark`: white light that adds, its outline melting into the ground;
    /// `darkRim`: the same with a faint rim (the view picks it from 120 pt up); `paperBead`: on paper,
    /// a deep teal glass bead with a thin rim and the same light inside.
    enum Ground { case dark, darkRim, paperBead }

    /// The same particle set at every size: the ball is only scaled, so a small orb looks like the
    /// large one shrunk (its particles average out under the pixels), not like a thinner drawing.
    /// `radiusPx` is kept for callers that want to step the count down under load.
    static let fullCount = 1820
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
        let breath = 1 + 0.06 * sin(wave) + 0.02 * sin(beat) + 0.25 * level
        let activity = 0.55 + 0.45 * thinking                // how many particles are lit
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

        // Ground under the light: a solid disc when transparency is reduced, or the glass bead on paper.
        if solid && ground != .paperBead {
            ctx.fill(disc(R * 1.02), with: .color(Color(red: 0.059, green: 0.106, blue: 0.110)))
        }
        if ground == .paperBead {
            // Lighter than a hole in the paper: deep teal #1F3D3F...#163033, a thin rim lit from above.
            let b = R * 1.05
            ctx.fill(disc(b), with: .radialGradient(Gradient(stops: [
                .init(color: Color(red: 0.122, green: 0.239, blue: 0.247), location: 0),
                .init(color: Color(red: 0.086, green: 0.188, blue: 0.200), location: 1),
            ]), center: CGPoint(x: c.x, y: c.y - 0.3 * b), startRadius: 0, endRadius: b * 1.3))
            ctx.stroke(disc(b - 0.5 * px), with: .linearGradient(Gradient(colors: [
                Color.white.opacity(0.45), Color.white.opacity(0.12), Color.white.opacity(0.22)]),
                startPoint: CGPoint(x: c.x, y: c.y - b), endPoint: CGPoint(x: c.x, y: c.y + b)),
                lineWidth: max(px, 0.010 * R))
        }
        if ground == .darkRim {
            ctx.stroke(disc(R * 1.05), with: .linearGradient(Gradient(colors: [
                Color.white.opacity(0.16), Color.white.opacity(0.05), Color.white.opacity(0.09)]),
                startPoint: CGPoint(x: c.x, y: c.y - R), endPoint: CGPoint(x: c.x, y: c.y + R)),
                lineWidth: max(px, 0.008 * R))
        }

        ctx.blendMode = .plusLighter
        // Glow on the dark ground only, gone by 1.3 R. Inside, a haze that falls smoothly from the
        // centre to the edge (no dark moat before the shell), and a soft heart: a cloud, not a dot.
        if ground != .paperBead {
            radial(R * 1.3, light, [(0.70, 0.06), (0.77, 0.04), (0.85, 0.018), (0.92, 0.006), (1.0, 0)])
        }
        radial(R * 1.0, light, [(0, 0.45), (0.3, 0.38), (0.5, 0.31), (0.65, 0.26), (0.8, 0.21),
                                (0.9, 0.16), (0.96, 0.08), (1, 0)])
        let heartR = R * (0.30 + 0.03 * level) * breath
        radial(heartR, (1.0, 1.0, 1.0), [(0, 0.95), (0.3, 0.7), (0.6, 0.32), (0.85, 0.08), (1, 0)])

        // Particles. Each lives 1/k of the wave's turn, flares and fades while it moves outward, then
        // reappears elsewhere. Every one is a streak along its outward motion that tapers to nothing at
        // both ends (motion blur), filled as a lens. Kinds: 0 shell (short streaks on 0.95...1.0 R),
        // 1 core (fine streaks in a cloud to 0.4 R, some streaming to 0.6 R), 3 rain (medium streaks
        // 0.5...0.82 R), 2 drops (16 large soft lenses, mostly in the upper half).
        let n = count ?? particleCount(radiusPx: R * Double(displayScale))
        let nDrops = 16
        let phase = (wave / (2 * .pi)).truncatingRemainder(dividingBy: 1) + (wave < 0 ? 1 : 0)
        let buckets = 6
        var shellP = [Path](repeating: Path(), count: buckets)
        var coreP = [Path](repeating: Path(), count: buckets)
        var rainP = [Path](repeating: Path(), count: buckets)
        var dropP = [Path](repeating: Path(), count: buckets)
        let width = 0.0105 * R                              // widest point of a fine streak
        func lens(_ x: Double, _ y: Double, _ ux: Double, _ uy: Double, _ len: Double, _ w: Double) -> Path {
            // a streak centred on (x, y) along (ux, uy), len long, w wide at the middle, pointed ends
            let hx = ux * len / 2, hy = uy * len / 2, nx = -uy * w, ny = ux * w
            var p = Path()
            p.move(to: CGPoint(x: x - hx, y: y - hy))
            p.addQuadCurve(to: CGPoint(x: x + hx, y: y + hy), control: CGPoint(x: x + nx, y: y + ny))
            p.addQuadCurve(to: CGPoint(x: x - hx, y: y - hy), control: CGPoint(x: x - nx, y: y - ny))
            p.closeSubpath()
            return p
        }
        for i in 0..<(n + nDrops) {
            let m = i % 25
            // 48 % shell, 4 % rain, 40 % core cloud, 8 % core streams
            let kind = i >= n ? 2 : (m < 12 ? 0 : (m < 13 ? 3 : 1))
            let k = kind == 0 ? 6 + Int(hash(UInt64(i), 0) * 7)
                  : kind == 1 ? 10 + Int(hash(UInt64(i), 0) * 10)
                  : kind == 3 ? 7 + Int(hash(UInt64(i), 0) * 6) : 4 + Int(hash(UInt64(i), 0) * 4)
            let x = phase * Double(k) + hash(UInt64(i), 1)
            let cyc = Int(x) % k, u = x - floor(x)
            let s = UInt64(i) &* 977 &+ UInt64(cyc) &* 7919
            if kind != 2 && hash(s, 2) > activity { continue }
            // Direction: uniform on the sphere, z toward the viewer. Rain and drops move across the
            // view (in its plane), placed by their seen radius, so they do not pile up into a second ring.
            var dz = 2 * hash(s, 3) - 1
            if kind == 2 || kind == 3 { dz = 0 }
            let phi = 2 * .pi * hash(s, 4)
            let sxy = (1 - dz * dz).squareRoot()
            let ux = cos(phi)
            var uy = sin(phi)
            if kind == 2 && uy > 0 && hash(s, 13) < 0.75 { uy = -uy }   // drops gather in the upper half
            var limb = 1.0
            if kind == 0 {
                // The shell is seen mostly at its limb. Its clumps change brightness only, so the
                // outline stays an exact circle.
                let clump = 0.82 + 0.18 * sin(3 * phi + 1.3 + 0.6 * beat) + 0.12 * sin(7 * phi + 4.1 - 0.9 * beat)
                                 + 0.08 * sin(12 * phi + 2.0 + 1.4 * beat)
                if hash(s, 10) > 0.05 + 0.95 * pow(sxy, 7) { continue }
                limb = (0.35 + 0.65 * pow(sxy, 4)) * max(0.4, min(1.2, clump))
            }
            let life = 2.86 / Double(k)
            var rho: Double, len: Double, w: Double, peak: Double, speed: Double, env0: Double
            switch kind {
            case 0:
                len = 0.036 * exp(0.35 * gauss(hash(s, 6), hash(s, 7)))
                rho = (0.995 - len / 2) - 0.03 * hash(s, 5)       // the outer tip never passes 1.0 R
                w = width * 1.05
                peak = 2.5 * (1 + 0.6 * level); speed = 0; env0 = pow(sin(.pi * u), 0.8)
            case 1:
                let stream = m >= 23 || hash(s, 11) < 0.1
                rho = stream ? 0.34 + 0.26 * hash(s, 5) : 0.40 * pow(hash(s, 5), 0.5)
                len = (stream ? 0.07 : 0.03) * exp(0.4 * gauss(hash(s, 6), hash(s, 7)))
                w = width * (stream ? 1.0 : 0.9)
                peak = 1.45; speed = 0.10 + 0.10 * thinking; env0 = pow(sin(.pi * u), 0.8)
            case 3:
                rho = 0.50 + 0.32 * pow(hash(s, 5), 1.3)
                len = 0.07 + 0.05 * hash(s, 6)
                w = width * 1.1
                peak = 0.95; speed = 0.12 + 0.12 * thinking; env0 = pow(sin(.pi * u), 1.0)
            default:
                rho = 0.40 + 0.38 * hash(s, 5)
                len = 0.13 + 0.06 * hash(s, 6)
                w = 0.036 * R * (0.8 + 0.4 * hash(s, 9))
                peak = 1.8; speed = 0.15 + 0.15 * thinking; env0 = pow(sin(.pi * u), 1.3)
            }
            rho = rho * (kind == 2 || kind == 3 ? 1 : sxy) + (kind == 0 ? 0 : speed * (u - 0.5) * life * sxy)
            let up = -uy * rho                              // screen y grows downward
            let depth = 0.82 + 0.18 * dz                    // the far side a little dimmer
            let env = env0 * peak * (0.65 + 0.35 * hash(s, 8)) * breath * (1 + 0.35 * up) * depth * limb
            // seen length: the outward motion foreshortened (a dot when it moves toward the viewer)
            let seen = max(len * (kind == 2 || kind == 3 ? 1 : sxy) * R, 1.6 * w)
            let p = lens(c.x + ux * rho * R, c.y + uy * rho * R, ux, uy, seen, w)
            let bk = max(0, min(buckets - 1, Int(env * Double(buckets))))
            switch kind {
            case 0: shellP[bk].addPath(p)
            case 1: coreP[bk].addPath(p)
            case 3: rainP[bk].addPath(p)
            default: dropP[bk].addPath(p)
            }
        }
        // Each group is drawn with a slight blur; then again blurred wide to bleed light around the
        // sharp streaks (the reference's brightness comes from this bloom). The shell's bloom is weak,
        // so there is no thick glowing band at the edge.
        func alpha(_ b: Int) -> Double { min(1, 1.8 * (Double(b) + 0.5) / Double(buckets)) }
        let groups: [([Path], Double)] = [(shellP, 0.45), (coreP, 0.7), (rainP, 0.7)]
        ctx.drawLayer { l in
            l.blendMode = .plusLighter
            l.addFilter(.blur(radius: 0.006 * R))
            for (paths, _) in groups {
                for b in 0..<buckets { l.fill(paths[b], with: .color(color((0.90, 0.95, 1.0), alpha(b)))) }
            }
        }
        ctx.drawLayer { l in                                // the drops are softer, out-of-focus blobs
            l.blendMode = .plusLighter
            l.addFilter(.blur(radius: 0.014 * R))
            for b in 0..<buckets { l.fill(dropP[b], with: .color(color((0.90, 0.95, 1.0), alpha(b)))) }
            for b in 0..<buckets { l.fill(dropP[b], with: .color(color((0.66, 0.79, 1.0), 0.5 * alpha(b)))) }
        }
        ctx.drawLayer { l in
            l.blendMode = .plusLighter
            l.addFilter(.blur(radius: 0.035 * R))
            for (paths, bs) in groups {
                for b in 0..<buckets {
                    let a = bs * alpha(b)
                    l.fill(paths[b], with: .color(color((0.66, 0.79, 1.0), a)))
                    if bs >= 0.6 { l.stroke(paths[b], with: .color(color((0.66, 0.79, 1.0), 0.6 * a)),
                                            style: StrokeStyle(lineWidth: width * 1.5, lineCap: .round)) }
                }
            }
        }
        ctx.blendMode = .normal
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
                                    ground: ground == .dark && size >= 120 ? .darkRim : ground)
            }
            .frame(width: size * 1.3, height: size * 1.3)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
#endif
