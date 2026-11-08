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
        if let action { return method == "POST" && ["archive", "restore"].contains(action) && body == nil && version != nil }
        guard ["POST", "PATCH"].contains(method), let body,
              let fields = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        let allowed: Set<String> = method == "POST" ? ["id", "title", "description", "priority", "dueDate"] : ["title", "description", "priority", "dueDate"]
        return !fields.isEmpty && Set(fields.keys).isSubset(of: allowed)
    }

    func isReflected(in task: LAALinearTask) -> Bool {
        guard isValid, id.lowercased() == task.id.lowercased() else { return false }
        if let action { return action == "archive" ? task.isArchived : !task.isArchived }
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
            default: return false
            }
        }
        return true
    }
}
#endif
