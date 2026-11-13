#if LAA_BUILD
import SwiftUI
import UIKit

/// Which face a model gets: its provider's own mark (owner, 2026-11-13: the
/// official icons). Claude's Spark and OpenAI's Blossom are drawn as their
/// makers issue them, never recoloured, reshaped or turned; what tells one
/// model from another is its name and its capsule's rank colour
/// (LAAModelRank), not the mark. Until OpenAI's mark is in the asset
/// catalogue, GPT keeps the celestial symbol of its name (Sol the sun, Terra
/// the earth, Luna the moon, Astra a star). Rendering only: the identifiers
/// are not changed.
enum LAAModelFace: Equatable {
    case claude
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
            return .claude
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

    /// The provider alone ("Claude"), for a model whose exact name is unknown.
    var providerName: String? {
        switch self {
        case .claude: "Claude"
        case .gpt: "GPT"
        case .deepSeek: "DeepSeek"
        case .gemini: "Gemini"
        case .grok: "Grok"
        case .unknown: nil
        }
    }
}

/// The model's round face beside its name, in Work's transcript, the session
/// heading and the model capsule: the provider's official mark on a plain
/// disc, with room around it. No gradient or shadow; an unknown model keeps
/// the neutral sparkle.
struct LAAModelMark: View {
    let model: String?
    let provider: String?
    var size: CGFloat = LAASender.avatarSize
    private var face: LAAModelFace { .face(model: model, provider: provider) }

    var body: some View {
        Group {
            switch face {
            case .claude: claude
            case .gpt(let body): gpt(body)
            case .deepSeek: deepSeek
            case .gemini: symbol("sparkle", ink: LAAModelInk.gemini, disc: LAAModelInk.geminiDisc, scale: 0.56)
            case .grok: grok
            case .unknown: LAAAgentPlaceholderAvatar(size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Claude: Anthropic's Spark in Clay (#D97757), as issued
    /// (`LAAClaudeMark`, original rendering), on a paper disc with a fifth of
    /// the disc clear on every side.
    private var claude: some View {
        Image("LAAClaudeMark")
            .renderingMode(.original)
            .resizable().scaledToFit()
            .frame(width: size * 0.6, height: size * 0.6)
            .frame(width: size, height: size)
            .background(LAACeremonyColor.claudeDisc, in: Circle())
            .overlay { Circle().strokeBorder(LAACeremonyColor.claudeDiscRim, lineWidth: 0.5) }
    }

    /// GPT: OpenAI's Blossom as issued (`LAAOpenAIMark`: black, with a white
    /// dark appearance) on a neutral disc, once it is in the catalogue;
    /// until then the graphite disc and the body its name is named after.
    @ViewBuilder private func gpt(_ body: LAAModelFace.Body) -> some View {
        if LAAModelMark.hasOpenAIMark {
            Image("LAAOpenAIMark")
                .renderingMode(.original)
                .resizable().scaledToFit()
                .frame(width: size * 0.6, height: size * 0.6)
                .frame(width: size, height: size)
                .background(LAACeremonyColor.openAIDisc, in: Circle())
        } else {
            celestial(body)
        }
    }

    static let hasOpenAIMark = UIImage(named: "LAAOpenAIMark") != nil

    private func celestial(_ body: LAAModelFace.Body) -> some View {
        let glyph: (String, Color, CGFloat) = switch body {
        case .sol: ("sun.max.fill", LAAModelInk.sol, 0.56)
        case .terra: ("globe.asia.australia.fill", LAAModelInk.terra, 0.56)
        case .luna: ("moon.fill", LAAModelInk.luna, 0.5)
        case .astra: ("star.fill", LAAModelInk.astra, 0.5)
        case .other: ("circle.hexagongrid.fill", LAAModelInk.luna, 0.5)
        }
        return symbol(glyph.0, ink: glyph.1, disc: LAAModelInk.gptDisc, scale: glyph.2)
    }

    /// DeepSeek: its own whale, the vector from deepseek.com's header as it
    /// is (owner, 2026-11-12: not a fish), in DeepSeek's blue on a near-white
    /// disc in both light and dark, as DeepSeek shows it.
    private var deepSeek: some View {
        Image("LAADeepSeekMark")
            .renderingMode(.template)
            .resizable().scaledToFit()
            .foregroundStyle(LAAModelInk.deepSeek)
            .frame(width: size * 0.7, height: size * 0.7)
            .frame(width: size, height: size)
            .background(LAAModelInk.deepSeekDisc, in: Circle())
            .overlay { Circle().strokeBorder(LAAModelInk.deepSeek.opacity(0.16), lineWidth: 0.5) }
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
/// light and dark. Claude's and OpenAI's discs are in LAACeremonyColor.
enum LAAModelInk {
    static let gptDisc = Color(red: 0.13, green: 0.14, blue: 0.15)
    static let sol = Color(red: 0.98, green: 0.73, blue: 0.27)
    static let terra = Color(red: 0.36, green: 0.78, blue: 0.62)
    static let luna = Color(red: 0.86, green: 0.88, blue: 0.95)
    static let astra = Color(red: 0.62, green: 0.70, blue: 1.0)
    /// DeepSeek's blue, #4D6BFE.
    static let deepSeek = Color(red: 0x4D / 255, green: 0x6B / 255, blue: 0xFE / 255)
    static let deepSeekDisc = Color(red: 0.97, green: 0.975, blue: 1.0)
    static let gemini = Color(red: 0.36, green: 0.52, blue: 0.97)
    static let geminiDisc = Color(red: 0.92, green: 0.94, blue: 1.0)
    static let grokDisc = Color(red: 0.06, green: 0.06, blue: 0.07)
}
/// A model's rank in a menu row. The system draws the row's text in one ink,
/// so a ranked model carries a small disc of its capsule's face (Mythos with
/// its rim); other models carry nothing.
enum LAAModelMenu {
    @MainActor
    static func icon(model: String?, scheme: ColorScheme, scale: CGFloat) -> Image? {
        guard let rank = LAAModelRank.of(model).colors else { return nil }
        let disc = Circle().fill(rank.fill)
            .overlay { Circle().strokeBorder(rank.rim ?? LAAColor.separator, lineWidth: 1) }
            .frame(width: 16, height: 16)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: disc)
        renderer.scale = scale
        return renderer.uiImage.map { Image(uiImage: $0.withRenderingMode(.alwaysOriginal)) }
    }

    /// A model row's name, with the rank disc when the model has one. The
    /// current value's row keeps the system's check instead.
    struct Name: View {
        let label: String
        let model: String?
        @Environment(\.colorScheme) private var scheme
        @Environment(\.displayScale) private var scale

        var body: some View {
            if let icon = LAAModelMenu.icon(model: model, scheme: scheme, scale: scale) {
                Label { Text(verbatim: label) } icon: { icon }
            } else {
                Text(verbatim: label)
            }
        }
    }
}
#endif
