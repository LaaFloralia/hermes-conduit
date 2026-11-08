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
    private let readCredentials: () throws -> LAABridgeCredentials?

    init(keychain: LAABridgeKeychain = .init(), client: LAABridgeClient = .init(),
         readCredentials: (() throws -> LAABridgeCredentials?)? = nil) {
        self.keychain = keychain
        self.client = client
        let read = readCredentials ?? { try keychain.read() }
        self.readCredentials = read
        do {
            credentials = try read()
            status = credentials == nil ? .unpaired : .paired
        } catch { status = .keychainError }
    }

    #if DEBUG
    /// An in-memory status for UI fixtures; no Keychain or network access.
    init(statusForTesting: Status, readCredentials: @escaping () throws -> LAABridgeCredentials? = { throw LAABridgeError.keychain }) {
        self.keychain = .init()
        self.client = .init()
        self.readCredentials = readCredentials
        self.status = statusForTesting
    }

    /// In-memory credentials for a local HTTP fixture; never written to Keychain.
    init(credentialsForTesting: LAABridgeCredentials) {
        self.keychain = .init()
        self.client = .init()
        self.readCredentials = { nil }
        self.credentials = credentialsForTesting
        self.status = .paired
    }
    #endif

    var address: String { credentials?.baseURL.absoluteString ?? LAABridgeEndpoint.defaultAddress }
    var deviceID: String? { credentials?.deviceID }

    /// A background launch can encounter protected Keychain data while locked.
    /// Retry only a missing or unreadable local item: an explicit 401/revocation
    /// must never be converted back to paired without a new enrollment.
    func retryReadingCredentialsIfNeeded() {
        guard status == .keychainError || status == .unpaired else { return }
        do {
            let loaded = try readCredentials()
            let next: Status = loaded == nil ? .unpaired : .paired
            guard next != status || loaded != credentials else { return }
            credentials = loaded
            status = next
            revision += 1
        } catch {
            guard status != .keychainError else { return }
            status = .keychainError
            revision += 1
        }
    }

    func driveRange(path: String, offset: Int64, length: Int, expectedVersion: String? = nil,
                    timeout: TimeInterval? = nil) async throws -> LAADriveRangeResponse {
        guard let current = credentials, status == .paired else { throw LAABridgeError.unauthorized }
        do {
            let result = try await client.driveRange(path: path, credentials: current, offset: offset, length: length,
                                                     expectedVersion: expectedVersion, timeout: timeout)
            guard current == credentials, status == .paired else { throw CancellationError() }
            return result
        } catch let error as LAABridgeHTTPError {
            if current == credentials, error.status == 401 {
                status = error.code == "token_revoked" ? .revoked : .unauthorized
                revision += 1
            }
            throw error
        }
    }

    func driveThumbnail(id: String) async throws -> Data {
        guard let current = credentials, status == .paired else { throw LAABridgeError.unauthorized }
        do {
            let result = try await client.driveThumbnail(id: id, credentials: current)
            guard current == credentials, status == .paired else { throw CancellationError() }
            return result
        } catch let error as LAABridgeHTTPError {
            recordBinaryError(error, current: current)
            throw error
        }
    }

    func driveExportPDF(id: String, expectedVersion: String? = nil) async throws -> LAADrivePDFExport {
        guard let current = credentials, status == .paired else { throw LAABridgeError.unauthorized }
        do {
            let result = try await client.driveExportPDF(id: id, credentials: current, expectedVersion: expectedVersion)
            guard current == credentials, status == .paired else { throw CancellationError() }
            return result
        } catch let error as LAABridgeHTTPError {
            recordBinaryError(error, current: current)
            throw error
        }
    }

    private func recordBinaryError(_ error: LAABridgeHTTPError, current: LAABridgeCredentials) {
        guard current == credentials, error.status == 401 else { return }
        status = error.code == "token_revoked" ? .revoked : .unauthorized
        revision += 1
    }

    func withAuthenticatedClient<T>(_ operation: (LAABridgeClient, LAABridgeCredentials) async throws -> T) async throws -> T {
        guard let current = credentials, status == .paired else { throw LAABridgeError.unauthorized }
        do {
            let result = try await operation(client, current)
            guard current == credentials, status == .paired else { throw CancellationError() }
            return result
        } catch let error as LAABridgeHTTPError {
            if current == credentials, error.status == 401 {
                status = error.code == "token_revoked" ? .revoked : .unauthorized
                revision += 1
            }
            throw error
        }
    }

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
                               ifNoneMatch: String? = nil, timeout: TimeInterval? = nil) async throws -> LAABridgeResponse<T> {
        guard let current = credentials, status == .paired else { throw LAABridgeError.unauthorized }
        do {
            let result: LAABridgeResponse<T> = try await client.request(
                method: method, path: path, jsonBody: jsonBody, credentials: current,
                idempotencyKey: idempotencyKey, ifMatch: ifMatch, ifNoneMatch: ifNoneMatch, timeout: timeout)
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

#endif
