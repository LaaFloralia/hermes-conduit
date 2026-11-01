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
        let ignoreFile = root.appendingPathComponent(".stignore")
        try Data("// existing rule\nother-pattern".utf8).write(to: ignoreFile)
        try check(LAABrainSaveCoordinator.ensureFallbackIgnored(root: root), "ignore rule was not installed")
        let ignoreBytes = try Data(contentsOf: ignoreFile)
        try check(ignoreBytes == Data("// existing rule\nother-pattern\n.laa-tmp\n".utf8), "existing ignore bytes changed")
        try check(LAABrainSaveCoordinator.ensureFallbackIgnored(root: root) && tryData(ignoreFile) == ignoreBytes, "ignore rule duplicated")
        let selective = work.appendingPathComponent("selective", isDirectory: true)
        try manager.createDirectory(at: selective, withIntermediateDirectories: true)
        let selectiveIgnore = selective.appendingPathComponent(".stignore")
        let selectiveBytes = Data("!/selected\n*\n".utf8)
        try selectiveBytes.write(to: selectiveIgnore)
        try check(!LAABrainSaveCoordinator.ensureFallbackIgnored(root: selective) && tryData(selectiveIgnore) == selectiveBytes,
                  "selective SyncTrain ignore changed")
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
        try check(!manager.fileExists(atPath: root.appendingPathComponent(".laa-tmp").path), "opening created the fallback folder")
        guard case .saved(.checkedReplacement) = try fallback.save(root: root, snapshot: fallbackSnapshot, draft: Data("FALLBACK".utf8)) else { throw FixtureFailure() }
        let temporaryDirectory = root.appendingPathComponent(".laa-tmp", isDirectory: true)
        let temporaryFiles = try manager.contentsOfDirectory(atPath: temporaryDirectory.path)
        try check(temporaryFiles.isEmpty, "fallback temporary draft was left in vault")
        let oldTemp = temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tmp")
        let freshTemp = temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tmp")
        let unrelatedTemp = temporaryDirectory.appendingPathComponent("other.tmp")
        for file in [oldTemp, freshTemp, unrelatedTemp] { try Data("TEMP".utf8).write(to: file) }
        try manager.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -48 * 60 * 60)], ofItemAtPath: oldTemp.path)
        let cleanupSnapshot = try fallback.begin(root: root, path: "fallback.md")
        _ = try fallback.save(root: root, snapshot: cleanupSnapshot, draft: Data("FALLBACK".utf8))
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

        // Reopening and saving unchanged text must not consume history slots,
        // and unique displaced/interrupted records are outside the 30 slots.
        try put("noop.md", "UNCHANGED")
        let noop = try coordinator.begin(root: root, path: "noop.md")
        _ = try journal.record(vault: noop.vault, path: noop.path, kind: .displaced, bytes: Data("UNIQUE-DISPLACED".utf8))
        _ = try journal.record(vault: noop.vault, path: noop.path, kind: .interrupted, bytes: Data("UNIQUE-INTERRUPTED".utf8))
        for index in 0..<35 {
            _ = try journal.record(vault: noop.vault, path: noop.path, kind: .draft, bytes: Data("change-\(index)".utf8))
        }
        for _ in 0..<35 {
            let snapshot = try coordinator.begin(root: root, path: "noop.md")
            _ = try coordinator.save(root: root, snapshot: snapshot, draft: snapshot.base)
        }
        let noopHistory = try journal.versions(vault: noop.vault, path: noop.path)
        try check(noopHistory.filter { $0.kind == .original || $0.kind == .draft || $0.kind == .conflict }.count == 30,
                  "no-op consumed retention slots")
        try check(noopHistory.contains { $0.bytes == Data("UNIQUE-DISPLACED".utf8) } &&
                  noopHistory.contains { $0.bytes == Data("UNIQUE-INTERRUPTED".utf8) } &&
                  noopHistory.filter { $0.bytes == Data("UNCHANGED".utf8) }.count == 1,
                  "no-op removed protected versions or duplicated the unchanged version")

        func metadataFile(_ id: UUID) throws -> URL {
            guard let enumerator = manager.enumerator(at: privateDir.appendingPathComponent("versions"), includingPropertiesForKeys: nil),
                  let file = enumerator.allObjects.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == id.uuidString + ".json" }) else { throw FixtureFailure() }
            return file
        }
        func makeSparse(_ file: URL, size: Int) throws {
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            object["byteCount"] = size
            try JSONSerialization.data(withJSONObject: object).write(to: file)
            let body = file.deletingPathExtension().appendingPathExtension("bin")
            let fd = open(body.path, O_WRONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw FixtureFailure() }
            defer { close(fd) }
            guard ftruncate(fd, off_t(size)) == 0 else { throw FixtureFailure() }
        }

        // Sparse synthetic records exercise the real 128 MiB limit without
        // allocating 128 MiB of disk or reading/hash-checking bodies during lists.
        let oldLarge = try journal.record(vault: noop.vault, path: "quota.md", kind: .draft, bytes: Data("a".utf8))
        let oldLargeFile = try metadataFile(oldLarge.id)
        try makeSparse(oldLargeFile, size: 128 * 1024 * 1024 - 512)
        _ = try journal.record(vault: noop.vault, path: "quota.md", kind: .draft, bytes: Data(repeating: 7, count: 1024))
        try check(!manager.fileExists(atPath: oldLargeFile.path) &&
                  !manager.fileExists(atPath: oldLargeFile.deletingPathExtension().appendingPathExtension("bin").path),
                  "byte quota did not remove the old metadata and body")

        let protectedLarge = try journal.record(vault: noop.vault, path: "protected-quota.md", kind: .displaced, bytes: Data("b".utf8))
        let protectedFile = try metadataFile(protectedLarge.id)
        try makeSparse(protectedFile, size: 128 * 1024 * 1024 - 256)
        let protectedPending = try journal.makePending(vault: noop.vault, path: "protected-quota.md", base: Data(), draft: Data())
        let protectedPendingStage = try journal.stageURL(protectedPending)
        try Data("UNIQUE-STAGE".utf8).write(to: protectedPendingStage)
        do {
            _ = try journal.record(vault: noop.vault, path: "protected-quota.md", kind: .interrupted, bytes: Data(repeating: 9, count: 1024))
            throw FixtureFailure()
        } catch LAABrainSaveJournal.JournalError.capacity {}
        try check(manager.fileExists(atPath: protectedFile.path) && tryData(protectedPendingStage) == Data("UNIQUE-STAGE".utf8),
                  "capacity limit removed a protected version or pending stage")
        try journal.finish(protectedPending)
        try manager.removeItem(at: protectedFile)
        try manager.removeItem(at: protectedFile.deletingPathExtension().appendingPathExtension("bin"))

        try put("post-swap-quota.md", "BASE")
        var quotaRace = LAABrainSaveCoordinator(journal: journal)
        let quotaSnapshot = try quotaRace.begin(root: root, path: "post-swap-quota.md")
        let quotaProtected = try journal.record(vault: quotaSnapshot.vault, path: quotaSnapshot.path, kind: .displaced, bytes: Data("z".utf8))
        let quotaProtectedFile = try metadataFile(quotaProtected.id)
        try makeSparse(quotaProtectedFile, size: 128 * 1024 * 1024 - 4096)
        let interveningLarge = Data(repeating: 65, count: 8192)
        quotaRace.fixtureAfterComparison = { try interveningLarge.write(to: root.appendingPathComponent("post-swap-quota.md")) }
        do { _ = try quotaRace.save(root: root, snapshot: quotaSnapshot, draft: Data("DRAFT".utf8)); throw FixtureFailure() }
        catch LAABrainSaveCoordinator.SaveError.recoveryPending {}
        let quotaPending = try journal.pending(vault: quotaSnapshot.vault, path: quotaSnapshot.path)
        guard let quotaItem = quotaPending.first else { throw FixtureFailure() }
        let exportedStage = try coordinator.pendingBytes(quotaItem)
        try check(quotaPending.count == 1 && exportedStage == interveningLarge &&
                  tryData(root.appendingPathComponent("post-swap-quota.md")) == Data("DRAFT".utf8),
                  "post-swap quota failure lost the intervening version")
        try manager.removeItem(at: quotaProtectedFile)
        try manager.removeItem(at: quotaProtectedFile.deletingPathExtension().appendingPathExtension("bin"))
        _ = try coordinator.preservePending(quotaItem)

        // Unknown future schemas are reported but never quarantined or pruned.
        let future = try journal.record(vault: noop.vault, path: "future.md", kind: .draft, bytes: Data("FUTURE".utf8))
        let futureFile = try metadataFile(future.id)
        var futureJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: futureFile)) as! [String: Any]
        futureJSON["schema"] = 42
        futureJSON.removeValue(forKey: "kind")
        try JSONSerialization.data(withJSONObject: futureJSON).write(to: futureFile)
        let unknown = try journal.unreadableCount(vault: noop.vault, path: "future.md")
        let unknownCatalogue = try journal.catalogue(vault: noop.vault)
        try check(unknown == 1 && unknownCatalogue.unreadable > 0 && manager.fileExists(atPath: futureFile.path) &&
                  !manager.fileExists(atPath: futureFile.path + ".corrupt"), "future schema was quarantined")

        // Aged detached and quarantined files are removed, recent/live data is not.
        let cleanupFolder = oldLargeFile.deletingLastPathComponent()
        let oldOrphan = cleanupFolder.appendingPathComponent(UUID().uuidString + ".bin")
        let freshOrphan = cleanupFolder.appendingPathComponent(UUID().uuidString + ".bin")
        let corruptID = UUID().uuidString
        let agedCorrupt = [cleanupFolder.appendingPathComponent(corruptID + ".json.corrupt"),
                           cleanupFolder.appendingPathComponent(corruptID + ".bin.corrupt")]
        let freshCorrupt = cleanupFolder.appendingPathComponent(UUID().uuidString + ".bin.corrupt")
        for file in [oldOrphan, freshOrphan, freshCorrupt] + agedCorrupt { try Data("x".utf8).write(to: file) }
        for file in [oldOrphan] + agedCorrupt {
            try manager.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -48 * 60 * 60)], ofItemAtPath: file.path)
        }
        try journal.prepare()
        try check(!manager.fileExists(atPath: oldOrphan.path) && agedCorrupt.allSatisfy { !manager.fileExists(atPath: $0.path) } &&
                  manager.fileExists(atPath: freshOrphan.path) && manager.fileExists(atPath: freshCorrupt.path), "orphan cleanup removed the wrong files")

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

        for name in ["conflict.sync-conflict-20261101-ABC.md", "ノート（GitHub競合 2026）.md", "Note (conflicted copy 2026).md"] {
            try put(name, "CONFLICT")
            do { _ = try coordinator.begin(root: root, path: name); throw FixtureFailure() }
            catch LAABrainSaveCoordinator.SaveError.conflictCopy {}
            let synthetic = LAABrainSaveCoordinator.Snapshot(vault: normal.vault, path: name, base: Data("CONFLICT".utf8))
            do { _ = try coordinator.save(root: root, snapshot: synthetic, draft: Data("REPLACE".utf8)); throw FixtureFailure() }
            catch LAABrainSaveCoordinator.SaveError.conflictCopy {}
            try check(tryData(root.appendingPathComponent(name)) == Data("CONFLICT".utf8), "conflict copy was overwritten")
        }
        try check(LAABrainSaveCoordinator.conflictOriginalPath("Folder/Note (conflicted copy 2026).md") == "Folder/Note.md" &&
                  LAABrainSaveCoordinator.conflictOriginalPath("ノート（GitHub競合 2026）.md") == "ノート.md", "conflict original link incorrect")

        // A successful rename with a failed directory sync leaves recovery pending.
        for forceFallback in [false, true] {
            let name = forceFallback ? "durability-fallback.md" : "durability-swap.md"
            try put(name, "BASE")
            var failedSync = LAABrainSaveCoordinator(journal: journal)
            failedSync.fixtureForceFallback = forceFallback
            failedSync.fixtureDirectorySyncFails = true
            let snap = try failedSync.begin(root: root, path: name)
            do { _ = try failedSync.save(root: root, snapshot: snap, draft: Data("DRAFT".utf8)); throw FixtureFailure() }
            catch LAABrainSaveCoordinator.SaveError.durabilityUncertain {}
            let pendingSync = try journal.pending(vault: snap.vault, path: name)
            guard let pendingItem = pendingSync.first else { throw FixtureFailure() }
            let pendingStage = try journal.stageURL(pendingItem)
            try check(tryData(root.appendingPathComponent(name)) == Data("DRAFT".utf8) && pendingSync.count == 1 &&
                      tryData(pendingStage) != nil, "failed directory sync lost pending stage")
            _ = try coordinator.preservePending(pendingSync[0])
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

        // Swap a whole intermediate directory for a symlink after comparison.
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        let movedNested = root.appendingPathComponent("moved-nested", isDirectory: true)
        let externalNested = work.appendingPathComponent("external-nested", isDirectory: true)
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        try manager.createDirectory(at: externalNested, withIntermediateDirectories: true)
        try Data("BASE".utf8).write(to: nested.appendingPathComponent("note.md"))
        try Data("OUTSIDE".utf8).write(to: externalNested.appendingPathComponent("note.md"))
        var parentRace = LAABrainSaveCoordinator(journal: journal)
        let parentSnapshot = try parentRace.begin(root: root, path: "nested/note.md")
        parentRace.fixtureAfterComparison = {
            try manager.moveItem(at: nested, to: movedNested)
            try manager.createSymbolicLink(at: nested, withDestinationURL: externalNested)
        }
        do { _ = try parentRace.save(root: root, snapshot: parentSnapshot, draft: Data("MINE".utf8)); throw FixtureFailure() }
        catch LAABrainSaveCoordinator.SaveError.invalidPath {}
        let parentPending = try journal.pending(vault: parentSnapshot.vault, path: parentSnapshot.path)
        try check(parentPending.count == 1 && tryData(externalNested.appendingPathComponent("note.md")) == Data("OUTSIDE".utf8) &&
                  tryData(movedNested.appendingPathComponent("note.md")) == Data("BASE".utf8), "intermediate symlink race changed a note")
        _ = try coordinator.preservePending(parentPending[0])

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
        catch LAABrainSaveCoordinator.SaveError.recoveryExportRequired {}
        let unsafePending = try journal.pending(vault: safeSnapshot.vault, path: safeSnapshot.path)
        let outsideFiles = try manager.contentsOfDirectory(atPath: outsideFolder.path)
        try check(unsafePending.isEmpty && outsideFiles.isEmpty && tryData(otherRoot.appendingPathComponent("note.md")) == Data("BASE".utf8), "fallback followed a symlink directory")

        let ignoredRoot = work.appendingPathComponent("unsafe-ignore-vault", isDirectory: true)
        try manager.createDirectory(at: ignoredRoot, withIntermediateDirectories: true)
        try Data("!/anything\n".utf8).write(to: ignoredRoot.appendingPathComponent(".stignore"))
        try Data("BASE".utf8).write(to: ignoredRoot.appendingPathComponent("note.md"))
        try check(!LAABrainSaveCoordinator.ensureFallbackIgnored(root: ignoredRoot), "earlier negation should block fallback")
        let unsafeIgnoreSnapshot = try unsafeFallback.begin(root: ignoredRoot, path: "note.md")
        do { _ = try unsafeFallback.save(root: ignoredRoot, snapshot: unsafeIgnoreSnapshot, draft: Data("DRAFT".utf8)); throw FixtureFailure() }
        catch LAABrainSaveCoordinator.SaveError.recoveryExportRequired {}
        let unsafeIgnorePending = try journal.pending(vault: unsafeIgnoreSnapshot.vault, path: "note.md")
        try check(unsafeIgnorePending.isEmpty && !manager.fileExists(atPath: ignoredRoot.appendingPathComponent(".laa-tmp").path) &&
                  tryData(ignoredRoot.appendingPathComponent("note.md")) == Data("BASE".utf8), "unsafe ignore allowed fallback")

        let readonlyRoot = work.appendingPathComponent("readonly-ignore-vault", isDirectory: true)
        try manager.createDirectory(at: readonlyRoot, withIntermediateDirectories: true)
        let readonlyIgnore = readonlyRoot.appendingPathComponent(".stignore")
        try Data("// read only\n".utf8).write(to: readonlyIgnore)
        try manager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: readonlyIgnore.path)
        try check(!LAABrainSaveCoordinator.ensureFallbackIgnored(root: readonlyRoot) && tryData(readonlyIgnore) == Data("// read only\n".utf8), "unwritable ignore was changed")
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: readonlyIgnore.path)
        try Data(".laa-tmp\n#include missing-patterns\n".utf8).write(to: readonlyIgnore)
        try check(!LAABrainSaveCoordinator.ensureFallbackIgnored(root: readonlyRoot), "unchecked include was treated as a safe ignore")
        try Data(".laa-tmp\n[invalid\n".utf8).write(to: readonlyIgnore)
        try check(!LAABrainSaveCoordinator.ensureFallbackIgnored(root: readonlyRoot), "invalid glob was treated as a safe ignore")

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
        let manifest = try journal.makePending(vault: normal.vault, path: "manifest-symlink.md", base: Data(), draft: Data())
        let key = LAABrainSaveJournal.digest(Data((manifest.vault + "\u{0}" + manifest.path).utf8))
        let manifestFile = privateDir.appendingPathComponent("pending/" + key + "/" + manifest.id.uuidString + ".json")
        try manager.removeItem(at: manifestFile)
        try manager.createSymbolicLink(at: manifestFile, withDestinationURL: outside)
        do { _ = try journal.pending(vault: manifest.vault, path: manifest.path); throw FixtureFailure() }
        catch is LAABrainSaveJournal.JournalError {}
        let symlinkCatalogue = try journal.catalogue(vault: normal.vault)
        try check(symlinkCatalogue.unreadable > 0 && tryData(outside) == Data("OUTSIDE".utf8), "pending symlink was followed")
        try manager.removeItem(at: manifestFile)
        print("PASS: Swift exchange, conflict, fallback, missing stages, quarantine, retention, migration, export, binary and deleted/renamed recovery")
    }
}
#endif
