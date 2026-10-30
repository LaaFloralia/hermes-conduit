#if LAA_BUILD
import Foundation
import Combine

@MainActor
final class LAABridgeSession: ObservableObject {
    enum Status: Equatable { case unpaired, paired, revoked, unauthorized, keychainError }
    @Published private(set) var status: Status
    @Published private(set) var revision = 0
    private var credentials: LAABridgeCredentials?
    private let keychain: LAABridgeKeychain
    private let client: LAABridgeClient

    init(keychain: LAABridgeKeychain = .init(), client: LAABridgeClient = .init()) {
        self.keychain = keychain
        self.client = client
        do {
            credentials = try keychain.read()
            status = credentials == nil ? .unpaired : .paired
        } catch { status = .keychainError }
    }

    #if DEBUG
    /// An in-memory status for UI fixtures; no Keychain or network access.
    init(statusForTesting: Status) {
        self.keychain = .init()
        self.client = .init()
        self.status = statusForTesting
    }
    #endif

    var address: String { credentials?.baseURL.absoluteString ?? LAABridgeEndpoint.defaultAddress }
    var deviceID: String? { credentials?.deviceID }

    func pair(address: String, code: String, name: String) async throws {
        let url = try LAABridgeEndpoint.parse(address)
        let enrolled = try await client.enroll(baseURL: url, code: code, name: name)
        let newCredentials = LAABridgeCredentials(baseURL: url, deviceID: enrolled.deviceId, token: enrolled.token)
        // Do not adopt or display success until the one-time token is safely stored.
        try keychain.save(newCredentials)
        credentials = newCredentials
        status = .paired
        revision += 1
    }

    private struct Device: Decodable { let deviceId: String }

    func verify() async throws {
        let _: Device = try await read("/v1/me")
    }

    func read<T: Decodable>(_ path: String) async throws -> T {
        guard let current = credentials, status == .paired else { throw LAABridgeError.unauthorized }
        do {
            let result: T = try await client.get(path, credentials: current)
            guard current == credentials, status == .paired else { throw CancellationError() }
            return result
        } catch let error as LAABridgeError {
            if current == credentials {
                if error == .revoked || error == .unauthorized {
                    status = error == .revoked ? .revoked : .unauthorized
                    revision += 1
                }
            }
            throw error
        }
    }

    /// Use wait + 10 seconds as the timeout for a long-poll request.
    func request<T: Decodable>(method: String, path: String, jsonBody: Data? = nil,
                               idempotencyKey: LAABridgeIdempotencyKey? = nil, ifMatch: String? = nil,
                               timeout: TimeInterval? = nil) async throws -> LAABridgeResponse<T> {
        guard let current = credentials, status == .paired else { throw LAABridgeError.unauthorized }
        do {
            let result: LAABridgeResponse<T> = try await client.request(
                method: method, path: path, jsonBody: jsonBody, credentials: current,
                idempotencyKey: idempotencyKey, ifMatch: ifMatch, timeout: timeout)
            guard current == credentials, status == .paired else { throw CancellationError() }
            return result
        } catch let error as LAABridgeHTTPError {
            if current == credentials {
                let legacy = error.legacyError
                if legacy == .revoked || legacy == .unauthorized {
                    status = legacy == .revoked ? .revoked : .unauthorized
                    revision += 1
                }
            }
            throw error
        }
    }
}

enum LAAScreenState {
    case bridgeNotPaired, revoked, connected, loading, empty, failed

    static func current(_ status: LAABridgeSession.Status) -> LAAScreenState {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-laa-state"), index + 1 < arguments.count {
            switch arguments[index + 1] {
            case "loading": return .loading
            case "empty": return .empty
            case "failed": return .failed
            default: break
            }
        }
        #endif
        switch status {
        case .paired: return .connected
        case .revoked, .unauthorized: return .revoked
        case .unpaired: return .bridgeNotPaired
        case .keychainError: return .failed
        }
    }
}
#endif
