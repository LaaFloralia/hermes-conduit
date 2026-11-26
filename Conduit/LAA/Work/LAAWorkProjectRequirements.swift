#if LAA_BUILD
import Foundation

/// A list that keeps the rows it can read. The Bridge adds fields over time;
/// one row the app does not understand must not hide the others.
struct LAAWorkLossyList<Item: Decodable>: Decodable {
    let items: [Item]
    private struct Skip: Decodable {}
    init(from decoder: Decoder) throws {
        var box = try decoder.unkeyedContainer()
        var items: [Item] = []
        while !box.isAtEnd {
            if let item = try? box.decode(Item.self) { items.append(item) } else { _ = try? box.decode(Skip.self) }
        }
        self.items = items
    }
}

/// Where one requirement stands. The Bridge's four values, plus one for a
/// value this app does not know yet, which is shown as unknown rather than
/// passed off as one of the four.
enum LAAWorkRequirementStatus: String, CaseIterable, Hashable {
    case inProgress = "in_progress"
    case awaitingDecision = "awaiting_decision"
    case notStarted = "not_started"
    case completed
    case unknown

    init(raw: String) { self = Self(rawValue: raw) ?? .unknown }

    /// The values the owner can choose (the Bridge accepts these four).
    static let choices: [Self] = [.inProgress, .awaitingDecision, .notStarted, .completed]

    /// The order of the list: what is moving first, then what waits for the
    /// owner, then what has not begun; finished work sinks to the end.
    var rank: Int {
        switch self {
        case .inProgress: 0
        case .awaitingDecision: 1
        case .notStarted: 2
        case .unknown: 3
        case .completed: 4
        }
    }

    var label: String { LAACopy.WorkProject.status(self) }

    /// The same marks as the session rows: a working dot, the plum question,
    /// the hollow ring and the teal check.
    var mark: LAAWorkStatus {
        switch self {
        case .inProgress: .running
        case .awaitingDecision: .decision
        case .notStarted, .unknown: .pending
        case .completed: .done
        }
    }
}

struct LAAWorkRequirement: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let details: String?
    /// `owner` (the owner's own words) or `ai` (an item the AI added).
    let source: String
    let statusValue: String
    let sessionIds: [String]
    let order: Int
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, title, details, source, sessionIds, order, updatedAt
        case statusValue = "status"
    }

    init(id: String, title: String, details: String? = nil, source: String = "owner",
         status: LAAWorkRequirementStatus, sessionIds: [String] = [], order: Int, updatedAt: String? = nil) {
        self.id = id; self.title = title; self.details = details; self.source = source
        statusValue = status.rawValue; self.sessionIds = sessionIds; self.order = order; self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(String.self, forKey: .id)
        title = try box.decode(String.self, forKey: .title)
        let details = try box.decodeIfPresent(String.self, forKey: .details)
        self.details = details.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        source = (try? box.decodeIfPresent(String.self, forKey: .source)) ?? "owner"
        statusValue = (try? box.decodeIfPresent(String.self, forKey: .statusValue)) ?? "unknown"
        sessionIds = (try? box.decodeIfPresent([String].self, forKey: .sessionIds)) ?? []
        order = (try? box.decodeIfPresent(Int.self, forKey: .order)) ?? Int.max
        updatedAt = try? box.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    var status: LAAWorkRequirementStatus { LAAWorkRequirementStatus(raw: statusValue) }
    var addedByAI: Bool { source == "ai" }
}

/// A project's sessions before paging: unarchived and archived. `active` is
/// every unarchived Session, at work or not; the breakdown (BUS-508) is absent
/// from an older Bridge and from a reading kept by an earlier build.
struct LAAWorkSessionCounts: Codable, Hashable {
    let active: Int
    let archived: Int
    var running: Int? = nil
    var awaitingDecision: Int? = nil
    var waiting: Int? = nil
}

struct LAAWorkRequirementSummary: Codable, Hashable {
    let completed: Int
    let total: Int

    init(completed: Int, total: Int) { self.completed = completed; self.total = total }
    init(_ requirements: [LAAWorkRequirement]) {
        completed = requirements.filter { $0.status == .completed }.count
        total = requirements.count
    }

    var fraction: Double { total > 0 ? Double(min(completed, total)) / Double(total) : 0 }
}

/// One of the project's sessions as the project detail lists it.
struct LAAWorkProjectSession: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    /// running, waiting, awaiting_decision or completed.
    let status: String
    let model: String?
    let updatedAt: String?
    let parentId: String?
    let archivedAt: String?

    var isArchived: Bool { archivedAt != nil }

    /// The session list's mark: a session waiting for its next instruction is
    /// 待機, apart from 完了 and 実行中 (BUS-508).
    var mark: LAAWorkStatus {
        switch status {
        case "running": .running
        case "awaiting_decision": .decision
        case "waiting": .waiting
        case "completed": .done
        default: .pending
        }
    }
    var statusLabel: String { LAACopy.WorkProject.sessionStatus(status) }
}

