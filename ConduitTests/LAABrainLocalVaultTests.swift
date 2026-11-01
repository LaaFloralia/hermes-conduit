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

    func testAttachmentsStayInsideVaultAndAmbiguousNamesAreRejected() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("Assets/図.png"))
        let relative = try LAABrainVaultIO.attachment(root: root, currentPath: "Folder/日本語.md", target: "../Assets/図.png")
        XCTAssertEqual(relative.path, "Assets/図.png")
        XCTAssertEqual(relative.data, Data([0, 1, 2]))
        XCTAssertEqual(try LAABrainVaultIO.attachment(root: root, currentPath: "Folder/日本語.md", target: "図.png").path, "Assets/図.png")
        XCTAssertThrowsError(try LAABrainVaultIO.attachment(root: root, currentPath: "Folder/日本語.md", target: "../../outside/secret.md"))
        XCTAssertThrowsError(try LAABrainVaultIO.attachment(root: root, currentPath: "Folder/日本語.md", target: "linked/secret.md"))
        try manager.createDirectory(at: root.appendingPathComponent("Other"), withIntermediateDirectories: true)
        try Data([3]).write(to: root.appendingPathComponent("Other/図.png"))
        XCTAssertThrowsError(try LAABrainVaultIO.attachment(root: root, currentPath: "Folder/日本語.md", target: "図.png"))
    }
    func testFolderListingIncludesEmptyAndNestedFoldersButNotHiddenOrSymlinks() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder/Empty"), withIntermediateDirectories: true)
        let listing = try LAABrainVaultIO.listing(root: root)
        XCTAssertEqual(Set(listing.folders), Set(["Folder", "Folder/Empty"]))
        XCTAssertEqual(listing.files.map(\.path), ["Folder/日本語.md"])
    }

    func testCreateFolderAndNoteNeverReplaceExistingItems() throws {
        let journal = LAABrainSaveJournal(directory: outside.appendingPathComponent("history", isDirectory: true))
        let folder = try LAABrainFolderStore.create(root: root, parent: "Folder", name: "新しいフォルダ", kind: .folder)
        XCTAssertEqual(folder, "Folder/新しいフォルダ")
        let note = try LAABrainFolderStore.create(root: root, parent: folder, name: "メモ", kind: .note, body: Data("NEW".utf8), journal: journal)
        XCTAssertEqual(note, "Folder/新しいフォルダ/メモ.md")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(note)), Data("NEW".utf8))
        XCTAssertTrue(try journal.versions(vault: LAABrainSaveJournal.vaultID(root), path: note).contains { $0.bytes == Data("NEW".utf8) })
        try Data("ORIGINAL".utf8).write(to: root.appendingPathComponent(note))
        XCTAssertThrowsError(try LAABrainFolderStore.create(root: root, parent: folder, name: "メモ.md", kind: .note, journal: journal))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(note)), Data("ORIGINAL".utf8))
        XCTAssertThrowsError(try LAABrainFolderStore.create(root: root, parent: "Folder", name: "新しいフォルダ", kind: .folder))
        for unsafe in ["", ".hidden", "../escape", "path/name", "x\\y", "note.sync-conflict-20261101-A"] {
            XCTAssertThrowsError(try LAABrainFolderStore.create(root: root, parent: "", name: unsafe, kind: .note), unsafe)
        }
        for unsafe in ["../outside", "linked", ".obsidian"] {
            XCTAssertThrowsError(try LAABrainFolderStore.create(root: root, parent: unsafe, name: "Escape", kind: .note), unsafe)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("Escape.md").path))
    }

}
#endif
