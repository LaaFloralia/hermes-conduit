import Foundation

private final class RangeTimeoutProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var values: [TimeInterval] = []
    private static var versions: [String?] = []
    static var timeouts: [TimeInterval] { lock.withLock { values } }
    static var sentVersions: [String?] { lock.withLock { versions } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock {
            Self.values.append(request.timeoutInterval)
            Self.versions.append(request.value(forHTTPHeaderField: "x-laa-drive-version"))
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil,
                                       headerFields: ["Content-Range": "bytes 0-0/1", "Content-Length": "1",
                                                      "x-laa-drive-version": "42"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([1]))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// Both callers use the same public session signature after Studio integration.
@MainActor private func sessionAPITypecheck(_ bridge: LAABridgeSession) async throws {
    _ = try await bridge.driveRange(path: "/v1/drive/files/file_good/content", offset: 0, length: 1,
                                    expectedVersion: "42", timeout: 150)
    let studioPath = "/v1/studio/media/catalog/" + String(repeating: "a", count: 64) + ".pdf"
    _ = try await bridge.driveRange(path: studioPath, offset: 0, length: 1, timeout: 150)
}

@main private struct RangeVersionFixture {
    static func main() async throws {
        let credentials = LAABridgeCredentials(baseURL: URL(string: CommandLine.arguments[1])!,
                                                deviceID: "fixture", token: "fixture-token")
        let client = LAABridgeClient()
        func read(_ id: String, version: String? = nil) async throws -> LAADriveRangeResponse {
            try await client.driveRange(path: "/v1/drive/files/\(id)/content", credentials: credentials,
                                        offset: 0, length: 4, expectedVersion: version)
        }
        let correct = try await read("file_good", version: "42")
        precondition(correct.data == Data("test".utf8) && correct.version == "42" && correct.total == 4)
        let old = try await read("file_old")
        precondition(old.version == nil && old.data == Data("test".utf8))
        for id in ["file_changed", "file_old"] {
            do { _ = try await read(id, version: "42"); fatalError("expected version mismatch") }
            catch LAADriveRangeError.versionChanged { }
        }
        do { _ = try await read("file_bad"); fatalError("expected invalid version") }
        catch LAADriveRangeError.invalidRange { }
        do { _ = try await read("file_good", version: "x"); fatalError("expected invalid expected version") }
        catch LAABridgeError.invalidAddress { }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeTimeoutProtocol.self]
        let timeoutSession = URLSession(configuration: configuration)
        defer { timeoutSession.invalidateAndCancel() }
        let timeoutClient = LAABridgeClient(session: timeoutSession)
        _ = try await timeoutClient.driveRange(path: "/v1/drive/files/file_good/content", credentials: credentials,
                                               offset: 0, length: 1)
        let studioPath = "/v1/studio/media/catalog/" + String(repeating: "a", count: 64) + ".pdf"
        _ = try await timeoutClient.driveRange(path: studioPath, credentials: credentials,
                                               offset: 0, length: 1, timeout: 150)
        _ = try await timeoutClient.driveRange(path: "/v1/drive/files/file_good/content", credentials: credentials,
                                               offset: 0, length: 1, expectedVersion: "42", timeout: 90)
        precondition(RangeTimeoutProtocol.timeouts == [30, 150, 90], "default, Studio and pinned Drive timeouts")
        precondition(RangeTimeoutProtocol.sentVersions == [nil, nil, "42"], "timeout keeps the version header")
        print("Drive authenticated range version fixture passed")
    }
}
