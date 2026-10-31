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
    enum SaveError: Error {
        case invalidPath, notRegularFile, tooLarge, invalidText, pendingRecovery, unsafeStage, storage, coordination
        case exchange(Int32)
    }

    let journal: LAABrainSaveJournal
    #if DEBUG
    /// Synthetic fixtures use this to place a write in the comparison/swap gap.
    var fixtureBeforeStage: (() throws -> Void)? = nil
    var fixtureStagePrepared: ((URL) throws -> Void)? = nil
    var fixtureAfterComparison: (() throws -> Void)? = nil
    var fixtureAfterExchange: (() throws -> Void)? = nil
    var fixtureForceFallback = false
    #endif

    init(journal: LAABrainSaveJournal = LAABrainSaveJournal()) { self.journal = journal }

    func begin(root: URL, path: String) throws -> Snapshot {
        let file = try Self.noteURL(root: root, path: path)
        let vault = LAABrainSaveJournal.vaultID(root)
        guard try journal.pending(vault: vault, path: path).isEmpty else { throw SaveError.pendingRecovery }
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
    func preservePending(_ pending: LAABrainSaveJournal.Pending) throws -> LAABrainSaveJournal.Version? {
        let stage = try journal.stageURL(pending)
        var version: LAABrainSaveJournal.Version?
        if try journal.stageExists(pending) {
            version = try journal.record(vault: pending.vault, path: pending.path, kind: .interrupted,
                                         bytes: Data(contentsOf: stage))
        }
        try journal.finish(pending)
        return version
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

    private static func supportsFallback(error: Int32) -> Bool {
        [EXDEV, ENOTSUP, EINVAL, EPERM, EACCES, ENOSYS].contains(error)
    }
}
#endif
