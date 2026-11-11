#if LAA_BUILD
import SwiftUI

/// Which face a model gets. The provider sets the colour; the model's family
/// sets the small joke inside it: Claude's spark has as many rays as its
/// family name suggests (a haiku's five, a sonnet's fourteen lines), and GPT's
/// celestial names draw their own body (Sol the sun, Terra the earth, Luna the
/// moon, Astra a star). Rendering only: the identifiers are not changed.
enum LAAModelFace: Equatable {
    case claude(rays: Int)
    case gpt(LAAModelFace.Body)
    case deepSeek
    case gemini
    case grok
    case unknown

    enum Body: Equatable { case sol, terra, luna, astra, other }

    static func face(model: String?, provider: String?) -> LAAModelFace {
        let raw = (model ?? "").lowercased()
        let provider = (provider ?? "").lowercased()
        if raw.contains("deepseek") || provider == "dsh" { return .deepSeek }
        if raw.contains("gemini") || provider == "gemini" { return .gemini }
        if raw.contains("grok") || provider == "grok" { return .grok }
        if raw.contains("claude") || ["opus", "sonnet", "haiku", "mythos", "fable"].contains(where: raw.contains)
            || provider == "claude" {
            if raw.contains("haiku") { return .claude(rays: 5) }
            if raw.contains("sonnet") { return .claude(rays: 14) }
            if raw.contains("mythos") { return .claude(rays: 7) }
            if raw.contains("fable") { return .claude(rays: 9) }
            return .claude(rays: 12)
        }
        if raw.contains("gpt") || provider == "codex" || provider == "openai" {
            if raw.contains("sol") { return .gpt(.sol) }
            if raw.contains("terra") { return .gpt(.terra) }
            if raw.contains("luna") { return .gpt(.luna) }
            if raw.contains("astra") { return .gpt(.astra) }
            return .gpt(.other)
        }
        return .unknown
    }
}

/// The model's round face beside its name, in Work's transcript, the session
/// heading and the model pill. Flat colour on a flat disc, no gradient or
/// shadow; an unknown model keeps the neutral sparkle.
struct LAAModelMark: View {
    let model: String?
    let provider: String?
    var size: CGFloat = LAASender.avatarSize
    @Environment(\.colorScheme) private var scheme

    private var face: LAAModelFace { .face(model: model, provider: provider) }

    var body: some View {
        Group {
            switch face {
            case .claude(let rays): claude(rays)
            case .gpt(let body): gpt(body)
            case .deepSeek: symbol("fish.fill", ink: LAAModelInk.deepSeek, disc: LAAModelInk.deepSeekDisc, scale: 0.5)
            case .gemini: symbol("sparkle", ink: LAAModelInk.gemini, disc: LAAModelInk.geminiDisc, scale: 0.56)
            case .grok: grok
            case .unknown: LAAAgentPlaceholderAvatar(size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Claude: the clay disc and a hand-cut spark of uneven rays.
    private func claude(_ rays: Int) -> some View {
        ZStack {
            Circle().fill(LAAModelInk.claudeDisc(scheme))
            ForEach(0..<rays, id: \.self) { index in
                // Alternate long and short rays, so the spark reads as drawn
                // rather than as a gear.
                let long = index % 2 == 0 || rays < 8
                Capsule()
                    .fill(LAAModelInk.claude)
                    .frame(width: max(1.4, size * (rays > 10 ? 0.07 : 0.09)),
                           height: size * (long ? 0.34 : 0.25))
                    .offset(y: -size * (long ? 0.17 : 0.125))
                    .rotationEffect(.degrees(Double(index) / Double(rays) * 360 + 8))
            }
        }
        .overlay { Circle().strokeBorder(LAAModelInk.claude.opacity(0.18), lineWidth: 0.5) }
    }

    /// GPT: graphite disc, the body its name is named after.
    private func gpt(_ body: LAAModelFace.Body) -> some View {
        let glyph: (String, Color, CGFloat) = switch body {
        case .sol: ("sun.max.fill", LAAModelInk.sol, 0.56)
        case .terra: ("globe.asia.australia.fill", LAAModelInk.terra, 0.56)
        case .luna: ("moon.fill", LAAModelInk.luna, 0.5)
        case .astra: ("star.fill", LAAModelInk.astra, 0.5)
        case .other: ("circle.hexagongrid.fill", LAAModelInk.luna, 0.5)
        }
        return symbol(glyph.0, ink: glyph.1, disc: LAAModelInk.gptDisc, scale: glyph.2)
    }

    private var grok: some View {
        ZStack {
            Circle().fill(LAAModelInk.grokDisc)
            Capsule().fill(.white)
                .frame(width: size * 0.09, height: size * 0.56)
                .rotationEffect(.degrees(35))
        }
    }

    private func symbol(_ name: String, ink: Color, disc: Color, scale: CGFloat) -> some View {
        Image(systemName: name)
            .font(.system(size: size * scale, weight: .semibold))
            .foregroundStyle(ink)
            .frame(width: size, height: size)
            .background(disc, in: Circle())
            .overlay { Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5) }
    }
}

/// The marks' own colours. They name a provider, so they stay the same in
/// light and dark; only Claude's paper-like disc darkens with the page.
enum LAAModelInk {
    static let claude = Color(red: 0.80, green: 0.42, blue: 0.29)
    static func claudeDisc(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.24, green: 0.17, blue: 0.14) : Color(red: 0.96, green: 0.91, blue: 0.86)
    }
    static let gptDisc = Color(red: 0.13, green: 0.14, blue: 0.15)
    static let sol = Color(red: 0.98, green: 0.73, blue: 0.27)
    static let terra = Color(red: 0.36, green: 0.78, blue: 0.62)
    static let luna = Color(red: 0.86, green: 0.88, blue: 0.95)
    static let astra = Color(red: 0.62, green: 0.70, blue: 1.0)
    static let deepSeek = Color.white
    static let deepSeekDisc = Color(red: 0.30, green: 0.42, blue: 0.99)
    static let gemini = Color(red: 0.36, green: 0.52, blue: 0.97)
    static let geminiDisc = Color(red: 0.92, green: 0.94, blue: 1.0)
    static let grokDisc = Color(red: 0.06, green: 0.06, blue: 0.07)
}
#endif
