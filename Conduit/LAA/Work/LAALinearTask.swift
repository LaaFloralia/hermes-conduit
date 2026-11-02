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

    var isOpen: Bool { status != "done" && status != "canceled" }
    func needsAttention(today: String) -> Bool {
        isOpen && (priority == 1 || priority == 2 || dueDate.map { $0 <= today } == true)
    }
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
    var path: String { "/v1/linear-owner-tasks" + (method == "POST" ? "" : "/\(id)") }
    var isValid: Bool { UUID(uuidString: id) != nil && ["POST", "PATCH", "DELETE"].contains(method) }
}
#endif
