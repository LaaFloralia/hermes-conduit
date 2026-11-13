#if LAA_BUILD
import SwiftUI
import UIKit

/// The colours of the model and effort capsules' ceremony and of a model's
/// rank, in one place. The owner asked for them (2026-11-13: "Mythos is set
/// apart, Fable and Astra each their own colour"; an effort that is applied
/// moves like Claude Code's Ultracode), so they are the one place where the
/// house rule against colour flowing over a surface gives way, and only on
/// the capsules' letters and faces. Studio: 「LAAアプリ｜モデルとeffortの演出 2026.11」.
enum LAACeremonyColor {
    // MARK: Effort

    /// XHigh's gilt is the house deep-effort colour; this is the light that
    /// passes over it.
    static let giltLight = adaptive(light: 0xC8952F, dark: 0xFFF4DC)

    /// Which colours flow over Max. `.pigments` is the recommendation: five
    /// colours, one per meter tick, readable on the paper. `.rainbow` is the
    /// reference's pale rainbow (Claude Code's own values in dark, darkened
    /// to stay readable on the paper in light).
    enum FlowStyle { case pigments, rainbow }
    static let flowStyle: FlowStyle = .pigments

    static var flow: [Color] { flowStyle == .pigments ? pigments : rainbow }
    static var flowLight: [Color] { flowStyle == .pigments ? pigmentsLight : rainbowLight }

    /// Teal, verdigris, gilt, red earth, plum.
    private static let pigments = [
        adaptive(light: 0x00585E, dark: 0x75C3C3), adaptive(light: 0x2F6B4F, dark: 0x9CCBA6),
        adaptive(light: 0x8A5F14, dark: 0xE2B866), adaptive(light: 0x9A4527, dark: 0xE9A27F),
        adaptive(light: 0x6C244C, dark: 0xD49AB6),
    ]
    /// Each pigment lifted toward white (45% light, 55% dark): the passing light.
    private static let pigmentsLight = [
        adaptive(light: 0x73A3A6, dark: 0xC1E4E4), adaptive(light: 0x8DAE9E, dark: 0xD2E8D7),
        adaptive(light: 0xBFA77E, dark: 0xF2DFBA), adaptive(light: 0xC79988, dark: 0xF5D5C5),
        adaptive(light: 0xAE879D, dark: 0xECD2DE),
    ]
    private static let rainbow = [
        adaptive(light: 0xB4413F, dark: 0xFF8787), adaptive(light: 0xA8562A, dark: 0xFFAF87),
        adaptive(light: 0x86640F, dark: 0xFFD787), adaptive(light: 0x3D7444, dark: 0xAFD7AF),
        adaptive(light: 0x4B4E9A, dark: 0xAFAFD7), adaptive(light: 0x87488A, dark: 0xD7AFD7),
    ]
    private static let rainbowLight = [
        adaptive(light: 0xD69695, dark: 0xFFC9C9), adaptive(light: 0xCFA28A, dark: 0xFFDBC9),
        adaptive(light: 0xBCAA7B, dark: 0xFFEDC9), adaptive(light: 0x94B398, dark: 0xDBEDDB),
        adaptive(light: 0x9C9EC7, dark: 0xDBDBED), adaptive(light: 0xBD9ABF, dark: 0xEDDBED),
    ]

    // MARK: Model rank

    struct Rank {
        /// The capsule's face, laid inside the glass.
        let fill: Color
        /// The name and chevron on that face.
        let ink: Color
        /// The light that passes over the name when the model is applied.
        let light: Color
        /// A 1 pt rim, Mythos only.
        let rim: Color?
        /// The ▲ on this face, where the house plum would not read.
        var attention: Color = LAAColor.attention
    }

    /// Lacquer and gilt in light; a gilt face and ink in dark. The strongest
    /// face of the three, so it reads first.
    static let mythos = Rank(fill: adaptive(light: 0x1C2A2B, dark: 0xE2B866),
                             ink: adaptive(light: 0xE9C77E, dark: 0x172627),
                             light: adaptive(light: 0xFFF1CF, dark: 0xFFF8E8),
                             rim: adaptive(light: 0xB99B7A, dark: 0xF2CF8A),
                             attention: adaptive(light: 0xD49AB6, dark: 0x6C244C))
    /// The house teal, softened to a face.
    static let fable = Rank(fill: adaptive(light: 0xD3E5E1, dark: 0x21494B),
                            ink: adaptive(light: 0x00585E, dark: 0xA4DDDC),
                            light: adaptive(light: 0x2E9C9F, dark: 0xE4F6F5), rim: nil)
    /// Indigo, a star's night: apart from Fable at a glance.
    static let astra = Rank(fill: adaptive(light: 0xE2E1F1, dark: 0x2E3152),
                            ink: adaptive(light: 0x3D3F86, dark: 0xC9CBF4),
                            light: adaptive(light: 0x8C8FD9, dark: 0xF0F1FF), rim: nil)

    // MARK: Model marks

