#if LAA_BUILD
import Darwin
import Foundation

/// Saves an existing local Markdown note. The caller keeps the selected folder
/// security-scoped for the entire editing session.
struct LAABrainSaveCoordinator {
    struct Snapshot {
        let vault: String
        let path: String
        let base: Data
    }

    enum Method { case exchange, checkedReplacement }
    enum Outcome {
        case saved(Method)
        case conflict(current: Data, draft: Data)
        case intervening(displaced: Data, draft: Data)
    }
    enum RecoveryOutcome {
        case restored(path: String)
        case uncertain(path: String)
    }
    enum SaveError: Error {
        case invalidPath, notRegularFile, tooLarge, invalidText, pendingRecovery, unsafeStage, missingStage, storage, coordination
        case recoveryExportRequired, recoveryDestinationExists
        case exchange(Int32)
    }

    let journal: LAABrainSaveJournal
    #if DEBUG
    /// Synthetic fixtures use this to place a write in the comparison/swap gap.
    var fixtureBeforeStage: (() throws -> Void)? = nil
    var fixtureStagePrepared: ((URL) throws -> Void)? = nil
    var fixtureAfterComparison: (() throws -> Void)? = nil
    var fixtureAfterExchange: (() throws -> Void)? = nil
    var fixtureBeforeRecoveryRename: ((URL) throws -> Void)? = nil
    var fixtureForceRecoveryFallback = false
    var fixtureForceFallback = false
    #endif

    init(journal: LAABrainSaveJournal = LAABrainSaveJournal()) { self.journal = journal }

