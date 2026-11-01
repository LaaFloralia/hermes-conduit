#if LAA_BUILD
import Foundation

/// Last confirmed list and previously opened details. Offline edits retain the
/// cached revision; the server's If-Match check still protects later changes.
struct LAAOwnerTaskCache: Codable, Equatable {
    var items: [LAAOwnerTask] = []
    var details: [LAAOwnerTask] = []
    var observedAt: Date?
}

@MainActor
enum LAAOwnerTaskCacheStore {
    private static func key(_ deviceID: String) -> ComposerDraftKey {
        ComposerDraftKey(profile: "laa-owner-task-cache-v1", sessionID: Data(deviceID.utf8).base64EncodedString(),
                         dashboardID: LAAWorkDrafts.dashboardID)
    }

    static func read(_ store: ComposerDraftStore, deviceID: String) -> LAAOwnerTaskCache? {
        guard !deviceID.isEmpty else { return nil }
        let key = key(deviceID)
        guard store.hasDraft(for: key), let data = store.draft(for: key).text.data(using: .utf8),
              let cache = try? JSONDecoder().decode(LAAOwnerTaskCache.self, from: data),
              Set(cache.items.map(\.id)).count == cache.items.count,
              Set(cache.details.map(\.id)).count == cache.details.count else { return nil }
        return cache
    }

    @discardableResult
    static func save(_ cache: LAAOwnerTaskCache, in store: ComposerDraftStore, deviceID: String) -> Bool {
        guard !deviceID.isEmpty else { return false }
        let key = key(deviceID)
        // A corrupt cache is not evidence that the protected snapshot is safe
        // to replace. Leave it in place for inspection.
        if store.hasDraft(for: key) && read(store, deviceID: deviceID) == nil { return false }
        guard let data = try? JSONEncoder().encode(cache), let text = String(data: data, encoding: .utf8) else { return false }
        return store.save(ComposerDraft(text: text, attachments: []), for: key)
    }
}
#endif
