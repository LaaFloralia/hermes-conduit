#if LAA_BUILD
import Foundation
import CryptoKit

struct LAADriveOfflineMetadata: Sendable {
    let version: String?
    let size: Int64?
    let downloadable: Bool?
}

struct LAADriveOfflineChunk: Sendable {
    let data: Data
    let total: Int64
    let version: String?
}

struct LAADriveOfflinePDF: Sendable {
    let data: Data
    let version: String
}

enum LAADriveOfflineError: Error, Equatable {
    case invalidItem, permissionUnknown, forbidden, notFound, versionUnavailable, versionChanged
    case invalidRange, invalidDocument, insufficientSpace, alreadySaving, accessChanged, corruptIndex, unavailable, cleanupFailed
}

enum LAADriveOfflineAccess: String, Codable, Sendable {
    case verified, stale, denied, missing, unknown
}

enum LAADriveOfflineSourceFormat: String, Codable, Sendable { case workspacePDF }

struct LAADriveOfflineRecord: Codable, Identifiable, Sendable {
    let id: String
    let pairingID: String
    let name: String
    let mimeType: String
    let version: String
    let size: Int64
    /// Nil is an original file from an older or current index.
    let sourceFormat: LAADriveOfflineSourceFormat?
    let savedAt: Date
    var verifiedAt: Date
    var access: LAADriveOfflineAccess
    fileprivate let bodyName: String
    fileprivate let sha256: String
}

enum LAADriveOfflineCheck: Sendable {
    case metadata(LAADriveOfflineMetadata)
    case denied
    case missing
}

