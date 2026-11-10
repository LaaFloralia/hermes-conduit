#if LAA_BUILD
import XCTest
@testable import Conduit

@MainActor
final class LAAWorkSessionCachePerformanceTests: XCTestCase {
    func testIdenticalPollDoesNotRewriteProtectedStoreButChangedPollDoes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("drafts.json")
        let store = ComposerDraftStore(fileURL: url)
        let value = ["b": "second", "a": "first"]
        LAAWorkSessionCache.save(value, store: store, device: "test-device", target: "history")
        let original = try Data(contentsOf: url)
        let oldDate = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
        // Reverse key insertion order; sorted encoding still identifies the same data.
        LAAWorkSessionCache.save(["a": "first", "b": "second"], store: store, device: "test-device", target: "history")
        XCTAssertEqual(try Data(contentsOf: url), original)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.modificationDate] as? Date)?.timeIntervalSince1970, oldDate.timeIntervalSince1970)
        LAAWorkSessionCache.save(["a": "changed"], store: store, device: "test-device", target: "history")
        XCTAssertNotEqual(try Data(contentsOf: url), original)
        let decoded = LAAWorkSessionCache.read([String: String].self, store: store, device: "test-device", target: "history")
        XCTAssertEqual(decoded, ["a": "changed"])
    }
}
#endif
