#if LAA_BUILD
import Foundation

// These models describe the personal Linear endpoint.
struct LAAPersonalTask: Codable, Identifiable, Hashable {
    struct Person: Codable, Hashable { let id: String?; let name: String?; let kind: String? }
    struct State: Codable, Hashable { let id: String?; let name: String?; let type: String? }
    struct Named: Codable, Identifiable, Hashable {
        let id: String
        let name: String?
        let key: String?
        let number: Int?
        let identifier: String?
        let title: String?
    }
    struct Label: Codable, Identifiable, Hashable { let id: String; let name: String; let color: String? }
    let id: String
    let sourceId: String
    let linearId: String?
    let title: String
    let description: String?
    let owner: Person?
    let executor: Person?
    let status: State?
    let team: Named?
    let project: Named?
    let milestone: Named?
    let cycle: Named?
    let parent: Named?
    let priority: Int?
    let estimate: Double?
    let dueDate: String?
    let labels: [Label]?
    let labelsComplete: Bool?
    let url: String?
    let updatedAt: String?
}

struct LAAPersonalTaskResponse: Decodable { let task: LAAPersonalTask; let viewerId: String }
struct LAAPersonalPage<Item: Decodable>: Decodable {
    let items: [Item]
    var inboxMode: String? = nil
    let nextCursor: String?
    let observedAt: String?
    let viewerId: String
}
struct LAAPersonalNotification: Decodable, Identifiable {
    struct Actor: Decodable { let id: String; let name: String? }
    struct Issue: Decodable { let id: String; let identifier: String; let title: String }
    let id: String
    let type: String
    let title: String?
    let subtitle: String?
    let createdAt: String
    let updatedAt: String
    let readAt: String?
    let archivedAt: String?
    let snoozedUntilAt: String?
    let actor: Actor?
    let issue: Issue?
    var isUnread: Bool { readAt == nil }
    var isArchived: Bool { archivedAt != nil }

    private enum CodingKeys: String, CodingKey {
        case id, type, title, subtitle, createdAt, updatedAt, readAt, archivedAt, snoozedUntilAt, actor, issue
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        type = try values.decode(String.self, forKey: .type)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        subtitle = try values.decodeIfPresent(String.self, forKey: .subtitle)
        createdAt = try values.decode(String.self, forKey: .createdAt)
        updatedAt = try values.decode(String.self, forKey: .updatedAt)
        // Missing status is not the same as an explicit Linear null.
        guard values.contains(.readAt), values.contains(.archivedAt) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Missing notification state"))
        }
        readAt = try values.decodeIfPresent(String.self, forKey: .readAt)
        archivedAt = try values.decodeIfPresent(String.self, forKey: .archivedAt)
        snoozedUntilAt = try values.decodeIfPresent(String.self, forKey: .snoozedUntilAt)
        actor = try values.decodeIfPresent(Actor.self, forKey: .actor)
        issue = try values.decodeIfPresent(Issue.self, forKey: .issue)
    }
}
struct LAAPersonalNotificationResponse: Decodable {
    let notification: LAAPersonalNotification
    let viewerId: String
    let observedAt: String?
}

/// Cursor pages are live. Never infer a zero unread count from a partial page.
struct LAAPersonalInboxSnapshot {
    enum Failure: Error { case viewerChanged, repeatedCursor }
    let viewerId: String
    private(set) var items: [LAAPersonalNotification] = []
    private(set) var nextCursor: String?
    private(set) var observedAt: String?
    private var seenCursors = Set<String>()