    /// The paper disc under Claude's Spark (Clay, as Anthropic issues it).
    static let claudeDisc = adaptive(light: 0xF6F2E9, dark: 0xF6F2E9)
    static let claudeDiscRim = adaptive(light: 0xD7D5CC, dark: 0xB99B7A)
    /// The neutral disc under OpenAI's Blossom, black in light and white in
    /// dark as OpenAI issues it (the asset's own appearances).
    static let openAIDisc = adaptive(light: 0xEBE6DC, dark: 0x243638)

    static func adaptive(light: Int, dark: Int) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                           green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        })
    }
}

/// A model's rank, read from its id: Mythos above all, then Fable and Astra,
/// each its own colour; every other model (and an unknown one) keeps the
/// neutral glass.
enum LAAModelRank: Equatable {
    case mythos, fable, astra, none

    static func of(_ model: String?) -> LAAModelRank {
        let raw = (model ?? "").lowercased()
        if raw.contains("mythos") { return .mythos }
        if raw.contains("fable") { return .fable }
        if raw.contains("astra") { return .astra }
        return .none
    }

    var colors: LAACeremonyColor.Rank? {
        switch self {
        case .mythos: LAACeremonyColor.mythos
        case .fable: LAACeremonyColor.fable
        case .astra: LAACeremonyColor.astra
        case .none: nil
        }
    }
}

/// How long and how fast. Effort: the meter's ticks rise one after another;
/// from High on, a light passes letter by letter, as Claude Code's Ultracode
/// does; Max's colours flow over the ticks and letters. Model: a ranked face
/// wipes in from the leading edge, then a light passes over the name.
enum LAACeremony {
    static let rise: Double = 0.22
    static let riseStagger: Double = 0.06

    static func duration(effort: String) -> Double {
        switch effort {
        case "low": 0.30
        case "medium": 0.36
        case "high": 0.62
        case "xhigh": 1.30
        case "max": 1.60
        default: 0
        }
    }
    static let highDelay: Double = 0.16, highStep: Double = 0.07
    static let xhighDelay: Double = 0.10, xhighStep: Double = 0.065, xhighPasses = 2
    static let maxCycles = 4

    static func duration(rank: LAAModelRank) -> Double {
        switch rank {
        case .mythos: 1.25
        case .fable, .astra: 0.90
        case .none: 0.60
        }
    }
    static func wipe(rank: LAAModelRank) -> Double {
        switch rank {
        case .mythos: 0.42
        case .fable, .astra: 0.30
        case .none: 0
        }
    }
    static let nameStep: Double = 0.045

    /// The house `pop` and `state` curves (tokens.json motion.easing).
    static func pop(_ x: Double) -> Double { bezier(x, 0.3, 1.4, 0.55, 1) }
    static func state(_ x: Double) -> Double { bezier(x, 0.25, 0.9, 0.3, 1) }

    private static func bezier(_ t: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        let t = min(1, max(0, t))
        var u = t
        for _ in 0..<8 {
            let x = 3 * x1 * u * (1 - u) * (1 - u) + 3 * x2 * u * u * (1 - u) + u * u * u - t
            let d = 3 * x1 * (1 - u) * (1 - u) + 6 * (x2 - x1) * u * (1 - u) + 3 * (1 - x2) * u * u
            if abs(d) < 1e-6 { break }
            u = min(1, max(0, u - x / d))
        }
        return 3 * y1 * u * (1 - u) * (1 - u) + 3 * y2 * u * u * (1 - u) + u * u * u
    }
}

/// Starts a ceremony when an applied value arrives, never for a value only
/// chosen. The capsules get no event of their own, so the change itself is
/// the trigger, and only one this control asked for: the value must change
/// while `changing` is on or within a short grace after it ends. Opening
/// another session or chat, which swaps the value without a request, stays
/// still. Unknown values, last-confirmed values and Reduce Motion never
/// start one.
struct LAACeremonyTrigger<Value: Equatable>: ViewModifier {
    let value: Value
    let changing: Bool
    let enabled: Bool
    @Binding var start: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pending = false
    @State private var graceUntil: Date = .distantPast

    /// How long after "変更中" ends an arriving value still counts as the answer.
    static var grace: TimeInterval { 3 }

    func body(content: Content) -> some View {
        content
            .onChange(of: changing) { _, now in
                if now {
                    pending = false
                } else {
                    graceUntil = Date().addingTimeInterval(Self.grace)
                    if pending { pending = false; play() }
                }
            }
            .onChange(of: value) { old, new in
                guard old != new else { return }
                if changing { pending = true; return }
                if Date() < graceUntil { graceUntil = .distantPast; play() }
            }
    }

    private func play() {
        guard enabled, !reduceMotion else { return }
        start = Date()
    }
}

extension View {
    func laaCeremonyTrigger<Value: Equatable>(value: Value, changing: Bool, enabled: Bool,
                                              start: Binding<Date?>) -> some View {
        modifier(LAACeremonyTrigger(value: value, changing: changing, enabled: enabled, start: start))
    }
}

extension Text {
    /// Letters each in their own colour, joined into one Text so the line
    /// still wraps, scales and reads as one word.
    static func laaLetters(_ value: String, colors: (Int) -> Color) -> Text {
        var text = Text(verbatim: "")
        for (index, character) in value.enumerated() {
            text = text + Text(verbatim: String(character)).foregroundStyle(colors(index))
        }
        return text
    }
}
#endif
