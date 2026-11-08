#if LAA_BUILD
import Foundation

/// One question waiting for the owner on the Work hub's board. Board items are
/// records an agent posted through `laa-bridge decide`; session items are a
/// Paseo conversation's own pending question, answered through the existing
/// session decision endpoints.
struct LAADecision: Decodable, Identifiable, Equatable {
    struct Option: Decodable, Equatable {
        let label: String
        let detail: String?
        let recommended: Bool
        init(label: String, detail: String? = nil, recommended: Bool = false) {
            self.label = label; self.detail = detail; self.recommended = recommended
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decode(String.self, forKey: .label)
            detail = try c.decodeIfPresent(String.self, forKey: .detail)
            recommended = try c.decodeIfPresent(Bool.self, forKey: .recommended) ?? false
        }
        private enum CodingKeys: String, CodingKey { case label, detail, recommended }
    }
    struct Source: Decodable, Equatable {
        let paseoAgentId: String?
        let sessionId: String?
        let name: String?
    }
    struct Answer: Decodable, Equatable {
        let optionIndex: Int?
        let label: String
        let note: String?
        let answeredAt: String?
    }
    struct Delivery: Decodable, Equatable {
        let state: String
        let attempts: Int?
        let deliveredAt: String?
        let error: String?
    }
    enum Kind: String, Decodable { case board, session }

    let kind: Kind
    let id: String
    let ref: String?
    let status: String
    let title: String
    let summary: String
    let options: [Option]
    let allowOther: Bool
    let impact: String?
    let deadline: String?
    let source: Source?
    let sourceRef: String?
    let createdAt: String?
    let answer: Answer?
    let delivery: Delivery?
    /// Session items only: the Bridge session that holds the native question.
    let sessionId: String?

    init(kind: Kind = .board, id: String, ref: String? = nil, status: String = "open", title: String, summary: String,
         options: [Option] = [], allowOther: Bool = true, impact: String? = nil, deadline: String? = nil,
         source: Source? = nil, sourceRef: String? = nil, createdAt: String? = nil,
         answer: Answer? = nil, delivery: Delivery? = nil, sessionId: String? = nil) {
        self.kind = kind; self.id = id; self.ref = ref; self.status = status; self.title = title; self.summary = summary
        self.options = options; self.allowOther = allowOther; self.impact = impact; self.deadline = deadline
        self.source = source; self.sourceRef = sourceRef; self.createdAt = createdAt
        self.answer = answer; self.delivery = delivery; self.sessionId = sessionId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A record read from `GET /v1/decisions/:id` carries no kind.
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .board
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        if kind == .session {
            guard let sessionId else {
                throw DecodingError.keyNotFound(CodingKeys.sessionId, .init(codingPath: c.codingPath, debugDescription: "session item"))
            }
            id = sessionId
        } else {
            id = try c.decode(String.self, forKey: .id)
        }
        ref = try c.decodeIfPresent(String.self, forKey: .ref)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "open"
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        // Board records are stored recommended-first; keep that promise on
        // the client too, so an older or hand-written record reads the same.
        let raw = try c.decodeIfPresent([Option].self, forKey: .options) ?? []
        options = raw.filter(\.recommended) + raw.filter { !$0.recommended }
        allowOther = try c.decodeIfPresent(Bool.self, forKey: .allowOther) ?? true
        impact = try c.decodeIfPresent(String.self, forKey: .impact)
        deadline = try c.decodeIfPresent(String.self, forKey: .deadline)
        source = try c.decodeIfPresent(Source.self, forKey: .source)
        sourceRef = try c.decodeIfPresent(String.self, forKey: .sourceRef)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        answer = try c.decodeIfPresent(Answer.self, forKey: .answer)
        delivery = try c.decodeIfPresent(Delivery.self, forKey: .delivery)
    }
    private enum CodingKeys: String, CodingKey {
        case kind, id, ref, status, title, summary, options, allowOther, impact, deadline, source, sourceRef
        case createdAt, answer, delivery, sessionId
    }

    var recommended: Option? { options.first(where: \.recommended) }
    var deliveryFailed: Bool { delivery?.state == "failed" }
    /// The board's original option order is recommended-first; the answer's
    /// optionIndex refers to the stored order, which is the same.
    func index(of option: Option) -> Int? { options.firstIndex(of: option) }