    mutating func merge(_ page: LAAPersonalPage<LAAPersonalNotification>, reset: Bool) throws {
        guard page.viewerId == viewerId else { throw Failure.viewerChanged }
        var cursors = reset ? Set<String>() : seenCursors
        if let cursor = page.nextCursor, !cursors.insert(cursor).inserted { throw Failure.repeatedCursor }
        var current = reset ? [] : items
        var ids = Set(current.map(\.id))
        current.append(contentsOf: page.items.filter { ids.insert($0.id).inserted })
        items = current; nextCursor = page.nextCursor; observedAt = page.observedAt; seenCursors = cursors
    }
    var summary: String {
        if items.contains(where: { $0.isUnread && !$0.isArchived }) { return "未読あり" }
        return nextCursor == nil ? "取得分に未読なし" : "一部取得・未読未確認"
    }
}
struct LAAPersonalChoice: Codable, Identifiable, Hashable {
    struct Reference: Codable, Hashable { let id: String }
    let id: String
    let name: String?
    let key: String?
    let number: Int?
    let team: Reference?
    let project: Reference?
    let active: Bool?
    let modelName: String?
    var displayName: String { name ?? key ?? number.map(String.init) ?? id }
}
struct LAAPersonalChoices: Decodable { let items: [LAAPersonalChoice]; let complete: Bool }
struct LAAPersonalMetadata: Decodable {
    struct Viewer: Decodable { let id: String; let name: String? }
    struct Priority: Decodable, Identifiable { let priority: Int; let label: String; var id: Int { priority } }
    let viewer: Viewer
    let ownerUserId: String?
    let agentAccount: Bool?
    let teams: LAAPersonalChoices
    let users: LAAPersonalChoices
    let workflowStates: LAAPersonalChoices
    let issueLabels: LAAPersonalChoices
    let projects: LAAPersonalChoices
    let projectMilestones: LAAPersonalChoices
    let cycles: LAAPersonalChoices
    let priorities: [Priority]
}
struct LAAPersonalOperationResponse: Decodable {
    struct Operation: Decodable, Identifiable {
        let operationId: String
        let kind: String
        let targetId: String
        let contextId: String?
        let status: String
        let createdAt: String?
        let resultId: String?
        let identifier: String?
        let resolution: String?
        let rejection: String?
        let replayExpired: Bool?
        var id: String { operationId }
    }
    let operation: Operation
}
struct LAAPersonalOperationList: Decodable { let items: [LAAPersonalOperationResponse.Operation]; let viewerId: String }

/// An immutable, protected follow-up to a create whose result is not yet
/// known. A request can only be built after the same viewer has read back the
/// exact issue recorded by the parent operation.
struct LAAPersonalDependency: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case comment, subtask, relation, link
        var caption: String {
            switch self {
            case .comment: return "Comment"
            case .subtask: return "Subtask"
            case .relation: return "Relation"
            case .link: return "Link"
            }
        }
    }
    struct Request { let path: String; let body: Data }
    let viewerId: String
    let deviceId: String
    let parentKey: String
    let childKey: String
    let teamId: String
    var kind: Kind = .comment
    var first = ""
    var second = ""
    var relationType = "related"

    private static func validID(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,200}$"#, options: .regularExpression) != nil
    }
    var valid: Bool {
        guard Self.validID(viewerId), Self.validID(deviceId), Self.validID(parentKey), Self.validID(childKey),
              parentKey != childKey, !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch kind {
        case .comment: return first.utf8.count <= 48 * 1024
        case .subtask: return first.utf16.count <= 512 && Self.validID(teamId)
        case .relation: return Self.validID(first.trimmingCharacters(in: .whitespacesAndNewlines)) &&
            ["blocks", "duplicate", "related", "similar"].contains(relationType)
        case .link:
            guard first.utf16.count <= 512, second.utf16.count <= 2048,
                  let url = URL(string: second.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
            return url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
        }
    }

    func parentTarget(_ operation: LAAPersonalOperationResponse.Operation, device: String, viewer: String) -> String? {
        guard valid, device == deviceId, viewer == viewerId, operation.kind == "create",
              let target = UUID(uuidString: operation.targetId) else { return nil }
        if operation.status == "succeeded" {
            guard let result = operation.resultId.flatMap(UUID.init(uuidString:)), result == target else { return nil }
        } else if operation.status != "resolved" || operation.resolution != "applied" { return nil }
        return operation.targetId
    }

    func request(parent: LAAPersonalOperationResponse.Operation, verified: LAAPersonalTaskResponse,
                 device: String, viewer: String) -> Request? {
        guard let target = parentTarget(parent, device: device, viewer: viewer),
              verified.viewerId == viewerId, let readID = verified.task.linearId.flatMap(UUID.init(uuidString:)),
              readID == UUID(uuidString: target) else { return nil }
        var payload = ["expectedViewerId": viewerId]
        let path: String
        switch kind {
        case .comment:
            path = "/v1/personal-tasks/\(target)/comments"; payload["body"] = first
        case .subtask:
            path = "/v1/personal-tasks"; payload["title"] = first; payload["teamId"] = teamId; payload["parentId"] = target
        case .relation:
            path = "/v1/personal-tasks/\(target)/relations"
            payload["relatedIssueId"] = first.trimmingCharacters(in: .whitespacesAndNewlines); payload["type"] = relationType
        case .link:
            path = "/v1/personal-tasks/\(target)/attachments"
            payload["title"] = first; payload["url"] = second.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return nil }
        return Request(path: path, body: body)
    }
}

