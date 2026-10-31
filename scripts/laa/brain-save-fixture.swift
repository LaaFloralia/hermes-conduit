#if LAA_BUILD && DEBUG
import Foundation
import Darwin

/// CLI checks for the same journal and coordinator compiled into the iOS app.
/// Call only with disposable synthetic folders, never the user's vault.
@main struct BrainSaveFixture {
    struct FixtureFailure: Error {}

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw NSError(domain: "BrainFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { throw FixtureFailure() }
        let root = URL(fileURLWithPath: args[2], isDirectory: true)
        if args[1] == "selftest" { try selftest(root); return }
        guard args[1] == "race", args.count == 7 || args.count == 8 else { throw FixtureFailure() }
        let journal = LAABrainSaveJournal(directory: URL(fileURLWithPath: args[3], isDirectory: true))
        var coordinator = LAABrainSaveCoordinator(journal: journal)
        let path = args[4]
        let snap = try coordinator.begin(root: root, path: path)
        if args.count == 8, args[7] == "change-metadata" {
            coordinator.fixtureStagePrepared = { stage in
                try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 946684800),
                                                       .posixPermissions: 0o600], ofItemAtPath: stage.path)
                let value = Data("changed-xattr".utf8)
                let result = value.withUnsafeBytes { bytes in
                    setxattr(stage.path, "com.laa.fixture", bytes.baseAddress, bytes.count, 0, 0)
                }
                guard result == 0 else { throw FixtureFailure() }
            }
        }
        coordinator.fixtureAfterComparison = { try Data(args[6].utf8).write(to: root.appendingPathComponent(path)) }
        let outcome = try coordinator.save(root: root, snapshot: snap, draft: Data(args[5].utf8))
        guard case let .intervening(displaced, draft) = outcome else { throw FixtureFailure() }
        let versions = try journal.versions(vault: snap.vault, path: path)
        try check(displaced == Data(args[6].utf8) && draft == Data(args[5].utf8), "intervening and draft mismatch")
        try check(versions.contains { $0.kind == .displaced && $0.bytes == displaced }, "displaced journal entry missing")
        let json: [String: Any] = ["outcome": "intervening", "journalKinds": versions.map { $0.kind.rawValue }]
        print(String(decoding: try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), as: UTF8.self))
    }

    static func selftest(_ work: URL) throws {
        let manager = FileManager.default
        let root = work.appendingPathComponent("notes", isDirectory: true)
        let privateDir = work.appendingPathComponent("private", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let journal = LAABrainSaveJournal(directory: privateDir)
        let coordinator = LAABrainSaveCoordinator(journal: journal)
        func put(_ path: String, _ content: String) throws { try Data(content.utf8).write(to: root.appendingPathComponent(path)) }
        func read(_ path: String) throws -> String { String(decoding: try Data(contentsOf: root.appendingPathComponent(path)), as: UTF8.self) }

        try put("normal.md", "BASE")
        let normal = try coordinator.begin(root: root, path: "normal.md")
        guard case .saved(.exchange) = try coordinator.save(root: root, snapshot: normal, draft: Data("DRAFT".utf8)) else { throw FixtureFailure() }
        let normalText = try read("normal.md")
        let normalHistory = try journal.versions(vault: normal.vault, path: normal.path)
        try check(normalText == "DRAFT", "exchange did not save draft")
        try check(Set(normalHistory.map(\.kind.rawValue)) == Set(["original", "draft", "displaced"]), "exchange history incomplete")
        try check(normalHistory.filter { $0.kind != .draft }.allSatisfy { $0.bytes == Data("BASE".utf8) }, "base history incorrect")

        try put("conflict.md", "BASE")
        let conflict = try coordinator.begin(root: root, path: "conflict.md")
        try put("conflict.md", "OTHER")
        guard case let .conflict(current, draft) = try coordinator.save(root: root, snapshot: conflict, draft: Data("MINE".utf8)) else { throw FixtureFailure() }
        let conflictText = try read("conflict.md")
        let conflictHistory = try journal.versions(vault: conflict.vault, path: conflict.path)
        try check(current == Data("OTHER".utf8) && draft == Data("MINE".utf8) && conflictText == "OTHER", "conflict modified original")
        try check(conflictHistory.contains { $0.kind == .conflict && $0.bytes == current }, "conflict history missing")

        try put("fallback.md", "BASE")
        var fallback = LAABrainSaveCoordinator(journal: journal)
        fallback.fixtureForceFallback = true
        let fallbackSnapshot = try fallback.begin(root: root, path: "fallback.md")
        guard case .saved(.checkedReplacement) = try fallback.save(root: root, snapshot: fallbackSnapshot, draft: Data("FALLBACK".utf8)) else { throw FixtureFailure() }
        let fallbackText = try read("fallback.md")
        let fallbackHistory = try journal.versions(vault: fallbackSnapshot.vault, path: fallbackSnapshot.path)
        try check(fallbackText == "FALLBACK", "fallback did not save")
        try check(fallbackHistory.contains { $0.kind == .draft && $0.bytes == Data("FALLBACK".utf8) }, "fallback draft not retained")

        try put("fallback-conflict.md", "BASE")
        let fallbackConflict = try fallback.begin(root: root, path: "fallback-conflict.md")
        fallback.fixtureAfterComparison = { try put("fallback-conflict.md", "OTHER") }
        guard case .conflict = try fallback.save(root: root, snapshot: fallbackConflict, draft: Data("MINE".utf8)) else { throw FixtureFailure() }
        let fallbackConflictText = try read("fallback-conflict.md")
        try check(fallbackConflictText == "OTHER", "fallback did not recheck hash")

        try put("interrupted.md", "BASE")
        var interrupted = LAABrainSaveCoordinator(journal: journal)
        let interruptedSnapshot = try interrupted.begin(root: root, path: "interrupted.md")
        interrupted.fixtureAfterComparison = { try put("interrupted.md", "BETWEEN") }
        interrupted.fixtureAfterExchange = { throw FixtureFailure() }
        do {
            _ = try interrupted.save(root: root, snapshot: interruptedSnapshot, draft: Data("DRAFT".utf8))
            throw NSError(domain: "BrainFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "injected interruption did not fire"])
        } catch is FixtureFailure {}
        let outstanding = try journal.pending(vault: interruptedSnapshot.vault, path: interruptedSnapshot.path)
        try check(outstanding.count == 1, "interrupted exchange manifest missing")
        let stage = try journal.stageURL(outstanding[0])
        let stageData = try Data(contentsOf: stage)
        try check(stageData == Data("BETWEEN".utf8), "interrupted displaced stage missing")
        let preserved = try coordinator.preservePending(outstanding[0])
        try check(preserved?.bytes == Data("BETWEEN".utf8), "interrupted version not preserved")
        let remaining = try journal.pending(vault: interruptedSnapshot.vault, path: interruptedSnapshot.path)
        try check(remaining.isEmpty && !manager.fileExists(atPath: stage.path), "preserved stage not cleaned")

        // A private-storage write failure must happen before touching the note.
        try put("storage-failure.md", "BASE")
        let failedSnapshot = try coordinator.begin(root: root, path: "storage-failure.md")
        let staging = privateDir.appendingPathComponent("staging", isDirectory: true)
        var failing = LAABrainSaveCoordinator(journal: journal)
        failing.fixtureBeforeStage = { try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: staging.path) }
        do {
            _ = try failing.save(root: root, snapshot: failedSnapshot, draft: Data("DRAFT".utf8))
            throw FixtureFailure()
        } catch is FixtureFailure { throw FixtureFailure() }
        catch {}
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
        let failedText = try read("storage-failure.md")
        let failedPending = try journal.pending(vault: failedSnapshot.vault, path: failedSnapshot.path)
        let failedVersions = try journal.versions(vault: failedSnapshot.vault, path: failedSnapshot.path)
        try check(failedText == "BASE" && failedPending.count == 1, "storage failure modified the note or lost the manifest")
        try check(failedVersions.contains { $0.kind == .draft && $0.bytes == Data("DRAFT".utf8) }, "draft lost on storage failure")
        _ = try coordinator.preservePending(failedPending[0])

        let outside = work.appendingPathComponent("outside.md")
        try Data("OUTSIDE".utf8).write(to: outside)
        try manager.createSymbolicLink(at: root.appendingPathComponent("link.md"), withDestinationURL: outside)
        for path in ["../outside.md", "link.md", ".git/config.md"] {
            do { _ = try coordinator.begin(root: root, path: path); throw FixtureFailure() }
            catch is LAABrainSaveCoordinator.SaveError {} catch is CocoaError {}
        }
        let suspicious = try journal.makePending(vault: normal.vault, path: "synthetic.md", base: Data(), draft: Data())
        let suspiciousStage = try journal.stageURL(suspicious)
        try manager.createSymbolicLink(at: suspiciousStage, withDestinationURL: outside)
        do { _ = try coordinator.preservePending(suspicious); throw FixtureFailure() }
        catch is LAABrainSaveJournal.JournalError {}
        let stillPending = try journal.pending(vault: normal.vault, path: "synthetic.md")
        let outsideText = try String(contentsOf: outside, encoding: .utf8)
        try check(stillPending.count == 1 && outsideText == "OUTSIDE", "unsafe stage was followed or manifest removed")
        try manager.removeItem(at: suspiciousStage)
        _ = try coordinator.preservePending(suspicious)
        print("PASS: real Swift journal and save coordinator: exchange, conflict, fallback, interruption and storage failure recovery, path checks")
    }
}
#endif
