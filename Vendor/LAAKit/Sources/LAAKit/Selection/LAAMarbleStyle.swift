#if !os(watchOS)
import LAATokens
import SwiftUI

enum LAAMarbleStep: CaseIterable, Sendable {
    case plain, model, xhigh, max, ultracode

    static func effort(_ id: String?) -> Self {
        switch id {
        case "xhigh": .xhigh
        case "max": .max
        case "ultracode": .ultracode
        default: .plain
        }
    }

    var tokens: LAAAppSelection.Step {
        switch self {
        case .plain: LAAAppSelection.plainStep
        case .model: LAAAppSelection.modelStep
        case .xhigh: LAAAppSelection.xhighStep
        case .max: LAAAppSelection.maxStep
        case .ultracode: LAAAppSelection.ultracodeStep
        }
    }
}

extension LAAPickerModel.Tier {
    var modelStep: LAAMarbleStep {
        switch self {
        case .mythos, .astra, .neon: .model
        case .stone, .plain: .plain
        }
    }

    var tokens: LAAAppSelection.Model {
        switch self {
        case .mythos: LAAAppSelection.mythos
        case .astra: LAAAppSelection.astra
        case .neon: LAAAppSelection.neon
        case .stone, .plain: LAAAppSelection.stone
        }
    }
}

/// The adopted `appSelection.formula`: one model and step set every visual layer.
struct LAAMarbleStyle: Equatable, Sendable {
    let tier: LAAPickerModel.Tier
    let step: LAAMarbleStep
    typealias T = LAAAppSelection

    var model: T.Model { tier.tokens }
    var intensity: Double { model.strength * step.tokens.intensity }
    var isPlain: Bool { intensity <= 0 }

    func bodyOpacity(dark: Bool) -> Double {
        isPlain ? 0 : T.bodyOpacity.value(dark: dark) * (0.55 + 0.45 * min(1, intensity))
    }

    func veinOpacity(_ layer: T.Pair, dark: Bool) -> Double {
        min(1, layer.value(dark: dark) * intensity)
    }

    func hairOpacity(dark: Bool) -> Double {
        min(1, T.hairOpacity.value(dark: dark) * intensity * step.tokens.hair)
    }

    func lightOpacity(dark: Bool) -> Double { min(1, T.lightPeak.value(dark: dark) * intensity) }
    func glowOpacity(dark: Bool) -> Double { min(1, T.glowOpacity.value(dark: dark) * intensity) }

    var tileSize: CGSize {
        let scale = model.tileScale * step.tokens.tileScale
        return CGSize(width: T.tileWidthPt * scale, height: T.tileHeightPt * scale)
    }

    var crossingSeconds: Double { T.secondsPerCrossing * model.speed * step.tokens.speed }
}

enum LAAMarble {
    typealias T = LAAAppSelection

    static func seed(_ text: String?) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in (text ?? "").utf8 { h = (h ^ UInt64(byte)) &* 0x100_0000_01B3 }
        return h
    }

    private static func hash(_ a: UInt64, _ b: UInt64) -> Double {
        var z = a &+ b &* 0x9E37_79B9_7F4A_7C15 &+ 0x632B_E59B_D9B4_E019
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }

    /// Seed each capsule independently to keep neighbouring patterns from lining up.
    static func offset(seed: UInt64, tile: CGSize) -> CGPoint {
        CGPoint(x: hash(seed, 0) * tile.width, y: hash(seed, 1) * tile.height)
    }

    /// Attenuate veins underneath the label and chevron.
    static func labelBand(width: CGFloat) -> (locations: [Double], opacities: [Double]) {
        let s = T.labelBandStops
        guard width > 1, s.count == 5 else { return (s, [1, 1, T.labelBandMiddle, 1, 1]) }
        let middle = s[2]
        let from = min(1, max(middle, Double((width - T.labelBandChevronSpanPt.from) / width)))
        let to = min(1, max(from, Double((width - T.labelBandChevronSpanPt.to) / width)))
        return ([s[0], s[1], middle, from, to, s[4]],
                [1, 1, T.labelBandMiddle, T.labelBandChevron, T.labelBandChevron, 1])
    }
}

extension LAAAppSelection.RGB {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

/// A sweep follows a caller-reported applied change, never a menu tap or an unrelated ID swap.
struct LAACeremonyTrigger {
    struct Input: Equatable {
        let id: String?
        let changing: Bool
    }

    private var pending = false
    private var graceUntil: Date = .distantPast
    private(set) var start: Date?

    mutating func update(from old: Input, to new: Input, now: Date, enabled: Bool) {
        let changed = old.id != new.id
        if new.changing {
            if !old.changing { pending = false; graceUntil = .distantPast; start = nil }
            pending = pending || changed
        } else if old.changing {
            graceUntil = now.addingTimeInterval(3)
            if pending || changed { play(at: now, enabled: enabled) }
            pending = false
        } else if changed && now < graceUntil {
            play(at: now, enabled: enabled)
        }
    }

    private mutating func play(at now: Date, enabled: Bool) {
        graceUntil = .distantPast
        start = enabled ? now : nil
    }
}
#endif
