#if LAA_BUILD
import Foundation

// These are presentation models. Wire decoding and request encoding belong to the
// Bridge adapter, whose contract is maintained separately.
enum LAAOwnerTaskStatus: String, CaseIterable, Identifiable {
    case todo
    case doing
    case done
    case canceled

    var id: String { rawValue }

    var label: String {
        switch self {
        case .todo: return "Todo"
        case .doing: return "In Progress"
        case .done: return "Done"
        case .canceled: return "Canceled"
        }
    }

    var isOpen: Bool { self == .todo || self == .doing }
}

/// A calendar day, with no time or timezone. Invalid or noncanonical days are
/// rejected instead of being silently normalized by a date formatter.
struct LAAOwnerTaskDay: Equatable, Comparable {
    let value: String

    init?(_ value: String) {
        let bytes = Array(value.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45 else { return nil }
        for index in [0, 1, 2, 3, 5, 6, 8, 9] where !(48...57).contains(bytes[index]) {
            return nil
        }
        func number(_ range: Range<Int>) -> Int {
            range.reduce(0) { $0 * 10 + Int(bytes[$1] - 48) }
        }
        let year = number(0..<4)
        let month = number(5..<7)
        let day = number(8..<10)
        guard year > 0, (1...12).contains(month) else { return nil }
        let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let daysInMonth = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...daysInMonth[month - 1]).contains(day) else { return nil }
        self.value = value
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
}

enum LAAOwnerTaskSource: String {
    case owner
    case agent
    case linearImport = "linear_import"

    var label: String {
        switch self {
        case .owner: return "本人"
        case .agent: return "エージェント"
        case .linearImport: return "Linear から取込み"
        }
    }
}

enum LAAOwnerTaskLink {
    static func openableURL(_ text: String) -> URL? {
        guard let components = URLComponents(string: text),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        return components.url
    }
}

struct LAAOwnerTask: Identifiable, Equatable {
    let id: UUID
    let title: String
    let memo: String
    let status: LAAOwnerTaskStatus
    let dueDate: LAAOwnerTaskDay?
    let source: LAAOwnerTaskSource
    let links: [String]
    let updatedAt: Date
    let revision: Int
}

struct LAAOwnerTaskGroups {
    let open: [LAAOwnerTask]
    let done: [LAAOwnerTask]
    let canceled: [LAAOwnerTask]

    init(tasks: [LAAOwnerTask]) {
        func newestFirst(_ lhs: LAAOwnerTask, _ rhs: LAAOwnerTask) -> Bool {
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        open = tasks.filter(\.status.isOpen).sorted { lhs, rhs in
            switch (lhs.dueDate, rhs.dueDate) {
            case let (left?, right?) where left != right: return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return newestFirst(lhs, rhs)
            }
        }
        done = tasks.filter { $0.status == .done }.sorted(by: newestFirst)
        canceled = tasks.filter { $0.status == .canceled }.sorted(by: newestFirst)
    }
}

struct LAAOwnerTaskDraft: Equatable {
    enum ValidationError: Error, Equatable {
        case missingTitle
        case invalidDueDate
        case emptyLink
    }

    // The identifier remains stable if the draft is queued and retried.
    let id: UUID
    let base: LAAOwnerTask?
    var title: String
    var memo: String
    var status: LAAOwnerTaskStatus
    var dueDateText: String
    var links: [String]

    init(task: LAAOwnerTask? = nil, id: UUID = UUID()) {
        self.id = task?.id ?? id
        self.base = task
        self.title = task?.title ?? ""
        self.memo = task?.memo ?? ""
        self.status = task?.status ?? .todo
        self.dueDateText = task?.dueDate?.value ?? ""
        self.links = task?.links ?? []
    }

    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.missingTitle
        }
        guard dueDateText.isEmpty || LAAOwnerTaskDay(dueDateText) != nil else {
            throw ValidationError.invalidDueDate
        }
        guard links.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ValidationError.emptyLink
        }
    }
}
#endif
