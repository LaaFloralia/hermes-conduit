#if LAA_BUILD
import Foundation
import CryptoKit

/// A bounded device-scoped snapshot, displayed while the live read refreshes.
/// Cached data never authorizes a write or triggers a queued request.
enum LAALinearTaskCache {
    struct OwnerSnapshot: Codable { let items: [LAALinearTask] }
    struct BrowseSnapshot: Codable {
        let items: [LAAPersonalTask]
        let viewerId: String
        let observedAt: String?
    }
    private static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LinearSnapshots", isDirectory: true)
    }
    private static func file(device: String, scope: String) -> URL {
        let hash = SHA256.hash(data: Data("\(device)\u{1f}\(scope)".utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(hash + ".json")
    }
    static func read<T: Decodable>(device: String, scope: String) -> T? {
        let url = file(device: device, scope: scope)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1024 * 1024,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    static func save<T: Encodable>(_ snapshot: T, device: String, scope: String) {
        guard let data = try? JSONEncoder().encode(snapshot), data.count <= 4 * 1024 * 1024 else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Keep no more than 20 filter snapshots; this cache may be purged.
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
            if files.count >= 20 {
                let sorted = files.sorted {
                    let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return lhs < rhs
                }
                for old in sorted.prefix(files.count - 19) { try? FileManager.default.removeItem(at: old) }
            }
            try data.write(to: file(device: device, scope: scope), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { /* A cache failure never blocks the authoritative read. */ }
    }
}
#endif
