#if LAA_BUILD
import Foundation

struct LAAWorkPage<Item: Decodable>: Decodable {
    let items: [Item]
    let nextCursor: String?
    let sources: [LAAWorkSource]?
    let total: Int?
    /// Rows the Bridge could not read from its source. A list with any is
    /// partial: it must not be presented as the whole answer.
    let skipped: Int?
    /// When the Bridge last read a cacheable list successfully. Its slow
    /// read-only routes answer from the last good value while they refresh,
    /// so a page older than the freshness window is shown as such.
    let fetchedAt: String?
}

enum LAAWorkFreshness {
    static let staleAfter: TimeInterval = 60

    static func date(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func isStale(_ fetchedAt: Date?, now: Date = Date()) -> Bool {
        guard let fetchedAt else { return false }
        return now.timeIntervalSince(fetchedAt) > staleAfter
    }
}

struct LAAWorkConversationMessage: Codable, Identifiable {
    let id: String
    let role: String
    let text: String
    let timestamp: String?
    var images: [String]? = nil
    /// The model the Bridge observed both before and after this reply was
    /// written. Absent when it cannot vouch for one (an older reply, a gap
    /// between observations, the turn before a provider's own switch) or from
    /// an older Bridge: the row then names the provider only.
    var model: LAAWorkModel? = nil
}

/// `GET /v1/sessions/:id/conversation`. The Bridge sends only the owner's and
/// the AI's messages; `compacting` says the provider is compacting the context
/// now. An older Bridge omits it, which reads as false.
struct LAAWorkConversationPage: Decodable {
    let items: [LAAWorkConversationMessage]
    var compacting: Bool? = nil
}

struct LAAWorkRoutine: Codable, Identifiable {
    let id: String
    let name: String
    let schedule: String?
    let nextRunAt: String?
    let lastRunAt: String?
    let result: String?
    var triggerKind: String? = nil
    var destination: String? = nil
    var state: String? = nil
    var businessStatus: String? = nil
    var notificationStatus: String? = nil
    var runId: String? = nil
    var reasonCode: String? = nil
    var observationStatus: String? = nil
    var scheduledAt: String? = nil
    var expectedRunAt: String? = nil
    var startedAt: String? = nil
    var finishedAt: String? = nil
    var notificationAcceptedAt: String? = nil
    var notificationSentAt: String? = nil
    var notificationReceivedAt: String? = nil
    /// The short number the owner says ("R7"). Absent from an older Bridge.
    var ref: String? = nil

    static func recordedTime(_ value: String?) -> String {
        guard let date = LAAWorkFreshness.date(value) else { return "未確認" }
        return LAADateText.string(date, .monthDayTime)
    }

    var notificationSummary: String? {
        switch notificationStatus {
        case "accepted": "チャット受付済み・端末受信未確認"
        case "delivered": "送信済み・端末受信未確認"
        case "read_back": "端末受信確認済み"
        case "not_received": "通知未到達"
        case "failed", "error", "partial", "timeout": "配信失敗"
        case "suppressed": "通知なし"
        default: nil
        }
    }

    func previousRunSummary(timeZone: TimeZone = .current) -> String {
        let status = businessStatus == nil || businessStatus == "unknown" ? result : businessStatus
        let outcome: String
        switch reasonCode ?? "" {
        case "schedule_overdue": outcome = "予定超過・結果なし"
        case "read_unavailable": outcome = "取得不能"
        default:
        switch status {
        case "success", "ok", "succeeded", "completed": outcome = "完了"
        case "running": outcome = "実行中"
        case "pending": outcome = "待機中"
        case "failed", "error": outcome = "業務エラー"
        case "partial": outcome = "業務一部未完了"
        case "timeout": outcome = "業務時間切れ"
        default: outcome = "未確認"
        }
        }
        var results = [outcome]
        if let notification = notificationSummary { results.append(notification) }
        guard let lastRunAt else { return results == ["未確認"] ? "未確認" : (["時刻未確認"] + results).joined(separator: " · ") }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let time: String
        if let date = fractional.date(from: lastRunAt) ?? plain.date(from: lastRunAt) {
            time = LAADateText.string(date, .monthDayTime, timeZone: timeZone)
        } else { time = "時刻未確認" }
        return ([time] + results).joined(separator: " · ")
    }
}

struct LAAWorkSource: Decodable {
    let source: String
    let state: String
    let reason: String?
    let truncated: Bool?
}

struct LAAWorkProject: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let nameSource: String?
    let instructionRef: String?
    let instructionHash: String?
    let instructionVersion: Int?
    let instructions: String?
    let instructionError: String?
    let version: Int?
    let etag: String?
    let updatedAt: String?
    let archivedAt: String?
    let fileCount: Int?
    let files: [LAAWorkProjectFile]?
    /// The short number the owner says ("P2"). Absent from an older Bridge.
    let ref: String?