/// App-private, explicitly saved files. Callers must provide version-bearing
/// range responses and a fresh Drive metadata check before and after a save.
/// A failed replacement leaves the previous saved version untouched. Keep one
/// instance per root. An offline result reflects the last successful access
/// check; the caller must recheck when online and stop an open player if access
/// is subsequently denied.
actor LAADriveOfflineStore {
    typealias MetadataReader = @Sendable () async throws -> LAADriveOfflineMetadata
    typealias RangeReader = @Sendable (_ offset: Int64, _ length: Int, _ version: String) async throws -> LAADriveOfflineChunk
    typealias PDFReader = @Sendable (_ version: String) async throws -> LAADriveOfflinePDF
    typealias CapacityReader = @Sendable (_ directory: URL) -> Int64?

    private let root: URL
    private let capacity: CapacityReader
    private let fileManager = FileManager.default
    private let chunkSize = 256 * 1024
    private let maximumIDBytes = 2048
    private var saving: Set<String> = []
    private var accessGeneration: [String: UInt64] = [:]
    private var files: URL { root.appendingPathComponent("files", isDirectory: true) }
    private var pending: URL { root.appendingPathComponent("pending", isDirectory: true) }
    private var index: URL { root.appendingPathComponent("index.json", isDirectory: false) }

    init(root: URL, capacity: @escaping CapacityReader = { url in
        try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    }) {
        self.root = root
        self.capacity = capacity
    }

    static func appStorageRoot() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent("DriveOffline", isDirectory: true)
    }

    func records(pairingID: String) throws -> [LAADriveOfflineRecord] {
        try readIndex().filter { $0.pairingID == pairingID }.sorted { $0.savedAt > $1.savedAt }
    }

    /// Only call after the user explicitly removes a saved copy. Index-first
    /// makes a crash leave an orphan for startup cleanup, rather than a record
    /// pointing at bytes that were already deleted.
    @discardableResult
    func remove(pairingID: String, id: String) throws -> Bool {
        guard validText(pairingID, maximum: 200), validText(id, maximum: maximumIDBytes) else {
            throw LAADriveOfflineError.invalidItem
        }
        guard !saving.contains(itemKey(pairingID: pairingID, id: id)) else {
            throw LAADriveOfflineError.alreadySaving
        }
        let previous = try readIndex()
        guard let entry = previous.first(where: { $0.pairingID == pairingID && $0.id == id }) else { return false }
        let body = files.appendingPathComponent(entry.bodyName, isDirectory: false)
        do {
            let attributes = try fileManager.attributesOfItem(atPath: body.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw LAADriveOfflineError.unavailable
            }
        } catch {
            if !isMissingFile(error) { throw error }
        }
        try writeIndex(previous.filter { $0.pairingID != pairingID || $0.id != id })
        accessGeneration[itemKey(pairingID: pairingID, id: id), default: 0] &+= 1
        do {
            try fileManager.removeItem(at: body)
        } catch {
            if isMissingFile(error) { return true }
            do { try writeIndex(previous) }
            catch { throw LAADriveOfflineError.cleanupFailed }
            throw error
        }
        return true
    }

    /// Returns no file for known denial, deletion, or unknown permission.
    /// A stale but still permitted version remains available and is marked stale.
    func localFile(pairingID: String, id: String) throws -> URL? {
        try localCopy(pairingID: pairingID, id: id)?.url
    }

    /// The record and URL describe the same saved version, even if a
    /// replacement is committed by another task immediately afterwards.
    func localCopy(pairingID: String, id: String) throws -> (record: LAADriveOfflineRecord, url: URL)? {
        guard let record = try readIndex().first(where: { $0.pairingID == pairingID && $0.id == id }),
              record.access == .verified || record.access == .stale else { return nil }
        let url = files.appendingPathComponent(record.bodyName, isDirectory: false)
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, let size = values?.fileSize, Int64(size) == record.size else {
            throw LAADriveOfflineError.unavailable
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: chunkSize), !data.isEmpty { digest.update(data: data) }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == record.sha256 else {
            throw LAADriveOfflineError.unavailable
        }
        return (record, url)
    }

    /// Snapshot an access check so a slower response cannot undo a newer denial,
    /// deletion, or replacement of the saved copy.
    func accessCheckGeneration(pairingID: String, id: String) throws -> UInt64 {
        guard try readIndex().contains(where: { $0.pairingID == pairingID && $0.id == id }) else {
            throw LAADriveOfflineError.unavailable
        }
        return accessGeneration[itemKey(pairingID: pairingID, id: id), default: 0]
    }

    /// Store a known access result without erasing the user's saved bytes.
    func recordCheck(pairingID: String, id: String, result: LAADriveOfflineCheck,
                     expectedGeneration: UInt64? = nil, now: Date = Date()) throws {
        let key = itemKey(pairingID: pairingID, id: id)
        if let expectedGeneration, accessGeneration[key, default: 0] != expectedGeneration {
            // A known denial or missing file must still block access, even if
            // another check completed first. A fresh check can restore it.
            switch result {
            case .denied, .missing: break
            case .metadata(let metadata) where metadata.downloadable == false: break
            default: throw LAADriveOfflineError.accessChanged
            }
        }
        accessGeneration[key, default: 0] &+= 1
        var entries = try readIndex()
        guard let at = entries.firstIndex(where: { $0.pairingID == pairingID && $0.id == id }) else { return }
        switch result {
        case .denied: entries[at].access = .denied
        case .missing: entries[at].access = .missing
        case .metadata(let metadata):
            if metadata.downloadable == false { entries[at].access = .denied }
            else if metadata.downloadable != true || validVersion(metadata.version) == nil { entries[at].access = .unknown }
            else if metadata.version == entries[at].version, entries[at].sourceFormat != .workspacePDF,
                    metadata.size != entries[at].size {
                entries[at].access = .unknown
            } else {
                entries[at].access = metadata.version == entries[at].version ? .verified : .stale
                entries[at].verifiedAt = now
            }
        }
        try writeIndex(entries)
    }

    @discardableResult
    func save(pairingID: String, id: String, name: String, mimeType: String,
              metadata: @escaping MetadataReader, range: @escaping RangeReader) async throws -> LAADriveOfflineRecord {
        guard validText(pairingID, maximum: 200), validText(id, maximum: maximumIDBytes),
              validText(name, maximum: 2000), validText(mimeType, maximum: 200) else { throw LAADriveOfflineError.invalidItem }
        let key = itemKey(pairingID: pairingID, id: id)
        guard saving.insert(key).inserted else { throw LAADriveOfflineError.alreadySaving }
        defer { saving.remove(key) }
        let generation = accessGeneration[key, default: 0]
        try prepareDirectories()
        let initial = try await checkedMetadata(metadata, pairingID: pairingID, id: id)
        let (version, size) = try validated(initial)
        guard accessGeneration[key, default: 0] == generation else { throw LAADriveOfflineError.accessChanged }
        try Task.checkCancellation()
        let (required, overflow) = size.addingReportingOverflow(1_048_576)
        if overflow || capacity(root).map({ $0 < required }) == true { throw LAADriveOfflineError.insufficientSpace }

        let temporary = pending.appendingPathComponent(UUID().uuidString, isDirectory: false)
        guard fileManager.createFile(atPath: temporary.path, contents: nil, attributes: protectionAttributes) else {
            throw LAADriveOfflineError.unavailable
        }
        defer { try? fileManager.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        var offset: Int64 = 0
        var digest = SHA256()
        while offset < size {
            try Task.checkCancellation()
            let count = Int(min(Int64(chunkSize), size - offset))
            let part: LAADriveOfflineChunk
            do { part = try await range(offset, count, version) }
            catch {
                try persistKnownDenial(error, pairingID: pairingID, id: id)
                throw error
            }
            try Task.checkCancellation()
            guard accessGeneration[key, default: 0] == generation else { throw LAADriveOfflineError.accessChanged }
            guard part.version == version else { throw LAADriveOfflineError.versionChanged }
            guard part.total == size, part.data.count == count else { throw LAADriveOfflineError.invalidRange }
            try handle.write(contentsOf: part.data)
            digest.update(data: part.data)
            offset += Int64(count)
        }
        try handle.synchronize()
        try handle.close()
        let final = try await checkedMetadata(metadata, pairingID: pairingID, id: id)
        let (finalVersion, finalSize) = try validated(final)
        guard finalVersion == version, finalSize == size else { throw LAADriveOfflineError.versionChanged }
        try Task.checkCancellation()
        guard accessGeneration[key, default: 0] == generation else { throw LAADriveOfflineError.accessChanged }
        return try commit(temporary: temporary, pairingID: pairingID, id: id, name: name, mimeType: mimeType,
                          version: version, size: size, sourceFormat: nil,
                          sha256: digest.finalize().map({ String(format: "%02x", $0) }).joined())
    }

    /// Workspace exports have no source byte size. The export is bounded,
    /// version checked, and only installed after a second metadata check.
    @discardableResult
    func saveWorkspacePDF(pairingID: String, id: String, name: String,
                          metadata: @escaping MetadataReader, export: @escaping PDFReader) async throws -> LAADriveOfflineRecord {
        guard validText(pairingID, maximum: 200), validText(id, maximum: maximumIDBytes),
              validText(name, maximum: 2000) else { throw LAADriveOfflineError.invalidItem }
        let key = itemKey(pairingID: pairingID, id: id)
        guard saving.insert(key).inserted else { throw LAADriveOfflineError.alreadySaving }
        defer { saving.remove(key) }
        let generation = accessGeneration[key, default: 0]
        try prepareDirectories()
        let initial = try await checkedMetadata(metadata, pairingID: pairingID, id: id)
        let version = try validatedVersion(initial)
        guard accessGeneration[key, default: 0] == generation else { throw LAADriveOfflineError.accessChanged }
        try Task.checkCancellation()
        let pdf: LAADriveOfflinePDF
        do { pdf = try await export(version) }
        catch {
            try persistKnownDenial(error, pairingID: pairingID, id: id)
            throw error
        }
        try Task.checkCancellation()
        guard accessGeneration[key, default: 0] == generation else { throw LAADriveOfflineError.accessChanged }
        guard pdf.version == version else { throw LAADriveOfflineError.versionChanged }
        guard pdf.data.count <= 10_000_000, pdf.data.starts(with: Data("%PDF-".utf8)) else {
            throw LAADriveOfflineError.invalidDocument
        }
        let size = Int64(pdf.data.count)
        let (required, overflow) = size.addingReportingOverflow(1_048_576)
        if overflow || capacity(root).map({ $0 < required }) == true { throw LAADriveOfflineError.insufficientSpace }
        let temporary = pending.appendingPathComponent(UUID().uuidString, isDirectory: false)
        guard fileManager.createFile(atPath: temporary.path, contents: nil, attributes: protectionAttributes) else {
            throw LAADriveOfflineError.unavailable
        }
        defer { try? fileManager.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        try handle.write(contentsOf: pdf.data)
        try handle.synchronize()
        try handle.close()
        let final = try await checkedMetadata(metadata, pairingID: pairingID, id: id)
        guard try validatedVersion(final) == version else { throw LAADriveOfflineError.versionChanged }
        try Task.checkCancellation()
        guard accessGeneration[key, default: 0] == generation else { throw LAADriveOfflineError.accessChanged }
        let digest = SHA256.hash(data: pdf.data).map { String(format: "%02x", $0) }.joined()
        return try commit(temporary: temporary, pairingID: pairingID, id: id, name: name, mimeType: "application/pdf",
                          version: version, size: size, sourceFormat: .workspacePDF, sha256: digest)
    }

    private func commit(temporary: URL, pairingID: String, id: String, name: String, mimeType: String,
                        version: String, size: Int64, sourceFormat: LAADriveOfflineSourceFormat?,
                        sha256: String) throws -> LAADriveOfflineRecord {
        let bodyName = UUID().uuidString
        let destination = files.appendingPathComponent(bodyName, isDirectory: false)
        try fileManager.moveItem(at: temporary, to: destination)
        var committed = false
        defer { if !committed { try? fileManager.removeItem(at: destination) } }
        var entries = try readIndex()
        let old = entries.first { $0.pairingID == pairingID && $0.id == id }
        let now = Date()
        let saved = LAADriveOfflineRecord(id: id, pairingID: pairingID, name: name, mimeType: mimeType,
                                          version: version, size: size, sourceFormat: sourceFormat,
                                          savedAt: now, verifiedAt: now, access: .verified, bodyName: bodyName,
                                          sha256: sha256)
        entries.removeAll { $0.pairingID == pairingID && $0.id == id }
        entries.append(saved)
        try writeIndex(entries)
        accessGeneration[itemKey(pairingID: pairingID, id: id), default: 0] &+= 1
        committed = true
        if let old { try? fileManager.removeItem(at: files.appendingPathComponent(old.bodyName)) }
        return saved
    }

    /// Call at startup on the sole instance, before starting any saves.
    /// Invalid indexes and unrecognized files are never discarded.
    func discardIncompleteSaves() throws {
        guard saving.isEmpty else { throw LAADriveOfflineError.alreadySaving }
        let referenced = Set(try readIndex().map(\.bodyName))
        for directory in [pending, files] where fileManager.fileExists(atPath: directory.path) {
            let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            for url in contents {
                let name = url.lastPathComponent
                guard UUID(uuidString: name)?.uuidString == name,
                      !referenced.contains(name),
                      try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func itemKey(pairingID: String, id: String) -> String { "\(pairingID.utf8.count):\(pairingID)\(id)" }
    private func isMissingFile(_ error: Error) -> Bool {
        let failure = error as NSError
        return (failure.domain == NSCocoaErrorDomain &&
                (failure.code == NSFileNoSuchFileError || failure.code == NSFileReadNoSuchFileError)) ||
            (failure.domain == NSPOSIXErrorDomain && failure.code == 2)
    }
    private func checkedMetadata(_ reader: MetadataReader, pairingID: String, id: String) async throws -> LAADriveOfflineMetadata {
        let result: LAADriveOfflineMetadata
        do { result = try await reader() }
        catch {
            try persistKnownDenial(error, pairingID: pairingID, id: id)
            throw error
        }
        if result.downloadable == false {
            try recordCheck(pairingID: pairingID, id: id, result: .denied)
            throw LAADriveOfflineError.forbidden
        }
        if result.downloadable != true || validVersion(result.version) == nil {
            try recordCheck(pairingID: pairingID, id: id, result: .metadata(result))
        }
        return result
    }
    private func persistKnownDenial(_ error: Error, pairingID: String, id: String) throws {
        guard let error = error as? LAADriveOfflineError else { return }
        if error == .forbidden { try recordCheck(pairingID: pairingID, id: id, result: .denied) }
        if error == .notFound { try recordCheck(pairingID: pairingID, id: id, result: .missing) }
    }
    private func validText(_ value: String, maximum: Int) -> Bool { (1...maximum).contains(value.utf8.count) }
    private func validVersion(_ version: String?) -> String? {
        guard let version, (1...30).contains(version.utf8.count),
              version.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return version
    }
    private func validated(_ metadata: LAADriveOfflineMetadata) throws -> (String, Int64) {
        let version = try validatedVersion(metadata)
        guard let size = metadata.size, size >= 0 else { throw LAADriveOfflineError.invalidItem }
        return (version, size)
    }
    private func validatedVersion(_ metadata: LAADriveOfflineMetadata) throws -> String {
        if metadata.downloadable == false { throw LAADriveOfflineError.forbidden }
        guard metadata.downloadable == true else { throw LAADriveOfflineError.permissionUnknown }
        guard let version = validVersion(metadata.version) else { throw LAADriveOfflineError.versionUnavailable }
        return version
    }
    private var protectionAttributes: [FileAttributeKey: Any]? {
        #if os(iOS)
        return [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        return nil
        #endif
    }
    private func prepareDirectories() throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: protectionAttributes)
        try fileManager.createDirectory(at: files, withIntermediateDirectories: true, attributes: protectionAttributes)
        try fileManager.createDirectory(at: pending, withIntermediateDirectories: true, attributes: protectionAttributes)
        #if os(iOS)
        var directory = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        #endif
    }
    private func readIndex() throws -> [LAADriveOfflineRecord] {
        guard fileManager.fileExists(atPath: index.path) else { return [] }
        do {
            let entries = try JSONDecoder().decode([LAADriveOfflineRecord].self, from: Data(contentsOf: index))
            guard entries.allSatisfy({ UUID(uuidString: $0.bodyName)?.uuidString == $0.bodyName && $0.size >= 0 &&
                                      ($0.sourceFormat != .workspacePDF || ($0.mimeType == "application/pdf" && $0.size <= 10_000_000)) &&
                                      validText($0.pairingID, maximum: 200) && validText($0.id, maximum: maximumIDBytes) &&
                                      validVersion($0.version) != nil && $0.sha256.utf8.count == 64 &&
                                      $0.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) }),
                  Set(entries.map { itemKey(pairingID: $0.pairingID, id: $0.id) }).count == entries.count,
                  Set(entries.map(\.bodyName)).count == entries.count else { throw LAADriveOfflineError.corruptIndex }
            return entries
        } catch { throw LAADriveOfflineError.corruptIndex }
    }
    private func writeIndex(_ entries: [LAADriveOfflineRecord]) throws {
        try prepareDirectories()
        let data = try JSONEncoder().encode(entries)
        #if os(iOS)
        try data.write(to: index, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: index, options: .atomic)
        #endif
    }
}
#endif
