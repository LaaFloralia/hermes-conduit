#if LAA_BUILD
import CryptoKit
import Darwin
import Foundation

/// Local, immutable recovery records. This never stores data in the vault.
struct LAABrainSaveJournal {
    enum Kind: String, Codable { case original, draft, displaced, conflict, interrupted }

    struct Version: Codable, Identifiable {
        let id: UUID
        let vault: String
        let path: String
        let kind: Kind
        let created: Date
        let bytes: Data
        let digest: String
    }

    /// The history list does not keep the potentially large note bodies in
    /// memory. A selected record is checked and loaded separately.
    struct VersionSummary: Codable, Identifiable {
        let schema: Int
        let id: UUID
        let vault: String
        let path: String
        let kind: Kind
        let created: Date
        let digest: String
        let byteCount: Int

        init(id: UUID, vault: String, path: String, kind: Kind, created: Date, digest: String, byteCount: Int) {
            schema = 1
            self.id = id; self.vault = vault; self.path = path; self.kind = kind
            self.created = created; self.digest = digest; self.byteCount = byteCount
        }

        private enum CodingKeys: String, CodingKey { case schema, id, vault, path, kind, created, digest, byteCount }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schema = try container.decodeIfPresent(Int.self, forKey: .schema) ?? 1
            id = try container.decode(UUID.self, forKey: .id)
            vault = try container.decode(String.self, forKey: .vault)
            path = try container.decode(String.self, forKey: .path)
            kind = try container.decode(Kind.self, forKey: .kind)
            created = try container.decode(Date.self, forKey: .created)
            digest = try container.decode(String.self, forKey: .digest)
            byteCount = try container.decode(Int.self, forKey: .byteCount)
        }
    }

    struct Catalogue {
        struct Note: Identifiable {
            let path: String
            var versions: [VersionSummary] = []
            var pending: [Pending] = []
            var id: String { path }
        }
        let notes: [Note]
        let unreadable: Int
    }

    /// Written before replacement. A remaining stage must be retained until
    /// the person has reviewed it; its contents may be the displaced file.
    struct Pending: Codable, Identifiable {
        let id: UUID
        let vault: String
        let path: String
        let created: Date
        let stageName: String
        let baseDigest: String
        let draftDigest: String
    }

    enum JournalError: Error { case invalidRecord, invalidStage, unsupportedSchema, capacity, storage }

    private static let recordLock = NSRecursiveLock()
    private static let maximumRecords = 30
    private static let maximumBytes: Int64 = 128 * 1024 * 1024
    private static let recoveryStageMaxAge: TimeInterval = 24 * 60 * 60

    let directory: URL
    private var versionsDirectory: URL { directory.appendingPathComponent("versions", isDirectory: true) }
    private var pendingDirectory: URL { directory.appendingPathComponent("pending", isDirectory: true) }
    private var stagingDirectory: URL { directory.appendingPathComponent("staging", isDirectory: true) }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Brain", isDirectory: true).appendingPathComponent("History", isDirectory: true)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func vaultID(_ root: URL) -> String { digest(Data(root.standardizedFileURL.path.utf8)) }

    func prepare() throws {
        Self.recordLock.lock(); defer { Self.recordLock.unlock() }
        for url in [directory, versionsDirectory, pendingDirectory, stagingDirectory] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                  ofItemAtPath: url.path)
            #endif
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = directory
        try mutable.setResourceValues(values)
        try cleanRecoveryStages()
        try cleanOrphanedVersions()
    }

    @discardableResult
    func record(vault: String, path: String, kind: Kind, bytes: Data) throws -> Version {
        Self.recordLock.lock(); defer { Self.recordLock.unlock() }
        try prepare()
        let version = Version(id: UUID(), vault: vault, path: path, kind: kind, created: Date(),
                              bytes: bytes, digest: Self.digest(bytes))
        let folder = try itemDirectory(versionsDirectory, vault: vault, path: path)
        let existing = try summaries(vault: vault, path: path)
        if (kind == .original || kind == .draft), let latest = existing.first, latest.digest == version.digest {
            return Version(id: latest.id, vault: vault, path: path, kind: latest.kind,
                           created: latest.created, bytes: bytes, digest: latest.digest)
        }
        let base = folder.appendingPathComponent(version.id.uuidString)
        let summary = VersionSummary(id: version.id, vault: vault, path: path, kind: kind,
                                     created: version.created, digest: version.digest, byteCount: bytes.count)
        let metadata = try JSONEncoder().encode(summary)
        // Reserve room before writing, but never evict unique displaced or interrupted versions.
        try prune(folder: folder, records: existing, reserveBytes: Int64(bytes.count + metadata.count),
                  reserveCount: Self.isProtected(kind) ? 0 : 1)
        // Publish metadata only after the bytes and their directory entry are durable.
        // A detached body is removed only after the 24-hour recovery window.
        try writeProtected(bytes, to: base.appendingPathExtension("bin"))
        try writeProtected(metadata, to: base.appendingPathExtension("json"))
        _ = try summaries(vault: vault, path: path)
        return version
    }

    func versions(vault: String, path: String) throws -> [Version] {
        try summaries(vault: vault, path: path).map { try version($0) }
    }

    /// Only metadata and file attributes are read. Content hashes are checked
    /// when the person selects a record for recovery or export.
    func validate(vault: String, path: String) throws {
        _ = try summaries(vault: vault, path: path)
    }

    func summaries(vault: String, path: String) throws -> [VersionSummary] {
        Self.recordLock.lock(); defer { Self.recordLock.unlock() }
        try prepare()
        let folder = try itemDirectory(versionsDirectory, vault: vault, path: path)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        var result: [VersionSummary] = []
        for file in files where file.pathExtension == "json" {
            do {
                if let item = try readSummary(file, folder: folder, vault: vault, path: path) { result.append(item) }
            } catch JournalError.unsupportedSchema { continue }
        }
        result.sort { $0.created == $1.created ? $0.id.uuidString > $1.id.uuidString : $0.created > $1.created }
        let removed = try prune(folder: folder, records: result)
        return result.filter { !removed.contains($0.id) }
    }

    private static func isProtected(_ kind: Kind) -> Bool { kind == .displaced || kind == .interrupted }

    /// The 30 slots are for ordinary versions. The 128 MiB cap includes
    /// protected, unknown, quarantined and orphan files until they are cleaned.
    /// When protected copies fill the cap, leave the pending stage untouched.
    @discardableResult
    private func prune(folder: URL, records: [VersionSummary], reserveBytes: Int64 = 0, reserveCount: Int = 0) throws -> Set<UUID> {
        var total: Int64 = 0
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            var status = stat()
            guard lstat(file.path, &status) == 0 else { throw JournalError.storage }
            if status.st_mode & S_IFMT == S_IFREG { total += status.st_size }
        }
        var count = records.filter { !Self.isProtected($0.kind) }.count + reserveCount
        total += reserveBytes
        var remove: [VersionSummary] = []
        for item in records.reversed() where !Self.isProtected(item.kind) {
            if count <= Self.maximumRecords && total <= Self.maximumBytes { break }
            let base = folder.appendingPathComponent(item.id.uuidString)
            for suffix in ["json", "bin"] {
                var status = stat()
                guard lstat(base.appendingPathExtension(suffix).path, &status) == 0,
                      status.st_mode & S_IFMT == S_IFREG else { throw JournalError.storage }
                total -= status.st_size
            }
            count -= 1
            remove.append(item)
        }
        if count > Self.maximumRecords || total > Self.maximumBytes {
            if reserveBytes > 0 || reserveCount > 0 { throw JournalError.capacity }
            return [] // Existing protected data remains visible even when it exceeds the limit.
        }
        for item in remove {
            let base = folder.appendingPathComponent(item.id.uuidString)
            // Metadata first; a crash leaves only an orphan body, never a broken visible record.
            try FileManager.default.removeItem(at: base.appendingPathExtension("json"))
            try synchronizeDirectory(folder)
            try FileManager.default.removeItem(at: base.appendingPathExtension("bin"))
        }
        if !remove.isEmpty { try synchronizeDirectory(folder) }
        return Set(remove.map(\.id))
    }

    /// Count quarantined metadata, including across application restarts.
    func corruptCount(vault: String, path: String) throws -> Int {
        Self.recordLock.lock(); defer { Self.recordLock.unlock() }
        _ = try summaries(vault: vault, path: path)
        let folder = try itemDirectory(versionsDirectory, vault: vault, path: path)
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".json.corrupt") }.count
    }

    func unreadableCount(vault: String, path: String) throws -> Int {
        Self.recordLock.lock(); defer { Self.recordLock.unlock() }
        try prepare()
        let folder = try itemDirectory(versionsDirectory, vault: vault, path: path)
        var count = 0
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            do { _ = try readSummary(file, folder: folder, vault: vault, path: path) }
            catch JournalError.unsupportedSchema { count += 1 }
        }
        return count
    }

    func version(_ summary: VersionSummary) throws -> Version {
        Self.recordLock.lock(); defer { Self.recordLock.unlock() }
        try prepare()
        let folder = try itemDirectory(versionsDirectory, vault: summary.vault, path: summary.path)
        let file = folder.appendingPathComponent(summary.id.uuidString + ".json")
        guard let current = try readSummary(file, folder: folder, vault: summary.vault, path: summary.path),
              current.id == summary.id, current.kind == summary.kind, current.created == summary.created,
              current.digest == summary.digest, current.byteCount == summary.byteCount else { throw JournalError.invalidRecord }
        let body = folder.appendingPathComponent(summary.id.uuidString + ".bin")
        let bytes = try readRegularFile(body)
        guard bytes.count == current.byteCount, Self.digest(bytes) == current.digest else {
            try quarantine(file, body: body)
            throw JournalError.invalidRecord
        }
        return Version(id: current.id, vault: current.vault, path: current.path, kind: current.kind,
                       created: current.created, bytes: bytes, digest: current.digest)
    }

    /// Existing fixture builds used inline base64 records. Convert each one
    /// once, publishing the new metadata only after its body is durable.
    private func readSummary(_ file: URL, folder: URL, vault: String, path: String) throws -> VersionSummary? {
        do {
            let data = try readRegularFile(file)
            try Self.checkSchema(data)
            let item: VersionSummary
            if let decoded = try? JSONDecoder().decode(VersionSummary.self, from: data) {
                item = decoded
            } else {
                let legacy = try JSONDecoder().decode(Version.self, from: data)
                guard legacy.vault == vault, legacy.path == path,
                      file.lastPathComponent == legacy.id.uuidString + ".json",
                      Self.digest(legacy.bytes) == legacy.digest else { throw JournalError.invalidRecord }
                item = VersionSummary(id: legacy.id, vault: legacy.vault, path: legacy.path, kind: legacy.kind,
                                      created: legacy.created, digest: legacy.digest, byteCount: legacy.bytes.count)
                let body = folder.appendingPathComponent(legacy.id.uuidString + ".bin")
                var bodyStatus = stat()
                if lstat(body.path, &bodyStatus) == 0 {
                    guard bodyStatus.st_mode & S_IFMT == S_IFREG,
                          try readRegularFile(body) == legacy.bytes else { throw JournalError.invalidRecord }
                } else if errno == ENOENT {
                    try writeProtected(legacy.bytes, to: body)
                } else { throw JournalError.storage }
                try writeProtected(JSONEncoder().encode(item), to: file)
            }
            guard item.vault == vault, item.path == path, file.lastPathComponent == item.id.uuidString + ".json",
                  item.byteCount >= 0, item.digest.count == 64,
                  item.digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw JournalError.invalidRecord }
            let body = folder.appendingPathComponent(item.id.uuidString + ".bin")
            var status = stat()
            if lstat(body.path, &status) != 0 {
                if errno == ENOENT { throw JournalError.invalidRecord }
                throw JournalError.storage
            }
            guard status.st_mode & S_IFMT == S_IFREG, status.st_size == item.byteCount else { throw JournalError.invalidRecord }
            return item
        } catch is DecodingError {
            try quarantineRecord(file, folder: folder)
            return nil
        } catch JournalError.invalidRecord {
            try quarantineRecord(file, folder: folder)
            return nil
        }
    }

    private struct SchemaHeader: Decodable { let schema: Int? }
    private static func checkSchema(_ data: Data) throws {
        let schema = try JSONDecoder().decode(SchemaHeader.self, from: data).schema ?? 1
        guard schema == 1 else { throw JournalError.unsupportedSchema }
    }

    private func quarantineRecord(_ file: URL, folder: URL) throws {
        let stem = file.deletingPathExtension().lastPathComponent
        let body = UUID(uuidString: stem).map { _ in folder.appendingPathComponent(stem + ".bin") }
        try quarantine(file, body: body)
    }

    private func quarantine(_ metadata: URL, body: URL?) throws {
        for file in [metadata, body].compactMap({ $0 }) {
            var status = stat()
            guard lstat(file.path, &status) == 0 else {
                if errno == ENOENT { continue }; throw JournalError.storage
            }
            let wasRegular = status.st_mode & S_IFMT == S_IFREG
            var destination = file.appendingPathExtension("corrupt")
            if lstat(destination.path, &status) == 0 {
                destination = file.appendingPathExtension("corrupt-" + UUID().uuidString)
            }
            guard renamex_np(file.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw JournalError.storage }
            if wasRegular {
                let fd = open(destination.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard fd >= 0 else { throw JournalError.storage }
                let result = futimes(fd, nil)
                close(fd)
                guard result == 0 else { throw JournalError.storage }
            }
        }
        try synchronizeDirectory(metadata.deletingLastPathComponent())
    }

    private func readRegularFile(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ELOOP { throw JournalError.invalidRecord }
            throw JournalError.storage
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { throw JournalError.invalidRecord }
        return try handle.readToEnd() ?? Data()
    }

    private func cleanRecoveryStages() throws {
        let files = try FileManager.default.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil)
        let cutoff = Date().addingTimeInterval(-Self.recoveryStageMaxAge).timeIntervalSince1970
        for file in files where file.pathExtension == "recovery" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
            var status = stat()
            guard lstat(file.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
                  Double(status.st_mtimespec.tv_sec) < cutoff else { continue }
            try FileManager.default.removeItem(at: file)
        }
    }

    private func cleanOrphanedVersions() throws {
        let cutoff = Date().addingTimeInterval(-Self.recoveryStageMaxAge).timeIntervalSince1970
        for folder in try FileManager.default.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil) {
            var folderStatus = stat()
            let key = folder.lastPathComponent
            guard key.count == 64, key.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                  lstat(folder.path, &folderStatus) == 0, folderStatus.st_mode & S_IFMT == S_IFDIR else { continue }
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                let parts = file.lastPathComponent.split(separator: ".", omittingEmptySubsequences: false)
                guard parts.count >= 2, UUID(uuidString: String(parts[0])) != nil else { continue }
                let isBody = parts.count == 2 && parts[1] == "bin"
                let isCorrupt = parts.count == 3 && (parts[1] == "bin" || parts[1] == "json") &&
                    (parts[2] == "corrupt" || parts[2].hasPrefix("corrupt-"))
                guard isBody || isCorrupt else { continue }
                var status = stat()
                guard lstat(file.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
                      Double(status.st_mtimespec.tv_sec) < cutoff else { continue }
                if isBody {
                    var metadata = stat()
                    let metadataPath = folder.appendingPathComponent(String(parts[0]) + ".json").path
                    if lstat(metadataPath, &metadata) == 0 { continue }
                    guard errno == ENOENT else { throw JournalError.storage }
                }
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Find history by its recorded path, without requiring the original note
    /// (or even its containing directory) to still exist in the vault.
    func catalogue(vault: String) throws -> Catalogue {
        Self.recordLock.lock(); defer { Self.recordLock.unlock() }
        try prepare()
        var notes: [String: Catalogue.Note] = [:]
        var unreadable = 0
        for (base, pendingRecords) in [(versionsDirectory, false), (pendingDirectory, true)] {
            let folders = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            for folder in folders {
                guard let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { unreadable += 1; continue }
                guard values.isDirectory == true, values.isSymbolicLink != true else { unreadable += 1; continue }
                let files: [URL]
                do { files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) }
                catch { unreadable += 1; continue }
                for file in files where file.pathExtension == "json" {
                    do {
                        try autoreleasepool {
                            let data = try readRegularFile(file)
                            if pendingRecords {
                                let item = try JSONDecoder().decode(Pending.self, from: data)
                                _ = try stageURL(item)
                                guard folder.lastPathComponent == Self.itemKey(vault: item.vault, path: item.path),
                                      file.lastPathComponent == item.id.uuidString + ".json" else { throw JournalError.invalidRecord }
                                if item.vault == vault {
                                    var note = notes[item.path] ?? Catalogue.Note(path: item.path)
                                    note.pending.append(item); notes[item.path] = note
                                }
                            } else {
                                try Self.checkSchema(data)
                                let decoded: VersionSummary
                                if let item = try? JSONDecoder().decode(VersionSummary.self, from: data) { decoded = item }
                                else {
                                    let legacy = try JSONDecoder().decode(Version.self, from: data)
                                    decoded = VersionSummary(id: legacy.id, vault: legacy.vault, path: legacy.path, kind: legacy.kind,
                                                             created: legacy.created, digest: legacy.digest, byteCount: legacy.bytes.count)
                                }
                                guard folder.lastPathComponent == Self.itemKey(vault: decoded.vault, path: decoded.path),
                                      let item = try readSummary(file, folder: folder, vault: decoded.vault, path: decoded.path) else {
                                    throw JournalError.invalidRecord
                                }
                                if item.vault == vault {
                                    var note = notes[item.path] ?? Catalogue.Note(path: item.path)
                                    note.versions.append(item); notes[item.path] = note
                                }
                            }
                        }
                    } catch is DecodingError {
                        unreadable += 1
                        if !pendingRecords { try quarantineRecord(file, folder: folder) }
                    } catch JournalError.invalidRecord {
                        unreadable += 1
                        if !pendingRecords { try quarantineRecord(file, folder: folder) }
                    } catch JournalError.unsupportedSchema {
                        unreadable += 1
                    } catch {
                        unreadable += 1
                    }
                }
                if !pendingRecords { unreadable += files.filter { $0.lastPathComponent.contains(".json.corrupt") }.count }
            }
        }
        let sorted = try notes.values.map { note in
            var result = note
            // This also applies the 30-record limit to migrated fixture data.
            result.versions = try summaries(vault: vault, path: note.path)
            result.pending.sort { $0.created > $1.created }
            return result
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return Catalogue(notes: sorted, unreadable: unreadable)
    }

    /// A recovery stage is only a duplicate of an already checked journal
    /// record. It never holds an unrecorded file displaced from the vault.
    func makeRecoveryStage(_ bytes: Data) throws -> URL {
        try prepare()
        let url = stagingDirectory.appendingPathComponent(UUID().uuidString + ".recovery")
        do { try writeProtected(bytes, to: url); return url }
        catch { try? FileManager.default.removeItem(at: url); throw error }
    }

    func discardRecoveryStage(_ url: URL) throws {
        guard url.deletingLastPathComponent().standardizedFileURL == stagingDirectory.standardizedFileURL,
              url.pathExtension == "recovery", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else {
            throw JournalError.invalidStage
        }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func makePending(vault: String, path: String, base: Data, draft: Data) throws -> Pending {
        try prepare()
        let id = UUID()
        let transaction = Pending(id: id, vault: vault, path: path, created: Date(), stageName: id.uuidString + ".stage",
                                  baseDigest: Self.digest(base), draftDigest: Self.digest(draft))
        try writeProtected(JSONEncoder().encode(transaction), to: try pendingURL(transaction))
        return transaction
    }

    func pending(vault: String, path: String) throws -> [Pending] {
        try prepare()
        let folder = try itemDirectory(pendingDirectory, vault: vault, path: path)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        return try files.filter { $0.pathExtension == "json" }.map { file in
            let item = try JSONDecoder().decode(Pending.self, from: readRegularFile(file))
            _ = try stageURL(item)
            guard item.vault == vault, item.path == path,
                  file.lastPathComponent == item.id.uuidString + ".json" else { throw JournalError.invalidRecord }
            return item
        }.sorted { $0.created > $1.created }
    }

    func stageURL(_ item: Pending) throws -> URL {
        guard item.stageName == item.id.uuidString + ".stage" else { throw JournalError.invalidStage }
        return stagingDirectory.appendingPathComponent(item.stageName)
    }

    func synchronizeStagingDirectory() throws { try synchronizeDirectory(stagingDirectory) }

    /// `fileExists` also returns false on permission errors; only ENOENT is
    /// proof that an interrupted stage is actually absent.
    func stageExists(_ item: Pending) throws -> Bool {
        let url = try stageURL(item)
        var attributes = stat()
        if lstat(url.path, &attributes) == 0 {
            guard attributes.st_mode & S_IFMT == S_IFREG else { throw JournalError.invalidStage }
            return true
        }
        guard errno == ENOENT else { throw JournalError.storage }
        return false
    }

    /// Call only after a stage has been recorded or is known not to contain a
    /// displaced file. Both the journal and the note survive if removal fails.
    func finish(_ item: Pending) throws {
        let stage = try stageURL(item)
        if try stageExists(item) { try FileManager.default.removeItem(at: stage) }
        let manifest = try pendingURL(item)
        if FileManager.default.fileExists(atPath: manifest.path) { try FileManager.default.removeItem(at: manifest) }
    }

    /// Used only after a person acknowledges an absent stage. Never delete a
    /// stage that could have appeared after the absence check.
    func finishMissingStage(_ item: Pending) throws {
        guard try !stageExists(item) else { throw JournalError.invalidStage }
        let manifest = try pendingURL(item)
        if FileManager.default.fileExists(atPath: manifest.path) { try FileManager.default.removeItem(at: manifest) }
    }

    private func pendingURL(_ item: Pending) throws -> URL {
        try itemDirectory(pendingDirectory, vault: item.vault, path: item.path)
            .appendingPathComponent(item.id.uuidString + ".json")
    }

    private func itemDirectory(_ base: URL, vault: String, path: String) throws -> URL {
        let key = Self.itemKey(vault: vault, path: path)
        let folder = base.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: folder.path)
        #endif
        try synchronizeDirectory(base)
        return folder
    }

    private static func itemKey(vault: String, path: String) -> String {
        digest(Data((vault + "\u{0}" + path).utf8))
    }

    private func writeProtected(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.synchronize()
        // Persist the directory entry, too. A filesystem that cannot do so
        // fails closed rather than claiming the record is durable.
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else { throw JournalError.storage }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw JournalError.storage }
    }
}
/// The latest uncommitted editor buffer is separate from bounded history.
/// It survives suspension without changing the vault or rotating old versions.
struct LAABrainDraftStore {
    struct Draft: Codable, Equatable {
        let vault: String
        let path: String
        let base: Data
        let bytes: Data
    }
    let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Brain/Drafts", isDirectory: true)
    }
    private func url(vault: String, path: String) -> URL {
        directory.appendingPathComponent(LAABrainSaveJournal.digest(Data((vault + "\u{0}" + path).utf8)) + ".json")
    }
    func save(_ draft: Draft) throws {
        guard draft.base.count <= 32 * 1024 * 1024, draft.bytes.count <= 32 * 1024 * 1024 else {
            throw LAABrainSaveJournal.JournalError.capacity
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = url(vault: draft.vault, path: draft.path)
        try JSONEncoder().encode(draft).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
        #endif
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var folder = directory; try folder.setResourceValues(values)
    }
    func load(vault: String, path: String) throws -> Draft? {
        let source = url(vault: vault, path: path)
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        guard let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 96 * 1024 * 1024 else {
            throw LAABrainSaveJournal.JournalError.invalidRecord
        }
        let draft = try JSONDecoder().decode(Draft.self, from: Data(contentsOf: source))
        guard draft.vault == vault, draft.path == path else { throw LAABrainSaveJournal.JournalError.invalidRecord }
        return draft
    }
    func clear(vault: String, path: String) throws {
        let source = url(vault: vault, path: path)
        if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.removeItem(at: source) }
    }
}
#endif
