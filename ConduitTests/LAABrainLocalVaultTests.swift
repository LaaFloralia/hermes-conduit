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

    #if targetEnvironment(macCatalyst)
    @MainActor func testMacBookmarksMigrateAndSwitchWithoutLosingLegacyOrScope() throws {
        let brain = root.appendingPathComponent("Brain", isDirectory: true)
        let hq = root.appendingPathComponent("hq", isDirectory: true)
        let store = root.appendingPathComponent("bookmarks", isDirectory: true)
        try FileManager.default.createDirectory(at: brain, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hq, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let legacy = try brain.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let legacyURL = store.appendingPathComponent("vault.bookmark")
        try legacy.write(to: legacyURL)
        let suite = "LAABrainLocalVaultTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var acquired: [String] = []; var released: [String] = []
        let vault = LAABrainLocalVault(bookmarkDirectory: store, preferences: defaults, homeDirectory: root,
            beginScope: { acquired.append($0.lastPathComponent); return true },
            endScope: { released.append($0.lastPathComponent) })
        XCTAssertEqual(vault.location, .brain)
        XCTAssertEqual(try vault.snapshot().standardizedFileURL, brain.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: legacyURL), legacy)
        XCTAssertTrue(vault.hasBookmark(.brain))
        vault.select(.hq)
        XCTAssertEqual(defaults.string(forKey: "laa.brain.mac.location"), "Brain")
        XCTAssertEqual(released, ["Brain"])
        XCTAssertFalse(vault.isReady)
        try vault.connect(hq)
        XCTAssertEqual(vault.location, .hq)
        XCTAssertTrue(vault.hasBookmark(.hq))
        XCTAssertEqual(defaults.string(forKey: "laa.brain.mac.location"), "HQ")
        XCTAssertTrue(vault.prepareDaily())
        XCTAssertEqual(released, ["Brain", "hq"])
        XCTAssertEqual(try vault.snapshot().standardizedFileURL, brain.standardizedFileURL)
        let daily = try LAABrainDailyNote.open(root: vault.snapshot())
        XCTAssertTrue(FileManager.default.fileExists(atPath: brain.appendingPathComponent(daily).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hq.appendingPathComponent("daily journal").path))
        XCTAssertEqual(acquired, ["Brain", "hq", "Brain"])
        XCTAssertEqual(try Data(contentsOf: legacyURL), legacy)
    }

    @MainActor func testMacMigrationDoesNotReplaceExistingBookmarkAndMissingBrainCannotOpenDaily() throws {
        let brain = root.appendingPathComponent("Brain", isDirectory: true)
        let other = root.appendingPathComponent("other/Brain", isDirectory: true)
        let store = root.appendingPathComponent("bookmarks", isDirectory: true)
        for directory in [brain, other, store] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let original = try brain.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let existing = try other.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        try original.write(to: store.appendingPathComponent("vault.bookmark"))
        let newURL = store.appendingPathComponent("vault-Brain.bookmark")
        try existing.write(to: newURL)
        let suite = "LAABrainLocalVaultTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = LAABrainLocalVault(bookmarkDirectory: store, preferences: defaults, homeDirectory: root,
                                      beginScope: { _ in true }, endScope: { _ in })
        XCTAssertEqual(try Data(contentsOf: newURL), existing)
        XCTAssertFalse(vault.isReady)
        XCTAssertThrowsError(try vault.snapshot())
        vault.select(.hq)
        XCTAssertFalse(vault.prepareDaily())
        XCTAssertEqual(vault.location, .brain)
        XCTAssertThrowsError(try vault.snapshot())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("daily journal").path))
    }

    @MainActor func testFailedScopeDoesNotPersistNewActiveLocation() throws {
        let brain = root.appendingPathComponent("Brain", isDirectory: true)
        let hq = root.appendingPathComponent("hq", isDirectory: true)
        let store = root.appendingPathComponent("bookmarks", isDirectory: true)
        for directory in [brain, hq, store] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for (url, name) in [(brain, "Brain"), (hq, "HQ")] {
            try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                .write(to: store.appendingPathComponent("vault-\(name).bookmark"))
        }
        let suite = "LAABrainLocalVaultTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Brain", forKey: "laa.brain.mac.location")
        var released: [String] = []
        let vault = LAABrainLocalVault(bookmarkDirectory: store, preferences: defaults, homeDirectory: root,
            beginScope: { $0.lastPathComponent != "hq" }, endScope: { released.append($0.lastPathComponent) })
        XCTAssertTrue(vault.isReady)
        vault.select(.hq)
        XCTAssertEqual(vault.state, .needsAccess)
        XCTAssertEqual(defaults.string(forKey: "laa.brain.mac.location"), "Brain")
        XCTAssertEqual(released, ["Brain"])
        XCTAssertTrue(vault.prepareDaily())
        XCTAssertEqual(vault.location, .brain)
    }

    @MainActor func testMacRejectsHomeAndMismatchedLocation() throws {
        let suite = "LAABrainLocalVaultTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = LAABrainLocalVault(bookmarkDirectory: root, preferences: defaults, homeDirectory: root,
                                       beginScope: { _ in true }, endScope: { _ in })
        vault.select(.brain)
        XCTAssertThrowsError(try vault.connect(root))
        XCTAssertThrowsError(try vault.connect(root.deletingLastPathComponent()))
        let hq = root.appendingPathComponent("hq", isDirectory: true)
        try FileManager.default.createDirectory(at: hq, withIntermediateDirectories: true)
        XCTAssertThrowsError(try vault.connect(hq))
        XCTAssertFalse(vault.hasBookmark(.brain))
        XCTAssertFalse(vault.isReady)
        let noHome = LAABrainLocalVault(bookmarkDirectory: root, preferences: defaults, homeDirectory: nil,
                                        beginScope: { _ in true }, endScope: { _ in })
        noHome.select(.hq)
        XCTAssertThrowsError(try noHome.connect(hq))
        XCTAssertFalse(noHome.isReady)
    }

    @MainActor func testUnknownLegacyBookmarkIsPreservedButNeverOpened() throws {
        let unknown = root.appendingPathComponent("unknown", isDirectory: true)
        let store = root.appendingPathComponent("bookmarks", isDirectory: true)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let data = try unknown.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let legacy = store.appendingPathComponent("vault.bookmark")
        try data.write(to: legacy)
        let suite = "LAABrainLocalVaultTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var scopeCalls = 0
        let vault = LAABrainLocalVault(bookmarkDirectory: store, preferences: defaults, homeDirectory: root,
            beginScope: { _ in scopeCalls += 1; return true }, endScope: { _ in })
        XCTAssertEqual(vault.state, .needsAccess)
        XCTAssertNil(vault.location)
        XCTAssertEqual(scopeCalls, 0)
        XCTAssertEqual(try Data(contentsOf: legacy), data)
        XCTAssertFalse(vault.prepareDaily())
        XCTAssertThrowsError(try vault.snapshot())
    }
    #endif

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
        // Create the symlink first: it must neither expose its target nor make
        // the enumerator skip the real directory that follows it.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Nested"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Nested/alias"), withDestinationURL: outside)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Nested/Actual"), withIntermediateDirectories: true)
        try Data("visible".utf8).write(to: root.appendingPathComponent("Nested/Actual/visible.md"))
        let listing = try LAABrainVaultIO.listing(root: root)
        XCTAssertEqual(Set(listing.folders), Set(["Folder", "Folder/Empty", "Nested", "Nested/Actual"]))
        XCTAssertEqual(Set(listing.files.map(\.path)), Set(["Folder/日本語.md", "Nested/Actual/visible.md"]))
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
