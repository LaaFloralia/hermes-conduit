import Foundation

private func entry(_ id: String, kind: String, target: String? = nil,
                   requiresKey: Bool? = false, details: Bool = true) throws -> LAADriveListingItem {
    var payload: [String: Any] = ["id": id, "name": id, "kind": kind,
                                  "mimeType": kind == "folder" ? "application/vnd.google-apps.folder" :
                                      kind == "shortcut" ? "application/vnd.google-apps.shortcut" : "image/png"]
    if kind == "shortcut" && details {
        var shortcut: [String: Any] = [:]
        if let target { shortcut["targetId"] = target }
        if let requiresKey { shortcut["requiresResourceKey"] = requiresKey }
        payload["shortcut"] = shortcut
    }
    return try JSONDecoder().decode(LAADriveListingItem.self, from: JSONSerialization.data(withJSONObject: payload))
}

private actor Gate {
    private var entered = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        waiting?.resume(); waiting = nil
        await withCheckedContinuation { release = $0 }
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { waiting = $0 } }
    }
    func unblock() { release?.resume(); release = nil }
}

@main private struct DriveShortcutFixture {
    @MainActor static func expectError(_ expected: LAADriveShortcutError,
                                       _ run: () async throws -> LAADriveListingItem) async {
        do { _ = try await run(); fatalError("expected \(expected)") }
        catch let error as LAADriveShortcutError { precondition(error == expected) }
        catch { fatalError("unexpected error \(error)") }
    }

    @MainActor static func main() async throws {
        let first = try entry("link01", kind: "shortcut", target: "link02")
        let second = try entry("link02", kind: "shortcut", target: "folder01")
        let folder = try entry("folder01", kind: "folder")
        let objects = [second.id: second, folder.id: folder]
        var requested: [String] = []
        let load: LAADriveShortcutResolver.MetadataLoader = { id in
            requested.append(id)
            guard let result = objects[id] else { throw LAADriveShortcutError.invalidTarget }
            return result
        }
        let resolved = try await LAADriveShortcutResolver.resolve(first, visitedFolderIDs: ["root01"], metadata: load)
        precondition(resolved.id == "folder01" && requested == ["link02", "folder01"])
        await expectError(.tooManyLinks) { try await LAADriveShortcutResolver.resolve(first, maxHops: 1, metadata: load) }
        await expectError(.cycle) { try await LAADriveShortcutResolver.resolve(first, visitedFolderIDs: ["link02"], metadata: load) }
        let loop = try entry("link02", kind: "shortcut", target: "link01")
        await expectError(.cycle) { try await LAADriveShortcutResolver.resolve(first, metadata: { _ in loop }) }
        await expectError(.invalidTarget) { try await LAADriveShortcutResolver.resolve(first, metadata: { _ in folder }) }
        let needsKey = try entry("link03", kind: "shortcut", target: "folder01", requiresKey: true)
        await expectError(.resourceKeyRequired) { try await LAADriveShortcutResolver.resolve(needsKey, metadata: load) }
        let unknown = try entry("link04", kind: "shortcut", target: "folder01", requiresKey: nil)
        await expectError(.permissionUnknown) { try await LAADriveShortcutResolver.resolve(unknown, metadata: load) }
        let malformed = try entry("link05", kind: "shortcut", target: "../outside")
        await expectError(.invalidTarget) { try await LAADriveShortcutResolver.resolve(malformed, metadata: load) }
        let missing = try entry("link06", kind: "shortcut", details: false)
        await expectError(.invalidTarget) { try await LAADriveShortcutResolver.resolve(missing, metadata: load) }

        let gate = Gate()
        let operation = Task {
            try await LAADriveShortcutResolver.resolve(first, metadata: { _ in
                await gate.wait()
                return second
            })
        }
        await gate.waitForEntry()
        operation.cancel()
        await gate.unblock()
        do { _ = try await operation.value; fatalError("expected cancellation") }
        catch is CancellationError { }
        print("Drive shortcut resolution fixture passed")
    }
}
