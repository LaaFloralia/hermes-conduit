import Foundation
import Darwin

private func expect(_ condition: Bool, _ message: String) {
    guard condition else { fatalError(message) }
}

private func expectError(_ expected: LAADriveOfflineError,
                         _ run: () async throws -> Void) async {
    do { try await run(); fatalError("expected \(expected)") }
    catch let error as LAADriveOfflineError { expect(error == expected, "expected \(expected), got \(error)") }
    catch { fatalError("unexpected error: \(error)") }
}

private actor Source {
    let data: Data
    let version: String
    let finalVersion: String?
    let downloadable: Bool?
    let finalDenied: Bool
    let badRange: Bool
    private var metadataCount = 0
    private(set) var rangeCount = 0

    init(data: Data, version: String, finalVersion: String? = nil,
         downloadable: Bool? = true, finalDenied: Bool = false, badRange: Bool = false) {
        self.data = data
        self.version = version
        self.finalVersion = finalVersion
        self.downloadable = downloadable
        self.finalDenied = finalDenied
        self.badRange = badRange
    }

    func metadata() -> LAADriveOfflineMetadata {
        metadataCount += 1
        return LAADriveOfflineMetadata(version: metadataCount > 1 ? finalVersion ?? version : version,
                                       size: Int64(data.count), downloadable: metadataCount > 1 && finalDenied ? false : downloadable)
    }

    func range(offset: Int64, length: Int, version: String) -> LAADriveOfflineChunk {
        rangeCount += 1
        let start = Int(offset)
        return LAADriveOfflineChunk(data: data.subdata(in: start..<(start + length)),
                                    total: Int64(data.count) + (badRange ? 1 : 0), version: version)
    }
}

private actor PDFSource {
    let data: Data
    let version: String
    let finalVersion: String?
    let responseVersion: String?
    private var metadataCount = 0

    init(data: Data, version: String, finalVersion: String? = nil, responseVersion: String? = nil) {
        self.data = data; self.version = version; self.finalVersion = finalVersion; self.responseVersion = responseVersion
    }

    func metadata() -> LAADriveOfflineMetadata {
        metadataCount += 1
        return LAADriveOfflineMetadata(version: metadataCount > 1 ? finalVersion ?? version : version,
                                       size: nil, downloadable: true)
    }

    func export(expected: String) throws -> LAADriveOfflinePDF {
        guard expected == version else { throw LAADriveOfflineError.versionChanged }
        return LAADriveOfflinePDF(data: data, version: responseVersion ?? version)
    }
}

