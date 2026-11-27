#if LAA_BUILD
import XCTest
@testable import Conduit

/// Long polls often return the same history. An identical poll must not touch
/// disk; a changed one rewrites only its own snapshot file, never the protected
/// draft store (the multi-MB rewrite on every poll and keystroke, D-16).
@MainActor
final class LAAWorkSessionCachePerformanceTests: XCTestCase {
    func testSameValueRetriesAfterWriteFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LAAWorkSessionCacheStore(directory: directory.appendingPathComponent("session-cache-v2"))
        let url = cache.fileURL(device: "test-device", target: "history")
        // Obstruct the snapshot file with a folder so the first write fails.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        cache.save(["text": "saved"], store: nil, device: "test-device", target: "history")
        cache.flush()
        try FileManager.default.removeItem(at: url)
        cache.save(["text": "saved"], store: nil, device: "test-device", target: "history")
        cache.flush()
        XCTAssertFalse(try Data(contentsOf: url).isEmpty)
    }

    func testIdenticalPollDoesNotRewriteItsFileButChangedPollDoes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("drafts.json")
        let store = ComposerDraftStore(capacity: .max, fileURL: storeURL)
        XCTAssertTrue(store.save(ComposerDraft(text: "draft", attachments: []), for: LAAWorkDrafts.key(deviceID: "test-device", target: "s")))
        let storeBytes = try Data(contentsOf: storeURL)
        let cache = LAAWorkSessionCacheStore(directory: directory.appendingPathComponent("session-cache-v2"))
        let url = cache.fileURL(device: "test-device", target: "history")
        cache.save(["b": "second", "a": "first"], store: store, device: "test-device", target: "history")
        cache.flush()
        let original = try Data(contentsOf: url)
        let oldDate = Date(timeIntervalSinceNow: -60)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
        // Reverse key insertion order; sorted encoding still identifies the same data.
        cache.save(["a": "first", "b": "second"], store: store, device: "test-device", target: "history")
        cache.flush()
        XCTAssertEqual(try Data(contentsOf: url), original)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.modificationDate] as? Date)?.timeIntervalSince1970, oldDate.timeIntervalSince1970)
        cache.save(["a": "changed"], store: store, device: "test-device", target: "history")
        cache.flush()
        XCTAssertNotEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(cache.read([String: String].self, store: store, device: "test-device", target: "history"), ["a": "changed"])
        XCTAssertEqual(try Data(contentsOf: storeURL), storeBytes)
    }
}
#endif
