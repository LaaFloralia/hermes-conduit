#if LAA_BUILD
import XCTest
@testable import Conduit

final class LAABrainIndexTests: XCTestCase {
    private func file(_ path: String) -> LAABrainFile {
        LAABrainFile(id: LAABrainReference(path: path, includeInbox: true).id, path: path,
                     title: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                     modifiedAt: "", area: "local", unreadable: nil)
    }

    func testJapaneseSubstringTagsAndLinksExcludeCode() {
        let files = [file("A/Start.md"), file("A/Other.md"), file("B/Other.md"), file("Broken.md")]
        let texts = ["A/Start.md": "---\ntags: [仕事, planning]\n---\n# 見出し\n日本語の本文 カタカナ\n#庭/花 [[Other|次]]\n`#ignored [[Broken]]`\n```\n#hidden\n```",
                     "A/Other.md": "# 次のメモ\n[[Start#見出し]]",
                     "B/Other.md": "同名のメモ"]
        let index = LAABrainIndex(files: files) { path in
            guard let text = texts[path] else { throw NSError(domain: "fixture", code: 1) }
            return text
        }
        XCTAssertEqual(index.search("日本語の").map(\.path), ["A/Start.md"])
        XCTAssertEqual(index.search("ｶﾀｶﾅ").map(\.path), ["A/Start.md"])
        XCTAssertEqual(Set(index.tags), ["仕事", "planning", "庭/花"])
        XCTAssertEqual(index.files(tag: "仕事").map(\.path), ["A/Start.md"])
        XCTAssertEqual(index.outgoing(from: "A/Start.md", files: files).map(\.path), ["A/Other.md"])
        XCTAssertEqual(index.backlinks(to: "A/Start.md", files: files).map(\.path), ["A/Other.md"])
        XCTAssertEqual(index.unreadableCount, 1)
    }

    func testRebuildingReflectsChangedAndRemovedNotes() {
        let files = [file("Start.md")]
        let original = LAABrainIndex(files: files) { _ in "以前の内容 #古い" }
        let changed = LAABrainIndex(files: files) { _ in "現在の内容 #新しい" }
        let removed = LAABrainIndex(files: []) { _ in "" }
        XCTAssertEqual(original.search("以前").count, 1)
        XCTAssertTrue(changed.search("以前").isEmpty)
        XCTAssertEqual(changed.search("現在").count, 1)
        XCTAssertEqual(changed.tags, ["新しい"])
        XCTAssertTrue(removed.search("現在").isEmpty)
    }

    func testPinsPersistSeparatelyForEachFolderAndMac() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("brain-pins-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = URL(fileURLWithPath: "/fixture/first")
        let second = URL(fileURLWithPath: "/fixture/second")
        try LAABrainPins.save(["A/Start.md"], root: first, directory: directory)
        try LAABrainPins.save(["Other.md"], root: nil, directory: directory)
        XCTAssertEqual(try LAABrainPins.load(root: first, directory: directory), ["A/Start.md"])
        XCTAssertTrue(try LAABrainPins.load(root: second, directory: directory).isEmpty)
        XCTAssertEqual(try LAABrainPins.load(root: nil, directory: directory), ["Other.md"])
    }
}
#endif
