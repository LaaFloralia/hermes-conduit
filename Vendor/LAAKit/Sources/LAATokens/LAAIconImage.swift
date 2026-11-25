import SwiftUI

/// A Phosphor glyph (or the mapped SF Symbol) at one of the four icon sizes (16/18/20/24).
/// Regular by default; `selected` draws the fill weight. Colour comes from `foregroundStyle`
/// (default `textMuted`; `accent` for tappable/selected per DESIGN.md).
public struct LAAIconImage: View {
    public let icon: LAAIcon
    public let size: Double
    public let selected: Bool
    @Environment(\.laaPalette) private var palette

    public init(_ icon: LAAIcon, size: Double = LAAIconSize.default, selected: Bool = false) {
        self.icon = icon
        self.size = size
        self.selected = selected
    }

    public var body: some View {
        Group {
            if icon.prefersSFSymbol {
                Image(systemName: selected ? icon.sfSymbol + ".fill" : icon.sfSymbol)
                    .font(.system(size: size * 0.85, weight: .regular))
                    .frame(width: size, height: size)
            } else {
                LAAGlyph(selected ? icon.fillPath : icon.regularPath)
                    .fill(style: FillStyle(eoFill: false, antialiased: true))
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}

/// An SVG path (`d` attribute, 256-unit box) scaled into the frame. Parsed once per string and cached.
public struct LAAGlyph: Shape {
    public let data: String
    public init(_ data: String) { self.data = data }

    public func path(in rect: CGRect) -> Path {
        let unit = LAASVGPath.parse(data)
        let scale = min(rect.width, rect.height) / 256
        let dx = rect.minX + (rect.width - 256 * scale) / 2
        let dy = rect.minY + (rect.height - 256 * scale) / 2
        return unit.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: dx, ty: dy))
    }
}

/// Minimal SVG path-data parser (M L H V C S Q T A Z, absolute and relative). Phosphor uses only these.
public enum LAASVGPath {
    private static let cache = Cache()

    public static func parse(_ data: String) -> Path {
        if let hit = cache.get(data) { return hit }
        var scanner = Tokens(data)
        var path = Path()
        var current = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?
        var lastQuad: CGPoint?
        var command: Character = "M"
        while let next = scanner.command(default: command) {
            command = next
            let rel = command.isLowercase
            let base = rel ? current : .zero
            func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: base.x + x, y: base.y + y) }
            switch command.uppercased().first! {
            case "M":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = pt(x, y); start = current
                path.move(to: current)
                command = rel ? "l" : "L"   // subsequent pairs are implicit line-tos
                lastControl = nil; lastQuad = nil
                continue
            case "L":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = pt(x, y); path.addLine(to: current)
                lastControl = nil; lastQuad = nil
            case "H":
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: rel ? current.x + x : x, y: current.y); path.addLine(to: current)
                lastControl = nil; lastQuad = nil
            case "V":
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: rel ? current.y + y : y); path.addLine(to: current)
                lastControl = nil; lastQuad = nil
            case "C":
                guard let x1 = scanner.number(), let y1 = scanner.number(), let x2 = scanner.number(),
                      let y2 = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return path }
                let c2 = pt(x2, y2), end = pt(x, y)
                path.addCurve(to: end, control1: pt(x1, y1), control2: c2)
                current = end; lastControl = c2; lastQuad = nil
            case "S":
                guard let x2 = scanner.number(), let y2 = scanner.number(), let x = scanner.number(),
                      let y = scanner.number() else { return path }
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = pt(x2, y2), end = pt(x, y)
                path.addCurve(to: end, control1: c1, control2: c2)
                current = end; lastControl = c2; lastQuad = nil
            case "Q":
                guard let x1 = scanner.number(), let y1 = scanner.number(), let x = scanner.number(),
                      let y = scanner.number() else { return path }
                let c = pt(x1, y1), end = pt(x, y)
                path.addQuadCurve(to: end, control: c)
                current = end; lastQuad = c; lastControl = nil
            case "T":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                let c = lastQuad.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let end = pt(x, y)
                path.addQuadCurve(to: end, control: c)
                current = end; lastQuad = c; lastControl = nil
            case "A":
                guard let rx = scanner.number(), let ry = scanner.number(), let rotation = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let end = pt(x, y)
                arc(&path, from: current, to: end, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = end; lastControl = nil; lastQuad = nil
            case "Z":
                path.closeSubpath(); current = start
                lastControl = nil; lastQuad = nil
                scanner.consumeCommand()
                continue
            default:
                return path
            }
        }
        cache.set(data, path)
        return path
    }

    /// SVG endpoint arc → centre parameterisation → cubic segments (≤ 90° each).
    static func arc(_ path: inout Path, from p0: CGPoint, to p1: CGPoint, rx: Double, ry: Double,
                    rotation: Double, large: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = den == 0 ? 0 : max(0, num / den).squareRoot()
        if large == sweep { coef = -coef }
        let cx1 = coef * rx * y1 / ry, cy1 = -coef * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        let segments = Int(ceil(abs(delta) / (.pi / 2)))
        let step = delta / Double(segments)
        let t = 4.0 / 3.0 * tan(step / 4)
        var theta = theta1
        for _ in 0..<segments {
            let cos1 = cos(theta), sin1 = sin(theta), cos2 = cos(theta + step), sin2 = sin(theta + step)
            func map(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: cx + rx * x * cosPhi - ry * y * sinPhi, y: cy + rx * x * sinPhi + ry * y * cosPhi)
            }
            path.addCurve(to: map(cos2, sin2),
                          control1: map(cos1 - t * sin1, sin1 + t * cos1),
                          control2: map(cos2 + t * sin2, sin2 - t * cos2))
            theta += step
        }
    }

    private struct Tokens {
        let chars: [Character]
        var i = 0
        init(_ s: String) { chars = Array(s) }

        mutating func skip() {
            while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" || chars[i] == "\t" { i += 1 }
        }

        /// The next explicit command, or the previous one repeated when numbers follow.
        mutating func command(default previous: Character) -> Character? {
            skip()
            guard i < chars.count else { return nil }
            if chars[i].isLetter, chars[i] != "e", chars[i] != "E" { let c = chars[i]; i += 1; return c }
            return previous.uppercased() == "Z" ? nil : previous
        }

        mutating func consumeCommand() {}

        mutating func flag() -> Bool? {
            skip()
            guard i < chars.count, chars[i] == "0" || chars[i] == "1" else { return nil }
            defer { i += 1 }
            return chars[i] == "1"
        }

        mutating func number() -> Double? {
            skip()
            var j = i, text = ""
            if j < chars.count, chars[j] == "-" || chars[j] == "+" { text.append(chars[j]); j += 1 }
            var dot = false, exp = false
            while j < chars.count {
                let c = chars[j]
                if c.isNumber { text.append(c) }
                else if c == ".", !dot, !exp { dot = true; text.append(c) }
                else if (c == "e" || c == "E"), !exp, !text.isEmpty {
                    exp = true; text.append(c)
                    if j + 1 < chars.count, chars[j + 1] == "-" || chars[j + 1] == "+" { j += 1; text.append(chars[j]) }
                } else { break }
                j += 1
            }
            guard let value = Double(text) else { return nil }
            i = j
            return value
        }
    }

    private final class Cache: @unchecked Sendable {
        private var store: [String: Path] = [:]
        private let lock = NSLock()
        func get(_ key: String) -> Path? { lock.lock(); defer { lock.unlock() }; return store[key] }
        func set(_ key: String, _ value: Path) { lock.lock(); store[key] = value; lock.unlock() }
    }
}