    /// `S5 · 会話名`, the name alone, or nil. Refs are filled in later by the
    /// Bridge, so a null ref must read naturally.
    var sourceLine: String? {
        // A session item's own name is its title; only its ref is extra.
        let name = kind == .session ? nil : source?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [kind == .session ? ref : sourceRef, name].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct LAADecisionPage: Decodable {
    let items: [LAADecision]
    let fetchedAt: String?
}

/// The answer endpoint's envelope.
struct LAADecisionAnswerResult: Decodable { let decision: LAADecision }

enum LAADecisionOrder {
    /// The Bridge's order, applied again so a merged or cached list reads the
    /// same: failed delivery, then deadline (soonest first, none last), then
    /// newest.
    static func sorted(_ items: [LAADecision]) -> [LAADecision] {
        items.enumerated().sorted { lhs, rhs in
            let a = lhs.element, b = rhs.element
            if a.deliveryFailed != b.deliveryFailed { return a.deliveryFailed }
            let da = LAAWorkFreshness.date(a.deadline), db = LAAWorkFreshness.date(b.deadline)
            switch (da, db) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            let ca = LAAWorkFreshness.date(a.createdAt) ?? .distantPast
            let cb = LAAWorkFreshness.date(b.createdAt) ?? .distantPast
            if ca != cb { return ca > cb }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}

enum LAADecisionDeadline {
    /// Relative Japanese text and whether it falls within 24 hours (or has passed).
    static func describe(_ value: String?, now: Date = Date()) -> (text: String, urgent: Bool)? {
        guard let date = LAAWorkFreshness.date(value) else { return nil }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return ("期限を過ぎています", true) }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return ("あと\(max(minutes, 1))分", true) }
        let hours = minutes / 60
        if hours < 24 { return ("あと\(hours)時間", true) }
        let days = hours / 24
        if days < 7 { return ("あと\(days)日", false) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M月d日まで"
        return (formatter.string(from: date), false)
    }
}

enum LAADecisionCopy {
    static let recommended = "推奨"
    static let other = "その他（自由記入）"
    static let notDelivered = "届いていません"
    static let empty = "判断待ちはありません"
    static let emptyDetail = "エージェントが判断を求めると、ここに届きます。"
    static let unsupported = "Macのアップデート待ち"
    static let unsupportedDetail = "Macの LAA Bridge が新しくなると、判断ボードを使えます。"

    /// VoiceOver: 「判断、<title>、推奨 <label>」.
    static func accessibilityLabel(_ item: LAADecision, now: Date = Date()) -> String {
        var parts = ["判断"]
        if item.kind == .board, let ref = LAAWorkRef.display(item.ref) { parts.append(ref) }
        parts.append(item.title)
        if let answer = item.answer { parts.append("回答 \(answer.label)") }
        else if let label = item.recommended?.label { parts.append("推奨 \(label)") }
        if item.deliveryFailed { parts.append(notDelivered) }
        if let deadline = LAADecisionDeadline.describe(item.deadline, now: now) { parts.append(deadline.text) }
        if let source = item.sourceLine { parts.append(source) }
        return parts.joined(separator: "、")
    }

    /// Why a delivery failed, in the owner's words. Codes come from the Bridge.
    static func deliveryError(_ code: String?) -> String {
        switch code {
        case "agent_archived": return "依頼元の会話はアーカイブされています。"
        case "pending_decision_requires_reply": return "依頼元の会話が別の確認を待っています。その確認に答えてから届け直してください。"
        case "paseo_unavailable": return "Macの作業エンジンに届きませんでした。"
        case "delivery_unconfirmed": return "送りましたが、会話が再開したことを確認できませんでした。"
        case "not_found": return "依頼元の会話が見つかりません。"
        default: return "依頼元の会話へ届けられませんでした。"
        }
    }

    static func answerError(_ error: Error) -> String {
        if let error = error as? LAABridgeHTTPError {
            switch error.code {
            case "decision_closed": return "この判断はすでに回答済みか、取り下げられています。"
            case "not_found", "decision_not_found": return "この判断は見つかりません。取り下げられた可能性があります。"
            default: return LAAWorkHTTP.message(error)
            }
        }
        if let error = error as? LAABridgeError { return error.japaneseText }
        return "送信の結果を確認できません。読み直してください。"
    }
}
#endif
