#if LAA_BUILD
import Foundation

// These models intentionally describe the personal endpoint, leaving the older
// agent task model and its wire format unchanged.
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
    let nextCursor: String?
    let observedAt: String?
    let viewerId: String
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
    var displayName: String { name ?? key ?? number.map { "Cycle \($0)" } ?? id }
}
struct LAAPersonalChoices: Decodable { let items: [LAAPersonalChoice]; let complete: Bool }
struct LAAPersonalMetadata: Decodable {
    struct Viewer: Decodable { let id: String; let name: String? }
    struct Priority: Decodable, Identifiable { let priority: Int; let label: String; var id: Int { priority } }
    let viewer: Viewer
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
    struct Operation: Decodable {
        let operationId: String
        let kind: String
        let targetId: String
        let status: String
        let resultId: String?
        let identifier: String?
        let resolution: String?
        let rejection: String?
        let replayExpired: Bool?
    }
    let operation: Operation
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
        estimate = task?.estimate.map { String($0) } ?? ""
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
        if priority != old.priority { changes["priority"] = priority }
        if estimate != old.estimate {
            if estimate.isEmpty { changes["estimate"] = NSNull() }
            else if let number = Double(estimate), number.isFinite, (0...10000).contains(number) { changes["estimate"] = number }
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
        if before.count > 1_000 || after.count > 1_000 {
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
        return after.difference(from: before).map { change in
            switch change {
            case .remove(_, let line, _): return "− " + line
            case .insert(_, let line, _): return "+ " + line
            }
        }
    }
}
#endif
