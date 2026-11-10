#if LAA_BUILD
import Foundation
import Security

/// Shared only with this app's widget extension. Credentials never enter the
/// App Group JSON, defaults, timeline entries, or logs.
struct LAAWidgetUsageConnection: Codable, Equatable {
    let baseURL: URL
    let deviceID: String
    let token: String

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.laa.usage.widget",
         kSecAttrAccount as String: "connection",
         kSecAttrAccessGroup as String: WidgetSnapshotStore.appGroup,
         kSecUseDataProtectionKeychain as String: true]
    }

    static func read() -> Self? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    static func save(_ connection: Self?) throws {
        guard let connection else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw RefreshError.keychain }
            return
        }
        guard read() != connection else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(connection),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            attributes.forEach { add[$0.key] = $0.value }
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw RefreshError.keychain }
        } else if status != errSecSuccess { throw RefreshError.keychain }
    }

    enum RefreshError: Error { case keychain, invalidResponse }
}

private final class LAAWidgetNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum LAAWidgetUsageRefresh {
    private struct Envelope: Decodable { let data: LAAUsagePage }

    /// One bounded authenticated read per OS-granted reload. The server serves
    /// an in-memory feed, so no upstream work is started by the widget.
    static func refresh(store: WidgetSnapshotStore? = .production,
                        readConnection: () -> LAAWidgetUsageConnection? = { LAAWidgetUsageConnection.read() },
                        saveConnection: (LAAWidgetUsageConnection?) throws -> Void = { try LAAWidgetUsageConnection.save($0) },
                        session suppliedSession: URLSession? = nil,
                        onSuccessfulFetch: () -> Void = {}) async -> WidgetSnapshot? {
        guard let store else { return nil }
        guard let connection = readConnection() else { return store.read() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        let session = suppliedSession ?? URLSession(configuration: configuration, delegate: LAAWidgetNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            var request = URLRequest(url: connection.baseURL.appendingPathComponent("v1/usage"))
            request.timeoutInterval = 8
            request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled, readConnection() == connection else { return store.read() }
            guard let response = response as? HTTPURLResponse else { throw LAAWidgetUsageConnection.RefreshError.invalidResponse }
            if [401, 403].contains(response.statusCode) {
                try? saveConnection(nil)
                try store.writeUsage(nil)
                try store.writeUsageItems(nil)
                return store.read()
            }
            guard response.statusCode == 200, data.count < 512 * 1024 else { throw LAAWidgetUsageConnection.RefreshError.invalidResponse }
            let page = try JSONDecoder().decode(Envelope.self, from: data).data
            guard page.nextCursor == nil else { throw LAAWidgetUsageConnection.RefreshError.invalidResponse }
            try store.updateUsage { previous in
                guard readConnection() == connection else { return previous }
                return LAAWidgetUsageBuilder.make(items: page.items, receivedAt: Date(), previous: previous)
            }
            onSuccessfulFetch()
        } catch {
            // A transport failure preserves the original observation. Freshness
            // remains a property of that observation, never of this attempt.
        }
        return store.read()
    }
}
#endif