/// A session a requirement names, from whichever list knows it.
struct LAAWorkLinkedSession: Hashable, Identifiable {
    let id: String
    let name: String
    let ref: String?
    let mark: LAAWorkStatus
    let statusLabel: String

    static func lookup(compact: [LAAWorkProjectSession]?, full: [LAAWorkSession]) -> [String: LAAWorkLinkedSession] {
        var result: [String: LAAWorkLinkedSession] = [:]
        for row in compact ?? [] {
            result[row.id] = .init(id: row.id, name: row.name, ref: nil, mark: row.mark, statusLabel: row.statusLabel)
        }
        for row in full {
            let mark = LAAWorkStatus.session(row.needsDecision ? "awaiting_decision" : row.phase)
            result[row.id] = .init(id: row.id, name: row.name, ref: row.ref, mark: mark, statusLabel: mark.label)
        }
        return result
    }

    /// A linked session the shown pages don't hold (archived, or past the
    /// first 200). It still opens by its ID.
    static func unlisted(_ id: String) -> LAAWorkLinkedSession {
        .init(id: id, name: LAACopy.WorkProject.unlistedSession, ref: nil, mark: .pending,
              statusLabel: LAACopy.WorkProject.unlistedSession)
    }
}

/// The detail, re-read with the tag of the last answer: an unchanged project
/// costs the Bridge a 304 and the phone nothing. The tag covers the shown
/// sessions too; the project's own `etag` stays the one writes send.
enum LAAWorkProjectDetailAPI {
    enum Answer {
        case changed(LAAWorkProject, tag: String?)
        case unchanged
    }

    @MainActor static func read(_ bridge: LAABridgeSession, id: String, tag: String?) async throws -> Answer {
        do {
            let response: LAABridgeResponse<LAAWorkProject> = try await bridge.request(
                method: "GET", path: "/v1/projects/\(id)", ifNoneMatch: tag)
            return .changed(response.data, tag: response.etag)
        } catch let failure as LAABridgeHTTPError where failure.status == 304 && tag != nil {
            return .unchanged
        }
    }
}

/// A project's full session rows (`GET /v1/sessions?projectId=`), read a page
/// at a time: the first screen holds up to 200, and the owner reads on from
/// there. Archived rows are a list of their own, read only when asked for.
enum LAAWorkProjectSessionsAPI {
    static let firstScreen = 200
    static let pageSize = 100

    static func query(_ projectID: String, archived: Bool, cursor: String?) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "projectId", value: projectID), URLQueryItem(name: "limit", value: String(pageSize))]
        if archived { items.append(URLQueryItem(name: "archived", value: "only")) }
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return items
    }

    /// Reads on from `cursor` until it holds `atLeast` rows or the list ends.
    @MainActor static func read(_ bridge: LAABridgeSession, project: String, archived: Bool, from cursor: String? = nil,
                                atLeast: Int = firstScreen) async throws -> (rows: [LAAWorkSession], cursor: String?) {
        var rows: [LAAWorkSession] = []
        var next = cursor
        var seen = Set<String>()
        repeat {
            let page: LAAWorkPage<LAAWorkSession> = try await bridge.read(
                LAAWorkPresentation.path("/v1/sessions", query: query(project, archived: archived, cursor: next)))
            rows += page.items
            next = page.nextCursor
            if let next, !seen.insert(next).inserted { throw LAABridgeError.invalidResponse }
        } while next != nil && rows.count < atLeast
        return (rows.filter { $0.worktree != true && $0.isArchived == archived }, next)
    }
}

/// The requirements in the order the detail draws them: one group per status,
/// each in the Bridge's own order.
struct LAAWorkRequirementBoard: Equatable {
    struct Group: Equatable, Identifiable {
        let status: LAAWorkRequirementStatus
        let items: [LAAWorkRequirement]
        var id: String { status.rawValue }
    }

    let groups: [Group]
    let summary: LAAWorkRequirementSummary

    init(_ requirements: [LAAWorkRequirement]) {
        summary = LAAWorkRequirementSummary(requirements)
        let byStatus = Dictionary(grouping: requirements, by: \.status)
        groups = LAAWorkRequirementStatus.allCases.sorted { $0.rank < $1.rank }.compactMap { status in
            guard let items = byStatus[status], !items.isEmpty else { return nil }
            return Group(status: status, items: items.sorted { ($0.order, $0.id) < ($1.order, $1.id) })
        }
    }

    func count(_ status: LAAWorkRequirementStatus) -> Int {
        groups.first { $0.status == status }?.items.count ?? 0
    }

    /// The finished group starts folded while anything else is open, so the
    /// open work is what the owner sees; when all is done it opens.
    var foldsCompleted: Bool { groups.contains { $0.status != .completed } }

    /// The groups that start open: what needs the owner and what is moving
    /// (owner, 2026-11-26: the opened project was too dense). Not started,
    /// unknown and done start folded; when none of the open kinds exists,
    /// the first group opens so the page never shows only headings.
    var openByDefault: Set<LAAWorkRequirementStatus> {
        let attention = Set(groups.map(\.status)).intersection([.awaitingDecision, .inProgress])
        if !attention.isEmpty { return attention }
        return groups.first.map { [$0.status] } ?? []
    }
}