/// The base and viewer travel with the protected draft, so a restored edit
/// neither changes unrelated fields nor crosses to a different Linear user.
struct LAAPersonalTaskDraft: Codable, Equatable {
    let viewerId: String
    var base: LAAPersonalTask?
    var title: String
    var description: String
    var teamId: String
    var stateId: String
    var assigneeId: String
    var priority: Int
    var projectId: String
    var milestoneId: String
    var cycleId: String
    var parentId: String?
    var estimate: String
    var dueDate: String
    var labelIds: [String]

    init(viewerId: String, task: LAAPersonalTask?) {
        self.viewerId = viewerId
        base = task
        title = task?.title ?? ""
        description = task?.description ?? ""
        teamId = task?.team?.id ?? ""
        stateId = task?.status?.id ?? ""
        assigneeId = task?.owner?.id ?? ""
        priority = task?.priority ?? 0
        projectId = task?.project?.id ?? ""
        milestoneId = task?.milestone?.id ?? ""
        cycleId = task?.cycle?.id ?? ""
        parentId = task?.parent?.id
        estimate = task?.estimate.map { value in
            value.isFinite && value.rounded() == value && (0...10000).contains(value) ? String(Int(value)) : String(value)
        } ?? ""
        dueDate = task?.dueDate ?? ""
        labelIds = task?.labels?.map(\.id).sorted() ?? []
    }

    var descriptionChanged: Bool { base == nil || description != (base?.description ?? "") }

    /// Preserve only fields edited against the old base when rebasing after a
    /// conflict; otherwise unrelated remote changes would be overwritten.
    mutating func rebase(on remote: LAAPersonalTask) {
        let old = LAAPersonalTaskDraft(viewerId: viewerId, task: base)
        let fresh = LAAPersonalTaskDraft(viewerId: viewerId, task: remote)
        if title == old.title { title = fresh.title }
        if description == old.description { description = fresh.description }
        if teamId == old.teamId { teamId = fresh.teamId }
        if stateId == old.stateId { stateId = fresh.stateId }
        if assigneeId == old.assigneeId { assigneeId = fresh.assigneeId }
        if priority == old.priority { priority = fresh.priority }
        if projectId == old.projectId { projectId = fresh.projectId }
        if milestoneId == old.milestoneId { milestoneId = fresh.milestoneId }
        if cycleId == old.cycleId { cycleId = fresh.cycleId }
        if parentId == old.parentId { parentId = fresh.parentId }
        if estimate == old.estimate { estimate = fresh.estimate }
        if dueDate == old.dueDate { dueDate = fresh.dueDate }
        if labelIds.sorted() == old.labelIds.sorted() { labelIds = fresh.labelIds }
        base = remote
    }

    enum Validation: Error { case missingTitle, missingTeam, invalidEstimate, missingVersion, incompleteLabels, noChanges }
    func requestBody() throws -> Data {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Validation.missingTitle }
        guard !teamId.isEmpty else { throw Validation.missingTeam }
        let old = LAAPersonalTaskDraft(viewerId: viewerId, task: base)
        let creating = base == nil
        var changes: [String: Any] = ["expectedViewerId": viewerId]
        if creating || title != old.title { changes["title"] = title }
        if descriptionChanged {
            if !creating && base?.updatedAt == nil { throw Validation.missingVersion }
            changes["description"] = description
        }
        if creating || teamId != old.teamId { changes["teamId"] = teamId }
        if !stateId.isEmpty && stateId != old.stateId { changes["stateId"] = stateId }
        func nullable(_ key: String, _ value: String, _ previous: String) {
            if value != previous { changes[key] = value.isEmpty ? NSNull() : value as Any }
        }
        nullable("assigneeId", assigneeId, old.assigneeId)
        nullable("projectId", projectId, old.projectId)
        nullable("projectMilestoneId", milestoneId, old.milestoneId)
        nullable("cycleId", cycleId, old.cycleId)
        if parentId != old.parentId { changes["parentId"] = parentId as Any? ?? NSNull() }
        if priority != old.priority { changes["priority"] = priority }
        if estimate != old.estimate {
            if estimate.isEmpty { changes["estimate"] = NSNull() }
            else if let number = Double(estimate), number.isFinite, (0...10000).contains(number), number.rounded() == number {
                changes["estimate"] = Int(number)
            }
            else { throw Validation.invalidEstimate }
        }
        nullable("dueDate", dueDate, old.dueDate)
        if labelIds.sorted() != old.labelIds.sorted() {
            if !creating && base?.labelsComplete != true { throw Validation.incompleteLabels }
            changes["labelIds"] = labelIds.sorted()
        }
        guard changes.count > 1 else { throw Validation.noChanges }
        return try JSONSerialization.data(withJSONObject: changes, options: [.sortedKeys])
    }
}

