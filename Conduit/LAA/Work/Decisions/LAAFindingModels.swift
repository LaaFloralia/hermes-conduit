#if LAA_BUILD
import Foundation

/// D-18: something a session or an AI employee found outside its request and
/// filed with `laa-bridge finding add` without stopping. The owner reads it on
/// the board's Findings side and either hands it to Monet or lets it go.
struct LAAFinding: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case open, delegated, done, dismissed }
    enum Effort: String, Codable { case small, medium, large }
    struct Source: Codable, Equatable {
        let sessionId: String?
        let name: String?
    }
    struct Pickup: Codable, Equatable {
        let plan: String?
        let at: String?
    }

    let id: String
    let ref: String?
    let title: String
    let found: String
    let evidence: String
    let plan: String
    /// Nil for a value this build does not know.
    let effort: Effort?
    let source: Source?
    /// `S5` when the Bridge could resolve the conversation.
    let sourceRef: String?
    let images: [LAADecision.Image]
    /// Nil for a status this build does not know; such a row is not shown.
    let status: Status?
    let result: String?
    let pickup: Pickup?
    let stale: Bool
    let createdAt: String?
    let updatedAt: String?
    let delegatedAt: String?
    let doneAt: String?

    init(id: String, ref: String? = nil, title: String, found: String = "", evidence: String = "", plan: String = "",
         effort: Effort? = .small, source: Source? = nil, sourceRef: String? = nil, images: [LAADecision.Image] = [],
         status: Status? = .open, result: String? = nil, pickup: Pickup? = nil, stale: Bool = false,
         createdAt: String? = nil, updatedAt: String? = nil, delegatedAt: String? = nil, doneAt: String? = nil) {
        self.id = id; self.ref = ref; self.title = title; self.found = found; self.evidence = evidence
        self.plan = plan; self.effort = effort; self.source = source; self.sourceRef = sourceRef
        self.images = images; self.status = status; self.result = result; self.pickup = pickup; self.stale = stale
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.delegatedAt = delegatedAt; self.doneAt = doneAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        ref = try c.decodeIfPresent(String.self, forKey: .ref)
        title = try c.decode(String.self, forKey: .title)
        found = try c.decodeIfPresent(String.self, forKey: .found) ?? ""
        evidence = try c.decodeIfPresent(String.self, forKey: .evidence) ?? ""
        plan = try c.decodeIfPresent(String.self, forKey: .plan) ?? ""
        effort = (try? c.decodeIfPresent(String.self, forKey: .effort)).flatMap { $0.flatMap(Effort.init(rawValue:)) }
        source = try? c.decodeIfPresent(Source.self, forKey: .source)
        sourceRef = try c.decodeIfPresent(String.self, forKey: .sourceRef)
        // A finding has no option pictures; only ids the route accepts are kept.
        let stored = (try? c.decodeIfPresent([LAADecision.Image].self, forKey: .images)) ?? []
        images = stored.filter { LAADecision.Image.validID($0.id) }
            .map { .init(id: $0.id, width: $0.width, height: $0.height) }
        status = (try? c.decodeIfPresent(String.self, forKey: .status)).flatMap { $0.flatMap(Status.init(rawValue:)) }
        result = try c.decodeIfPresent(String.self, forKey: .result)
        pickup = try? c.decodeIfPresent(Pickup.self, forKey: .pickup)
        stale = (try? c.decodeIfPresent(Bool.self, forKey: .stale)) ?? false
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        delegatedAt = try c.decodeIfPresent(String.self, forKey: .delegatedAt)
        doneAt = try c.decodeIfPresent(String.self, forKey: .doneAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, ref, title, found, evidence, plan, effort, source, sourceRef, images, status, result, pickup, stale
        case createdAt, updatedAt, delegatedAt, doneAt
    }

    /// Only an id the Bridge issues is ever put into a path.
    static func validID(_ id: String) -> Bool {
        id.range(of: #"^fnd_[0-9a-f]{16}$"#, options: .regularExpression) != nil
    }

    var isOpen: Bool { status == .open }
    /// Open and delegated: what the menu counts (CONTRACT D-18).
    var counts: Bool { status == .open || status == .delegated }
    /// What the board lists: open, delegated and done (the Bridge drops done after 7 days).
    var listed: Bool { status == .open || status == .delegated || status == .done }

    /// `S5 · 会話名`, the name alone, or nil.
    var sourceLine: String? {
        let name = source?.name?
            .replacingOccurrences(of: #"\s*｜\s*"#, with: " · ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [sourceRef, name].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The D-17 picture components take a decision; a finding lends its id
    /// and general pictures (the image key routes `fnd_` ids to findings).
    var imageCarrier: LAADecision {
        LAADecision(id: id, status: status?.rawValue ?? "open", title: title, summary: "", images: images)
    }

    /// The same record after the owner's action, until the Bridge's copy arrives.
    func with(status: Status) -> LAAFinding {
        LAAFinding(id: id, ref: ref, title: title, found: found, evidence: evidence, plan: plan, effort: effort,
                   source: source, sourceRef: sourceRef, images: images, status: status, result: result, pickup: pickup,
                   stale: stale, createdAt: createdAt, updatedAt: updatedAt, delegatedAt: delegatedAt, doneAt: doneAt)
    }
}

struct LAAFindingPage: Decodable {
    struct Counts: Decodable, Equatable {
        let open: Int
        let delegated: Int
        let done: Int
    }
    let items: [LAAFinding]
    let counts: Counts?
}

/// The delegate and dismiss envelope.
struct LAAFindingResult: Decodable { let finding: LAAFinding }

enum LAAFindingOrder {
    /// Newest first, as the Bridge lists them; the Bridge's order breaks ties.
    static func sorted(_ items: [LAAFinding]) -> [LAAFinding] {
        items.enumerated().sorted { lhs, rhs in
            let a = LAAWorkFreshness.date(lhs.element.createdAt) ?? .distantPast
            let b = LAAWorkFreshness.date(rhs.element.createdAt) ?? .distantPast
            if a != b { return a > b }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}

enum LAAFindingCopy {
    static let delegate = "Monetに任せる"
    static let dismiss = "見送る"
    static let delegated = "Monetが対応中"
    static let done = "Done"
    static let empty = "No Findings"
    static let unsupported = "Macのアップデート待ち"
    static let unsupportedDetail = "気づきを使うには、MacのLAAアプリを最新にしてください。"
    static let loadFailed = "気づきを読めません"
    static let choose = "気づきを選んでください"
    static let sectionFound = "何に気づいたか"
    static let sectionEvidence = "根拠"
    static let sectionPlan = "対応方法"
    static let sectionEffort = "影響と手間"
    static let sectionSource = "見つけた会話"
    static let unknownSource = "会話は不明です"

    static func effort(_ value: LAAFinding.Effort?) -> String? {
        switch value {
        case .small: "小"
        case .medium: "中"
        case .large: "大"
        case nil: nil
        }
    }

    /// `手間 小`.
    static func effortLine(_ value: LAAFinding.Effort?) -> String? { effort(value).map { "手間 \($0)" } }

    /// The row's quiet second line: where it was found and how big it is;
    /// Monet's turn once delegated; the result once done.
    static func meta(_ item: LAAFinding) -> String? {
        switch item.status {
        case .delegated: return delegated
        case .done:
            let result = item.result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return result.isEmpty ? done : "\(done) · \(result)"
        default:
            let parts = [item.sourceLine, effortLine(item.effort)].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    /// VoiceOver: 「気づき、F3、<題>、<2行目>」.
    static func accessibilityLabel(_ item: LAAFinding) -> String {
        var parts = ["気づき"]
        if let ref = LAAWorkRef.display(item.ref) { parts.append(ref) }
        parts.append(item.title)
        if let meta = meta(item) { parts.append(meta) }
        if !item.images.isEmpty { parts.append(LAADecisionCopy.imagesAttached) }
        return parts.joined(separator: "、")
    }

    /// Why a delegate or dismiss was not taken.
    static func actionError(_ error: Error) -> String {
        if let error = error as? LAABridgeHTTPError {
            switch error.code {
            case "finding_state": return "この気づきはすでに任せたか、見送られています。"
            case "not_found", "finding_not_found": return "この気づきは見つかりません。"
            default:
                if error.status == 404 || error.status == 405 { return unsupportedDetail }
                return LAAWorkHTTP.message(error)
            }
        }
        if let error = error as? LAABridgeError { return error.japaneseText }
        return "送信の結果を確認できません。読み直してください。"
    }
}
#endif