private actor Gate {
    private var entered = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func blockRange() async {
        entered = true
        startedWaiter?.resume()
        startedWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

@main private struct OfflineFixture {
    static func save(_ source: Source, to store: LAADriveOfflineStore,
                     pairing: String = "pairing-a", id: String = "file-a") async throws -> LAADriveOfflineRecord {
        try await store.save(pairingID: pairing, id: id, name: "fixture.mp4", mimeType: "video/mp4",
                             metadata: { await source.metadata() },
                             range: { offset, length, version in await source.range(offset: offset, length: length, version: version) })
    }

    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let bytes = Data((0..<700_000).map { UInt8($0 % 251) })
        let source = Source(data: bytes, version: "1")
        let store = LAADriveOfflineStore(root: root, capacity: { _ in 10_000_000 })
        let original = try await save(source, to: store)
        expect(original.version == "1" && original.size == Int64(bytes.count), "saved version and size")
        expect(await source.rangeCount == 3, "download spans bounded ranges")
        let firstURL = try await store.localFile(pairingID: "pairing-a", id: "file-a")!
        expect(try Data(contentsOf: firstURL) == bytes, "saved bytes")
        expect(try await store.records(pairingID: "pairing-b").isEmpty, "pairings isolated")
        let otherBytes = Data(repeating: 42, count: 4096)
        let longPath = ["my", String(repeating: "資料", count: 20), String(repeating: "資料", count: 20), "fixture.mp4"]
        let longID = "d_" + (try JSONSerialization.data(withJSONObject: longPath)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        expect(longID.utf8.count > 200 && longID.utf8.count <= 2048, "fixture uses a long mount ID")
        _ = try await save(Source(data: otherBytes, version: "1"), to: store, id: longID)
        let reopenedStore = LAADriveOfflineStore(root: root, capacity: { _ in 10_000_000 })
        expect(try await reopenedStore.records(pairingID: "pairing-a").contains(where: { $0.id == longID }),
               "long mount ID survives index reload")
        let longURL = try await reopenedStore.localFile(pairingID: "pairing-a", id: longID)!
        expect(try Data(contentsOf: longURL) == otherBytes, "long mount ID opens saved bytes")
        expect(try await reopenedStore.remove(pairingID: "pairing-a", id: longID), "long mount ID can be removed")
        await expectError(.invalidItem) {
            _ = try await save(Source(data: otherBytes, version: "1"), to: store, id: String(repeating: "a", count: 2049))
        }
        _ = try await save(Source(data: otherBytes, version: "1"), to: store, pairing: "pairing-b")
        let otherURL = try await store.localFile(pairingID: "pairing-b", id: "file-a")!
        let otherStored = try Data(contentsOf: otherURL)
        expect(otherURL != firstURL && otherStored == otherBytes, "same ID is isolated by pairing")
        _ = try await save(Source(data: otherBytes, version: "1"), to: store, id: "replacement")
        let oldReplacement = try await store.localFile(pairingID: "pairing-a", id: "replacement")!
        _ = try await save(Source(data: Data(repeating: 7, count: 4096), version: "2"), to: store, id: "replacement")
        let newReplacement = try await store.localFile(pairingID: "pairing-a", id: "replacement")!
        expect(oldReplacement != newReplacement && !FileManager.default.fileExists(atPath: oldReplacement.path), "successful replacement commits before discarding old bytes")

        let changed = Source(data: bytes, version: "2", finalVersion: "3")
        await expectError(.versionChanged) { _ = try await save(changed, to: store) }
        expect(try await store.records(pairingID: "pairing-a").first(where: { $0.id == "file-a" })?.version == "1", "version change preserves old save")
        let badRange = Source(data: bytes, version: "2", badRange: true)
        await expectError(.invalidRange) { _ = try await save(badRange, to: store) }
        let unknown = Source(data: bytes, version: "2", downloadable: nil)
        await expectError(.permissionUnknown) { _ = try await save(unknown, to: store) }
        let denied = Source(data: bytes, version: "2", downloadable: false)
        await expectError(.forbidden) { _ = try await save(denied, to: store) }
        expect(try await store.localFile(pairingID: "pairing-a", id: "file-a") == nil, "denial during save blocks old file")
        let finalDenied = Source(data: bytes, version: "2", finalDenied: true)
        await expectError(.forbidden) { _ = try await save(finalDenied, to: store) }
        expect(try await store.records(pairingID: "pairing-a").first(where: { $0.id == "file-a" })?.access == .denied, "final denial blocks old file")
        let missingRange = Source(data: bytes, version: "2")
        await expectError(.notFound) {
            _ = try await store.save(pairingID: "pairing-a", id: "file-a", name: "fixture.mp4", mimeType: "video/mp4",
                                     metadata: { await missingRange.metadata() },
                                     range: { _, _, _ in throw LAADriveOfflineError.notFound })
        }
        expect(try await store.records(pairingID: "pairing-a").first(where: { $0.id == "file-a" })?.access == .missing, "range deletion blocks old file")
        expect(try Data(contentsOf: firstURL) == bytes, "failures preserve original bytes")

        try await store.recordCheck(pairingID: "pairing-a", id: "file-a", result: .denied)
        expect(try await store.localFile(pairingID: "pairing-a", id: "file-a") == nil, "known denial blocks opening")
        expect(FileManager.default.fileExists(atPath: firstURL.path), "known denial does not erase bytes")
        try await store.recordCheck(pairingID: "pairing-a", id: "file-a", result: .missing)
        expect(try await store.localFile(pairingID: "pairing-a", id: "file-a") == nil, "known deletion blocks opening")
        let stale = LAADriveOfflineMetadata(version: "2", size: Int64(bytes.count), downloadable: true)
        try await store.recordCheck(pairingID: "pairing-a", id: "file-a", result: .metadata(stale))
        expect(try await store.records(pairingID: "pairing-a").first(where: { $0.id == "file-a" })?.access == .stale, "permitted older save is marked stale")
        expect(try await store.localFile(pairingID: "pairing-a", id: "file-a") == firstURL, "stale bytes remain available")
        let inconsistent = LAADriveOfflineMetadata(version: "1", size: 1, downloadable: true)
        try await store.recordCheck(pairingID: "pairing-a", id: "file-a", result: .metadata(inconsistent))
        expect(try await store.localFile(pairingID: "pairing-a", id: "file-a") == nil, "inconsistent metadata is unknown")

        let gate = Gate()
        let next = Source(data: bytes, version: "2")
        let inFlight = Task {
            try await store.save(pairingID: "pairing-a", id: "file-a", name: "fixture.mp4", mimeType: "video/mp4",
                                 metadata: { await next.metadata() }, range: { offset, length, version in
                if offset == 0 { await gate.blockRange() }
                return await next.range(offset: offset, length: length, version: version)
            })
        }
        await gate.waitUntilEntered()
        await expectError(.alreadySaving) { _ = try await save(next, to: store) }
        await expectError(.alreadySaving) { _ = try await store.remove(pairingID: "pairing-a", id: "file-a") }
        try await store.recordCheck(pairingID: "pairing-a", id: "file-a", result: .denied)
        await gate.release()
        await expectError(.accessChanged) { _ = try await inFlight.value }
        expect(try await store.records(pairingID: "pairing-a").first(where: { $0.id == "file-a" })?.access == .denied, "new denial wins during save")
        expect(try Data(contentsOf: firstURL) == bytes, "concurrent denial retains old bytes")

        let initialGate = Gate()
        let initialSource = Source(data: otherBytes, version: "1")
        let initialPending = Task {
            try await store.save(pairingID: "pairing-a", id: "not-yet-saved", name: "fixture.mp4", mimeType: "video/mp4",
                                 metadata: { await initialGate.blockRange(); return await initialSource.metadata() },
                                 range: { offset, length, version in await initialSource.range(offset: offset, length: length, version: version) })
        }
        await initialGate.waitUntilEntered()
        try await store.recordCheck(pairingID: "pairing-a", id: "not-yet-saved", result: .denied)
        await initialGate.release()
        await expectError(.accessChanged) { _ = try await initialPending.value }
        expect(await initialSource.rangeCount == 0, "denial during initial check prevents first save")

        let cancelGate = Gate()
        let cancelledSource = Source(data: bytes, version: "2")
        let cancelled = Task {
            try await store.save(pairingID: "pairing-a", id: "file-a", name: "fixture.mp4", mimeType: "video/mp4",
                                 metadata: { await cancelledSource.metadata() }, range: { offset, length, version in
                if offset == 0 { await cancelGate.blockRange() }
                return await cancelledSource.range(offset: offset, length: length, version: version)
            })
        }
        await cancelGate.waitUntilEntered()
        cancelled.cancel()
        await cancelGate.release()
        do { _ = try await cancelled.value; fatalError("expected cancellation") } catch is CancellationError { }
        let pending = root.appendingPathComponent("pending", isDirectory: true)
        expect(try FileManager.default.contentsOfDirectory(atPath: pending.path).isEmpty, "failed saves leave no partial file")

        let noSpace = LAADriveOfflineStore(root: root.appendingPathComponent("low-space"), capacity: { _ in 0 })
        let sourceNoSpace = Source(data: bytes, version: "1")
        await expectError(.insufficientSpace) { _ = try await save(sourceNoSpace, to: noSpace) }
        expect(await sourceNoSpace.rangeCount == 0, "insufficient space fails before transfer")

        let pdfBytes = Data("%PDF-1.7\nsynthetic\n%%EOF\n".utf8)
        let pdfSource = PDFSource(data: pdfBytes, version: "9")
        let pdfRecord = try await store.saveWorkspacePDF(pairingID: "pairing-a", id: "workspace-a", name: "notes",
                                                          metadata: { await pdfSource.metadata() },
                                                          export: { try await pdfSource.export(expected: $0) })
        expect(pdfRecord.sourceFormat == .workspacePDF && pdfRecord.mimeType == "application/pdf" &&
               pdfRecord.version == "9" && pdfRecord.size == Int64(pdfBytes.count), "exported PDF metadata")
        let pdfURL = try await store.localFile(pairingID: "pairing-a", id: "workspace-a")!
        expect(try Data(contentsOf: pdfURL) == pdfBytes, "exported PDF bytes")
        try await store.recordCheck(pairingID: "pairing-a", id: "workspace-a",
                                    result: .metadata(.init(version: "9", size: nil, downloadable: true)))
        expect(try await store.records(pairingID: "pairing-a").first(where: { $0.id == "workspace-a" })?.access == .verified,
               "workspace source need not have a byte size")
        try await store.recordCheck(pairingID: "pairing-a", id: "workspace-a",
                                    result: .metadata(.init(version: "10", size: nil, downloadable: true)))
        expect(try await store.records(pairingID: "pairing-a").first(where: { $0.id == "workspace-a" })?.access == .stale,
               "changed workspace document marks the export stale")
        let changedPDF = PDFSource(data: pdfBytes, version: "10", finalVersion: "11")
        await expectError(.versionChanged) {
            _ = try await store.saveWorkspacePDF(pairingID: "pairing-a", id: "workspace-a", name: "notes",
                                                  metadata: { await changedPDF.metadata() },
                                                  export: { try await changedPDF.export(expected: $0) })
        }
        let wrongPDF = PDFSource(data: Data("invalid".utf8), version: "10")
        await expectError(.invalidDocument) {
            _ = try await store.saveWorkspacePDF(pairingID: "pairing-a", id: "workspace-a", name: "notes",
                                                  metadata: { await wrongPDF.metadata() },
                                                  export: { try await wrongPDF.export(expected: $0) })
        }
        let wrongVersion = PDFSource(data: pdfBytes, version: "10", responseVersion: "11")
        await expectError(.versionChanged) {
            _ = try await store.saveWorkspacePDF(pairingID: "pairing-a", id: "workspace-a", name: "notes",
                                                  metadata: { await wrongVersion.metadata() },
                                                  export: { try await wrongVersion.export(expected: $0) })
        }
        expect(try await store.localFile(pairingID: "pairing-a", id: "workspace-a") == pdfURL,
               "failed PDF replacements preserve the older export")
        let pdfNoSpace = PDFSource(data: pdfBytes, version: "9")
        await expectError(.insufficientSpace) {
            _ = try await noSpace.saveWorkspacePDF(pairingID: "pairing-a", id: "workspace-a", name: "notes",
                                                    metadata: { await pdfNoSpace.metadata() },
                                                    export: { try await pdfNoSpace.export(expected: $0) })
        }
        let pdfGate = Gate()
        let pdfConcurrent = PDFSource(data: pdfBytes, version: "10")
        let pendingPDF = Task {
            try await store.saveWorkspacePDF(pairingID: "pairing-a", id: "workspace-a", name: "notes",
                                              metadata: { await pdfConcurrent.metadata() }, export: { version in
                await pdfGate.blockRange()
                return try await pdfConcurrent.export(expected: version)
            })
        }
        await pdfGate.waitUntilEntered()
        try await store.recordCheck(pairingID: "pairing-a", id: "workspace-a", result: .denied)
        await pdfGate.release()
        await expectError(.accessChanged) { _ = try await pendingPDF.value }
        expect(try await store.localFile(pairingID: "pairing-a", id: "workspace-a") == nil &&
               FileManager.default.fileExists(atPath: pdfURL.path), "PDF denial blocks access without erasing saved bytes")

        expect(try await store.remove(pairingID: "pairing-a", id: "workspace-a"), "explicitly remove denied saved PDF")
        let recordsAfterRemoval = try await store.records(pairingID: "pairing-a")
        expect(!FileManager.default.fileExists(atPath: pdfURL.path) &&
               !recordsAfterRemoval.contains(where: { $0.id == "workspace-a" }),
               "removed record and its local bytes")
        let removedAgain = try await store.remove(pairingID: "pairing-a", id: "workspace-a")
        expect(!removedAgain, "repeated removal is harmless")
        expect(try await store.remove(pairingID: "pairing-b", id: "file-a"), "remove another pairing's own save")
        expect(!FileManager.default.fileExists(atPath: otherURL.path) &&
               FileManager.default.fileExists(atPath: firstURL.path), "removal is isolated by pairing")

        let absentSource = Source(data: otherBytes, version: "1")
        _ = try await save(absentSource, to: store, id: "absent-body")
        let absentURL = try await store.localFile(pairingID: "pairing-a", id: "absent-body")!
        try FileManager.default.removeItem(at: absentURL)
        expect(try await store.remove(pairingID: "pairing-a", id: "absent-body"), "missing bytes can be removed from the index")

        let displaced = pending.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: newReplacement, to: displaced)
        try FileManager.default.createDirectory(at: newReplacement, withIntermediateDirectories: false)
        let sentinel = newReplacement.appendingPathComponent("unrelated")
        try Data([5]).write(to: sentinel)
        await expectError(.unavailable) { _ = try await store.remove(pairingID: "pairing-a", id: "replacement") }
        expect(FileManager.default.fileExists(atPath: sentinel.path), "unexpected directory is not recursively deleted")
        try FileManager.default.removeItem(at: newReplacement)
        try FileManager.default.moveItem(at: displaced, to: newReplacement)

        if geteuid() != 0 {
            let directory = root.appendingPathComponent("files")
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
            var removalFailed = false
            do { _ = try await store.remove(pairingID: "pairing-a", id: "replacement") }
            catch { removalFailed = true }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let restored = try await store.records(pairingID: "pairing-a")
            expect(removalFailed && restored.contains(where: { $0.id == "replacement" }) &&
                   FileManager.default.fileExists(atPath: newReplacement.path), "failed removal restores its record")
        }

        let known = LAADriveOfflineMetadata(version: "1", size: Int64(bytes.count), downloadable: true)
        let rechecked = try await LAADriveOfflineOpener.open(pairingID: "pairing-a", id: "file-a", store: store) {
            .checked(.metadata(known))
        }
        expect(rechecked.checkedOnline && rechecked.record.access == .verified && rechecked.url == firstURL,
               "online open rechecks permission")
        let offline = try await LAADriveOfflineOpener.open(pairingID: "pairing-a", id: "file-a", store: store) { .offline }
        expect(!offline.checkedOnline && offline.record.access == .verified, "offline open retains last verification")
        let older = try await LAADriveOfflineOpener.open(pairingID: "pairing-a", id: "file-a", store: store) {
            .checked(.metadata(.init(version: "2", size: Int64(bytes.count), downloadable: true)))
        }
        expect(older.record.access == .stale && older.url == firstURL, "permitted older copy is marked stale")
        await expectError(.forbidden) {
            _ = try await LAADriveOfflineOpener.open(pairingID: "pairing-a", id: "file-a", store: store) { .checked(.denied) }
        }
        await expectError(.forbidden) {
            _ = try await LAADriveOfflineOpener.open(pairingID: "pairing-a", id: "file-a", store: store) { .offline }
        }
        await expectError(.permissionUnknown) {
            _ = try await LAADriveOfflineOpener.open(pairingID: "pairing-a", id: "file-a", store: store) {
                .checked(.metadata(.init(version: nil, size: nil, downloadable: nil)))
            }
        }
        await expectError(.notFound) {
            _ = try await LAADriveOfflineOpener.open(pairingID: "pairing-a", id: "file-a", store: store) { .checked(.missing) }
        }
        await expectError(.unavailable) {
            _ = try await LAADriveOfflineOpener.open(pairingID: "pairing-b", id: "file-a", store: store) { .offline }
        }
        expect(FileManager.default.fileExists(atPath: firstURL.path), "access loss never erases the saved copy")
        let denialGate = Gate()
        let earlierCheck = Task {
            try await LAADriveOfflineOpener.open(pairingID: "pairing-a", id: "file-a", store: store) {
                await denialGate.blockRange()
                return .checked(.metadata(known))
            }
        }
        await denialGate.waitUntilEntered()
        await expectError(.forbidden) {
            _ = try await LAADriveOfflineOpener.open(pairingID: "pairing-a", id: "file-a", store: store) { .checked(.denied) }
        }
        await denialGate.release()
        await expectError(.accessChanged) { _ = try await earlierCheck.value }
        expect(try await store.records(pairingID: "pairing-a").first(where: { $0.id == "file-a" })?.access == .denied,
               "older successful check cannot overwrite a newer denial")

        let slowDenialGate = Gate()
        let slowDenial = Task {
            try await LAADriveOfflineOpener.open(pairingID: "pairing-a", id: "file-a", store: store) {
                await slowDenialGate.blockRange()
                return .checked(.denied)
            }
        }
        await slowDenialGate.waitUntilEntered()
        _ = try await LAADriveOfflineOpener.open(pairingID: "pairing-a", id: "file-a", store: store) {
            .checked(.metadata(known))
        }
        await slowDenialGate.release()
        await expectError(.forbidden) { _ = try await slowDenial.value }
        expect(try await store.records(pairingID: "pairing-a").first(where: { $0.id == "file-a" })?.access == .denied,
               "late denial still blocks an earlier success")

        let replacementGate = Gate()
        let pendingReplacementCheck = Task {
            try await LAADriveOfflineOpener.open(pairingID: "pairing-a", id: "replacement", store: store) {
                await replacementGate.blockRange()
                return .checked(.metadata(.init(version: "2", size: Int64(otherBytes.count), downloadable: true)))
            }
        }
        await replacementGate.waitUntilEntered()
        _ = try await store.remove(pairingID: "pairing-a", id: "replacement")
        _ = try await save(Source(data: otherBytes, version: "3"), to: store, id: "replacement")
        await replacementGate.release()
        await expectError(.accessChanged) { _ = try await pendingReplacementCheck.value }
        expect(try await store.records(pairingID: "pairing-a").first(where: { $0.id == "replacement" })?.version == "3",
               "old check cannot update a removed and replaced copy")

        let openGate = Gate()
        let opening = Task {
            try await LAADriveOfflineOpener.open(pairingID: "pairing-a", id: "file-a", store: store) {
                await openGate.blockRange()
                return .checked(.metadata(known))
            }
        }
        await openGate.waitUntilEntered()
        opening.cancel()
        await openGate.release()
        do { _ = try await opening.value; fatalError("expected cancellation") } catch is CancellationError { }
        expect(try await store.records(pairingID: "pairing-a").first(where: { $0.id == "file-a" })?.access == .denied,
               "cancelled access check cannot restore permission")

        let oldMeta = LAADriveOfflineMetadata(version: "1", size: Int64(bytes.count), downloadable: true)
        try await store.recordCheck(pairingID: "pairing-a", id: "file-a", result: .metadata(oldMeta))
        var corrupted = bytes
        corrupted[0] ^= 0xff
        try corrupted.write(to: firstURL)
        await expectError(.unavailable) { _ = try await store.localFile(pairingID: "pairing-a", id: "file-a") }
        try bytes.write(to: firstURL)
        let unreferenced = root.appendingPathComponent("files").appendingPathComponent(UUID().uuidString)
        let incomplete = pending.appendingPathComponent(UUID().uuidString)
        let unrecognized = pending.appendingPathComponent("unrecognized")
        try Data([1]).write(to: unreferenced)
        try Data([2]).write(to: incomplete)
        try Data([3]).write(to: unrecognized)
        try await store.discardIncompleteSaves()
        expect(!FileManager.default.fileExists(atPath: unreferenced.path) && !FileManager.default.fileExists(atPath: incomplete.path), "orphan and partial cleaned")
        expect(FileManager.default.fileExists(atPath: unrecognized.path) && FileManager.default.fileExists(atPath: firstURL.path), "recognized save and unrelated data preserved")
        let index = root.appendingPathComponent("index.json")
        try Data("broken".utf8).write(to: index)
        await expectError(.corruptIndex) { try await store.discardIncompleteSaves() }
        await expectError(.corruptIndex) { _ = try await store.remove(pairingID: "pairing-a", id: "file-a") }
        expect(FileManager.default.fileExists(atPath: firstURL.path), "corrupt index cannot erase saved bytes")
        print("Drive offline fixture passed")
    }
}
