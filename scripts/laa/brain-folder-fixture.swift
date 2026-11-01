#if LAA_BUILD && DEBUG
import Foundation

@main struct BrainFolderFixture {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw NSError(domain: "BrainFolderFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        checks += 1
    }
    static func mustFail(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch { checks += 1; return }
        throw NSError(domain: "BrainFolderFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func main() throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("brain-folder-fixture-" + UUID().uuidString, isDirectory: true)
        let root = work.appendingPathComponent("vault", isDirectory: true)
        let outside = work.appendingPathComponent("outside", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let journal = LAABrainSaveJournal(directory: work.appendingPathComponent("history", isDirectory: true))
        try manager.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        let folder = try LAABrainFolderStore.create(root: root, parent: "", name: "会社", kind: .folder)
        try check(folder == "会社", "root folder")
        let nested = try LAABrainFolderStore.create(root: root, parent: folder, name: "空", kind: .folder)
        try check(nested == "会社/空", "nested folder")
        let note = try LAABrainFolderStore.create(root: root, parent: nested, name: "メモ", kind: .note, body: Data("NEW-BODY".utf8), journal: journal)
        try check(note == "会社/空/メモ.md", "note path")
        try check(manager.fileExists(atPath: root.appendingPathComponent(note).path), "note missing")
        let createdBytes = try Data(contentsOf: root.appendingPathComponent(note))
        try check(createdBytes == Data("NEW-BODY".utf8), "created contents differ")
        try check(!manager.fileExists(atPath: root.appendingPathComponent(".laa-tmp").path), "private creation made fallback folder")
        let versions = try journal.versions(vault: LAABrainSaveJournal.vaultID(root), path: note)
        try check(versions.contains { $0.kind == .draft && $0.bytes == createdBytes }, "new draft not recorded")
        let listing = try LAABrainVaultIO.listing(root: root)
        try check(Set(listing.folders) == Set(["会社", "会社/空"]), "listing lost folders or included hidden/symlink")
        try check(listing.files.map(\.path) == [note], "listing did not include new note")
        try Data("ORIGINAL".utf8).write(to: root.appendingPathComponent(note))
        try mustFail("duplicate note accepted") { _ = try LAABrainFolderStore.create(root: root, parent: nested, name: "メモ.md", kind: .note, journal: journal) }
        let bytes = try Data(contentsOf: root.appendingPathComponent(note))
        try check(bytes == Data("ORIGINAL".utf8), "duplicate replaced note")
        try mustFail("duplicate folder accepted") { _ = try LAABrainFolderStore.create(root: root, parent: folder, name: "空", kind: .folder) }
        for bad in ["", ".hidden", "../escape", "a/b", "x\\y", "x:y", "x.sync-conflict-20261101-A"] {
            try mustFail("unsafe name accepted: \(bad)") { _ = try LAABrainFolderStore.create(root: root, parent: "", name: bad, kind: .note) }
        }
        for bad in ["../outside", "linked", ".obsidian"] {
            try mustFail("unsafe parent accepted: \(bad)") { _ = try LAABrainFolderStore.create(root: root, parent: bad, name: "Escape", kind: .note) }
        }
        try check(!manager.fileExists(atPath: outside.appendingPathComponent("Escape.md").path), "wrote outside vault")
        let ext = try LAABrainFolderStore.create(root: root, parent: "", name: "名前.MD", kind: .note, journal: journal)
        try check(ext == "名前.MD", "duplicated extension")
        try mustFail("racing create replaced peer file") {
            _ = try LAABrainFolderStore.create(root: root, parent: nested, name: "Racing", kind: .note,
                                                body: Data("MY-DRAFT".utf8), journal: journal,
                                                fixtureBeforeRename: {
                try Data("PEER-CONTENT".utf8).write(to: root.appendingPathComponent(nested + "/Racing.md"))
            })
        }
        try check((try? Data(contentsOf: root.appendingPathComponent(nested + "/Racing.md"))) == Data("PEER-CONTENT".utf8),
                  "racing peer content was overwritten")
        let racingVersions = try journal.versions(vault: LAABrainSaveJournal.vaultID(root), path: nested + "/Racing.md")
        try check(racingVersions.contains { $0.bytes == Data("MY-DRAFT".utf8) }, "racing draft was not retained")
        try mustFail("racing fallback replaced peer file") {
            _ = try LAABrainFolderStore.create(root: root, parent: nested, name: "RacingFallback", kind: .note,
                                                body: Data("MY-FALLBACK-DRAFT".utf8), journal: journal, forceFallback: true,
                                                fixtureBeforeRename: {
                try Data("PEER-FALLBACK".utf8).write(to: root.appendingPathComponent(nested + "/RacingFallback.md"))
            })
        }
        try check((try? Data(contentsOf: root.appendingPathComponent(nested + "/RacingFallback.md"))) == Data("PEER-FALLBACK".utf8),
                  "racing fallback overwrote peer")
        let racingFallbackVersions = try journal.versions(vault: LAABrainSaveJournal.vaultID(root), path: nested + "/RacingFallback.md")
        try check(racingFallbackVersions.contains { $0.bytes == Data("MY-FALLBACK-DRAFT".utf8) }, "racing fallback draft missing")
        let fallback = try LAABrainFolderStore.create(root: root, parent: nested, name: "Fallback", kind: .note,
                                                       body: Data("FALLBACK".utf8), journal: journal, forceFallback: true)
        let fallbackBytes = try Data(contentsOf: root.appendingPathComponent(fallback))
        try check(fallbackBytes == Data("FALLBACK".utf8), "fallback contents differ")
        let temps = try manager.contentsOfDirectory(atPath: root.appendingPathComponent(".laa-tmp").path)
        try check(temps.isEmpty, "fallback stage not removed")
        try mustFail("fallback duplicate accepted") {
            _ = try LAABrainFolderStore.create(root: root, parent: nested, name: "Fallback", kind: .note,
                                                body: Data("OTHER".utf8), journal: journal, forceFallback: true)
        }
        try check((try? Data(contentsOf: root.appendingPathComponent(fallback))) == fallbackBytes, "fallback replaced duplicate")
        let selective = work.appendingPathComponent("selective", isDirectory: true)
        try manager.createDirectory(at: selective, withIntermediateDirectories: true)
        let selectiveIgnore = selective.appendingPathComponent(".stignore")
        let selectiveBytes = Data("!/Selected\n*\n".utf8)
        try selectiveBytes.write(to: selectiveIgnore)
        try mustFail("selective fallback accepted") {
            _ = try LAABrainFolderStore.create(root: selective, parent: "", name: "Unsafe", kind: .note,
                                                body: Data("DRAFT".utf8), journal: journal, forceFallback: true)
        }
        try check((try? Data(contentsOf: selectiveIgnore)) == selectiveBytes, "selective settings changed")
        try check(!manager.fileExists(atPath: selective.appendingPathComponent("Unsafe.md").path), "unsafe fallback created note")
        let rejectedHistory = try journal.versions(vault: LAABrainSaveJournal.vaultID(selective), path: "Unsafe.md")
        try check(rejectedHistory.contains { $0.bytes == Data("DRAFT".utf8) }, "rejected draft not retained")
        let lock = NSLock()
        var successes = 0
        var unexpected = 0
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            do {
                _ = try LAABrainFolderStore.create(root: root, parent: "", name: "race", kind: .note, journal: journal)
                lock.lock(); successes += 1; lock.unlock()
            } catch LAABrainFolderStore.Failure.exists {
            } catch {
                lock.lock(); unexpected += 1; lock.unlock()
            }
        }
        try check(successes == 1 && unexpected == 0, "concurrent create did not select one winner")
        print("PASS: \(checks) folder and creation checks")
    }
}
#endif
