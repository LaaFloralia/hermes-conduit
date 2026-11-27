#if LAA_BUILD
import Combine
import XCTest
@testable import Conduit

/// Work snapshots live in one file per (device, target), written off the main
/// thread; the protected draft store is never rewritten for them (D-16).
@MainActor
final class LAAWorkSessionCacheStoreTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var cacheDirectory: URL { folder.appendingPathComponent("session-cache-v2", isDirectory: true) }
    private var storeURL: URL { folder.appendingPathComponent("drafts-v1.json") }

    /// Counts file writes, and writes them like the real cache does.
    private final class WriteLog: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        var count: Int { lock.lock(); defer { lock.unlock() }; return urls.count }
        func written(_ url: URL) -> Int { lock.lock(); defer { lock.unlock() }; return urls.filter { $0 == url }.count }
        func record(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
    }

    private func makeCache(queue: DispatchQueue = DispatchQueue(label: "test.session-cache"),
                           log: WriteLog? = nil,
                           write: (@Sendable (Data, URL) throws -> Void)? = nil) -> LAAWorkSessionCacheStore {
        LAAWorkSessionCacheStore(directory: cacheDirectory, queue: queue) { data, url in
            log?.record(url)
            if let write { try write(data, url) } else { try LAAWorkSessionCacheStore.writeFile(data, to: url) }
        }
    }

    private func ownerKey(_ target: String) -> ComposerDraftKey { LAAWorkDrafts.key(deviceID: "a", target: target) }
    private func legacyKey(_ target: String) -> ComposerDraftKey {
        ComposerDraftKey(profile: "laa-session-cache-v1", sessionID: "a:\(target)", dashboardID: LAAWorkDrafts.dashboardID)
    }

    func testSnapshotRoundTripsThroughAFreshInstanceAndStaysPerDevice() throws {
        let first = makeCache()
        first.save(["name": "保存済み"], store: nil, device: "a", target: "list")
        first.flush()
        let fresh = makeCache()
        XCTAssertEqual(fresh.read([String: String].self, store: nil, device: "a", target: "list"), ["name": "保存済み"])
        XCTAssertNil(fresh.read([String: String].self, store: nil, device: "b", target: "list"))
        XCTAssertNil(fresh.read([String: String].self, store: nil, device: nil, target: "list"))
        let file = first.fileURL(device: "a", target: "list")
        XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL, cacheDirectory.standardizedFileURL)
        XCTAssertEqual(file.pathExtension, "json")
        XCTAssertNotNil(file.deletingPathExtension().lastPathComponent.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
        XCTAssertEqual(try cacheDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testUnchangedSaveWritesNothing() {
        let log = WriteLog()
        let cache = makeCache(log: log)
        cache.save(["b": "second", "a": "first"], store: nil, device: "a", target: "history")
        cache.flush()
        XCTAssertEqual(log.count, 1)
        // Reverse key insertion order; sorted encoding still identifies the same data.
        cache.save(["a": "first", "b": "second"], store: nil, device: "a", target: "history")
        cache.flush()
        XCTAssertEqual(log.count, 1)
        cache.save(["a": "changed"], store: nil, device: "a", target: "history")
        cache.flush()
        XCTAssertEqual(log.count, 2)
    }

    func testSavingOneKeyLeavesOtherFilesAndTheDraftStoreAlone() throws {
        let store = ComposerDraftStore(capacity: .max, fileURL: storeURL)
        XCTAssertTrue(store.save(ComposerDraft(text: "社長の下書き", attachments: []), for: ownerKey("s1")))
        let storeBytes = try Data(contentsOf: storeURL)
        let log = WriteLog()
        let cache = makeCache(log: log)
        cache.save(["v": "a1"], store: store, device: "a", target: "A")
        cache.save(["v": "b1"], store: store, device: "a", target: "B")
        cache.flush()
        let fileB = cache.fileURL(device: "a", target: "B")
        let bytesB = try Data(contentsOf: fileB)
        cache.save(["v": "a2"], store: store, device: "a", target: "A")
        cache.flush()
        XCTAssertEqual(log.written(fileB), 1)
        XCTAssertEqual(try Data(contentsOf: fileB), bytesB)
        XCTAssertEqual(try Data(contentsOf: storeURL), storeBytes, "the draft store file is never rewritten by the cache")
        XCTAssertEqual(store.keys, [ownerKey("s1")])
        XCTAssertEqual(ComposerDraftStore(capacity: .max, fileURL: storeURL).keys, [ownerKey("s1")])
    }

    func testLegacyEntriesLeaveTheStoreInOneWriteAndNothingElseChanges() throws {
        let store = ComposerDraftStore(capacity: .max, fileURL: storeURL)
        XCTAssertTrue(store.save(ComposerDraft(text: "first", attachments: []), for: ownerKey("s1")))
        XCTAssertTrue(store.save(ComposerDraft(text: "{}", attachments: []), for: legacyKey("list")))
        XCTAssertTrue(store.save(ComposerDraft(text: "second", attachments: []), for: ownerKey("s2")))
        XCTAssertTrue(store.save(ComposerDraft(text: "[]", attachments: []), for: legacyKey("ses_1")))
        XCTAssertTrue(store.save(ComposerDraft(text: "[]", attachments: []), for: legacyKey("ses_1:messages")))
        let pendingKey = ownerKey("s3")
        let submission = ComposerDraftStore.Submission(id: UUID(), key: pendingKey, dashboardID: LAAWorkDrafts.dashboardID,
                                                       draft: ComposerDraft(text: "sending", attachments: []), pendingSendID: UUID())
        XCTAssertTrue(store.beginSubmission(submission, clearingDraft: false))
        let reloaded = ComposerDraftStore(capacity: .max, fileURL: storeURL)
        XCTAssertEqual(reloaded.keys.count, 5)

        // Every persist publishes `persistenceFailed`, so changes count writes.
        var writes = 0
        let watch = reloaded.objectWillChange.sink { writes += 1 }
        let cache = makeCache()
        XCTAssertNil(cache.read([String].self, store: reloaded, device: "a", target: "list"), "legacy contents are not migrated")
        withExtendedLifetime(watch) {}
        XCTAssertEqual(writes, 1, "all legacy entries go in one persist")
        cache.save(["x"], store: reloaded, device: "a", target: "list")
        _ = cache.read([String].self, store: reloaded, device: "a", target: "list")
        XCTAssertEqual(writes, 1, "the cleanup runs once per store")
        watch.cancel()

        let after = ComposerDraftStore(capacity: .max, fileURL: storeURL)
        XCTAssertEqual(after.keys, [ownerKey("s2"), ownerKey("s1")])
        XCTAssertEqual(after.draft(for: ownerKey("s1")).text, "first")
        XCTAssertEqual(after.draft(for: ownerKey("s2")).text, "second")
        XCTAssertEqual(after.submissions.map(\.id), [submission.id])
        XCTAssertEqual(after.submissions.first?.draft.text, "sending")
        XCTAssertEqual(after.submissions.first?.pendingSendID, submission.pendingSendID)
    }

    func testAnUnreadableStoreIsLeftAlone() throws {
        let garbage = Data("not a snapshot".utf8)
        try garbage.write(to: storeURL)
        let store = ComposerDraftStore(capacity: .max, fileURL: storeURL)
        XCTAssertTrue(store.persistenceFailed)
        let cache = makeCache()
        cache.save(["v"], store: store, device: "a", target: "list")
        cache.flush()
        XCTAssertEqual(try Data(contentsOf: storeURL), garbage)
        XCTAssertEqual(makeCache().read([String].self, store: store, device: "a", target: "list"), ["v"])
    }

    func testLatestQueuedWriteWinsAndReadsSeeItBeforeTheFlush() throws {
        let queue = DispatchQueue(label: "test.session-cache.suspended")
        queue.suspend()
        let log = WriteLog()
        let cache = makeCache(queue: queue, log: log)
        for value in ["v1", "v2", "v3"] {
            cache.save([value], store: nil, device: "a", target: "history")
        }
        XCTAssertEqual(cache.read([String].self, store: nil, device: "a", target: "history"), ["v3"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.fileURL(device: "a", target: "history").path))
        queue.resume()
        cache.flush()
        XCTAssertEqual(log.count, 1, "queued writes for one key coalesce")
        XCTAssertEqual(makeCache().read([String].self, store: nil, device: "a", target: "history"), ["v3"])
    }

    func testAWriteQueuedDuringAnotherNeverLandsBeforeIt() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let calls = WriteLog()
        let cache = makeCache(log: calls) { data, url in
            if calls.count == 1 { entered.signal(); release.wait() }
            try LAAWorkSessionCacheStore.writeFile(data, to: url)
        }
        cache.save(["old"], store: nil, device: "a", target: "history")
        entered.wait()
        cache.save(["new"], store: nil, device: "a", target: "history")
        release.signal()
        cache.flush()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(makeCache().read([String].self, store: nil, device: "a", target: "history"), ["new"])
    }

    func testFilesUntouchedForFourteenDaysAreRemovedOnFirstUse() throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let old = cacheDirectory.appendingPathComponent("old.json")
        let recent = cacheDirectory.appendingPathComponent("recent.json")
        let outside = folder.appendingPathComponent("outside.json")
        for url in [old, recent, outside] { try Data("[]".utf8).write(to: url) }
        let day: TimeInterval = 24 * 60 * 60
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-15 * day)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-13 * day)], ofItemAtPath: recent.path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * day)], ofItemAtPath: outside.path)
        let cache = makeCache()
        _ = cache.read([String].self, store: nil, device: "a", target: "list")
        cache.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }
}
#endif