    var isArchived: Bool { archivedAt != nil }

    // An older server simply omits this field. Do not offer editing until the
    // Bridge confirms it can return the actual body and protect the version.
    let hasInstructionBody: Bool
    enum CodingKeys: String, CodingKey {
        case id, name, nameSource, instructionRef, instructionHash, instructionVersion
        case instructions, instructionError, version, etag, updatedAt, archivedAt, fileCount, files, ref
    }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(String.self, forKey: .id)
        name = try box.decode(String.self, forKey: .name)
        nameSource = try box.decodeIfPresent(String.self, forKey: .nameSource)
        instructionRef = try box.decodeIfPresent(String.self, forKey: .instructionRef)
        instructionHash = try box.decodeIfPresent(String.self, forKey: .instructionHash)
        instructionVersion = try box.decodeIfPresent(Int.self, forKey: .instructionVersion)
        hasInstructionBody = box.contains(.instructions)
        instructions = try box.decodeIfPresent(String.self, forKey: .instructions)
        instructionError = try box.decodeIfPresent(String.self, forKey: .instructionError)
        version = try box.decodeIfPresent(Int.self, forKey: .version)
        etag = try box.decodeIfPresent(String.self, forKey: .etag)
        updatedAt = try box.decodeIfPresent(String.self, forKey: .updatedAt)
        archivedAt = try box.decodeIfPresent(String.self, forKey: .archivedAt)
        fileCount = try box.decodeIfPresent(Int.self, forKey: .fileCount)
        files = try box.decodeIfPresent([LAAWorkProjectFile].self, forKey: .files)
        ref = try box.decodeIfPresent(String.self, forKey: .ref)
    }
}

/// A project's reference file on the Mac. The phone sees its name and size only.
struct LAAWorkProjectFile: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let size: Int?
    let mimeType: String?
    let createdAt: String?
}

/// Model/effort choices for a new session, from the HQ model table.
struct LAAWorkSessionOptions: Decodable {
    struct Profile: Decodable, Identifiable, Hashable {
        let id: String
        let label: String
        let provider: String
        let model: String
        let effort: String
        let fast: Bool
    }
    /// The efforts Paseo can apply to one model of a running session. More
    /// than the profiles: those name what a new session may start with.
    struct ModelEfforts: Decodable, Hashable {
        let provider: String
        let model: String
        let efforts: [String]
    }
    let profiles: [Profile]
    let defaultProfile: String?
    let defaultMode: String?
    /// Absent from a Bridge that predates it, and empty when Paseo could not
    /// be asked; the profiles then stand in.
    var efforts: [ModelEfforts]? = nil
}

struct LAAWorkWorkspace: Decodable, Identifiable, Hashable {
    let id: String
    let path: String
    let displayPath: String?
    let kind: String?
    let branch: String?
    let projectId: String?
    let repoId: String?
}

struct LAAWorkModel: Codable, Hashable {
    let provider: String?
    let model: String?
    let effort: String?
    let sources: [String: String]?

    var display: String {
        [provider, model, effort].map { $0?.isEmpty == false ? $0! : "未確認" }.joined(separator: " / ")
    }
}

struct LAAWorkSession: Codable, Identifiable, Hashable {
    struct Cursor: Codable, Hashable {
        let lastSeq: Int
        let oldestSeq: Int
        let cursor: String
    }
    struct Pending: Codable, Hashable {
        let count: Int
        let kinds: [String]?
    }
    struct Observation: Codable, Hashable {
        let available: Bool
        let code: String?
    }
    /// What the Bridge and its daemon can actually do to this session. A
    /// missing or false value means no control is offered.
    struct Capabilities: Codable, Hashable {
        let effort: Bool?
        /// The daemon accepts `PATCH /v1/sessions/:id {"fast": …}` for this
        /// session. An older Bridge omits it, so the Fast pill only reads.
        let fast: Bool?
        /// The daemon accepts `PATCH /v1/sessions/:id {"model": …}` within the
        /// session's provider. An older Bridge omits it: the menu lists the
        /// models without letting one be chosen.
        var model: Bool? = nil
    }
    let id: String
    let name: String
    let nameSource: String?
    let delegateSessionId: String?
    let requestId: String
    let parentId: String?
    let projectId: String?
    let workspaceId: String
    let cwd: String?
    let profile: String
    let requested: LAAWorkModel?
    let observed: LAAWorkModel?
    let runtimeVerified: Bool?
    let phase: String
    let pending: Pending?
    let resumedFrom: String?
    let resumedTo: String?
    let instructionVersion: Int?
    let instructionHash: String?
    let createdAt: String
    let updatedAt: String
    let observedAt: String?
    let events: Cursor
    let observation: Observation?
    // Newer Bridge fields; an older Bridge omits them.
    let favorite: Bool?
    let archivedAt: String?
    let mode: String?
    let fast: Bool?
    let worktree: Bool?
    /// The provider's own Fast value, when it reports one. `fast` is only what
    /// the Bridge requested at start, so it is not shown as the current state.
    let observedFast: Bool?
    let capabilities: Capabilities?
    /// What the owner changed after the start (model, effort); the request
    /// itself is never rewritten. Absent from an older Bridge.
    var ownerChanged: LAAWorkModel? = nil
    /// The short number the owner says ("S4"). Absent from an older Bridge.
    let ref: String?
    /// The last model change the Bridge itself observed. Absent when it has
    /// seen none, and from an older Bridge.
    var modelChange: ModelChange? = nil
    /// Follow-ups the Bridge holds until the running turn ends.
    var queue: Queue? = nil

