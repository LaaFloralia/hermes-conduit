#if LAA_BUILD
import Foundation
import CryptoKit

/// The shared Drive/Studio player reports one of these states on the main actor.
enum LAADrivePlaybackState: Equatable {
    case loading
    case paused
    case playing
    case ended
    case failed(String)
}

/// Resume information is scoped to the paired device, content and its version.
/// The persisted key is a digest, not a filename, path, or credential.
struct LAADrivePlaybackIdentity: Hashable {
    fileprivate let digest: String

    init?(pairingID: String?, contentID: String, version: String?) {
        guard let pairingID, let version,
              (1...200).contains(pairingID.utf8.count),
              (1...1024).contains(contentID.utf8.count),
              (1...200).contains(version.utf8.count),
              let encoded = try? JSONEncoder().encode([pairingID, contentID, version]) else { return nil }
        digest = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }
}

/// Keeps a bounded set of last positions. It never persists an identity when
/// the current file's version is unknown, and removes an entry on completion.
@MainActor
final class LAADriveResumeStore {
    private struct Entry: Codable {
        var seconds: Double
        var updatedAt: Date
    }
    private let defaults: UserDefaults
    private let storageKey: String
    private let maximumEntries: Int

    init(defaults: UserDefaults = .standard, storageKey: String = "laa.drive.playback.positions.v1",
         maximumEntries: Int = 200) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.maximumEntries = max(1, maximumEntries)
    }

    func position(for identity: LAADrivePlaybackIdentity?, duration: Double? = nil) -> Double? {
        guard let identity, let entry = read()[identity.digest],
              entry.seconds.isFinite, entry.seconds > 0 else { return nil }
        if let duration, duration.isFinite, duration > 0, entry.seconds >= duration { return nil }
        return entry.seconds
    }

    func save(_ seconds: Double, for identity: LAADrivePlaybackIdentity?, now: Date = Date()) {
        guard let identity, seconds.isFinite, seconds > 0 else { return }
        var entries = read()
        entries[identity.digest] = Entry(seconds: seconds, updatedAt: now)
        if entries.count > maximumEntries {
            let oldest = entries.sorted { $0.value.updatedAt < $1.value.updatedAt }
            for pair in oldest.prefix(entries.count - maximumEntries) { entries.removeValue(forKey: pair.key) }
        }
        write(entries)
    }

    func clear(_ identity: LAADrivePlaybackIdentity?) {
        guard let identity else { return }
        var entries = read()
        guard entries.removeValue(forKey: identity.digest) != nil else { return }
        write(entries)
    }

    private func read() -> [String: Entry] {
        guard let data = defaults.data(forKey: storageKey),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return entries
    }

    private func write(_ entries: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
#endif
