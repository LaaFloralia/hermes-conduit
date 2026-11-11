#if LAA_BUILD
import Foundation

// These are presentation models. Wire decoding and request encoding belong to the
// Bridge adapter, whose contract is maintained separately.
enum LAAOwnerTaskStatus: String, CaseIterable, Identifiable, Codable {
    case todo
    case doing
    case done
    case canceled

    var id: String { rawValue }

    var label: String {
        switch self {
        case .todo: return AppLocalization.string("To Do")
        case .doing: return AppLocalization.string("In progress")
        case .done: return AppLocalization.string("Done")
        case .canceled: return AppLocalization.string("Cancelled")
        }
    }

    var isOpen: Bool { self == .todo || self == .doing }
}

/// A calendar day, with no time or timezone. Invalid or noncanonical days are
/// rejected instead of being silently normalized by a date formatter.
struct LAAOwnerTaskDay: Equatable, Comparable, Codable {
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

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let day = Self(value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid task day")
        }
        self = day
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

enum LAAOwnerTaskSource: String, Codable {
    case owner
    case agent
    case linearImport = "linear_import"

    var label: String {
        switch self {
        case .owner: return AppLocalization.string("You")
        case .agent: return AppLocalization.string("Agent")
        case .linearImport: return AppLocalization.string("Imported from Linear")
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

/// Revisions are opaque ETags, not sequence numbers. Decode the former
/// integer representation as well so existing protected drafts still open.
struct LAAOwnerTaskRevision: Codable, Equatable, ExpressibleByStringLiteral {
    let value: String

    init(stringLiteral value: String) { self.value = value }

    var isValid: Bool {
        !value.isEmpty && value.utf8.allSatisfy { $0 == 0x21 || (0x23...0x7e).contains($0) }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let legacy = try? container.decode(Int.self), legacy > 0 {
            value = String(legacy)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid task revision")
        }
        guard isValid else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid task revision")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

struct LAAOwnerTask: Identifiable, Equatable, Codable {
    let id: UUID
    let title: String
    let memo: String
    let status: LAAOwnerTaskStatus
    let dueDate: LAAOwnerTaskDay?
    let source: LAAOwnerTaskSource
    let links: [String]
    let updatedAt: Date
    let revision: LAAOwnerTaskRevision
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

struct LAAOwnerTaskDraft: Equatable, Codable {
    enum ValidationError: Error, Equatable {
        case missingTitle
        case invalidTitle
        case invalidMemo
        case invalidDueDate
        case emptyLink
        case invalidLink
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
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw ValidationError.missingTitle
        }
        if base == nil || title != base?.title {
            guard trimmedTitle.utf16.count <= 500,
                  !trimmedTitle.unicodeScalars.contains(where: { $0.value <= 31 || $0.value == 127 }) else {
                throw ValidationError.invalidTitle
            }
        }
        if base == nil || memo != base?.memo {
            guard memo.utf16.count <= 20_000, !memo.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw ValidationError.invalidMemo
            }
        }
        guard dueDateText.isEmpty || LAAOwnerTaskDay(dueDateText) != nil else {
            throw ValidationError.invalidDueDate
        }
        if base == nil || links != base?.links {
            guard links.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw ValidationError.emptyLink
            }
            guard links.count <= 20, links.allSatisfy({ link in
                guard link.utf16.count <= 2048,
                      !link.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }),
                      let parts = URLComponents(string: link),
                      let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
                      let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return false }
                return true
            }) else { throw ValidationError.invalidLink }
        }
    }
}

struct LAAOwnerTaskConflict {
    enum Field: String, CaseIterable, Identifiable {
        case title, memo, status, dueDate, links
        var id: String { rawValue }
        var label: String {
            switch self {
            case .title: return AppLocalization.string("Title")
            case .memo: return AppLocalization.string("Note")
            case .status: return AppLocalization.string("Status")
            case .dueDate: return AppLocalization.string("Due date")
            case .links: return AppLocalization.string("Links")
            }
        }
    }

    let draft: LAAOwnerTaskDraft
    let current: LAAOwnerTask
    private let base: LAAOwnerTask

    init?(draft: LAAOwnerTaskDraft, current: LAAOwnerTask) {
        guard let base = draft.base, base.id == draft.id, current.id == draft.id else { return nil }
        self.draft = draft
        self.current = current
        self.base = base
    }

    var changedFields: [Field] {
        Field.allCases.filter { field in
            switch field {
            case .title: return draft.title != base.title
            case .memo: return draft.memo != base.memo
            case .status: return draft.status != base.status
            case .dueDate: return draft.dueDateText != (base.dueDate?.value ?? "")
            case .links: return draft.links != base.links
            }
        }
    }

    func currentValue(for field: Field) -> String {
        switch field {
        case .title: return current.title
        case .memo: return current.memo
        case .status: return current.status.label
        case .dueDate: return LAADateText.dueDay(current.dueDate?.value)?.label ?? ""
        case .links: return current.links.joined(separator: "\n")
        }
    }

    func draftValue(for field: Field) -> String {
        switch field {
        case .title: return draft.title
        case .memo: return draft.memo
        case .status: return draft.status.label
        case .dueDate: return LAADateText.dueDay(draft.dueDateText)?.label ?? draft.dueDateText
        case .links: return draft.links.joined(separator: "\n")
        }
    }

    /// Preserve remote changes to untouched fields. The caller still needs a
    /// new conditional request and an explicit decision before saving.
    func rebasedDraft() -> LAAOwnerTaskDraft {
        var result = LAAOwnerTaskDraft(task: current)
        for field in changedFields {
            switch field {
            case .title: result.title = draft.title
            case .memo: result.memo = draft.memo
            case .status: result.status = draft.status
            case .dueDate: result.dueDateText = draft.dueDateText
            case .links: result.links = draft.links
            }
        }
        return result
    }
}

/// Versioned local editor state; this is not a Bridge request format.
enum LAAOwnerTaskDraftArchive {
    private struct Record: Codable {
        let version: Int
        let draft: LAAOwnerTaskDraft
    }

    enum ArchiveError: Error {
        case unsupportedVersion
        case inconsistentIdentity
        case invalidText
    }

    static func encode(_ draft: LAAOwnerTaskDraft) throws -> String {
        let data = try JSONEncoder().encode(Record(version: 1, draft: draft))
        guard let text = String(data: data, encoding: .utf8) else { throw ArchiveError.invalidText }
        return text
    }

    static func decode(_ text: String) throws -> LAAOwnerTaskDraft {
        guard let data = text.data(using: .utf8) else { throw ArchiveError.invalidText }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.version == 1 else { throw ArchiveError.unsupportedVersion }
        if let base = record.draft.base, base.id != record.draft.id { throw ArchiveError.inconsistentIdentity }
        return record.draft
    }
}
#endif