    struct ModelChange: Codable, Hashable {
        let from: LAAWorkModel?
        let to: LAAWorkModel?
        let seenAt: String?
        let byOwner: Bool?
    }
    struct Queue: Codable, Hashable {
        let count: Int
    }

    var isFavorite: Bool { favorite == true }
    var isArchived: Bool { archivedAt != nil }

    var needsDecision: Bool {
        phase == "awaiting_decision" || (pending?.count ?? 0) > 0
    }

    var modelMismatch: Bool {
        guard let requested, let observed else { return false }
        // The owner's own later choice is what the observation should match.
        let model = ownerChanged?.model ?? requested.model
        let effort = ownerChanged?.effort ?? requested.effort
        return [(requested.provider, observed.provider), (model, observed.model),
                (effort, observed.effort)].contains { pair in
            guard let requested = pair.0, let actual = pair.1, !requested.isEmpty, !actual.isEmpty else { return false }
            return requested != actual
        }
    }
}

struct LAAWorkEvent: Decodable, Identifiable, Hashable {
    let seq: Int
    let type: String
    let occurredAt: String
    var id: Int { seq }
}
struct LAAWorkEventPage: Decodable {
    let items: [LAAWorkEvent]
    let nextCursor: String
    let oldestSeq: Int
    let headSeq: Int
    let resyncRequired: Bool
    let resyncReason: String?
}
struct LAAWorkArtifact: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let type: String
    let content: String?
    let available: Bool?
    let reason: String?
    let truncated: Bool?
}
struct LAAWorkArtifacts: Decodable { let items: [LAAWorkArtifact] }

struct LAAWorkTask: Decodable, Identifiable, Hashable {
    struct Person: Decodable, Hashable { let id: String?; let name: String?; let kind: String? }
    struct State: Decodable, Hashable { let name: String?; let type: String?; let category: String? }
    struct Project: Decodable, Hashable { let id: String?; let name: String? }
    let id: String
    let source: String
    let sourceId: String
    let title: String
    let owner: Person?
    let executor: Person?
    let status: State?
    let project: Project?
    let url: String?
    let updatedAt: String?
    let description: String?
}
enum LAAWorkPresentation {
    static func japanese(_ text: String) -> String { text }

    static func phase(_ raw: String) -> String {
        switch raw {
        case "created": return "開始中"
        case "running": return "実行中"
        case "awaiting_decision": return "判断待ち"
        case "awaiting_review": return "確認待ち"
        case "stopped": return "停止済み"
        case "stop_unconfirmed": return "停止未確認"
        case "closed": return "終了"
        case "error": return "エラー"
        default: return raw
        }
    }

    static func phaseSymbol(_ raw: String) -> String {
        switch raw {
        case "awaiting_decision", "stop_unconfirmed", "error": return "▲"
        case "created", "awaiting_review": return "○"
        case "running", "stopped", "closed": return "●"
        default: return "○"
        }
    }

    static func phaseNeedsAttention(_ raw: String) -> Bool {
        ["awaiting_decision", "stop_unconfirmed", "error"].contains(raw)
    }

    static func event(_ raw: String) -> String {
        switch raw {
        case "session.created": return "開始"
        case "session.phase": return "状態が変わりました"
        case "session.pending": return "判断待ちが変わりました"
        case "session.result": return "回答を更新"
        case "session.message.sent": return "追加指示を送信"
        case "session.stopped": return "停止を確認"
        case "session.stop_unconfirmed": return "停止を確認できません"
        case "session.resumed": return "後継セッションを開始"
        default: return raw
        }
    }

    static func date(_ text: String?) -> String {
        guard let text else { return "未確認" }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let date = fractional.date(from: text) ?? plain.date(from: text) else { return text }
        return LAADateText.string(date, .dayTime)
    }

    static func path(_ path: String, query: [URLQueryItem]) -> String {
        guard !query.isEmpty else { return path }
        var components = URLComponents()
        components.queryItems = query
        return path + "?" + (components.percentEncodedQuery ?? "")
    }
}
#endif
