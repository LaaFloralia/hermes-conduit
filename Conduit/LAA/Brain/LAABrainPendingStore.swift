#if LAA_BUILD
import Foundation
import Security

/// A write may have reached the Mac even if its reply was lost. Keep the
/// exact bytes and key in ThisDeviceOnly Keychain until it is reconciled.
struct LAABrainPendingStore {
    private let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.laa.conduit.brain-create-pending",
        kSecAttrAccount as String: "pending"
    ]

    func read() throws -> LAABrainPending? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let pending = try? JSONDecoder().decode(LAABrainPending.self, from: data),
              LAABridgeIdempotencyKey(restoring: pending.keyValue) != nil else { throw LAABridgeError.keychain }
        return pending
    }

    func save(_ pending: LAABrainPending) throws {
        let data = try JSONEncoder().encode(pending)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            attributes.forEach { add[$0.key] = $0.value }
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw LAABridgeError.keychain }
        } else if status != errSecSuccess { throw LAABridgeError.keychain }
    }

    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LAABridgeError.keychain }
    }
}
#endif
