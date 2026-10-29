#if LAA_BUILD
import Foundation

struct LAAWorkPage<Item: Decodable>: Decodable {
    let items: [Item]
    let nextCursor: String?
    let sources: [LAAWorkSource]?
    let total: Int?
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

    // An older server simply omits this field. Do not offer editing until the
    // Bridge confirms it can return the actual body and protect the version.
    let hasInstructionBody: Bool
    enum CodingKeys: String, CodingKey {
        case id, name, nameSource, instructionRef, instructionHash, instructionVersion
        case instructions, instructionError, version, etag, updatedAt
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
    }
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
    // LAA uses Japanese interface copy regardless of the device language.
    static func japanese(_ text: String) -> String { text }

    struct SessionRow: Identifiable {
        let session: LAAWorkSession
        let depth: Int
        var id: String { session.id }
    }

    static func sessionRows(_ sessions: [LAAWorkSession]) -> [SessionRow] {
        let sorted = sessions.sorted { $0.createdAt > $1.createdAt }
        let ids = Set(sorted.map(\.id))
        var children: [String: [LAAWorkSession]] = [:]
        var roots: [LAAWorkSession] = []
        for session in sorted {
            if let parent = session.parentId, ids.contains(parent), parent != session.id {
                children[parent, default: []].append(session)
            } else {
                roots.append(session)
            }
        }
        var rows: [SessionRow] = []
        var visited = Set<String>()
        func append(_ session: LAAWorkSession, depth: Int) {
            guard visited.insert(session.id).inserted else { return }
            rows.append(SessionRow(session: session, depth: depth))
            for child in children[session.id] ?? [] { append(child, depth: min(depth + 1, 4)) }
        }
        for session in roots { append(session, depth: 0) }
        // Keep malformed/cyclic parent relationships visible too.
        for session in sorted where !visited.contains(session.id) { append(session, depth: 0) }
        return rows
    }

    static func filteredSessionRows(_ sessions: [LAAWorkSession], projectID: String, phase: String) -> [SessionRow] {
        let matches = sessions.filter {
            (projectID.isEmpty || $0.projectId == projectID) && (phase.isEmpty || $0.phase == phase)
        }
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var included = Set(matches.map(\.id))
        for match in matches {
            var next = match.parentId
            var visited: Set<String> = [match.id]
            while let id = next, visited.insert(id).inserted, let parent = byID[id] {
                included.insert(id)
                next = parent.parentId
            }
        }
        return sessionRows(sessions.filter { included.contains($0.id) })
    }

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
