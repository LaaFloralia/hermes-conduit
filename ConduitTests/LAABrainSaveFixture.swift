#if LAA_BUILD && DEBUG
import Foundation
import Darwin
#if !LAA_FIXTURE_CLI
@testable import Conduit
#endif

/// CLI checks for the same journal and coordinator compiled into the iOS app.
/// Call only with disposable synthetic folders, never the user's vault.
struct BrainSaveFixture {
    struct FixtureFailure: Error {}

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw NSError(domain: "BrainFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func tryData(_ url: URL) -> Data? { try? Data(contentsOf: url) }

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
        let normalSummaries = try journal.summaries(vault: normal.vault, path: normal.path)
        try check(normalText == "DRAFT", "exchange did not save draft")
        try check(Set(normalHistory.map(\.kind.rawValue)) == Set(["original", "draft"]), "exchange history incomplete")
        try check(normalHistory.filter { $0.kind != .draft }.allSatisfy { $0.bytes == Data("BASE".utf8) }, "base history incorrect")
        guard let normalDraft = normalSummaries.first(where: { $0.kind == .draft }) else { throw FixtureFailure() }
        let loadedDraft = try journal.version(normalDraft)
        try check(loadedDraft.bytes == Data("DRAFT".utf8), "history did not load selected bytes")

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
        let temporaryDirectory = root.appendingPathComponent(".laa-tmp", isDirectory: true)
        let temporaryFiles = try manager.contentsOfDirectory(atPath: temporaryDirectory.path)
        try check(temporaryFiles.isEmpty, "fallback temporary draft was left in vault")
        let oldTemp = temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tmp")
        let freshTemp = temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tmp")
        let unrelatedTemp = temporaryDirectory.appendingPathComponent("other.tmp")
        for file in [oldTemp, freshTemp, unrelatedTemp] { try Data("TEMP".utf8).write(to: file) }
        try manager.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -48 * 60 * 60)], ofItemAtPath: oldTemp.path)
        _ = try fallback.begin(root: root, path: "fallback.md")
        try check(!manager.fileExists(atPath: oldTemp.path) && manager.fileExists(atPath: freshTemp.path) && manager.fileExists(atPath: unrelatedTemp.path), "fallback cleanup removed the wrong files")
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
        try manager.moveItem(at: root.appendingPathComponent("interrupted.md"), to: root.appendingPathComponent("renamed-interrupted.md"))
        let interruptedCatalogue = try journal.catalogue(vault: interruptedSnapshot.vault)
        try check(interruptedCatalogue.notes.contains { $0.path == "interrupted.md" && $0.pending.count == 1 }, "renamed note's interrupted stage is not discoverable")
        let stage = try journal.stageURL(outstanding[0])
        let stageData = try Data(contentsOf: stage)
        try check(stageData == Data("BETWEEN".utf8), "interrupted displaced stage missing")
        do { try coordinator.acknowledgeMissingStage(outstanding[0]); throw FixtureFailure() }
        catch is LAABrainSaveJournal.JournalError {}
        let stageAfterRefusal = try Data(contentsOf: stage)
        try check(stageAfterRefusal == stageData, "existing interrupted stage was removed without being recorded")
        let preserved = try coordinator.preservePending(outstanding[0])
        try check(preserved.bytes == Data("BETWEEN".utf8), "interrupted version not preserved")
        let remaining = try journal.pending(vault: interruptedSnapshot.vault, path: interruptedSnapshot.path)
        try check(remaining.isEmpty && !manager.fileExists(atPath: stage.path), "preserved stage not cleaned")

        try put("non-utf8-race.md", "BASE")
        var binaryRace = LAABrainSaveCoordinator(journal: journal)
        let binarySnapshot = try binaryRace.begin(root: root, path: "non-utf8-race.md")
        let nonUTF8 = Data([0xff, 0xfe, 0x80])
        binaryRace.fixtureAfterComparison = { try nonUTF8.write(to: root.appendingPathComponent("non-utf8-race.md")) }
        guard case let .intervening(bytes, _) = try binaryRace.save(root: root, snapshot: binarySnapshot, draft: Data("DRAFT".utf8)) else { throw FixtureFailure() }
        let binaryHistory = try journal.versions(vault: binarySnapshot.vault, path: binarySnapshot.path)
        try check(bytes == nonUTF8 && binaryHistory.contains { $0.kind == .displaced && $0.bytes == nonUTF8 }, "non-UTF-8 intervening bytes lost")

        try manager.removeItem(at: root.appendingPathComponent("normal.md"))
        try manager.moveItem(at: root.appendingPathComponent("non-utf8-race.md"), to: root.appendingPathComponent("renamed-binary.md"))
        _ = try journal.record(vault: "another-vault", path: "private.md", kind: .draft, bytes: Data("OTHER VAULT".utf8))
        let catalogue = try journal.catalogue(vault: normal.vault)
        guard let deleted = catalogue.notes.first(where: { $0.path == "normal.md" }),
              let deletedDraft = deleted.versions.first(where: { $0.id == normalDraft.id }),
              let renamed = catalogue.notes.first(where: { $0.path == "non-utf8-race.md" }),
              let binaryVersion = renamed.versions.first(where: { $0.kind == .displaced }) else { throw FixtureFailure() }
        try check(!catalogue.notes.contains { $0.path == "private.md" }, "catalogue exposed another vault")
        guard case let .restored(deletedCopy) = try coordinator.restoreCopy(root: root, summary: deletedDraft),
              case let .restored(binaryCopy) = try coordinator.restoreCopy(root: root, summary: binaryVersion) else { throw FixtureFailure() }
        let deletedBytes = try Data(contentsOf: root.appendingPathComponent(deletedCopy))
        let binaryBytes = try Data(contentsOf: root.appendingPathComponent(binaryCopy))
        let renamedText = try read("renamed-binary.md")
        try check(deletedBytes == Data("DRAFT".utf8) && binaryBytes == nonUTF8 && renamedText == "DRAFT", "deleted or renamed recovery was not byte-exact")
        try check(deletedCopy.hasSuffix(".md") && binaryCopy.hasSuffix(".bin"), "recovery used the wrong extension")
        let export = work.appendingPathComponent("export.bin")
        try nonUTF8.write(to: export)
        try check(LAABrainSaveCoordinator.verifyExport(export, digest: binaryVersion.digest), "matching export rejected")
        try Data([0xff, 0x00]).write(to: export)
        try check(!LAABrainSaveCoordinator.verifyExport(export, digest: binaryVersion.digest), "mismatching export accepted")
        try check(!manager.fileExists(atPath: root.appendingPathComponent("normal.md").path), "recovery recreated or replaced the old path")

        var collision = LAABrainSaveCoordinator(journal: journal)
        var collisionURL: URL?
        collision.fixtureBeforeRecoveryRename = { destination in
            collisionURL = destination
            try Data("EXISTING".utf8).write(to: destination)
        }
        do { _ = try collision.restoreCopy(root: root, summary: binaryVersion); throw FixtureFailure() }
        catch LAABrainSaveCoordinator.SaveError.recoveryDestinationExists {}
        guard let collisionURL else { throw FixtureFailure() }
        let collisionBytes = try Data(contentsOf: collisionURL)
        try check(collisionBytes == Data("EXISTING".utf8), "recovery overwrote a concurrently created file")
        var unsupported = LAABrainSaveCoordinator(journal: journal)
        unsupported.fixtureForceRecoveryFallback = true
        do { _ = try unsupported.restoreCopy(root: root, summary: binaryVersion); throw FixtureFailure() }
        catch LAABrainSaveCoordinator.SaveError.recoveryExportRequired {}
        let stillSaved = try journal.version(binaryVersion)
        try check(stillSaved.bytes == nonUTF8, "unsupported recovery lost the journal version")

        try put("corrupt.md", "BASE")
        let corrupt = try coordinator.begin(root: root, path: "corrupt.md")
        let corruptVersion = try journal.record(vault: corrupt.vault, path: corrupt.path, kind: .draft, bytes: Data("SAVED".utf8))
        guard let enumerator = manager.enumerator(at: privateDir.appendingPathComponent("versions"), includingPropertiesForKeys: nil),
              let corruptFile = enumerator.allObjects.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == corruptVersion.id.uuidString + ".json" }) else { throw FixtureFailure() }
        let corruptBody = corruptFile.deletingPathExtension().appendingPathExtension("bin")
        let metadata = try Data(contentsOf: corruptFile)
        let json = try JSONSerialization.jsonObject(with: metadata) as! [String: Any]
        try check(json["bytes"] == nil && metadata.count < 1024, "history metadata contains body")
        try Data("WRONG".utf8).write(to: corruptBody)
        let corruptSummaries = try journal.summaries(vault: corrupt.vault, path: corrupt.path)
        guard let corruptSummary = corruptSummaries.first(where: { $0.id == corruptVersion.id }) else { throw FixtureFailure() }
        // Listing and validation do not read/hash bodies, only restoration does.
        try journal.validate(vault: corrupt.vault, path: corrupt.path)
        do { _ = try journal.version(corruptSummary); throw FixtureFailure() }
        catch is LAABrainSaveJournal.JournalError {}
        let quarantined = try journal.corruptCount(vault: corrupt.vault, path: corrupt.path)
        try check(quarantined == 1 && manager.fileExists(atPath: corruptFile.path + ".corrupt") && manager.fileExists(atPath: corruptBody.path + ".corrupt"), "damaged bytes not quarantined")
        let invalidFile = corruptFile.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".json")
        try Data("invalid json".utf8).write(to: invalidFile)
        let afterQuarantine = try journal.summaries(vault: corrupt.vault, path: corrupt.path)
        let corruptCount = try journal.corruptCount(vault: corrupt.vault, path: corrupt.path)
        try check(corruptCount == 2 && afterQuarantine.contains { $0.kind == .original }, "damaged metadata blocked healthy history")
        let restarted = try coordinator.begin(root: root, path: "corrupt.md")
        guard case .saved = try coordinator.save(root: root, snapshot: restarted, draft: Data("SAFE".utf8)) else { throw FixtureFailure() }
        let corruptText = try read("corrupt.md")
        let unaffected = try journal.versions(vault: normal.vault, path: normal.path)
        try check(corruptText == "SAFE" && !unaffected.isEmpty, "quarantined history blocked editing or another note")
        let partiallyDamaged = try journal.catalogue(vault: normal.vault)
        try check(partiallyDamaged.unreadable > 0 && partiallyDamaged.notes.contains { $0.path == "normal.md" }, "catalogue lost healthy records")

        // Records are capped independently per note, oldest first.
        for index in 0..<35 {
            _ = try journal.record(vault: normal.vault, path: "retention.md", kind: .draft, bytes: Data("version-\(index)".utf8))
        }
        let retained = try journal.versions(vault: normal.vault, path: "retention.md")
        try check(retained.count == 30 && !retained.contains { $0.bytes == Data("version-0".utf8) } && retained.contains { $0.bytes == Data("version-34".utf8) }, "per-note retention incorrect")
        let unrelatedVersions = try journal.versions(vault: normal.vault, path: normal.path)
        try check(!unrelatedVersions.isEmpty, "retention removed another note")

        // Old debug fixtures had inline base64. Convert without discarding bytes.
        let legacy = LAABrainSaveJournal.Version(id: UUID(), vault: corrupt.vault, path: corrupt.path,
            kind: .draft, created: Date(), bytes: Data("LEGACY".utf8), digest: LAABrainSaveJournal.digest(Data("LEGACY".utf8)))
        let legacyFile = corruptFile.deletingLastPathComponent().appendingPathComponent(legacy.id.uuidString + ".json")
        try JSONEncoder().encode(legacy).write(to: legacyFile)
        let migrated = try journal.summaries(vault: corrupt.vault, path: corrupt.path)
        guard let legacySummary = migrated.first(where: { $0.id == legacy.id }) else { throw FixtureFailure() }
        let legacyBytes = try journal.version(legacySummary).bytes
        let migratedJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyFile)) as! [String: Any]
        try check(legacyBytes == legacy.bytes && migratedJSON["bytes"] == nil, "inline history migration lost bytes")

        // A disappeared stage after creation must leave the manifest and draft.
        try put("missing-stage.md", "BASE")
        var missingStage = LAABrainSaveCoordinator(journal: journal)
        let missingSnapshot = try missingStage.begin(root: root, path: "missing-stage.md")
        missingStage.fixtureStagePrepared = { try manager.removeItem(at: $0) }
        do { _ = try missingStage.save(root: root, snapshot: missingSnapshot, draft: Data("MINE".utf8)); throw FixtureFailure() }
        catch is LAABrainSaveCoordinator.SaveError {}
        let missingPending = try journal.pending(vault: missingSnapshot.vault, path: missingSnapshot.path)
        let missingVersions = try journal.versions(vault: missingSnapshot.vault, path: missingSnapshot.path)
        try check(missingPending.count == 1 && missingVersions.contains { $0.kind == .draft && $0.bytes == Data("MINE".utf8) }, "missing stage lost manifest or draft")
        do { _ = try coordinator.preservePending(missingPending[0]); throw FixtureFailure() }
        catch LAABrainSaveCoordinator.SaveError.missingStage {}
        try coordinator.acknowledgeMissingStage(missingPending[0])
        try check(tryData(root.appendingPathComponent("missing-stage.md")) == Data("BASE".utf8), "missing stage changed note")

        for name in ["conflict.sync-conflict-20261101-ABC.md", "ノート（GitHub競合 2026）.md"] {
            try put(name, "CONFLICT")
            do { _ = try coordinator.begin(root: root, path: name); throw FixtureFailure() }
            catch LAABrainSaveCoordinator.SaveError.conflictCopy {}
            let synthetic = LAABrainSaveCoordinator.Snapshot(vault: normal.vault, path: name, base: Data("CONFLICT".utf8))
            do { _ = try coordinator.save(root: root, snapshot: synthetic, draft: Data("REPLACE".utf8)); throw FixtureFailure() }
            catch LAABrainSaveCoordinator.SaveError.conflictCopy {}
            try check(tryData(root.appendingPathComponent(name)) == Data("CONFLICT".utf8), "conflict copy was overwritten")
        }

        let oldRecovery = privateDir.appendingPathComponent("staging").appendingPathComponent(UUID().uuidString + ".recovery")
        let freshRecovery = privateDir.appendingPathComponent("staging").appendingPathComponent(UUID().uuidString + ".recovery")
        let protectedStage = privateDir.appendingPathComponent("staging").appendingPathComponent(UUID().uuidString + ".stage")
        for file in [oldRecovery, freshRecovery, protectedStage] { try Data("TEMP".utf8).write(to: file) }
        for file in [oldRecovery, protectedStage] { try manager.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -48 * 60 * 60)], ofItemAtPath: file.path) }
        try journal.prepare()
        try check(!manager.fileExists(atPath: oldRecovery.path) && manager.fileExists(atPath: freshRecovery.path) && manager.fileExists(atPath: protectedStage.path), "recovery stage cleanup removed the wrong file")

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
        do { _ = try coordinator.preservePending(failedPending[0]); throw FixtureFailure() }
        catch LAABrainSaveCoordinator.SaveError.missingStage {}
        let notCleared = try journal.pending(vault: failedSnapshot.vault, path: failedSnapshot.path)
        try check(notCleared.count == 1, "missing stage silently cleared")
        try coordinator.acknowledgeMissingStage(failedPending[0])

        let outside = work.appendingPathComponent("outside.md")
        try Data("OUTSIDE".utf8).write(to: outside)
        try manager.createSymbolicLink(at: root.appendingPathComponent("link.md"), withDestinationURL: outside)
        for path in ["../outside.md", "link.md", ".git/config.md"] {
            do { _ = try coordinator.begin(root: root, path: path); throw FixtureFailure() }
            catch is LAABrainSaveCoordinator.SaveError {} catch is CocoaError {}
        }
        try put("swap-symlink.md", "BASE")
        var symlinkRace = LAABrainSaveCoordinator(journal: journal)
        let symlinkSnapshot = try symlinkRace.begin(root: root, path: "swap-symlink.md")
        symlinkRace.fixtureBeforeStage = {
            let note = root.appendingPathComponent("swap-symlink.md")
            try manager.removeItem(at: note)
            try manager.createSymbolicLink(at: note, withDestinationURL: outside)
        }
        do { _ = try symlinkRace.save(root: root, snapshot: symlinkSnapshot, draft: Data("MINE".utf8)); throw FixtureFailure() }
        catch LAABrainSaveCoordinator.SaveError.notRegularFile {}
        let symlinkPending = try journal.pending(vault: symlinkSnapshot.vault, path: symlinkSnapshot.path)
        try check(symlinkPending.count == 1 && tryData(outside) == Data("OUTSIDE".utf8), "source symlink was followed")
        try coordinator.acknowledgeMissingStage(symlinkPending[0])

        try put("swap-fifo.md", "BASE")
        var fifoRace = LAABrainSaveCoordinator(journal: journal)
        let fifoSnapshot = try fifoRace.begin(root: root, path: "swap-fifo.md")
        fifoRace.fixtureBeforeStage = {
            let note = root.appendingPathComponent("swap-fifo.md")
            try manager.removeItem(at: note)
            guard mkfifo(note.path, 0o600) == 0 else { throw FixtureFailure() }
        }
        do { _ = try fifoRace.save(root: root, snapshot: fifoSnapshot, draft: Data("MINE".utf8)); throw FixtureFailure() }
        catch LAABrainSaveCoordinator.SaveError.notRegularFile {}
        let fifoPending = try journal.pending(vault: fifoSnapshot.vault, path: fifoSnapshot.path)
        try check(fifoPending.count == 1, "FIFO race lost its pending manifest")
        try coordinator.acknowledgeMissingStage(fifoPending[0])
        try manager.removeItem(at: root.appendingPathComponent("swap-fifo.md"))

        let otherRoot = work.appendingPathComponent("symlink-temp-vault", isDirectory: true)
        let outsideFolder = work.appendingPathComponent("outside-folder", isDirectory: true)
        try manager.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        try manager.createDirectory(at: outsideFolder, withIntermediateDirectories: true)
        try Data("BASE".utf8).write(to: otherRoot.appendingPathComponent("note.md"))
        try manager.createSymbolicLink(at: otherRoot.appendingPathComponent(".laa-tmp"), withDestinationURL: outsideFolder)
        var unsafeFallback = LAABrainSaveCoordinator(journal: journal)
        unsafeFallback.fixtureForceFallback = true
        let safeSnapshot = try unsafeFallback.begin(root: otherRoot, path: "note.md")
        do { _ = try unsafeFallback.save(root: otherRoot, snapshot: safeSnapshot, draft: Data("MINE".utf8)); throw FixtureFailure() }
        catch LAABrainSaveCoordinator.SaveError.invalidPath {}
        let unsafePending = try journal.pending(vault: safeSnapshot.vault, path: safeSnapshot.path)
        let outsideFiles = try manager.contentsOfDirectory(atPath: outsideFolder.path)
        try check(unsafePending.count == 1 && outsideFiles.isEmpty && tryData(otherRoot.appendingPathComponent("note.md")) == Data("BASE".utf8), "fallback followed a symlink directory")
        _ = try coordinator.preservePending(unsafePending[0])

        let suspicious = try journal.makePending(vault: normal.vault, path: "synthetic.md", base: Data(), draft: Data())
        let suspiciousStage = try journal.stageURL(suspicious)
        try manager.createSymbolicLink(at: suspiciousStage, withDestinationURL: outside)
        do { _ = try coordinator.preservePending(suspicious); throw FixtureFailure() }
        catch is LAABrainSaveJournal.JournalError {}
        let stillPending = try journal.pending(vault: normal.vault, path: "synthetic.md")
        let outsideText = try String(contentsOf: outside, encoding: .utf8)
        try check(stillPending.count == 1 && outsideText == "OUTSIDE", "unsafe stage was followed or manifest removed")
        try manager.removeItem(at: suspiciousStage)
        try coordinator.acknowledgeMissingStage(suspicious)
        print("PASS: Swift exchange, conflict, fallback, missing stages, quarantine, retention, migration, export, binary and deleted/renamed recovery")
    }
}
#endif
