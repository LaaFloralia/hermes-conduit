#if LAA_BUILD
import Foundation

struct LAAChatPokemon: Sendable {
    enum Route: String {
        case go = "go-home-sv"
        case native = "sv-native"

        init(context: String) {
            self = context.split(whereSeparator: \.isNewline).contains {
                $0.trimmingCharacters(in: .whitespaces) == "route: sv-native"
            } ? .native : .go
        }
    }

    struct Row: Decodable, Equatable, Sendable {
        enum Exception: String, Decodable, Sendable {
            case notInSV, temporary, nonordinary, nonstandardGO

            var excludesFromBareSpecies: Bool { self == .temporary || self == .nonordinary }
        }
        enum UpperClass: Int, Decodable, Sendable { case short = 155, standard = 175, tall = 200 }
        let id: Int
        let national_dex_id: Int
        let name_ja: String
        let name_en: String
        let form: String
        let form_name_ja: String?
        let form_name_en: String?
        let base_dm: Int?
        /// Only present when PK compared this exact form's GO settings to the Pokédex.
        let xxl_class: UpperClass?
        let exception: Exception?

        var display: String {
            (form_name_ja ?? form_name_en ?? (isBase ? nil : form)).map { "\(name_ja)（\($0)）" } ?? name_ja
        }
        var isBase: Bool { form_name_ja == nil && form_name_en == nil && id == national_dex_id }
        var tagRanges: Estimate.TagRanges? {
            guard let base_dm, (1...10_000).contains(base_dm), let xxl_class else { return nil }
            return .init(baseDecimetres: base_dm, upperClass: xxl_class)
        }
        var estimate: Estimate? {
            guard exception == nil, let base_dm else { return nil }
            return Estimate(baseDecimetres: base_dm, tags: tagRanges)
        }
    }

    struct Estimate: Equatable, Sendable {
        let baseCentimetres: Int
        let miniAll: Int
        let miniPossible: Int
        let jumboAll: Int
        let jumboPossible: Int
        let tags: TagRanges?

        struct TagRanges: Equatable, Sendable {
            let xxsLow: Int
            let xxsHigh: Int   // Exclusive; XXL below uses the nominal inclusive upper bound.
            let xxlLow: Int
            let xxlHigh: Int

            init(baseDecimetres dm: Int, upperClass: Row.UpperClass) {
                xxsLow = dm * 49
                xxsHigh = dm * 50
                xxlLow = dm * 150
                xxlHigh = dm * upperClass.rawValue
            }
        }

        init?(baseDecimetres dm: Int, tags: TagRanges?) {
            guard (1...10_000).contains(dm) else { return nil }
            baseCentimetres = dm * 10
            // go-sv-pb7-proxy-v1. Use exact integer fractions in centimetres:
            // M/B = 0.6 + 0.79999995/255, J/B = 1.40. A display bin has
            // half-width 0.5 cm. Strict possible edges differ from all-bin
            // edges: ceil(x)-1 is the greatest integer strictly below x.
            let denominator = 25_500_000_000
            let mini = baseCentimetres * 15_379_999_995
            let half = denominator / 2
            miniAll = (mini - half) / denominator
            miniPossible = ((mini + half + denominator - 1) / denominator) - 1
            // J in cm is integral because all Pokédex bases are decimetres.
            // floor(J−0.5)+1 = J; ceil(J+0.5) = J+1.
            jumboPossible = dm * 14
            jumboAll = jumboPossible + 1
            self.tags = tags
        }

        static func metres(cm: Int) -> String { fixed(cm, scale: 100, places: 2) }
        static func metres(mm: Int) -> String { fixed(mm, scale: 1_000, places: 3) }

        private static func fixed(_ amount: Int, scale: Int, places: Int) -> String {
            let remainder = String(amount % scale)
            return "\(amount / scale)." + String(repeating: "0", count: places - remainder.count) + remainder
        }
    }

    enum Match: Equatable { case exact(Row), ambiguous([Row]), unknown }
    enum Guidance: Equatable { case local(String), reference(String) }
    private struct Dataset: Decodable { let rows: [Row] }

    // Pokédex bases may only produce a labelled, conditional estimate. A GO
    // true-height class is independently optional and is never inferred.
    static let bundled: Self? = Bundle.main.url(forResource: "LAAChatPokemonNames", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }.flatMap { try? Self(data: $0) }

    let count: Int
    let auditCount: Int
    let estimableFormCount: Int
    private let speciesByAlias: [String: [Row]]
    private let formsByAlias: [String: [Row]]

