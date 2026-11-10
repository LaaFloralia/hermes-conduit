#if LAA_BUILD
import Foundation
import CryptoKit

enum LAADriveThumbnailError: Error, Equatable { case tooLarge }

private struct LAADriveThumbnailErrorEnvelope: Decodable {
    struct Detail: Decodable { let code: String?; let message: String?; let retryable: Bool? }
    let error: Detail
    let requestId: String?
}

extension LAABridgeClient {
    /// Fetch only from the authenticated Bridge; never expose its bearer to a
    /// thumbnail URL from Drive. The existing session refuses redirects.
    func driveThumbnail(id: String, credentials: LAABridgeCredentials) async throws -> Data {
        try await LAADriveThumbnailQueue.shared.acquire()
        do {
            let result = try await fetchDriveThumbnail(id: id, credentials: credentials)
            await LAADriveThumbnailQueue.shared.release()
            return result
        } catch {
            await LAADriveThumbnailQueue.shared.release()
            throw error
        }
    }

    private func fetchDriveThumbnail(id: String, credentials: LAABridgeCredentials) async throws -> Data {
        try Task.checkCancellation()
        let maximum = 2 * 1024 * 1024
        let path = try LAADrivePaths.metadata(id) + "/thumbnail"
        guard let url = URL(string: path, relativeTo: credentials.baseURL)?.absoluteURL,
              url.scheme == credentials.baseURL.scheme, url.host == credentials.baseURL.host,
              url.port == credentials.baseURL.port else { throw LAABridgeError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue("image/jpeg, image/png, image/gif, image/webp", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await rangeSession.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw LAABridgeError.invalidResponse }
            guard http.statusCode == 200 else {
                var body = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard body.count < 8192 else { break }
                    body.append(byte)
                }
                let envelope = try? JSONDecoder().decode(LAADriveThumbnailErrorEnvelope.self, from: body)
                throw LAABridgeHTTPError(status: http.statusCode, code: envelope?.error.code,
                                         message: envelope?.error.message, retryable: envelope?.error.retryable,
                                         details: nil, requestId: envelope?.requestId, currentETag: nil)
            }
            guard let mime = http.mimeType?.lowercased(),
                  ["image/jpeg", "image/png", "image/gif", "image/webp"].contains(mime) else {
                throw LAABridgeError.invalidResponse
            }
            var declaredLength: Int?
            if let length = http.value(forHTTPHeaderField: "Content-Length") {
                guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }),
                      let parsed = Int(length) else { throw LAABridgeError.invalidResponse }
                guard parsed <= maximum else { throw LAADriveThumbnailError.tooLarge }
                declaredLength = parsed
            }
            var data = Data()
            if let declaredLength { data.reserveCapacity(declaredLength) }
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximum else { throw LAADriveThumbnailError.tooLarge }
                data.append(byte)
            }
            guard declaredLength == nil || declaredLength == data.count,
                  Self.validThumbnailBytes(data, mime: mime) else { throw LAABridgeError.invalidResponse }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            switch error.code {
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
                 .clientCertificateRequired: throw LAABridgeError.tlsFailed
            default: throw LAABridgeError.networkUnreachable
            }
        }
    }

    private static func validThumbnailBytes(_ data: Data, mime: String) -> Bool {
        switch mime {
        case "image/jpeg": return data.starts(with: [0xff, 0xd8, 0xff])
        case "image/png": return data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        case "image/gif": return data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8))
        case "image/webp":
            return data.count >= 12 && data.starts(with: Data("RIFF".utf8)) &&
                data.subdata(in: 8..<12) == Data("WEBP".utf8)
        default: return false
        }
    }
}

/// Leave connections for video, metadata and long polls when a grid appears.
actor LAADriveThumbnailQueue {
    static let shared = LAADriveThumbnailQueue()
    private let maximum: Int
    private var active = 0
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    init(maximum: Int = 6) { self.maximum = max(1, maximum) }

    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if active < maximum { active += 1; continuation.resume() }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }

    func release() {
        if !waiters.isEmpty { waiters.removeFirst().1.resume() }
        else { active -= 1 }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
}

/// Strictly bounded compressed bytes. A versionless image is never cached;
/// a new pairing or thumbnail version has a different key.
struct LAADriveThumbnailKey: Hashable {
    let pairingID: String
    let fileID: String
    let version: String

