#if LAA_BUILD
import Foundation

struct LAAWorkPage<Item: Decodable>: Decodable {
    let items: [Item]
    let nextCursor: String?
    let sources: [LAAWorkSource]?
    let total: Int?
}

struct LAAWorkConversationMessage: Decodable, Identifiable {
    let id: String
    let role: String
    let text: String
    let timestamp: String?
}

struct LAAWorkRoutine: Decodable, Identifiable {
    let id: String
    let name: String
    let schedule: String?
    let nextRunAt: String?
    let lastRunAt: String?
    let result: String?
    var destination: String? = nil
    var state: String? = nil
    var businessStatus: String? = nil
    var notificationStatus: String? = nil
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
    let fileCount: Int?
    let files: [LAAWorkProjectFile]?

    // An older server simply omits this field. Do not offer editing until the
    // Bridge confirms it can return the actual body and protect the version.
    let hasInstructionBody: Bool
    enum CodingKeys: String, CodingKey {
        case id, name, nameSource, instructionRef, instructionHash, instructionVersion
        case instructions, instructionError, version, etag, updatedAt, fileCount, files
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
        fileCount = try box.decodeIfPresent(Int.self, forKey: .fileCount)
        files = try box.decodeIfPresent([LAAWorkProjectFile].self, forKey: .files)
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
    let profiles: [Profile]
    let defaultProfile: String?
    let defaultMode: String?
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

struct LAAWorkModel: Decodable, Hashable {
    let provider: String?
    let model: String?
    let effort: String?
    let sources: [String: String]?

    var display: String {
        [provider, model, effort].map { $0?.isEmpty == false ? $0! : "未確認" }.joined(separator: " / ")
    }
}

struct LAAWorkSession: Decodable, Identifiable, Hashable {
    struct Cursor: Decodable, Hashable {
        let lastSeq: Int
        let oldestSeq: Int
        let cursor: String
    }
    struct Pending: Decodable, Hashable {
        let count: Int
        let kinds: [String]?
    }
    struct Observation: Decodable, Hashable {
        let available: Bool
        let code: String?
    }
    let id: String
    let name: String
    let nameSource: String?
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

    var isFavorite: Bool { favorite == true }
    var isArchived: Bool { archivedAt != nil }

    var needsDecision: Bool {
        phase == "awaiting_decision" || (pending?.count ?? 0) > 0
    }

    var modelMismatch: Bool {
        guard let requested, let observed else { return false }
        return [(requested.provider, observed.provider), (requested.model, observed.model),
                (requested.effort, observed.effort)].contains { pair in
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
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func path(_ path: String, query: [URLQueryItem]) -> String {
        guard !query.isEmpty else { return path }
        var components = URLComponents()
        components.queryItems = query
        return path + "?" + (components.percentEncodedQuery ?? "")
    }
}
#endif