    init(data: Data) throws {
        let rows = try JSONDecoder().decode(Dataset.self, from: data).rows
        count = rows.count
        auditCount = rows.count { $0.xxl_class != nil }
        estimableFormCount = rows.count { $0.estimate != nil }
        var species: [String: [Row]] = [:]
        var forms: [String: [Row]] = [:]
        let extraSpecies = [1: ["妙蛙種子", "妙蛙种子"], 25: ["皮卡丘"], 26: ["雷丘"],
                            29: ["Nidoran", "ニドラン"], 32: ["Nidoran", "ニドラン"], 129: ["鯉魚王", "鲤鱼王"]]
        let regionalPrefixes = ["alola": ["Alolan", "アローラ", "アローラの姿"],
                                "galar": ["Galarian", "ガラル", "ガラルの姿"],
                                "hisui": ["Hisuian", "ヒスイ", "ヒスイの姿"],
                                "paldea": ["Paldean", "パルデア", "パルデアの姿"]]
        for row in rows {
            let names = [row.name_ja, row.name_en] + (extraSpecies[row.national_dex_id] ?? [])
            for key in Set(names.map(Self.normalized)) { species[key, default: []].append(row) }
            var labels = [row.form_name_ja, row.form_name_en].compactMap { $0 }
            if row.isBase { labels += ["Normal", "Standard", "通常", "原種", "カントー", "Kantonian"] }
            if row.national_dex_id == 669, let ja = row.form_name_ja {
                labels += [ja.replacingOccurrences(of: "あかいはな", with: "赤い花")
                    .replacingOccurrences(of: "きいろのはな", with: "黄色の花")
                    .replacingOccurrences(of: "あおいはな", with: "青い花")
                    .replacingOccurrences(of: "しろいはな", with: "白い花")
                    .replacingOccurrences(of: "いろのはな", with: "色の花")]
            }
            for (region, prefixes) in regionalPrefixes where row.form.hasSuffix("-\(region)") { labels += prefixes }
            var keys: Set<String> = row.isBase ? [] : [Self.normalized(row.form)]
            for label in labels {
                let normalizedLabel = Self.normalized(label)
                for name in names {
                    if normalizedLabel.contains(Self.normalized(name)) { keys.insert(normalizedLabel) }
                    keys.insert(Self.normalized(label + name))
                    keys.insert(Self.normalized(name + label))
                }
            }
            for key in keys { forms[key, default: []].append(row) }
        }
        speciesByAlias = species
        formsByAlias = forms
    }

    func match(_ name: String) -> Match {
        let key = Self.normalized(name)
        if let rows = formsByAlias[key] { return rows.count == 1 ? .exact(rows[0]) : .ambiguous(rows) }
        guard let group = speciesByAlias[key], !group.isEmpty else { return .unknown }
        let usableNames = group.filter { $0.exception?.excludesFromBareSpecies != true }
        let rows = usableNames.isEmpty ? group : usableNames
        if rows.count == 1 { return .exact(rows[0]) }
        // Do not infer an exact form or a GO class from a bare species name.
        return .ambiguous(rows)
    }

    func guidance(_ name: String, route: Route) -> Guidance {
        switch match(name) {
        case .unknown: .local(LAACopy.ChatProjects.pokemonUnknown)
        case .ambiguous(let rows):
            if route == .go, let first = rows.first, (664...666).contains(first.national_dex_id),
               rows.allSatisfy({ $0.exception == .nonstandardGO }) {
                .local(LAACopy.ChatProjects.pokemonSpecialSize(first.name_ja))
            } else {
                .local(LAACopy.ChatProjects.pokemonAmbiguous(rows.prefix(5).map(\.display).joined(separator: "、")))
            }
        case .exact(let row):
            switch row.exception {
            case .notInSV:
                .local(LAACopy.ChatProjects.pokemonUnsupported(row.display, tags: route == .go ? row.tagRanges : nil))
            case .temporary, .nonordinary:
                .local(LAACopy.ChatProjects.pokemonSpecialForm(row.display))
            case .nonstandardGO where route == .go:
                .local(LAACopy.ChatProjects.pokemonSpecialSize(row.display))
            default:
                if route == .native {
                    .reference(LAACopy.ChatProjects.pokemonNative(row.display))
                } else if let estimate = row.estimate {
                    .reference(LAACopy.ChatProjects.pokemonEstimate(row.display, estimate: estimate))
                } else {
                    .local(LAACopy.ChatProjects.pokemonNoBase(row.display))
                }
            }
        }
    }

    private static func normalized(_ value: String) -> String {
        let locale = Locale(identifier: "ja_JP")
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
        let kana = folded.applyingTransform(.hiraganaToKatakana, reverse: false) ?? folded
        return kana.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "ー♀♂".unicodeScalars.contains($0) }
            .map(String.init).joined()
    }
}
#endif
