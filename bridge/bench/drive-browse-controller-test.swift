import Foundation

private func expect(_ value: Bool, _ message: String) {
    guard value else { fatalError(message) }
}

private func page(_ ids: [String], cursor: String? = nil, incomplete: Bool? = false) throws -> LAADriveListingPage {
    let items = ids.map { ["id": $0, "name": $0, "mimeType": "application/pdf", "kind": "file"] }
    var object: [String: Any] = ["items": items, "nextCursor": cursor as Any? ?? NSNull()]
    if let incomplete { object["incompleteSearch"] = incomplete }
    return try JSONDecoder().decode(LAADriveListingPage.self, from: JSONSerialization.data(withJSONObject: object))
}

private actor Gate {
    private var entered = false
    private var started: CheckedContinuation<Void, Never>?
    private var released: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true; started?.resume(); started = nil
        await withCheckedContinuation { released = $0 }
    }
    func wait() async { if !entered { await withCheckedContinuation { started = $0 } } }
    func release() { released?.resume(); released = nil }
}

private enum FixtureError: Error { case unavailable }

@main private struct BrowseControllerFixture {
    @MainActor
    static func main() async throws {
        let controller = LAADriveBrowseController()
        var queries: [LAADriveBrowseQuery] = []
        let original = LAADriveBrowseQuery(section: .starred, folderID: "fold_1", search: "a+b",
                                           cursor: "must-be-ignored", pageSize: 4)
        await controller.reload(original) { query in
            queries.append(query)
            return try page(["file_1", "file_1", "file_2"], cursor: "cursor_1", incomplete: nil)
        }
        expect(queries[0].section == .starred && queries[0].folderID == "fold_1" && queries[0].search == "a+b" &&
               queries[0].pageSize == 4 && queries[0].cursor == nil, "first page scope and cursor")
        expect(controller.items.map(\.id) == ["file_1", "file_2"] && controller.cursor == "cursor_1" &&
               controller.incompleteSearch == nil && !controller.loading, "first page deduplicated")
        await controller.loadMore { query in
            queries.append(query)
            throw FixtureError.unavailable
        }
        expect(controller.items.count == 2 && controller.cursor == "cursor_1" && controller.error != nil,
               "page failure keeps loaded items and allows retry")
        await controller.loadMore { query in
            queries.append(query)
            return try page(["file_2", "file_3"], cursor: "cursor_2", incomplete: false)
        }
        expect(queries.last?.cursor == "cursor_1" && queries.last?.section == .starred && queries.last?.folderID == "fold_1" &&
               queries.last?.search == "a+b" && queries.last?.pageSize == 4, "page cursor stays bound to scope")
        expect(controller.items.map(\.id) == ["file_1", "file_2", "file_3"] && controller.cursor == "cursor_2" &&
               controller.incompleteSearch == nil && controller.error == nil, "subsequent page and unknown completeness")
        await controller.loadMore { _ in try page(["file_4"], cursor: "cursor_1", incomplete: true) }
        expect(controller.items.map(\.id) == ["file_1", "file_2", "file_3", "file_4"] && controller.cursor == nil &&
               controller.incompleteSearch == true && (controller.error as? LAADriveBrowseError) == .invalidPage,
               "repeated cursor stops pagination and reports incomplete search")

        let gate = Gate()
        let old = Task {
            await controller.reload(LAADriveBrowseQuery(section: .my)) { _ in
                await gate.hold()
                return try page(["old_1"])
            }
        }
        await gate.wait()
        await controller.reload(LAADriveBrowseQuery(section: .shared)) { _ in try page(["new_1"]) }
        await gate.release()
        await old.value
        expect(controller.items.map(\.id) == ["new_1"] && !controller.loading, "late result cannot overwrite new scope")

        let revokedGate = Gate()
        let revoked = Task {
            await controller.reload(LAADriveBrowseQuery(section: .recent)) { _ in
                await revokedGate.hold()
                return try page(["old_2"])
            }
        }
        await revokedGate.wait()
        controller.invalidate()
        await revokedGate.release()
        await revoked.value
        expect(controller.items.isEmpty && !controller.loading && controller.cursor == nil,
               "pairing invalidation rejects delayed results")

        let cancellationGate = Gate()
        let cancelled = Task {
            await controller.reload(LAADriveBrowseQuery(section: .my)) { _ in
                await cancellationGate.hold()
                return try page(["old_3"])
            }
        }
        await cancellationGate.wait()
        cancelled.cancel()
        await cancellationGate.release()
        await cancelled.value
        expect(controller.items.isEmpty && !controller.loading && controller.error == nil, "cancelled load is not an error")
        var called = false
        await controller.reload(LAADriveBrowseQuery(section: .my, search: String(repeating: "x", count: 201))) { _ in
            called = true
            return try page([])
        }
        expect(!called && (controller.error as? LAADriveBrowseError) == .invalidQuery, "invalid query never reaches Bridge")
        await controller.reload(LAADriveBrowseQuery(section: .my)) { _ in try page([], cursor: "") }
        expect(controller.cursor == nil && (controller.error as? LAADriveBrowseError) == .invalidPage, "empty cursor rejected")
        print("Drive browse controller fixture passed")
    }
}
