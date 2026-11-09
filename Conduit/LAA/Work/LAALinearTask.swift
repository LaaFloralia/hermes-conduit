#if LAA_BUILD
import Foundation

struct LAALinearTask: Codable, Identifiable, Equatable {
    let id: String
    let identifier: String
    var title: String
    var description: String?
    var dueDate: String?
    var priority: Int
    var status: String
    var stateName: String
    var updatedAt: String
    var url: String?
    var archivedAt: String? = nil
    /// The short number the owner says ("T12"). Absent from an older Bridge.
    var ref: String? = nil
    /// The Bridge's execution record; absent from an older Bridge.
    var run: LAATaskRun? = nil

    var isArchived: Bool { archivedAt != nil }
    var isOpen: Bool { !isArchived && status != "done" && status != "canceled" }
    static func today(_ date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    static func priorityLabel(_ value: Int) -> String {
        switch value {
        case 1: "緊急"
        case 2: "高"
        case 3: "中"
        case 4: "低"
        default: "指定なし"
        }
    }
}

struct LAALinearTaskMutation: Codable {
    let method: String
    let id: String
    let body: Data?
    let version: String?
    var action: String? = nil
    var path: String {
        let base = "/v1/linear-owner-tasks"
        if let action { return "\(base)/\(id)/\(action)" }
        return base + (method == "POST" ? "" : "/\(id)")
    }
    var isRetired: Bool {
        if method == "DELETE" { return true }
        guard method == "PATCH", let body,
              let fields = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return fields.keys.contains("completed")
    }
    var isValid: Bool {
        guard UUID(uuidString: id) != nil else { return false }
        if let action {
            return method == "POST" && ["archive", "restore", "complete"].contains(action)
                && body == nil && version != nil
        }
        guard ["POST", "PATCH"].contains(method), let body,
              let fields = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        let allowed: Set<String> = method == "POST"
            ? ["id", "title", "description", "priority", "dueDate", "assignee", "profile"]
            : ["title", "description", "priority", "dueDate"]
        guard !fields.isEmpty, Set(fields.keys).isSubset(of: allowed) else { return false }
        // A create names its assignee; a staff task must carry a profile.
        return method == "POST" ? Self.assigneeIsValid(fields) : true
    }

    private static func assigneeIsValid(_ fields: [String: Any]) -> Bool {
        guard let raw = fields["assignee"] else { return fields["profile"] == nil }
        guard let assignee = raw as? [String: Any], let kind = assignee["kind"] as? String else { return false }
        switch kind {
        case "owner":
            return Set(assignee.keys) == ["kind"] && fields["profile"] == nil
        case "staff":
            guard Set(assignee.keys) == ["kind", "staff"],
                  let staff = assignee["staff"] as? String,
                  LAATaskStaff.assignable.contains(where: { $0.rawValue == staff }),
                  let profile = fields["profile"] as? String, !profile.isEmpty, profile.count <= 100 else { return false }
            return true
        default:
            return false
        }
    }

    func isReflected(in task: LAALinearTask) -> Bool {
        guard isValid, id.lowercased() == task.id.lowercased() else { return false }
        if let action {
            // A finished task leaves the open list; the readback sees Done,
            // canceled or archived, and a removed issue needs no retry.
            if action == "complete" { return !task.isOpen }
            return action == "archive" ? task.isArchived : !task.isArchived
        }
        guard isValid, !task.isArchived, let body,
              let fields = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        for (field, value) in fields {
            switch field {
            case "id": if (value as? String)?.lowercased() != task.id.lowercased() { return false }
            case "title": if value as? String != task.title { return false }
            case "description":
                guard value is NSNull || value is String else { return false }
                let desired: String = value is NSNull ? "" : (value as? String ?? "")
                let actual: String = task.description ?? ""
                if desired != actual { return false }
            case "priority": if value as? Int != task.priority { return false }
            case "dueDate": if (value is NSNull ? nil : value as? String) != task.dueDate { return false }
            case "assignee":
                guard let desired = value as? [String: Any], let kind = desired["kind"] as? String,
                      let run = task.run, let actual = run.assignee, actual.kind == kind else { return false }
                if kind == "staff", (desired["staff"] as? String) != actual.staff { return false }
            case "profile":
                guard let desired = value as? String, task.run?.profile == desired else { return false }
            default: return false
            }
        }
        return true
    }
}
#endif
