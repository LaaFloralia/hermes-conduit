#if LAA_BUILD
import XCTest
@testable import Conduit

final class LAABrainLocalVaultTests: XCTestCase {
    private var root: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("brain-local-test-" + UUID().uuidString, isDirectory: true)
        outside = FileManager.default.temporaryDirectory.appendingPathComponent("brain-outside-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("# 最初\n本文\n".utf8).write(to: root.appendingPathComponent("Folder/日本語.md"))
        try Data("settings".utf8).write(to: root.appendingPathComponent(".obsidian/hidden.md"))
        try Data("outside".utf8).write(to: outside.appendingPathComponent("secret.md"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }

    func testEnumeratesOnlyNotesInsideSelectedFolder() throws {
        let files = try LAABrainVaultIO.files(root: root)
        XCTAssertEqual(files.map(\.path), ["Folder/日本語.md"])
        XCTAssertEqual(try LAABrainVaultIO.note(root: root, path: "Folder/日本語.md").text, "# 最初\n本文\n")
        for path in ["../secret.md", "/secret.md", "linked/secret.md", ".obsidian/hidden.md"] {
            XCTAssertThrowsError(try LAABrainVaultIO.note(root: root, path: path), path)
        }
    }

    func testExternalChangeAndRemovalAreReadFromDisk() throws {
        let path = "Folder/日本語.md"
        let url = root.appendingPathComponent(path)
        try Data("他のアプリで更新".utf8).write(to: url, options: .atomic)
        XCTAssertEqual(try LAABrainVaultIO.note(root: root, path: path).text, "他のアプリで更新")
        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(try LAABrainVaultIO.files(root: root).isEmpty)
        XCTAssertThrowsError(try LAABrainVaultIO.note(root: root, path: path))
    }
}
#endif
