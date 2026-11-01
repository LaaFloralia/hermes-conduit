import Foundation

@main struct PlaybackStateFixture {
    @MainActor static func main() {
        let suite = "test.laa.drive-resume.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("fixture defaults unavailable") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LAADriveResumeStore(defaults: defaults, maximumEntries: 2)
        let first = LAADrivePlaybackIdentity(pairingID: "pairing-a", contentID: "drive/file-1", version: "11")!
        let nextVersion = LAADrivePlaybackIdentity(pairingID: "pairing-a", contentID: "drive/file-1", version: "12")!
        let otherPairing = LAADrivePlaybackIdentity(pairingID: "pairing-b", contentID: "drive/file-1", version: "11")!
        let studioOne = LAADrivePlaybackIdentity(pairingID: "pairing-a", contentID: "/v1/studio/media/project/aaa.mp4", version: "content-addressed")!
        let studioTwo = LAADrivePlaybackIdentity(pairingID: "pairing-a", contentID: "/v1/studio/media/project/bbb.mp4", version: "content-addressed")!
        precondition(studioOne != studioTwo)
        precondition(LAADrivePlaybackIdentity(pairingID: "pairing-a", contentID: "file-1", version: nil) == nil)
        precondition(LAADrivePlaybackIdentity(pairingID: nil, contentID: "file-1", version: "1") == nil)
        store.save(42, for: first, now: Date(timeIntervalSince1970: 1))
        precondition(store.position(for: first) == 42)
        precondition(store.position(for: nextVersion) == nil)
        precondition(store.position(for: otherPairing) == nil)
        precondition(store.position(for: first, duration: 40) == nil)
        store.save(.nan, for: first)
        store.save(-1, for: first)
        precondition(store.position(for: first) == 42)
        let persisted = String(data: defaults.data(forKey: "laa.drive.playback.positions.v1")!, encoding: .utf8)!
        precondition(!persisted.contains("file-1") && !persisted.contains("pairing-a"))
        let reloaded = LAADriveResumeStore(defaults: defaults, maximumEntries: 2)
        precondition(reloaded.position(for: first) == 42)
        store.save(3, for: nextVersion, now: Date(timeIntervalSince1970: 2))
        store.save(4, for: otherPairing, now: Date(timeIntervalSince1970: 3))
        precondition(store.position(for: first) == nil)
        precondition(store.position(for: nextVersion) == 3)
        precondition(store.position(for: otherPairing) == 4)
        store.clear(nextVersion)
        precondition(store.position(for: nextVersion) == nil)
        precondition(store.position(for: otherPairing) == 4)
        print("Drive playback resume fixture passed")
    }
}
