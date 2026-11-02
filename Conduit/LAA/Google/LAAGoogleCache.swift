#if LAA_BUILD
import CryptoKit
import Foundation

/// Small, protected metadata only. Pairing identity is part of every key.
enum LAAGoogleCache {
    private static func url(_ key: String) -> URL? {
        guard let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = root.appendingPathComponent("GoogleMetadata", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(digest + ".json")
    }
    static func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let url = url(key), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    static func save<T: Encodable>(_ value: T, key: String) {
        guard let url = url(key), let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
#endif
