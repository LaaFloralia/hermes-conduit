#if LAA_BUILD
import Foundation
import CryptoKit

/// Scope cached content to the paired Mac and device; never use an auth token as a cache key.
enum LAAStudioCache {
    @MainActor static func scope(_ bridge: LAABridgeSession) -> String {
        SHA256.hash(data: Data((bridge.address + "|" + (bridge.deviceID ?? "unpaired")).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func file(scope: String, item: String, directory: URL?) -> URL {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Studio/Cache")
        let name = SHA256.hash(data: Data((scope + "|" + item).utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(name + ".json")
    }
    static func loadSnapshot(scope: String, directory: URL? = nil) -> LAAStudioSnapshot? {
        load(LAAStudioSnapshot.self, scope: scope, item: "snapshot", directory: directory)
    }
    static func saveSnapshot(_ snapshot: LAAStudioSnapshot, scope: String, directory: URL? = nil) {
        save(snapshot, scope: scope, item: "snapshot", directory: directory)
    }
    static func exists(scope: String, item: String, directory: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: file(scope: scope, item: item, directory: directory).path)
    }
    static func load<T: Decodable>(_ type: T.Type, scope: String, item: String, directory: URL? = nil) -> T? {
        guard let data = try? Data(contentsOf: file(scope: scope, item: item, directory: directory)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    @discardableResult static func save<T: Encodable>(_ value: T, scope: String, item: String, directory: URL? = nil) -> Bool {
        let url = file(scope: scope, item: item, directory: directory)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var folder = url.deletingLastPathComponent(); try? folder.setResourceValues(values)
            return true
        } catch { return false }
    }
}
#endif
