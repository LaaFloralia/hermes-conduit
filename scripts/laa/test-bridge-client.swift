#if LAA_BUILD
import Foundation

final class BridgeMockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct BridgeClientTests {
    static func require(_ condition: @autoclosure () -> Bool, _ name: String) {
        if !condition() { fputs("FAILED: \(name)\n", stderr); exit(1) }
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        func fixture(_ name: String) throws -> LAAUsagePage {
            struct Envelope: Decodable { let data: LAAUsagePage }
            let data = try Data(contentsOf: root.appendingPathComponent("docs/laa/fixtures/usage/\(name).json"))
            return try JSONDecoder().decode(Envelope.self, from: data).data
        }
        let normal = try fixture("usage-normal")
        let degraded = try fixture("usage-degraded")
        let mac = try fixture("mac-status-normal")
        let unavailable = try fixture("mac-status-unavailable")
        require(normal.items.first { $0.label == "Claude" }?.detail?.windows?.count == 2, "quota windows")
        require(normal.items.first { $0.label == "DeepSeek" }?.availableValue == nil, "missing balance stays nil")
        require(normal.items.first { $0.label == "Gemini API" }?.availableValue == 0, "real zero stays zero")
        require(normal.items.first { $0.label == "Gemini API" }?.isExpired() == true, "expired balance")
        require(degraded.items.first { $0.label == "Claude" }?.stale == true, "stale quota")
        require(degraded.items.first { $0.label == "Codex" }?.availableValue == nil, "unavailable quota")
        require(mac.items.first { $0.kind == "host.memory" }?.detail?.totalBytes != nil, "memory total")
        require(unavailable.items.first { $0.kind == "host.cpu" }?.availableValue == nil, "missing CPU")
        require(unavailable.items.first { $0.kind == "host.disk" }?.stale == true, "stale disk")
        require(LAAUsageItem.date("2026-10-29T04:49:23.123Z") != nil, "fractional timestamp")
        require(LAABridgeError.response(status: 401, code: "token_revoked") == .revoked, "revoked")
        require(LAABridgeError.response(status: 401, code: "pairing_code_expired") == .unauthorized, "pair code")
        require(LAABridgeError.response(status: 403, code: nil) == .forbidden, "scope")
        require(LAABridgeError.response(status: 409, code: nil) == .conflict, "conflict")
        require(LAABridgeError.response(status: 410, code: nil) == .expired, "expired cursor")
        require(LAABridgeError.response(status: 429, code: nil) == .rateLimited, "rate limit")
        require(LAABridgeError.response(status: 503, code: nil) == .unavailable, "dependency")
        let base = try LAABridgeEndpoint.parse("https://example.ts.net")
        require(base.port == 8445, "default port")
        require((try? LAABridgeEndpoint.parse("http://example.ts.net")) == nil, "remote HTTP rejected")
        require((try? LAABridgeEndpoint.parse("https://example.com")) == nil, "non-Tailscale host rejected")
        require((try? LAABridgeEndpoint.parse("https://example.ts.net/path")) == nil, "path rejected")
        require((try? LAABridgeEndpoint.parse("https://user:pass@example.ts.net")) == nil, "credentials in URL rejected")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BridgeMockProtocol.self]
        let client = LAABridgeClient(session: URLSession(configuration: config))
        let creds = LAABridgeCredentials(baseURL: base, deviceID: "dev_test", token: "test-token")
        let key = LAABridgeIdempotencyKey()
        require(LAABridgeIdempotencyKey(restoring: key.value) == key, "restore idempotency key")
        require(LAABridgeIdempotencyKey(restoring: "bad key") == nil, "invalid idempotency key")
        BridgeMockProtocol.handler = { request in
            require(request.url?.path == "/v1/example", "request path")
            require(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token", "auth header")
            require(request.value(forHTTPHeaderField: "Idempotency-Key") == key.value, "idempotency key")
            require(request.url?.absoluteString.contains("test-token") == false, "token not in URL")
            return (200, Data("{\"data\":{\"items\":[],\"nextCursor\":null},\"requestId\":\"test\"}".utf8))
        }
        let page: LAAUsagePage = try await client.write("/v1/example", method: "POST", body: Data("{}".utf8), credentials: creds, key: key)
        require(page.items.isEmpty, "success envelope")
        BridgeMockProtocol.handler = { _ in (401, Data("{\"error\":{\"code\":\"token_revoked\"}}".utf8)) }
        do { let _: LAAUsagePage = try await client.get("/v1/example", credentials: creds); require(false, "401 must fail") }
        catch let e as LAABridgeError { require(e == .revoked, "401 envelope") }
        BridgeMockProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do { let _: LAAUsagePage = try await client.get("/v1/example", credentials: creds); require(false, "network must fail") }
        catch let e as LAABridgeError { require(e == .networkUnreachable, "network error") }
        BridgeMockProtocol.handler = { _ in throw URLError(.serverCertificateUntrusted) }
        do { let _: LAAUsagePage = try await client.get("/v1/example", credentials: creds); require(false, "TLS must fail") }
        catch let e as LAABridgeError { require(e == .tlsFailed, "TLS error") }
        print("Bridge client: fixtures, error mapping, URL policy and request headers passed")
    }
}
#endif