enum LAAPersonalTaskDiff {
    static func changes(current: String, mine: String) -> [String] {
        let before = current.components(separatedBy: "\n")
        let after = mine.components(separatedBy: "\n")
        // Keep a long, completely changed description from blocking the UI
        // during a potentially quadratic edit-distance calculation.
        if before.count > 200 || after.count > 200 {
            var result = ["差分が長いため先頭の変更を行番号順に表示します。全文も下に表示します。"]
            for index in 0..<max(before.count, after.count) {
                let left = index < before.count ? before[index] : nil
                let right = index < after.count ? after[index] : nil
                if left == right { continue }
                if let left { result.append("− \(index + 1): \(left)") }
                if let right { result.append("+ \(index + 1): \(right)") }
                if result.count >= 201 { result.append("…残りは全文を確認してください。 "); break }
            }
            return result
        }
        let changes = after.difference(from: before)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [String] = []; var old = 0; var new = 0
        while old < before.count || new < after.count {
            if old < before.count && removed.contains(old) { result.append("− \(old + 1): \(before[old])"); old += 1 }
            else if new < after.count && inserted.contains(new) { result.append("+ \(new + 1): \(after[new])"); new += 1 }
            else { old += 1; new += 1 }
        }
        return result
    }
}

enum LAAPersonalReconciliation {
    enum Disposition: Equatable { case complete, restore, compare, unsent, wait, invalid }
    static func taskLookup(_ operation: LAAPersonalOperationResponse.Operation) -> String? {
        guard ["create", "update"].contains(operation.kind) else { return nil }
        let id = operation.kind == "create" ? operation.targetId : (operation.resultId ?? operation.targetId)
        guard id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,200}$"#, options: .regularExpression) != nil else { return nil }
        return id
    }
    static func verifiedTaskID(_ response: LAAPersonalTaskResponse, operation: LAAPersonalOperationResponse.Operation,
                               viewer: String) -> String? {
        guard response.viewerId == viewer, let lookup = taskLookup(operation),
              !response.task.sourceId.isEmpty, response.task.id == "linear:\(response.task.sourceId)" else { return nil }
        if let expected = UUID(uuidString: lookup) {
            guard let actual = response.task.linearId.flatMap(UUID.init(uuidString:)), actual == expected else { return nil }
            if operation.kind == "create", let result = operation.resultId,
               UUID(uuidString: result) != expected { return nil }
        } else {
            guard operation.kind == "update",
                  lookup == response.task.id || lookup == response.task.sourceId else { return nil }
        }
        return response.task.id
    }
    static func disposition(_ operation: LAAPersonalOperationResponse.Operation, mayCompare: Bool) -> Disposition {
        switch operation.status {
        case "succeeded": return .complete
        case "preflight_retryable": return .unsent
        case "resolved":
            if operation.resolution == "applied" { return .complete }
            if operation.resolution == "not_applied" { return .restore }
            return .invalid
        case "rejected":
            return mayCompare && (operation.rejection == nil || operation.rejection == "version_mismatch") ? .compare : .restore
        default: return .wait
        }
    }
    static func isDefiniteRefusal(code: String?, status: Int? = nil) -> Bool {
        guard let code else { return false }
        if code == "linear_request_failed" && status == 403 { return true }
        return ["payload_invalid", "expected_viewer_required", "if_match_required", "linear_viewer_changed",
                "insufficient_scope", "task_id_invalid", "task_not_found", "notification_not_found", "linear_rejected",
                "linear_viewer_mismatch", "linear_personal_credential_invalid", "linear_personal_not_configured"].contains(code)
    }
}

enum LAAPersonalTaskSwipe {
    static func action(width: CGFloat, height: CGFloat) -> Bool? {
        guard abs(width) > abs(height) * 3, abs(width) > 25 else { return nil }
        return width < 0
    }
}
#endif