    init?(pairingID: String, fileID: String, version: String?) {
        guard (1...200).contains(pairingID.utf8.count), (try? LAADrivePaths.metadata(fileID)) != nil,
              let version, (1...30).contains(version.utf8.count),
              version.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        self.pairingID = pairingID; self.fileID = fileID; self.version = version
    }
}

actor LAADriveThumbnailCache {
    private struct Entry { let data: Data; var lastUsed: UInt64 }
    private let maximumBytes: Int
    private let maximumEntries: Int
    private var bytes = 0
    private var clock: UInt64 = 0
    private var entries: [LAADriveThumbnailKey: Entry] = [:]
    private let diskDirectory: URL?
    private let maximumDiskBytes: Int

    init(maximumBytes: Int = 8 * 1024 * 1024, maximumEntries: Int = 100,
         diskDirectory: URL? = nil, maximumDiskBytes: Int = 32 * 1024 * 1024) {
        self.maximumBytes = max(0, maximumBytes)
        self.maximumEntries = max(0, maximumEntries)
        self.diskDirectory = diskDirectory
        self.maximumDiskBytes = max(0, maximumDiskBytes)
    }

    func value(for key: LAADriveThumbnailKey?) -> Data? {
        guard let key else { return nil }
        guard var entry = entries[key] else {
            guard maximumDiskBytes > 0, let file = diskURL(key), let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, size > 0, size <= min(maximumBytes, 2 * 1024 * 1024),
                  let modified = values.contentModificationDate, Date().timeIntervalSince(modified) < 86_400,
                  let data = try? Data(contentsOf: file), data.count == size else { return nil }
            insert(data, for: key)
            return data
        }
        clock &+= 1; entry.lastUsed = clock; entries[key] = entry
        return entry.data
    }

    func insert(_ data: Data, for key: LAADriveThumbnailKey?) {
        guard let key else { return }
        remove(key)
        guard !data.isEmpty, data.count <= maximumBytes, maximumEntries > 0 else { return }
        while bytes > maximumBytes - data.count || entries.count >= maximumEntries {
            guard let oldest = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key else { break }
            remove(oldest)
        }
        clock &+= 1
        entries[key] = Entry(data: data, lastUsed: clock)
        bytes += data.count
        if let file = diskURL(key), data.count <= maximumDiskBytes {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            trimDisk()
        }
    }

    /// Call when metadata reports access loss, or clear all on pairing changes.
    func invalidate(pairingID: String, fileID: String) {
        for key in entries.keys.filter({ $0.pairingID == pairingID && $0.fileID == fileID }) { remove(key) }
        let prefix = diskPrefix(pairingID: pairingID, fileID: fileID) + "-"
        for file in diskFiles() where file.lastPathComponent.hasPrefix(prefix) { try? FileManager.default.removeItem(at: file) }
    }

    func removeAll() {
        entries.removeAll(); bytes = 0
        for file in diskFiles() { try? FileManager.default.removeItem(at: file) }
    }

    static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DriveThumbnails-v1", isDirectory: true)
    }

    private func diskPrefix(pairingID: String, fileID: String) -> String {
        let data = (try? JSONEncoder().encode([pairingID, fileID])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func diskURL(_ key: LAADriveThumbnailKey) -> URL? {
        diskDirectory?.appendingPathComponent(diskPrefix(pairingID: key.pairingID, fileID: key.fileID) + "-" + key.version + ".thumb")
    }

    private func diskFiles() -> [URL] {
        guard let diskDirectory else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: diskDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []).filter { $0.pathExtension == "thumb" }
    }

    private func trimDisk() {
        let files = diskFiles().map { file in
            (file, try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]))
        }.sorted { ($0.1?.contentModificationDate ?? .distantPast) < ($1.1?.contentModificationDate ?? .distantPast) }
        var total = files.reduce(0) { $0 + ($1.1?.fileSize ?? 0) }
        var count = files.count
        for (file, values) in files {
            let expired = Date().timeIntervalSince(values?.contentModificationDate ?? .distantPast) >= 86_400
            if expired || total > maximumDiskBytes || count > maximumEntries {
                try? FileManager.default.removeItem(at: file)
                total -= values?.fileSize ?? 0; count -= 1
            }
        }
    }

    private func remove(_ key: LAADriveThumbnailKey) {
        if let previous = entries.removeValue(forKey: key) { bytes -= previous.data.count }
    }
}
#endif
