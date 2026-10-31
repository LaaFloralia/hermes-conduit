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
        case recoveryExportRequired, recoveryDestinationExists, conflictCopy, historyUnavailable
        case durabilityUncertain, historyCapacity, recoveryPending
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
    var fixtureDirectorySyncFails = false
    #endif

    init(journal: LAABrainSaveJournal = LAABrainSaveJournal()) { self.journal = journal }

    func begin(root: URL, path: String) throws -> Snapshot {
        guard !Self.isConflictCopy(path) else { throw SaveError.conflictCopy }
        let file = try Self.noteURL(root: root, path: path)
        let vault = LAABrainSaveJournal.vaultID(root)
        do {
            guard try journal.pending(vault: vault, path: path).isEmpty else { throw SaveError.pendingRecovery }
            try journal.validate(vault: vault, path: path)
        } catch SaveError.pendingRecovery { throw SaveError.pendingRecovery }
        catch { throw SaveError.historyUnavailable }
        var result: Result<Data, Error> = .failure(SaveError.coordination)
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordinationError) { coordinated in
            result = Result {
                guard coordinated.standardizedFileURL == file.standardizedFileURL else { throw SaveError.invalidPath }
                return try Self.withNoteParent(root: root, path: path) { fd, name in try Self.readNote(fd: fd, name: name) }
            }
        }
        if let coordinationError { throw coordinationError }
        let base = try result.get()
        do { try journal.record(vault: vault, path: path, kind: .original, bytes: base) }
        catch { throw SaveError.historyUnavailable }
        return Snapshot(vault: vault, path: path, base: base)
    }

    /// A failed or interrupted exchange leaves its manifest and stage in app
    /// storage, so the recovery screen can copy the stage into the journal.
    func save(root: URL, snapshot: Snapshot, draft: Data) throws -> Outcome {
        guard snapshot.vault == LAABrainSaveJournal.vaultID(root) else { throw SaveError.invalidPath }
        guard !Self.isConflictCopy(snapshot.path) else { throw SaveError.conflictCopy }
        guard draft.count <= 32 * 1024 * 1024 else { throw SaveError.tooLarge }
        guard String(data: draft, encoding: .utf8) != nil else { throw SaveError.invalidText }
        let file = try Self.noteURL(root: root, path: snapshot.path)
        guard try journal.pending(vault: snapshot.vault, path: snapshot.path).isEmpty else { throw SaveError.pendingRecovery }
        do { try journal.record(vault: snapshot.vault, path: snapshot.path, kind: .draft, bytes: draft) }
        catch LAABrainSaveJournal.JournalError.capacity { throw SaveError.historyCapacity }
        try journal.validate(vault: snapshot.vault, path: snapshot.path)
        let transaction = try journal.makePending(vault: snapshot.vault, path: snapshot.path, base: snapshot.base, draft: draft)
        let stage = try journal.stageURL(transaction)
        let fallbackIgnored = Self.ensureFallbackIgnored(root: root)
        var result: Result<Outcome, Error> = .failure(SaveError.coordination)
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordinationError) { coordinated in
            result = Result {
                guard coordinated.standardizedFileURL == file.standardizedFileURL else { throw SaveError.invalidPath }
                #if DEBUG
                try fixtureBeforeStage?()
                #endif
                return try Self.withNoteParent(root: root, path: snapshot.path) { noteFD, noteName in
                    try Self.makeStage(sourceDirectory: noteFD, sourceName: noteName, stage: stage, draft: draft)
                    try journal.synchronizeStagingDirectory()
                    #if DEBUG
                    try fixtureStagePrepared?(stage)
                    #endif
                    let current = try Self.readNote(fd: noteFD, name: noteName)
                    if LAABrainSaveJournal.digest(current) != LAABrainSaveJournal.digest(snapshot.base) {
                        try journal.record(vault: snapshot.vault, path: snapshot.path, kind: .conflict, bytes: current)
                        try journal.finish(transaction)
                        return .conflict(current: current, draft: draft)
                    }
                    #if DEBUG
                    try fixtureAfterComparison?()
                    try Self.verifyNoteParent(root: root, path: snapshot.path, expected: noteFD)
                    let swapError = fixtureForceFallback ? EXDEV : Self.exchange(stage, noteDirectory: noteFD, noteName: noteName)
                    #else
                    try Self.verifyNoteParent(root: root, path: snapshot.path, expected: noteFD)
                    let swapError = Self.exchange(stage, noteDirectory: noteFD, noteName: noteName)
                    #endif
                    if swapError == 0 {
                        #if DEBUG
                        try fixtureAfterExchange?()
                        #endif
                        // The stage is now the exact displaced inode, even if its
                        // contents changed after the comparison. Do not remove it
                        // until a durable, integrity-checked record exists.
                        guard try journal.stageExists(transaction) else { throw SaveError.storage }
                        let displaced = try Self.readRegular(stage)
                        let changed = LAABrainSaveJournal.digest(displaced) != LAABrainSaveJournal.digest(snapshot.base)
                        if changed {
                            do { try journal.record(vault: snapshot.vault, path: snapshot.path, kind: .displaced, bytes: displaced) }
                            catch { throw SaveError.recoveryPending }
                        }
                        let stageFD = open(stage.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                        guard stageFD >= 0 else { throw SaveError.durabilityUncertain }
                        defer { close(stageFD) }
                        #if DEBUG
                        if fixtureDirectorySyncFails { throw SaveError.durabilityUncertain }
                        #endif
                        guard fsync(noteFD) == 0, fsync(stageFD) == 0 else { throw SaveError.durabilityUncertain }
                        try journal.finish(transaction)
                        return changed ? .intervening(displaced: displaced, draft: draft) : .saved(.exchange)
                    }
                    guard Self.supportsFallback(error: swapError) else { throw SaveError.exchange(swapError) }
                    // A synced, ignored temporary directory holds only a copy of
                    // the already journaled draft, never the displaced file.
                    guard fallbackIgnored, Self.isFallbackIgnored(root: root) else {
                        try journal.finish(transaction)
                        throw SaveError.recoveryExportRequired
                    }
                    do {
                        return try Self.withFallbackStage(root: root, draft: draft) { directoryFD, name in
                            let fallbackCurrent = try Self.readNote(fd: noteFD, name: noteName)
                            if LAABrainSaveJournal.digest(fallbackCurrent) != LAABrainSaveJournal.digest(snapshot.base) {
                                try journal.record(vault: snapshot.vault, path: snapshot.path, kind: .conflict, bytes: fallbackCurrent)
                                try journal.finish(transaction)
                                return .conflict(current: fallbackCurrent, draft: draft)
                            }
                            try Self.verifyNoteParent(root: root, path: snapshot.path, expected: noteFD)
                            guard renameat(directoryFD, name, noteFD, noteName) == 0 else { throw SaveError.storage }
                            #if DEBUG
                            if fixtureDirectorySyncFails { throw SaveError.durabilityUncertain }
                            #endif
                            guard fsync(noteFD) == 0, fsync(directoryFD) == 0 else { throw SaveError.durabilityUncertain }
                            try journal.finish(transaction)
                            return .saved(.checkedReplacement)
                        }
                    } catch SaveError.recoveryExportRequired {
                        try journal.finish(transaction)
                        throw SaveError.recoveryExportRequired
                    }
                }
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
                                         bytes: Self.readRegular(stage))
        try journal.finish(pending)
        return version
    }

    func pendingBytes(_ pending: LAABrainSaveJournal.Pending) throws -> Data {
        guard try journal.stageExists(pending) else { throw SaveError.missingStage }
        return try Self.readRegular(journal.stageURL(pending))
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

        let name = Self.recoveryName(bytes: version.bytes, path: summary.path)
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
                let restored = try Self.readRegular(destination)
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

    static func recoveryName(bytes: Data, path: String) -> String {
        let ext = String(data: bytes, encoding: .utf8) == nil ? "bin" : URL(fileURLWithPath: path).pathExtension.lowercased()
        return "Recovered-" + UUID().uuidString + "." + (ext.isEmpty ? "md" : ext)
    }

    static func isConflictCopy(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return name.contains("sync-conflict") || name.contains("github競合") || name.contains("conflicted copy")
    }

    static func conflictOriginalPath(_ path: String) -> String? {
        guard isConflictCopy(path) else { return nil }
        let url = URL(fileURLWithPath: path)
        let stem = url.deletingPathExtension().lastPathComponent
        let markers = [".sync-conflict", "（github競合", " (conflicted copy", "(conflicted copy"]
        guard let marker = markers.compactMap({ stem.range(of: $0, options: .caseInsensitive) }).min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let name = String(stem[..<marker.lowerBound]) + "." + url.pathExtension
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? name : parent + "/" + name
    }

    static func verifyExport(_ url: URL, digest: String) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var matches = false
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
            if let bytes = try? readRegular(coordinated) { matches = LAABrainSaveJournal.digest(bytes) == digest }
        }
        return coordinationError == nil && matches
    }

    private static let excluded: Set<String> = [".obsidian", ".git", ".trash", ".stfolder", ".stversions", ".laa-tmp"]

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

    private static func openRegular(_ url: URL) throws -> (Int32, stat) {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw SaveError.notRegularFile }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            close(fd); throw SaveError.notRegularFile
        }
        return (fd, status)
    }

    private static func withNoteParent<T>(root: URL, path: String, _ operation: (Int32, String) throws -> T) throws -> T {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, path.rangeOfCharacter(from: .controlCharacters) == nil,
              !path.contains("\\"), !path.contains(":"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !excluded.contains($0) }),
              URL(fileURLWithPath: path).pathExtension.lowercased() == "md" else { throw SaveError.invalidPath }
        var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw SaveError.invalidPath }
        defer { close(fd) }
        for part in parts.dropLast() {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw SaveError.invalidPath }
            close(fd); fd = next
        }
        return try operation(fd, parts[parts.count - 1])
    }

    private static func openRegular(fd directory: Int32, name: String) throws -> (Int32, stat) {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw SaveError.notRegularFile }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            close(fd); throw SaveError.notRegularFile
        }
        return (fd, status)
    }

    private static func verifyNoteParent(root: URL, path: String, expected: Int32) throws {
        var original = stat()
        guard fstat(expected, &original) == 0 else { throw SaveError.invalidPath }
        try withNoteParent(root: root, path: path) { current, _ in
            var status = stat()
            guard fstat(current, &status) == 0, status.st_dev == original.st_dev,
                  status.st_ino == original.st_ino else { throw SaveError.invalidPath }
        }
    }

    private static func readRegular(_ url: URL, limit: Int? = nil) throws -> Data {
        let (fd, status) = try openRegular(url)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        if let limit, status.st_size > limit { throw SaveError.tooLarge }
        let bytes = try handle.readToEnd() ?? Data()
        if let limit, bytes.count > limit { throw SaveError.tooLarge }
        return bytes
    }

    private static func readNote(fd: Int32, name: String) throws -> Data {
        let (file, status) = try openRegular(fd: fd, name: name)
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? handle.close() }
        guard status.st_size <= 32 * 1024 * 1024 else { throw SaveError.tooLarge }
        let bytes = try handle.readToEnd() ?? Data()
        guard bytes.count <= 32 * 1024 * 1024 else { throw SaveError.tooLarge }
        guard String(data: bytes, encoding: .utf8) != nil else { throw SaveError.invalidText }
        return bytes
    }

    private static func makeStage(sourceDirectory: Int32, sourceName: String, stage: URL, draft: Data) throws {
        let (sourceFD, status) = try openRegular(fd: sourceDirectory, name: sourceName)
        defer { close(sourceFD) }
        let stageFD = open(stage.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
        guard stageFD >= 0 else { throw SaveError.unsafeStage }
        let handle = FileHandle(fileDescriptor: stageFD, closeOnDealloc: true)
        defer { try? handle.close() }
        // Copy through verified descriptors, preserving metadata where possible.
        // A failed metadata copy must not leave unverified source data in use.
        if fcopyfile(sourceFD, stageFD, nil, copyfile_flags_t(COPYFILE_ALL)) != 0 {
            guard ftruncate(stageFD, 0) == 0 else { throw SaveError.storage }
        }
        guard fchmod(stageFD, status.st_mode & 0o777 | 0o200) == 0,
              ftruncate(stageFD, 0) == 0, lseek(stageFD, 0, SEEK_SET) >= 0 else { throw SaveError.storage }
        try handle.write(contentsOf: draft)
        guard fchmod(stageFD, status.st_mode & 0o777) == 0 else { throw SaveError.storage }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: stage.path)
        #endif
        try handle.synchronize()
    }

    /// `.stignore` is device-local. Preserve its bytes and append exactly one
    /// rule; an earlier negation or include is conservatively treated as unsafe.
    @discardableResult
    static func ensureFallbackIgnored(root: URL) -> Bool {
        var safe = false
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: root, options: [], error: &coordinationError) { coordinated in
            guard coordinated.standardizedFileURL == root.standardizedFileURL else { return }
            let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard directory >= 0 else { return }
            defer { close(directory) }
            if let data = readIgnore(directory), containsIgnoreRule(data) {
                safe = ignoreRuleIsSafe(data); return
            }
            // An existing non-UTF-8, non-regular or unreadable file is never changed.
            var info = stat()
            let exists = fstatat(directory, ".stignore", &info, AT_SYMLINK_NOFOLLOW) == 0
            if exists && (info.st_mode & S_IFMT != S_IFREG || readIgnore(directory) == nil) { return }
            if !exists && errno != ENOENT { return }
            let fd = openat(directory, ".stignore", O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { return }
            defer { close(fd) }
            let prior = readIgnore(directory) ?? Data()
            guard String(data: prior, encoding: .utf8) != nil else { return }
            if !containsIgnoreRule(prior) {
                let addition = Data(((!prior.isEmpty && prior.last != 10) ? "\n" : "").utf8) + Data(".laa-tmp\n".utf8)
                let written = addition.withUnsafeBytes { write(fd, $0.baseAddress, addition.count) }
                guard written == addition.count, fsync(fd) == 0, fsync(directory) == 0 else { return }
            }
            if let updated = readIgnore(directory) { safe = ignoreRuleIsSafe(updated) }
        }
        return coordinationError == nil && safe
    }

    private static func isFallbackIgnored(root: URL) -> Bool {
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { return false }
        defer { close(directory) }
        guard let data = readIgnore(directory) else { return false }
        return ignoreRuleIsSafe(data)
    }

    private static func readIgnore(_ directory: Int32) -> Data? {
        let fd = openat(directory, ".stignore", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 1024 * 1024,
              let data = try? handle.readToEnd(), data.count <= 1024 * 1024,
              String(data: data, encoding: .utf8) != nil else { return nil }
        return data
    }

    private static func containsIgnoreRule(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.components(separatedBy: .newlines).contains { $0.trimmingCharacters(in: .whitespaces) == ".laa-tmp" }
    }

    private static func ignoreRuleIsSafe(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        var found = false
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("//") { continue }
            guard line.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
            while line.hasPrefix("(?i)") || line.hasPrefix("(?d)") { line.removeFirst(4) }
            // Includes and complex glob/escape syntax can fail to parse as a
            // whole; do not infer that Syncthing loaded our rule in that case.
            if line.hasPrefix("#") || line.contains("(?") || line.rangeOfCharacter(from: CharacterSet(charactersIn: "[]{}\\|")) != nil { return false }
            if line == ".laa-tmp" { found = true; continue }
            // A preceding negation may match the temp directory or a child.
            if !found && line.hasPrefix("!") { return false }
        }
        return found
    }

    private static func withFallbackDirectory<T>(root: URL, _ operation: (Int32) throws -> T) throws -> T {
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootFD >= 0 else { throw SaveError.invalidPath }
        defer { close(rootFD) }
        if mkdirat(rootFD, ".laa-tmp", 0o700) != 0 && errno != EEXIST { throw SaveError.storage }
        let directoryFD = openat(rootFD, ".laa-tmp", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw SaveError.invalidPath }
        defer { close(directoryFD) }
        return try operation(directoryFD)
    }

    private static func prepareFallback(root: URL) throws {
        try withFallbackDirectory(root: root) { directoryFD in
            let folder = root.appendingPathComponent(".laa-tmp", isDirectory: true)
            let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            let cutoff = Date().addingTimeInterval(-24 * 60 * 60).timeIntervalSince1970
            for name in files where name.hasSuffix(".tmp") && UUID(uuidString: String(name.dropLast(4))) != nil {
                var status = stat()
                guard fstatat(directoryFD, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
                      status.st_mode & S_IFMT == S_IFREG, Double(status.st_mtimespec.tv_sec) < cutoff else { continue }
                guard unlinkat(directoryFD, name, 0) == 0 else { throw SaveError.storage }
            }
        }
    }

    private static func withFallbackStage<T>(root: URL, draft: Data, _ operation: (Int32, String) throws -> T) throws -> T {
        var ready = false
        do {
            try prepareFallback(root: root)
            return try withFallbackDirectory(root: root) { directoryFD in
                let name = UUID().uuidString + ".tmp"
                let fd = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                guard fd >= 0 else { throw SaveError.storage }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close(); _ = unlinkat(directoryFD, name, 0) }
                try handle.write(contentsOf: draft)
                try handle.synchronize()
                ready = true
                return try operation(directoryFD, name)
            }
        } catch {
            if !ready { throw SaveError.recoveryExportRequired }
            throw error
        }
    }

    private static func exchange(_ stage: URL, noteDirectory: Int32, noteName: String) -> Int32 {
        let directory = open(stage.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { return errno }
        defer { close(directory) }
        let result = renameatx_np(directory, stage.lastPathComponent, noteDirectory, noteName, UInt32(RENAME_SWAP))
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