/// One line of a requirement's name: the stored title up to its first line
/// break or sentence end, so a long title never wraps the list into
/// paragraphs. The full title is on the requirement's own page.
enum LAAWorkRequirementName {
    static func short(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        if let end = firstLine.firstIndex(where: { "。！？".contains($0) }), end != firstLine.startIndex {
            let head = String(firstLine[..<end])
            if head.count >= 4 { return head }
        }
        return firstLine
    }
}

/// Whether the project has anything at work now, for the list row's mark.
enum LAAWorkProjectActivity: Equatable {
    case idle
    case running(Int)
    case decision(Int)

    static func of(_ projectID: String, sessions: [LAAWorkSession]) -> Self {
        let mine = sessions.filter { !$0.isArchived && LAAWorkSessionOrder.projectID($0, in: sessions) == projectID }
        let waiting = mine.filter(\.needsDecision).count
        if waiting > 0 { return .decision(waiting) }
        let running = mine.filter { ["running", "created"].contains($0.phase) }.count
        return running > 0 ? .running(running) : .idle
    }

    static func of(_ compact: [LAAWorkProjectSession]) -> Self {
        let open = compact.filter { !$0.isArchived }
        let waiting = open.filter { $0.status == "awaiting_decision" }.count
        if waiting > 0 { return .decision(waiting) }
        let running = open.filter { $0.status == "running" }.count
        return running > 0 ? .running(running) : .idle
    }
}

/// What the detail keeps on the device, so a reopened project shows its last
/// reading while the Mac is out of reach. Never used to authorize a change:
/// every write needs the version a fresh read returned.
struct LAAWorkProjectSnapshot: Codable, Equatable {
    let progressNote: String?
    let requirements: [LAAWorkRequirement]?
    let sessions: [LAAWorkProjectSession]?
    /// Absent from a reading kept by an earlier build; decoded as nil.
    let sessionCounts: LAAWorkSessionCounts?
    let savedAt: Date

    init(_ project: LAAWorkProject, at date: Date = Date()) {
        progressNote = project.progressNote; requirements = project.requirements
        sessions = project.sessions; sessionCounts = project.sessionCounts; savedAt = date
    }
}

/// The owner's few requirement operations. Each is a versioned write on the
/// project (If-Match) with its own idempotency key, answered with the detail.
enum LAAWorkRequirementAPI {
    struct Addition: Encodable, Equatable {
        let title: String
        let details: String?
        let source = "owner"
        enum CodingKeys: String, CodingKey { case title, details, source }
    }
    struct StatusChange: Encodable { let status: String }

    static func path(_ projectID: String, _ requirementID: String? = nil) -> String {
        "/v1/projects/\(projectID)/requirements" + (requirementID.map { "/\($0)" } ?? "")
    }

    @MainActor static func add(_ addition: Addition, to project: LAAWorkProject, key: LAABridgeIdempotencyKey,
                               bridge: LAABridgeSession) async throws -> LAAWorkProject {
        guard let etag = project.etag else { throw LAABridgeError.invalidResponse }
        return try await LAAWorkHTTP.write(bridge, path: path(project.id), body: JSONEncoder().encode(addition),
                                           key: key, method: "POST", etag: etag)
    }

    @MainActor static func setStatus(_ status: LAAWorkRequirementStatus, of requirement: LAAWorkRequirement,
                                     in project: LAAWorkProject, bridge: LAABridgeSession) async throws -> LAAWorkProject {
        guard let etag = project.etag, status != .unknown else { throw LAABridgeError.invalidResponse }
        return try await LAAWorkHTTP.write(bridge, path: path(project.id, requirement.id),
                                           body: JSONEncoder().encode(StatusChange(status: status.rawValue)),
                                           key: LAABridgeIdempotencyKey(), method: "PATCH", etag: etag)
    }

    @MainActor static func withdraw(_ requirement: LAAWorkRequirement, in project: LAAWorkProject,
                                    bridge: LAABridgeSession) async throws -> LAAWorkProject {
        guard let etag = project.etag else { throw LAABridgeError.invalidResponse }
        return try await LAAWorkHTTP.write(bridge, path: path(project.id, requirement.id), body: Data("{}".utf8),
                                           key: LAABridgeIdempotencyKey(), method: "DELETE", etag: etag)
    }

    static func message(_ error: Error) -> String {
        if let failure = error as? LAABridgeHTTPError {
            if LAAWorkHTTP.isVersionConflict(failure) { return LAACopy.WorkProject.conflict }
            switch failure.code {
            case "requirement_limit": return LAACopy.WorkProject.limitReached
            case "project_archived": return LAACopy.WorkProject.archivedProject
            default: break
            }
            if failure.status == 404 || failure.status == 405 { return LAACopy.WorkProject.bridgeTooOld }
            return LAAWorkHTTP.message(failure)
        }
        if let failure = error as? LAABridgeError { return failure.japaneseText }
        return LAACopy.WorkProject.saveFailed
    }
}
#endif