    func begin(root: URL, path: String) throws -> Snapshot {
        let file = try Self.noteURL(root: root, path: path)
        let vault = LAABrainSaveJournal.vaultID(root)
        guard try journal.pending(vault: vault, path: path).isEmpty else { throw SaveError.pendingRecovery }
        try journal.validate(vault: vault, path: path)
        var result: Result<Data, Error> = .failure(SaveError.coordination)
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordinationError) { coordinated in
            result = Result {
                _ = try Self.noteURL(root: root, path: path)
                return try Self.readNote(coordinated)
            }
        }
        if let coordinationError { throw coordinationError }
        let base = try result.get()
        try journal.record(vault: vault, path: path, kind: .original, bytes: base)
        return Snapshot(vault: vault, path: path, base: base)
    }

    /// A failed or interrupted exchange leaves its manifest and stage in app
    /// storage, so the recovery screen can copy the stage into the journal.
    func save(root: URL, snapshot: Snapshot, draft: Data) throws -> Outcome {
        guard snapshot.vault == LAABrainSaveJournal.vaultID(root) else { throw SaveError.invalidPath }
        guard draft.count <= 32 * 1024 * 1024 else { throw SaveError.tooLarge }
        guard String(data: draft, encoding: .utf8) != nil else { throw SaveError.invalidText }
        let file = try Self.noteURL(root: root, path: snapshot.path)
        guard try journal.pending(vault: snapshot.vault, path: snapshot.path).isEmpty else { throw SaveError.pendingRecovery }
        try journal.record(vault: snapshot.vault, path: snapshot.path, kind: .draft, bytes: draft)
        try journal.validate(vault: snapshot.vault, path: snapshot.path)
        let transaction = try journal.makePending(vault: snapshot.vault, path: snapshot.path, base: snapshot.base, draft: draft)
        let stage = try journal.stageURL(transaction)
        var result: Result<Outcome, Error> = .failure(SaveError.coordination)
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordinationError) { coordinated in
            result = Result {
                _ = try Self.noteURL(root: root, path: snapshot.path)
                #if DEBUG
                try fixtureBeforeStage?()
                #endif
                try Self.makeStage(source: coordinated, stage: stage, draft: draft)
                try journal.synchronizeStagingDirectory()
                #if DEBUG
                try fixtureStagePrepared?(stage)
                #endif
                let current = try Self.readNote(coordinated)
                if LAABrainSaveJournal.digest(current) != LAABrainSaveJournal.digest(snapshot.base) {
                    try journal.record(vault: snapshot.vault, path: snapshot.path, kind: .conflict, bytes: current)
                    try journal.finish(transaction)
                    return .conflict(current: current, draft: draft)
                }
                #if DEBUG
                try fixtureAfterComparison?()
                let swapError = fixtureForceFallback ? EXDEV : Self.exchange(stage, coordinated)
                #else
                let swapError = Self.exchange(stage, coordinated)
                #endif
                if swapError == 0 {
                    #if DEBUG
                    try fixtureAfterExchange?()
                    #endif
                    // The stage is now the exact displaced inode, even if its
                    // contents changed after the comparison. Do not remove it
                    // until a durable, integrity-checked record exists.
                    guard try journal.stageExists(transaction) else { throw SaveError.storage }
                    let displaced = try Data(contentsOf: stage)
                    try journal.record(vault: snapshot.vault, path: snapshot.path, kind: .displaced, bytes: displaced)
                    try journal.finish(transaction)
                    if LAABrainSaveJournal.digest(displaced) != LAABrainSaveJournal.digest(snapshot.base) {
                        return .intervening(displaced: displaced, draft: draft)
                    }
                    return .saved(.exchange)
                }
                guard Self.supportsFallback(error: swapError) else { throw SaveError.exchange(swapError) }
                // File Providers / different volumes may reject a swap. This
                // approved fallback has a small compare/replace window.
                let fallbackCurrent = try Self.readNote(coordinated)
                if LAABrainSaveJournal.digest(fallbackCurrent) != LAABrainSaveJournal.digest(snapshot.base) {
                    try journal.record(vault: snapshot.vault, path: snapshot.path, kind: .conflict, bytes: fallbackCurrent)
                    try journal.finish(transaction)
                    return .conflict(current: fallbackCurrent, draft: draft)
                }
                try draft.write(to: coordinated, options: .atomic)
                try journal.finish(transaction)
                return .saved(.checkedReplacement)
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    /// Preserve an interrupted transaction's stage before dismissing it. Its
    /// contents can be either a draft or a displaced file; never guess which.
    @discardableResult
    func preservePending(_ pending: LAABrainSaveJournal.Pending) throws -> LAABrainSaveJournal.Version {
        let stage = try journal.stageURL(pending)
        guard try journal.stageExists(pending) else { throw SaveError.missingStage }
        let version = try journal.record(vault: pending.vault, path: pending.path, kind: .interrupted,
                                         bytes: Data(contentsOf: stage))
        try journal.finish(pending)
        return version
    }

    /// The recovery UI requires an explicit acknowledgement before clearing a
    /// manifest whose stage is missing. It might have contained another version.
    func acknowledgeMissingStage(_ pending: LAABrainSaveJournal.Pending) throws {
        try journal.finishMissingStage(pending)
    }

    /// Restore exact journal bytes as a new uniquely named file at the vault
    /// root. The original path is never replaced, even if it reappears.
    func restoreCopy(root: URL, summary: LAABrainSaveJournal.VersionSummary) throws -> RecoveryOutcome {
        guard summary.vault == LAABrainSaveJournal.vaultID(root) else { throw SaveError.invalidPath }
        let version = try journal.version(summary)
        let stage = try journal.makeRecoveryStage(version.bytes)
        defer { try? journal.discardRecoveryStage(stage) }

        let name = "Recovered-" + UUID().uuidString + ".md"
        var moved = false
        var verified = false
        var operationError: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: root, options: [], error: &coordinationError) { coordinatedRoot in
            do {
                let values = try coordinatedRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw SaveError.invalidPath }
                let destination = coordinatedRoot.appendingPathComponent(name)
                #if DEBUG
                try fixtureBeforeRecoveryRename?(destination)
                let error = fixtureForceRecoveryFallback ? EXDEV : Self.renameExclusive(stage, destination)
                #else
                let error = Self.renameExclusive(stage, destination)
                #endif
                if error == EEXIST { throw SaveError.recoveryDestinationExists }
                if Self.supportsFallback(error: error) { throw SaveError.recoveryExportRequired }
                guard error == 0 else { throw SaveError.exchange(error) }
                moved = true
                let restored = try Data(contentsOf: destination)
                let fd = open(coordinatedRoot.path, O_RDONLY)
                guard fd >= 0 else { return }
                defer { close(fd) }
                verified = LAABrainSaveJournal.digest(restored) == version.digest && fsync(fd) == 0
            } catch { operationError = error }
        }
        if moved {
            return verified && coordinationError == nil && operationError == nil ? .restored(path: name) : .uncertain(path: name)
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
        throw SaveError.coordination
    }

    private static let excluded: Set<String> = [".obsidian", ".git", ".trash", ".stfolder", ".stversions"]

    private static func noteURL(root: URL, path: String) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, path.rangeOfCharacter(from: .controlCharacters) == nil,
              !path.contains("\\"), !path.contains(":"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !excluded.contains(String($0)) }),
              URL(fileURLWithPath: path).pathExtension.lowercased() == "md" else { throw SaveError.invalidPath }
        var url = root
        for part in parts {
            url.appendPathComponent(String(part))
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw SaveError.invalidPath }
        }
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw SaveError.notRegularFile }
        return url
    }

    private static func readNote(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw SaveError.notRegularFile }
        guard (values.fileSize ?? 0) <= 32 * 1024 * 1024 else { throw SaveError.tooLarge }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= 32 * 1024 * 1024 else { throw SaveError.tooLarge }
        guard String(data: bytes, encoding: .utf8) != nil else { throw SaveError.invalidText }
        return bytes
    }

    private static func makeStage(source: URL, stage: URL, draft: Data) throws {
        let manager = FileManager.default
        var status = stat()
        guard lstat(stage.path, &status) != 0, errno == ENOENT else { throw SaveError.unsafeStage }
        // Copy when possible to carry the note's metadata; if a provider cannot
        // copy it, private staging still works and swap/fallback decides access.
        do { try manager.copyItem(at: source, to: stage) }
        catch {
            if lstat(stage.path, &status) == 0 {
                guard status.st_mode & S_IFMT == S_IFREG else { throw SaveError.unsafeStage }
                try manager.removeItem(at: stage)
            } else if errno != ENOENT { throw SaveError.unsafeStage }
            guard manager.createFile(atPath: stage.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw SaveError.storage
            }
        }
        #if os(iOS)
        try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: stage.path)
        #endif
        let attributes = try manager.attributesOfItem(atPath: stage.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        try manager.setAttributes([.posixPermissions: mode | 0o200], ofItemAtPath: stage.path)
        let fd = open(stage.path, O_WRONLY | O_TRUNC | O_NOFOLLOW)
        guard fd >= 0 else { throw SaveError.storage }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: draft)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try manager.setAttributes([.posixPermissions: mode], ofItemAtPath: stage.path)
    }

    private static func exchange(_ a: URL, _ b: URL) -> Int32 {
        let result = a.withUnsafeFileSystemRepresentation { first in
            b.withUnsafeFileSystemRepresentation { second in
                guard let first, let second else { return Int32(-1) }
                return renamex_np(first, second, UInt32(RENAME_SWAP))
            }
        }
        return result == 0 ? 0 : errno
    }

    private static func renameExclusive(_ a: URL, _ b: URL) -> Int32 {
        let result = a.withUnsafeFileSystemRepresentation { first in
            b.withUnsafeFileSystemRepresentation { second in
                guard let first, let second else { return Int32(-1) }
                return renamex_np(first, second, UInt32(RENAME_EXCL))
            }
        }
        return result == 0 ? 0 : errno
    }

    private static func supportsFallback(error: Int32) -> Bool {
        [EXDEV, ENOTSUP, EINVAL, EPERM, EACCES, ENOSYS].contains(error)
    }
}
#endif
