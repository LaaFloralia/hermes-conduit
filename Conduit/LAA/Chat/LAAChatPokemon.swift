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
        struct Audit: Decodable, Equatable, Sendable {
            let sv: Bool
            let mini: String?
            let jumbo: String?
        }
        let id: Int
        let national_dex_id: Int
        let name_ja: String
        let name_en: String
        let form: String
        let form_name_ja: String?
        let form_name_en: String?
        let is_battle_only: Bool
        let base_height_m: Double?
        let audit: Audit?

        var display: String { form_name_ja.map { "\(name_ja)（\($0)）" } ?? name_ja }
        var ordinary: Bool { form_name_ja == nil && form_name_en == nil && id == national_dex_id }
    }

    enum Match: Equatable { case exact(Row), ambiguous([Row]), unknown }
    enum Guidance: Equatable { case local(String), verified(String) }
    private struct Dataset: Decodable { let rows: [Row] }

    // Separate the lexical dictionary from the ten audited GO rows. Missing
    // evidence is not silently supplied by a Pokédex height or by the model.
    static let bundled: Self? = Bundle.main.url(forResource: "LAAChatPokemonNames", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }.flatMap { try? Self(data: $0) }

    let count: Int
    private let speciesByAlias: [String: [Row]]
    private let formsByAlias: [String: [Row]]

    init(data: Data) throws {
        let rows = try JSONDecoder().decode(Dataset.self, from: data).rows
        count = rows.count
        var species: [String: [Row]] = [:]
        var forms: [String: [Row]] = [:]
        let extraSpecies = [1: ["妙蛙種子", "妙蛙种子"], 25: ["皮卡丘"], 26: ["雷丘"], 129: ["鯉魚王", "鲤鱼王"]]
        let regionalPrefixes = ["alola": ["Alolan", "アローラ", "アローラの姿"],
                                "galar": ["Galarian", "ガラル", "ガラルの姿"],
                                "hisui": ["Hisuian", "ヒスイ", "ヒスイの姿"],
                                "paldea": ["Paldean", "パルデア", "パルデアの姿"]]
        for row in rows {
            let names = [row.name_ja, row.name_en] + (extraSpecies[row.national_dex_id] ?? [])
            for key in Set(names.map(Self.normalized)) { species[key, default: []].append(row) }
            var labels = [row.form_name_ja, row.form_name_en].compactMap { $0 }
            if row.ordinary { labels += ["Normal", "Standard", "通常", "原種", "カントー", "Kantonian"] }
            if row.national_dex_id == 669, let ja = row.form_name_ja {
                labels += [ja.replacingOccurrences(of: "あかいはな", with: "赤い花")
                    .replacingOccurrences(of: "きいろのはな", with: "黄色の花")
                    .replacingOccurrences(of: "あおいはな", with: "青い花")
                    .replacingOccurrences(of: "しろいはな", with: "白い花")
                    .replacingOccurrences(of: "いろのはな", with: "色の花")]
            }
            for (region, prefixes) in regionalPrefixes where row.form.hasSuffix("-\(region)") { labels += prefixes }
            var keys: Set<String> = row.ordinary ? [] : [Self.normalized(row.form)]
            for label in labels {
                for name in names {
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
        let rows = group.filter { !$0.is_battle_only }
        if rows.count == 1 { return .exact(rows[0]) }
        // A costume or battle form must be named explicitly. Bare species
        // are ambiguous when ordinary vs regional/dimension-changing data
        // differs, or when no ordinary/default form exists (flower colours).
        if let ordinary = rows.first(where: \.ordinary) {
            let relevant = rows.filter {
                $0.ordinary || $0.base_height_m != ordinary.base_height_m ||
                    ["-alola", "-galar", "-hisui", "-paldea"].contains(where: $0.form.hasSuffix)
            }
            return relevant.count == 1 ? .exact(ordinary) : .ambiguous(relevant)
        }
        return .ambiguous(rows.isEmpty ? group : rows)
    }

    func guidance(_ name: String, route: Route) -> Guidance {
        switch match(name) {
        case .unknown: .local(LAACopy.ChatProjects.pokemonUnknown)
        case .ambiguous(let rows): .local(LAACopy.ChatProjects.pokemonAmbiguous(rows.prefix(5).map(\.display).joined(separator: "、")))
        case .exact(let row):
            if row.audit?.sv == false || row.is_battle_only {
                .local(LAACopy.ChatProjects.pokemonUnsupported(row.display))
            } else if route == .native {
                .verified(LAACopy.ChatProjects.pokemonNative(row.display))
            } else if let audit = row.audit, let mini = audit.mini, let jumbo = audit.jumbo {
                .verified(LAACopy.ChatProjects.pokemonEstimate(row.display, mini: mini, jumbo: jumbo))
            } else {
                .local(LAACopy.ChatProjects.pokemonUnaudited(row.display))
            }
        }
    }

    private static func normalized(_ value: String) -> String {
        let locale = Locale(identifier: "ja_JP")
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
        let kana = folded.applyingTransform(.hiraganaToKatakana, reverse: false) ?? folded
        return kana.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "ー" }.map(String.init).joined()
    }
}
#endif
