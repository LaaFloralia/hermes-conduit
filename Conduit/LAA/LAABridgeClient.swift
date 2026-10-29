#if LAA_BUILD
import Foundation
import Security

struct LAABridgeCredentials: Codable, Equatable {
    let baseURL: URL
    let deviceID: String
    let token: String
}

struct LAABridgeEndpoint {
    // The Mac's Tailscale Serve address recorded in docs/laa/BASELINE.md.
    static let defaultAddress = "https://mac-mini.tailc9b8e7.ts.net:8445"

    static func parse(_ text: String) throws -> URL {
        guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(),
              !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/" else {
            throw LAABridgeError.invalidAddress
        }
        var allowed = scheme == "https" && host.hasSuffix(".ts.net")
        #if DEBUG && targetEnvironment(simulator)
        if scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) {
            allowed = true
        }
        #endif
        guard allowed else { throw LAABridgeError.invalidAddress }
        parts.scheme = scheme
        parts.path = ""
        if parts.port == nil { parts.port = 8445 }
        guard let url = parts.url else { throw LAABridgeError.invalidAddress }
        return url
    }
}

enum LAABridgeError: Error, Equatable {
    case invalidAddress, networkUnreachable, tlsFailed, invalidResponse, keychain
    case revoked, unauthorized, forbidden, conflict, expired, rateLimited, unavailable
    case other(status: Int, code: String?)

    static func response(status: Int, code: String?) -> LAABridgeError {
        switch status {
        case 401: return code == "token_revoked" ? .revoked : .unauthorized
        case 403: return .forbidden
        case 409: return .conflict
        case 410: return .expired
        case 429: return .rateLimited
        case 503: return .unavailable
        default: return .other(status: status, code: code)
        }
    }

    var japaneseText: String {
        switch self {
        case .invalidAddress: return "接続先はTailscaleのHTTPSアドレスで入力してください。"
        case .networkUnreachable: return "Macに届きません。TailscaleとMacの接続を確認してください。"
        case .tlsFailed: return "安全な接続を確認できません。接続先と証明書を確認してください。"
        case .invalidResponse: return "Macからの応答を読み取れませんでした。"
        case .keychain: return "接続情報を端末に保存または読み出しできませんでした。"
        case .revoked: return "この端末の接続は失効しています。新しいコードで接続してください。"
        case .unauthorized: return "認証できませんでした。コードの期限と入力を確認してください。"
        case .forbidden: return "この端末には必要な権限がありません。"
        case .conflict: return "操作が競合しました。状態を確認してください。"
        case .expired: return "取得位置の期限が切れました。もう一度読み込んでください。"
        case .rateLimited: return "試行が多すぎます。時間をおいてからお試しください。"
        case .unavailable: return "Mac側のサービスを利用できません。"
        case .other: return "Macからデータを取得できませんでした。"
        }
    }
}

/// Generate once per logical write and retain the same key when checking its result.
struct LAABridgeIdempotencyKey: Hashable {
    let value: String
    init() { value = UUID().uuidString.lowercased() }
    init?(restoring value: String) {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        guard (1...200).contains(value.utf8.count), value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        self.value = value
    }
}

private struct BridgeEnvelope<T: Decodable>: Decodable {
    let data: T
    let requestId: String
}
private struct BridgeErrorEnvelope: Decodable {
    struct Detail: Decodable { let code: String }
    let error: Detail
}
struct LAABridgeEnrollment: Decodable {
    let deviceId: String
    let token: String
    let scopes: [String]
}

private final class LAANoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct LAABridgeClient {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: config, delegate: LAANoRedirects(), delegateQueue: nil)
    }

    func enroll(baseURL: URL, code: String, name: String) async throws -> LAABridgeEnrollment {
        let body = try JSONEncoder().encode(EnrollmentRequest(code: code, name: name, platform: "ios"))
        return try await request(baseURL: baseURL, path: "/v1/devices/enroll", method: "POST", body: body)
    }

    func get<T: Decodable>(_ path: String, credentials: LAABridgeCredentials) async throws -> T {
        try await request(baseURL: credentials.baseURL, path: path, token: credentials.token)
    }

    /// Callers own the key and request bytes; this client never retries writes.
    func write<T: Decodable>(_ path: String, method: String, body: Data,
                             credentials: LAABridgeCredentials, key: LAABridgeIdempotencyKey) async throws -> T {
        try await request(baseURL: credentials.baseURL, path: path, method: method,
                          body: body, token: credentials.token, key: key)
    }

    private struct EnrollmentRequest: Encodable { let code: String; let name: String; let platform: String }

    private func request<T: Decodable>(baseURL: URL, path: String, method: String = "GET",
                                        body: Data? = nil, token: String? = nil,
                                        key: LAABridgeIdempotencyKey? = nil) async throws -> T {
        guard path.hasPrefix("/v1/"), !path.hasPrefix("//"),
              let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              url.host == baseURL.host, url.scheme == baseURL.scheme, url.port == baseURL.port else {
            throw LAABridgeError.invalidAddress
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let key { request.setValue(key.value, forHTTPHeaderField: "Idempotency-Key") }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            switch error.code {
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
                 .clientCertificateRequired:
                throw LAABridgeError.tlsFailed
            case .cancelled: throw CancellationError()
            default: throw LAABridgeError.networkUnreachable
            }
        } catch { throw LAABridgeError.networkUnreachable }
        guard let http = response as? HTTPURLResponse else { throw LAABridgeError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(BridgeErrorEnvelope.self, from: data))?.error.code
            throw LAABridgeError.response(status: http.statusCode, code: code)
        }
        guard let envelope = try? JSONDecoder().decode(BridgeEnvelope<T>.self, from: data) else {
            throw LAABridgeError.invalidResponse
        }
        return envelope.data
    }
}

struct LAABridgeKeychain {
    private let service = "com.laa.conduit.bridge"
    private let account = "device"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read() throws -> LAABridgeCredentials? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let credentials = try? JSONDecoder().decode(LAABridgeCredentials.self, from: data),
              (try? LAABridgeEndpoint.parse(credentials.baseURL.absoluteString)) == credentials.baseURL else {
            throw LAABridgeError.keychain
        }
        return credentials
    }

    func save(_ credentials: LAABridgeCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            attrs.forEach { add[$0.key] = $0.value }
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw LAABridgeError.keychain }
        } else if status != errSecSuccess { throw LAABridgeError.keychain }
    }
}
#endif
