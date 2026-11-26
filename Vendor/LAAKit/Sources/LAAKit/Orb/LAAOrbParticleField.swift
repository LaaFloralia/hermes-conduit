import LAATokens
import SwiftUI

/// Hortensia’s particle geometry: grouped streaks, grains and bright drops. No backing shape.
struct LAAOrbParticleField {
    struct Group {
        let paths: [Path]
        let sharp: Double
        let bloom: Double
        var isAccent = false
    }

    let groups: [Group]
    let halo: Path
    let radius: Double
    let litCount: Int
    let opacity: Double
    let paper: Bool
    let compactAtOneX: Bool
    static let buckets = 6

    // Hortensia and Voice both lower the large orb’s particle budget.
    static func innerCount(size: CGFloat) -> Int { size >= 120 ? 1000 : 1500 }
    static func alpha(_ bucket: Int) -> Double { min(1, 1.8 * (Double(bucket) + 0.5) / Double(buckets)) }

    static func frame(canvas: CGSize, size: CGFloat, displayScale: CGFloat, moment: LAAOrbMoment,
                      paper: Bool, seed: UInt64) -> Self {
        let c = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        let R = Double(size) * 0.48
        let px = 1 / max(1, Double(displayScale))
        let (beat, wave, level, thinking) = (moment.beat, moment.wave, moment.level, moment.thinking)
        let breath = 1 + 0.20 * sin(wave) + 0.02 * sin(beat) + 0.25 * level
        let activity = 0.55 + 0.45 * thinking
        let idle = 1 - thinking

        // Particles. Each lives 1/k of the wave's turn, flares and fades while it drifts in or out and a
        // little sideways, then
        // reappears elsewhere. Every one is a streak along its outward motion that tapers to nothing at
        // both ends (motion blur), filled as a lens.
        //   inside (`n`): 1 core cloud (fine grains to 0.4 R, many pale blue), short bright rays from
        //     the heart's edge (0.2...0.47 R), streams (0.3...0.6 R), medium bright streaks all round
        //     (0.4...0.85 R), hairs (very thin long dim streaks);
        //   0 shell (`n` x 2/3): a soft outer band, brightest near 0.94 R, lumps and gaps along it;
        //   2 drops (38 big bright lumps with a soft halo, most in six small clusters apart in the upper half, kept off the heart: 0.54...0.8 R).
        // Shell, rain, hairs and drops lie across the view (placed by their seen radius), so the shell
        // is one band at the edge and nothing piles up into a second ring.
        let n = innerCount(size: size)
        let nShell = n * 2 / 3, nDrops = 38
        let turn = wave / (2 * .pi)
        let phase = turn - floor(turn)
        let buckets = Self.buckets
        var shellP = [Path](repeating: Path(), count: buckets)
        var coreP = [Path](repeating: Path(), count: buckets)
        var rainP = [Path](repeating: Path(), count: buckets)
        var dropP = [Path](repeating: Path(), count: buckets)
        var blueP = [Path](repeating: Path(), count: buckets)        // pale blue grains around the heart
        var haloP = Path()                                          // wide soft light around the big lumps
        let width = 0.0145 * R                              // widest point of a fine streak
        let compactAtOneX = displayScale <= 1 && size <= LAASpace.s48
        let broadShell = paper || compactAtOneX
        let pixelFloor = broadShell ? 0.5 * px : 0
        func lens(_ x: Double, _ y: Double, _ ux: Double, _ uy: Double, _ len: Double, _ w0: Double) -> Path {
            // Paper and compact 1× orbs need a minimum grain width or subpixel paths vanish.
            let w = max(w0, pixelFloor)
            let length = max(len, 1.6 * pixelFloor)
            let hx = ux * length / 2, hy = uy * length / 2, nx = -uy * w, ny = ux * w
            var p = Path()
            p.move(to: CGPoint(x: x - hx, y: y - hy))
            p.addQuadCurve(to: CGPoint(x: x + hx, y: y + hy), control: CGPoint(x: x + nx, y: y + ny))
            p.addQuadCurve(to: CGPoint(x: x - hx, y: y - hy), control: CGPoint(x: x - nx, y: y - ny))
            p.closeSubpath()
            return p
        }
        var litCount = 0
        for i in 0..<(n + nShell + nDrops) {
            let m = i % 25
            let kind = i >= n + nShell ? 2 : i >= n ? 0 : (m < 4 ? 3 : m < 5 ? 4 : m < 9 ? 6 : m < 14 ? 5 : 1)
            let index = UInt64(i) &+ seed
            let k = kind == 0 ? 9 + Int(hash(index, 0) * 10)
                  : kind == 2 ? 4 + Int(hash(index, 0) * 4) : 13 + Int(hash(index, 0) * 14)
            let x = phase * Double(k) + hash(index, 1)
            let cyc = Int(x) % k, u = x - floor(x)
            let s = index &* 977 &+ UInt64(cyc) &* 7919
            if kind != 2 && hash(s, 2) > activity { continue }
            litCount += 1
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
                rho = min((broadShell ? 0.72 : 0.88) + (broadShell ? 0.28 : 0.12) * pow(h5, 0.6), 0.997 - len / 2)
                shade *= 0.25 + 0.75 * exp(-pow((rho - 0.94) / (broadShell ? 0.09 : 0.035), 2))
                if paper { shade *= 1 - 0.5 * idle }
                w = 0.0125 * R
                peak = 1.5 * (1 + 0.6 * level); speed = 0; env0 = pow(sin(.pi * u), 0.8)
            case 1:
                // Densify the inner grains to keep the luminous heart without a backing gradient.
                rho = hash(s, 11) < 0.40 ? 0.40 * pow(hash(s, 5), 1.35) : 0.24 + 0.32 * hash(s, 5)
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
                // big bright lumps: most gather in six clusters in the upper half, drifting slowly
                if hash(s, 15) < 0.65 {
                    let j = Int(hash(index, 16) * 6)
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
        return Self(groups: [
            Group(paths: shellP, sharp: paper ? 0.65 : 1, bloom: 0.5),
            Group(paths: coreP, sharp: 1, bloom: 1.15),
            Group(paths: blueP, sharp: 1, bloom: 1.15, isAccent: true),
            Group(paths: rainP, sharp: 1, bloom: 1.9),
            Group(paths: dropP, sharp: 0.65, bloom: 1.8),
        ], halo: haloP, radius: R, litCount: litCount, opacity: 1 - 0.35 * idle,
           paper: paper, compactAtOneX: compactAtOneX)
    }

    func draw(_ ctx: inout GraphicsContext, palette: LAAPalette, bloom: Bool) {
        // Normal blending keeps the pixel-width grains from saturating the orb on a 1× screen.
        let blend: GraphicsContext.BlendMode = paper || compactAtOneX ? .normal : .plusLighter
        let bloom = bloom && !compactAtOneX
        let crisp = paper ? 2.0 : 1.0
        ctx.opacity = opacity
        ctx.blendMode = blend
        func drawParticles(_ layer: inout GraphicsContext) {
            for group in groups {
                let tint = group.isAccent ? palette.accent : palette.text
                for (bucket, path) in group.paths.enumerated() {
                    layer.fill(path, with: .color(tint.opacity(min(1, crisp * group.sharp * Self.alpha(bucket)))))
                }
            }
        }
        if !bloom {
            drawParticles(&ctx)
        } else {
            ctx.drawLayer { layer in
                layer.blendMode = blend
                layer.addFilter(.blur(radius: 0.0065 * radius))
                drawParticles(&layer)
            }
        }
        // All glow is a blur of particles, never a filled sphere, separate ring or radial backing.
        if bloom {
            let tint = paper ? palette.accent : palette.text
            let bleed = paper ? 0.1 : 1.0
            ctx.drawLayer { layer in
                layer.blendMode = blend
                layer.addFilter(.blur(radius: 0.035 * radius))
                for group in groups {
                    for (bucket, path) in group.paths.enumerated() {
                        layer.fill(path, with: .color(tint.opacity(bleed * min(1, 1.6 * group.bloom * Self.alpha(bucket)))))
                    }
                }
                layer.fill(halo, with: .color(tint.opacity(bleed * 0.30)))
            }
        }
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
