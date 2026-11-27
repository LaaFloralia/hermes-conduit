#if LAA_BUILD
import Foundation
import Security

/// A write may have reached the Mac even if its reply was lost. Keep the
/// exact bytes and key in ThisDeviceOnly Keychain until it is reconciled.
struct LAABrainPendingStore {
    /// D-35 renamed the service. Until a later release removes the old item,
    /// both names hold the pending write, so a build from before the rename
    /// (a rollback) still finds it. It is never dropped on a guess: only
    /// `clear` removes it, and a retry reuses the same idempotency key.
    static let currentService = "com.laa.hortensia.brain-create-pending"
    static let legacyService = "com.laa.conduit.brain-create-pending"
    /// Tests pass their own names, so a real pending write is never touched.
    var service = LAABrainPendingStore.currentService
    var legacy = LAABrainPendingStore.legacyService
    private var query: [String: Any] { Self.query(service: service) }
    private var legacyQuery: [String: Any] { Self.query(service: legacy) }
    private static func query(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "pending"]
    }

    func read() throws -> LAABrainPending? {
        // A locked device throws here and never reads as "nothing pending".
        let current = try LAABridgeKeychain.item(query)
        let old: (data: Data, modified: Date?)?
        if current == nil { old = try LAABridgeKeychain.item(legacyQuery) }
        else { old = try? LAABridgeKeychain.item(legacyQuery) }
        guard let current else {
            guard let old else { return nil }
            let pending = try decode(old.data)
            // Insert only: a write saved at this moment is never overwritten.
            if LAABridgeKeychain.insert(old.data, query) == errSecDuplicateItem, let saved = try LAABridgeKeychain.item(query) {
                return try decode(saved.data)
            }
            return pending
        }
        // An older build saved a newer write after a rollback: that one is live.
        // Nothing is written here; `clear` removes both names.
        if let old, old.data != current.data, let then = current.modified, let later = old.modified,
           later > then, let pending = try? decode(old.data) {
            return pending
        }
        return try decode(current.data)
    }

    private func decode(_ data: Data) throws -> LAABrainPending {
        guard let pending = try? JSONDecoder().decode(LAABrainPending.self, from: data),
              LAABridgeIdempotencyKey(restoring: pending.keyValue) != nil else { throw LAABridgeError.keychain }
        return pending
    }

    func save(_ pending: LAABrainPending) throws {
        let data = try JSONEncoder().encode(pending)
        try LAABridgeKeychain.store(data, query)
        // The older build must find it too; otherwise nothing is kept and nothing is sent.
        do { try LAABridgeKeychain.store(data, legacyQuery) } catch {
            SecItemDelete(query as CFDictionary)
            throw error
        }
    }

    /// Both names must be gone, or the write would come back as pending.
    func clear() throws {
        let statuses = [SecItemDelete(legacyQuery as CFDictionary), SecItemDelete(query as CFDictionary)]
        guard statuses.allSatisfy({ $0 == errSecSuccess || $0 == errSecItemNotFound }) else { throw LAABridgeError.keychain }
    }
}
#endif
