import Foundation

private actor Gate {
    private var entered = false
    private var started: CheckedContinuation<Void, Never>?
    private var released: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        started?.resume(); started = nil
        await withCheckedContinuation { released = $0 }
    }
    func waitForEntry() async { if !entered { await withCheckedContinuation { started = $0 } } }
    func unblock() { released?.resume(); released = nil }
}

@main private struct DriveShareFixture {
    static func main() async throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let root = fixture.appendingPathComponent("shares", isDirectory: true)
        let source = fixture.appendingPathComponent("original")
        let bytes = Data("%PDF-1.7\nsynthetic\n%%EOF\n".utf8)
        try bytes.write(to: source)
        let store = LAADriveShareFiles(root: root, capacity: { _ in 10_000_000 })

        let file = try await store.prepare(file: source, name: "../../Folder/report\u{0000}", mimeType: "application/pdf")
        precondition(file.url.lastPathComponent == "report.pdf" && file.url.deletingLastPathComponent().deletingLastPathComponent() == root)
        let copiedBytes = try Data(contentsOf: file.url)
        let sourceBytes = try Data(contentsOf: source)
        precondition(copiedBytes == bytes && sourceBytes == bytes)
        try await store.discardAbandoned(now: Date().addingTimeInterval(172_800))
        precondition(FileManager.default.fileExists(atPath: file.url.path), "an active sheet retains its file")
        try await store.release(file.id)
        try await store.release(file.id)
        precondition(!FileManager.default.fileExists(atPath: file.url.path) && FileManager.default.fileExists(atPath: source.path))

        let dataCopy = try await store.prepare(data: bytes, name: "notes", mimeType: "application/pdf")
        let dataCopyBytes = try Data(contentsOf: dataCopy.url)
        precondition(dataCopy.url.pathExtension == "pdf" && dataCopyBytes == bytes)
        let sentinel = dataCopy.url.appendingPathComponent("unrelated")
        try FileManager.default.removeItem(at: dataCopy.url)
        try FileManager.default.createDirectory(at: dataCopy.url, withIntermediateDirectories: false)
        try Data([7]).write(to: sentinel)
        do { try await store.release(dataCopy.id); fatalError("expected invalid source") }
        catch LAADriveShareError.invalidSource { }
        precondition(FileManager.default.fileExists(atPath: sentinel.path), "unexpected directory must not be deleted")
        try FileManager.default.removeItem(at: dataCopy.url)
        try bytes.write(to: dataCopy.url)
        try await store.release(dataCopy.id)

        let noSpace = LAADriveShareFiles(root: fixture.appendingPathComponent("low-space"), capacity: { _ in 0 })
        do { _ = try await noSpace.prepare(data: bytes, name: "notes", mimeType: "application/pdf"); fatalError("expected capacity error") }
        catch LAADriveShareError.insufficientSpace { }
        let link = fixture.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        do { _ = try await store.prepare(file: link, name: "notes", mimeType: "application/pdf"); fatalError("expected invalid source") }
        catch LAADriveShareError.invalidSource { }

        let gate = Gate()
        let cancelled = Task {
            await gate.wait()
            return try await store.prepare(data: bytes, name: "cancelled", mimeType: "application/pdf")
        }
        await gate.waitForEntry()
        cancelled.cancel()
        await gate.unblock()
        do { _ = try await cancelled.value; fatalError("expected cancellation") } catch is CancellationError { }

        var oldProcess: LAADriveShareFiles? = LAADriveShareFiles(root: root, capacity: { _ in 10_000_000 })
        let abandoned = try await oldProcess!.prepare(data: bytes, name: "old", mimeType: "application/pdf")
        oldProcess = nil
        let oldDirectory = abandoned.url.deletingLastPathComponent()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-172_800)], ofItemAtPath: oldDirectory.path)
        let unexpected = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: unexpected, withIntermediateDirectories: false)
        try bytes.write(to: unexpected.appendingPathComponent("one"))
        try bytes.write(to: unexpected.appendingPathComponent("two"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-172_800)], ofItemAtPath: unexpected.path)
        try await store.discardAbandoned()
        precondition(!FileManager.default.fileExists(atPath: oldDirectory.path), "old lease cleaned")
        precondition(FileManager.default.fileExists(atPath: unexpected.appendingPathComponent("two").path), "unexpected contents kept")
        let finalSourceBytes = try Data(contentsOf: source)
        precondition(finalSourceBytes == bytes, "source is unchanged")
        print("Drive share fixture passed")
    }
}
