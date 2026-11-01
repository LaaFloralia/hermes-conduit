#if LAA_BUILD
import Foundation

/// A list item deliberately lacks memo and links. It must not be used as an
/// editing base: the detail endpoint is the source for those fields.
struct LAAOwnerTaskWire: Decodable {
    let id: UUID
    let title: String
    let memo: String?
    let status: LAAOwnerTaskStatus
    let dueDate: LAAOwnerTaskDay?
    let source: LAAOwnerTaskSource
    let links: [String]?
    let updatedAt: String
    let revision: Int

    func task(requiringDetail: Bool) throws -> LAAOwnerTask {
        if requiringDetail && (memo == nil || links == nil) { throw LAABridgeError.invalidResponse }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard revision > 0, let updated = fractional.date(from: updatedAt) ?? plain.date(from: updatedAt) else {
            throw LAABridgeError.invalidResponse
        }
        return LAAOwnerTask(id: id, title: title, memo: memo ?? "", status: status,
                            dueDate: dueDate, source: source, links: links ?? [],
                            updatedAt: updated, revision: revision)
    }
}

struct LAAOwnerTaskPage: Decodable {
    let items: [LAAOwnerTaskWire]
    let nextCursor: String?
    let total: Int
}

/// A partial or inconsistent listing is not an empty or complete task list.
struct LAAOwnerTaskPageAccumulator {
    private(set) var nextCursor: String?
    private var rows: [LAAOwnerTask] = []
    private var seenIDs = Set<UUID>()
    private var seenCursors = Set<String>()
    private var total: Int?

    mutating func append(_ page: LAAOwnerTaskPage) throws {
        guard page.total >= 0, total == nil || total == page.total else { throw LAABridgeError.invalidResponse }
        var ids = seenIDs
        let additions = try page.items.map { wire in
            let task = try wire.task(requiringDetail: false)
            guard ids.insert(task.id).inserted else { throw LAABridgeError.invalidResponse }
            return task
        }
        var cursors = seenCursors
        if let cursor = page.nextCursor {
            guard !cursor.isEmpty, cursors.insert(cursor).inserted, cursors.count < 100 else { throw LAABridgeError.invalidResponse }
        }
        rows.append(contentsOf: additions)
        seenIDs = ids; seenCursors = cursors; total = page.total; nextCursor = page.nextCursor
    }

    func complete() throws -> [LAAOwnerTask] {
        guard let total, nextCursor == nil, rows.count == total else { throw LAABridgeError.invalidResponse }
        return rows
    }
}

/// The immutable request is persisted before it is attempted. Replays use its
/// original bytes, key, device, target and revision, including after restart.
struct LAAOwnerTaskRequest: Codable, Equatable {
    var deviceID: String
    var originalDeviceID: String?
    let taskID: UUID
    let method: String
    let path: String
    let body: Data
    let key: String
    let ifMatch: String?
    let draft: LAAOwnerTaskDraft

    enum Error: Swift.Error { case invalid, unchanged, bodyTooLarge }

    static func create(_ draft: LAAOwnerTaskDraft, deviceID: String, key: String) throws -> Self {
        guard draft.base == nil, !deviceID.isEmpty, LAABridgeIdempotencyKey(restoring: key) != nil else { throw Error.invalid }
        try draft.validate()
        let object: [String: Any] = [
            "id": draft.id.uuidString.lowercased(), "title": draft.title, "memo": draft.memo,
            "status": draft.status.rawValue, "dueDate": draft.dueDateText.isEmpty ? NSNull() : draft.dueDateText as Any,
            "links": draft.links, "source": "owner"
        ]
        let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard body.count <= 64 * 1024 else { throw Error.bodyTooLarge }
        return Self(deviceID: deviceID, originalDeviceID: nil, taskID: draft.id, method: "POST", path: "/v1/owner-tasks", body: body,
                    key: key, ifMatch: nil, draft: draft)
    }

    static func update(_ draft: LAAOwnerTaskDraft, deviceID: String, key: String) throws -> Self {
        guard let base = draft.base, base.id == draft.id, base.revision > 0, !deviceID.isEmpty,
              LAABridgeIdempotencyKey(restoring: key) != nil else { throw Error.invalid }
        try draft.validate()
        var changes: [String: Any] = [:]
        if draft.title != base.title { changes["title"] = draft.title }
        if draft.memo != base.memo { changes["memo"] = draft.memo }
        if draft.status != base.status { changes["status"] = draft.status.rawValue }
        if draft.dueDateText != (base.dueDate?.value ?? "") {
            changes["dueDate"] = draft.dueDateText.isEmpty ? NSNull() : draft.dueDateText as Any
        }
        if draft.links != base.links { changes["links"] = draft.links }
        guard !changes.isEmpty else { throw Error.unchanged }
        let body = try JSONSerialization.data(withJSONObject: changes, options: [.sortedKeys])
        guard body.count <= 64 * 1024 else { throw Error.bodyTooLarge }
        return Self(deviceID: deviceID, originalDeviceID: nil, taskID: draft.id, method: "PATCH",
                    path: "/v1/owner-tasks/\(draft.id.uuidString.lowercased())",
                    body: body,
                    key: key, ifMatch: "\"\(base.revision)\"", draft: draft)
    }

    static func check(_ task: LAAOwnerTask, deviceID: String, key: String) throws -> Self {
        var draft = LAAOwnerTaskDraft(task: task)
        draft.status = task.status == .done ? .todo : .done
        return try update(draft, deviceID: deviceID, key: key)
    }
}
#endif
