#if DEBUG && LAA_BUILD
import XCTest
@testable import Conduit

final class LAALabLaneGuardTests: XCTestCase {
    private let origin = URL(string: "http://127.0.0.1:25001")!
    private var policy: LAALabNetworkPolicy {
        .init(environment: ["LAA_LANE_ID": "lab-a", "LAA_LANE_BRIDGE": origin.absoluteString,
                            "LAA_LANE_FIXTURE_HABITS": "http://127.0.0.1:25002",
                            "LAA_LANE_HERMES": "http://127.0.0.1:25003"])
    }

    func testOnlyConfiguredLaneOriginsAreAllowed() {
        XCTAssertTrue(policy.allowsBridge(origin))
        XCTAssertTrue(policy.allowsBridge(URL(string: "http://127.0.0.1:25002/v1/habits")))
        XCTAssertFalse(policy.allowsBridge(URL(string: "http://127.0.0.1:25003")))
        // The offline fixture (-LAA_UI_TEST_BRIDGE_OFFLINE) must stay a refused
        // connection inside a lane; every other legacy fixture port stays closed.
        XCTAssertTrue(policy.allowsBridge(URL(string: "http://127.0.0.1:1")))
        XCTAssertFalse(policy.allowsBridge(URL(string: "http://localhost:1")))
        XCTAssertFalse(policy.allowsBridge(URL(string: "http://127.0.0.1:19414")))
        XCTAssertFalse(policy.allowsBridge(URL(string: "http://user@127.0.0.1:25001")))
        XCTAssertFalse(policy.allowsBridge(URL(string: "http://127.1:25001")))
        XCTAssertFalse(policy.allowsBridge(URL(string: "https://test.example.ts.net:8445")))
        XCTAssertTrue(policy.allowsHermes(URL(string: "ws://127.0.0.1:25003/ws")))
        XCTAssertTrue(policy.allowsHermes(URL(string: "http://127.0.0.1:25003/api/status")))
        XCTAssertFalse(policy.allowsHermes(URL(string: "ws://127.0.0.1:9119/ws")))
        XCTAssertFalse(policy.allowsHermes(URL(string: "https://test.example.ts.net:8444")))
        XCTAssertFalse(policy.allowsPush)
    }

    func testLegacyTestSwitchRetainsFixturePortsButCannotReachProduction() throws {
        let legacy = LAALabNetworkPolicy(environment: ["CONDUIT_UITEST": "1", "LAA_BRIDGE_DEFAULT_ADDRESS": "http://localhost:9137"])
        XCTAssertFalse(legacy.allowsBridge(URL(string: "http://localhost:9137")))
        XCTAssertFalse(legacy.allowsBridge(URL(string: "http://[::1]:9119")))
        XCTAssertFalse(legacy.allowsHermes(origin))
        XCTAssertFalse(legacy.allowsPush)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:19584/v1/decisions")!)
        try legacy.stampBridgeRequest(&request)
        XCTAssertNil(request.value(forHTTPHeaderField: LAALabNetworkPolicy.header))
        let ordinary = LAALabNetworkPolicy(environment: [:])
        XCTAssertFalse(ordinary.isActive)
        XCTAssertTrue(ordinary.allowsPush)
        XCTAssertTrue(ordinary.allowsHermes(URL(string: "wss://example.com/ws")))
    }

    func testBridgeRefusesLegacyPeerBeforeSendingWriteOrToken() async throws {
        let spy = Stub(healthLane: nil, replyLane: "lab-a")
        let client = LAABridgeClient(labSession: spy.makeSession(), labPolicy: policy)
        do {
            let _: LAABridgeResponse<Payload> = try await client.request(method: "POST", path: "/v1/decisions",
                jsonBody: Data("{}".utf8), credentials: credentials, idempotencyKey: .init())
            XCTFail("legacy peer accepted")
        } catch {
            XCTAssertEqual(error as? LAABridgeError, .laneMismatch)
        }
        let sent = spy.requests
        XCTAssertEqual(sent.map { $0.url?.path }, ["/v1/health"])
        XCTAssertEqual(sent.first?.value(forHTTPHeaderField: LAALabNetworkPolicy.header), "lab-a")
        XCTAssertNil(sent.first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(sent.first?.httpMethod, "GET")
    }

    func testBridgeCannotDecodeWrongLaneSuccessOrErrorBody() async throws {
        for status in [200, 403] {
            let spy = Stub(healthLane: "lab-a", replyLane: "lab-b", replyStatus: status)
            let client = LAABridgeClient(labSession: spy.makeSession(), labPolicy: policy)
            do {
                let _: Payload = try await client.get("/v1/decisions", credentials: credentials)
                XCTFail("other lane accepted")
            } catch {
                XCTAssertEqual(error as? LAABridgeError, .laneMismatch)
            }
            XCTAssertEqual(spy.requests.map { $0.url?.path }, ["/v1/health", "/v1/decisions"])
            XCTAssertTrue(spy.requests.allSatisfy { $0.value(forHTTPHeaderField: LAALabNetworkPolicy.header) == "lab-a" })
        }
    }

    func testMatchingResponseCanBeDecodedBut421Cannot() async throws {
        let spy = Stub(healthLane: "lab-a", replyLane: "lab-a")
        let client = LAABridgeClient(labSession: spy.makeSession(), labPolicy: policy)
        let result: Payload = try await client.get("/v1/decisions", credentials: credentials)
        XCTAssertEqual(result.value, true)
        let refusal = HTTPURLResponse(url: origin, statusCode: 421, httpVersion: nil, headerFields: ["X-LAA-Lane": "lab-a"])!
        XCTAssertThrowsError(try policy.verifyBridgeResponse(refusal)) { XCTAssertEqual($0 as? LAABridgeError, .laneMismatch) }
    }

    private var credentials: LAABridgeCredentials { .init(baseURL: origin, deviceID: "fixture", token: "test-only") }
    private struct Payload: Decodable { let value: Bool }

    private final class Stub: @unchecked Sendable {
        let healthLane: String?
        let replyLane: String?
        let replyStatus: Int
        private let lock = NSLock()
        private var values: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { values } }

        init(healthLane: String?, replyLane: String?, replyStatus: Int = 200) {
            self.healthLane = healthLane
            self.replyLane = replyLane
            self.replyStatus = replyStatus
        }
        func makeSession() -> URLSession {
            StubProtocol.stub = self
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [StubProtocol.self]
            return URLSession(configuration: config)
        }
        func answer(_ request: URLRequest) -> (HTTPURLResponse, Data) {
            lock.withLock { values.append(request) }
            let health = request.url?.path == "/v1/health"
            var fields: [String: String] = [:]
            if let lane = health ? healthLane : replyLane { fields["X-LAA-Lane"] = lane }
            let response = HTTPURLResponse(url: request.url!, statusCode: health ? 200 : replyStatus, httpVersion: "HTTP/1.1", headerFields: fields)!
            let body = Data(#"{"data":{"value":true},"requestId":"fixture"}"#.utf8)
            return (response, body)
        }
    }

    private final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var stub: Stub?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let (response, body) = Self.stub?.answer(request) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
}
#endif
