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

    enum JournalError: Error { case invalidRecord, invalidStage, storage }

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
    }

    @discardableResult
    func record(vault: String, path: String, kind: Kind, bytes: Data) throws -> Version {
        try prepare()
        let version = Version(id: UUID(), vault: vault, path: path, kind: kind, created: Date(),
                              bytes: bytes, digest: Self.digest(bytes))
        let folder = try itemDirectory(versionsDirectory, vault: vault, path: path)
        let url = folder.appendingPathComponent(version.id.uuidString + ".json")
        try writeProtected(JSONEncoder().encode(version), to: url)
        return version
    }

    func versions(vault: String, path: String) throws -> [Version] {
        try prepare()
        let folder = try itemDirectory(versionsDirectory, vault: vault, path: path)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        return try files.filter { $0.pathExtension == "json" }.map { file in
            let entry = try JSONDecoder().decode(Version.self, from: Data(contentsOf: file))
            guard Self.digest(entry.bytes) == entry.digest, entry.vault == vault, entry.path == path else { throw JournalError.invalidRecord }
            return entry
        }.sorted { $0.created > $1.created }
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
            let item = try JSONDecoder().decode(Pending.self, from: Data(contentsOf: file))
            _ = try stageURL(item)
            guard item.vault == vault, item.path == path else { throw JournalError.invalidRecord }
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

    private func pendingURL(_ item: Pending) throws -> URL {
        try itemDirectory(pendingDirectory, vault: item.vault, path: item.path)
            .appendingPathComponent(item.id.uuidString + ".json")
    }

    private func itemDirectory(_ base: URL, vault: String, path: String) throws -> URL {
        let key = Self.digest(Data((vault + "\u{0}" + path).utf8))
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
#endif
