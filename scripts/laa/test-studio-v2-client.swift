// Host-side fixture for the real Studio data and Bridge client, without Xcode or a simulator.
// From the repo root, compile with:
// swiftc -D LAA_BUILD Conduit/LAA/LAABridgeClient.swift Conduit/LAA/Studio/LAAStudio{Models,Data,V2Models,V2Data}.swift scripts/laa/test-studio-v2-client.swift -o /tmp/test-studio-v2-client
// /tmp/test-studio-v2-client
import Foundation

enum LAACopy {}

// The session only supplies fixture credentials and forwards to the real Bridge client.
@MainActor final class LAABridgeSession {
    enum Status { case paired }
    let status: Status = .paired
    let credentials: LAABridgeCredentials
    let client: LAABridgeClient
    var deviceID: String? { credentials.deviceID }
    var revision = 0

    init(credentials: LAABridgeCredentials, client: LAABridgeClient) {
        self.credentials = credentials
        self.client = client
    }
    func request<T: Decodable>(method: String, path: String, jsonBody: Data? = nil,
                               idempotencyKey: LAABridgeIdempotencyKey? = nil, ifMatch: String? = nil,
                               ifNoneMatch: String? = nil, timeout: TimeInterval? = nil) async throws -> LAABridgeResponse<T> {
        try await client.request(method: method, path: path, jsonBody: jsonBody, credentials: credentials,
                                 idempotencyKey: idempotencyKey, ifMatch: ifMatch, ifNoneMatch: ifNoneMatch, timeout: timeout)
    }
}

private final class StudioFixtureProtocol: URLProtocol {
    static let oldTag = "\"" + String(repeating: "b", count: 64) + "\""
    static let newTag = "\"" + String(repeating: "c", count: 64) + "\""
    static let projectID = "70175325-5cf4-421f-8a6f-95beae8fca92"
    static let media = "/api/studio/media/catalog/" + String(repeating: "a", count: 64) + ".pdf"
    static var step = 0
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let step = Self.step
        Self.step += 1
        Self.lock.unlock()
        precondition(request.timeoutInterval == 45, "Studio v2 request timeout")
        let status: Int
        let body: Data
        let etag: String?
        switch step {
        case 0, 1:
            precondition(request.url?.path == "/v1/studio/catalog", "catalog path")
            precondition(request.value(forHTTPHeaderField: "If-None-Match") == (step == 0 ? nil : Self.oldTag), "old catalog validator")
            let tag = step == 0 ? Self.oldTag : Self.newTag
            let documents: [[String: Any]] = (1...8).map { index in
                var document: [String: Any] = ["id": "fixture-\(index)", "title": "Fixture \(index)",
                    "category": "Fixture", "detail": "Synthetic document", "format": "PDF",
                    "driveUrl": "https://drive.google.com/file/d/fixture-\(index)/view"]
                if step == 0 { document["unavailable"] = "source_unreadable" }
                else { document["media"] = Self.media; document["bytes"] = 321 }
                return document
            }
            let catalog: [String: Any] = ["etag": String(tag.dropFirst().dropLast()), "updatedAt": "2026-11-01T00:00:00Z",
                "principles": [], "adoptedPrincipleId": NSNull(), "documents": documents, "capabilities": [], "brief": []]
            body = try! JSONSerialization.data(withJSONObject: ["data": catalog, "requestId": "fixture"])
            status = 200
            etag = tag
        case 2:
            precondition(request.url?.path == "/v1/studio/catalog", "cached catalog path")
            precondition(request.value(forHTTPHeaderField: "If-None-Match") == Self.newTag, "new catalog validator")
            status = 304
            body = Data()
            etag = Self.newTag
        case 3:
            precondition(request.value(forHTTPHeaderField: "If-None-Match") == Self.newTag, "offline catalog validator")
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        case 4:
            precondition(request.url?.path == "/v1/studio/projects/\(Self.projectID)", "project path")
            let project: [String: Any] = ["id": Self.projectID, "title": "Fixture", "revision": 2, "pages": [], "assets": []]
            let detail: [String: Any] = ["project": project, "versions": [], "delivery": NSNull(), "reviews": []]
            body = try! JSONSerialization.data(withJSONObject: ["data": detail, "requestId": "fixture"])
            status = 200
            etag = nil
        default:
            preconditionFailure("Unexpected fixture request")
        }
        let headers = etag.map { ["ETag": $0] } ?? [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct StudioV2ClientTests {
    @MainActor static func main() async throws {
        let deviceID = "fixture-" + UUID().uuidString
        let cache = LAAStudioDraftStore.file(deviceID: deviceID)!.deletingLastPathComponent()
            .appendingPathComponent("catalog-\(deviceID).json")
        defer { try? FileManager.default.removeItem(at: cache) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StudioFixtureProtocol.self]
        let client = LAABridgeClient(session: URLSession(configuration: config))
        let credentials = LAABridgeCredentials(baseURL: URL(string: "https://fixture.ts.net:8445")!, deviceID: deviceID, token: "fixture")
        let bridge = LAABridgeSession(credentials: credentials, client: client)

        let old = try await LAAStudioData.catalog(bridge)
        precondition(!old.stale && old.catalog.documents.count == 8 && old.catalog.documents.allSatisfy { $0.unavailable == "source_unreadable" && $0.media == nil })
        let updated = try await LAAStudioData.catalog(bridge)
        precondition(!updated.stale && updated.catalog.documents.count == 8 && updated.catalog.documents.allSatisfy { $0.media == StudioFixtureProtocol.media && $0.bytes == 321 && $0.unavailable == nil })
        let unchanged = try await LAAStudioData.catalog(bridge)
        precondition(!unchanged.stale && unchanged.catalog.etag == updated.catalog.etag && unchanged.catalog.documents.allSatisfy { $0.bytes == 321 })
        let offline = try await LAAStudioData.catalog(bridge)
        precondition(offline.stale && offline.catalog.etag == updated.catalog.etag)
        let project = try await LAAStudioData.project(StudioFixtureProtocol.projectID, bridge: bridge)
        precondition(project.project.revision == 2 && StudioFixtureProtocol.step == 5)
        print("Studio v2 client: validator refresh, 304, offline cache and 45-second project timeout passed")
    }
}
