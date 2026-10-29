#if LAA_BUILD
import Foundation

final class BridgeMockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    static var headers: [String: String] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: Self.headers)!
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
    static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
    static func timedRequest(_ client: LAABridgeClient, credentials: LAABridgeCredentials,
                             timeout: TimeInterval?) async -> (TimeInterval, LAABridgeError?) {
        let start = Date()
        do {
            let _: LAABridgeResponse<LAAUsagePage> = try await client.request(
                method: "GET", path: "/v1/timeout-test", credentials: credentials, timeout: timeout)
            return (Date().timeIntervalSince(start), nil)
        } catch let error as LAABridgeError {
            return (Date().timeIntervalSince(start), error)
        } catch {
            return (Date().timeIntervalSince(start), .invalidResponse)
        }
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
            require(request.timeoutInterval == 20, "default request timeout")
            require(request.url?.absoluteString.contains("test-token") == false, "token not in URL")
            return (200, Data("{\"data\":{\"items\":[],\"nextCursor\":null},\"requestId\":\"test\"}".utf8))
        }
        let page: LAAUsagePage = try await client.write("/v1/example", method: "POST", body: Data("{}".utf8), credentials: creds, key: key)
        require(page.items.isEmpty, "success envelope")
        BridgeMockProtocol.headers = ["ETag": "\"4\""]
        BridgeMockProtocol.handler = { request in
            require(request.httpMethod == "PATCH", "general method")
            require(body(of: request) == Data("{\"name\":\"test\"}".utf8), "general JSON body")
            require(request.value(forHTTPHeaderField: "Content-Type") == "application/json", "JSON content type")
            require(request.value(forHTTPHeaderField: "Idempotency-Key") == key.value, "general idempotency key")
            require(request.value(forHTTPHeaderField: "If-Match") == "\"3\"", "If-Match header")
            require(request.timeoutInterval == 35, "long-poll timeout is not capped at 20 seconds")
            return (201, Data("{\"data\":{\"items\":[],\"nextCursor\":null},\"requestId\":\"req-test\"}".utf8))
        }
        let response: LAABridgeResponse<LAAUsagePage> = try await client.request(
            method: "PATCH", path: "/v1/example", jsonBody: Data("{\"name\":\"test\"}".utf8),
            credentials: creds, idempotencyKey: key, ifMatch: "\"3\"", timeout: 35)
        require(response.data.items.isEmpty && response.requestId == "req-test", "decoded response envelope")
        require(response.status == 201 && response.etag == "\"4\"", "response status and ETag")

        for (status, code) in [(409, "request_id_conflict"), (409, "idempotency_outcome_unknown"),
                               (409, "stop_unconfirmed"), (410, "cursor_expired"),
                               (412, "version_mismatch"), (428, "precondition_required")] {
            BridgeMockProtocol.headers = ["ETag": "\"5\""]
            BridgeMockProtocol.handler = { _ in
                let body = "{\"error\":{\"code\":\"\(code)\",\"message\":\"details\",\"retryable\":false,\"details\":{\"current\":5,\"nested\":[true,null,\"x\"]}},\"requestId\":\"req-error\"}"
                return (status, Data(body.utf8))
            }
            do {
                let _: LAABridgeResponse<LAAUsagePage> = try await client.request(method: "GET", path: "/v1/example", credentials: creds)
                require(false, "HTTP \(status) must fail")
            } catch let error as LAABridgeHTTPError {
                require(error.status == status && error.code == code, "structured HTTP status and code")
                require(error.message == "details" && error.retryable == false && error.requestId == "req-error", "error metadata")
                require(error.details == .object(["current": .number(5), "nested": .array([.bool(true), .null, .string("x")])]), "nested error details")
                require(error.currentETag == "\"5\"", "ETag on HTTP error")
            }
        }
        BridgeMockProtocol.headers = [:]
        BridgeMockProtocol.handler = { _ in
            (412, Data("{\"error\":{\"code\":\"version_mismatch\",\"details\":{\"current\":{\"etag\":\"\\\"17\\\"\",\"version\":17}}},\"requestId\":\"req-current\"}".utf8))
        }
        do {
            let _: LAABridgeResponse<LAAUsagePage> = try await client.request(method: "PATCH", path: "/v1/projects/test", credentials: creds)
            require(false, "stale project must fail")
        } catch let error as LAABridgeHTTPError {
            require(error.code == "version_mismatch" && error.currentETag == "\"17\"", "current ETag from server error details")
        }
        BridgeMockProtocol.handler = { _ in (412, Data("not-json".utf8)) }
        do {
            let _: LAABridgeResponse<LAAUsagePage> = try await client.request(method: "GET", path: "/v1/example", credentials: creds)
            require(false, "malformed error must fail")
        } catch let error as LAABridgeHTTPError {
            require(error.status == 412 && error.code == nil && error.currentETag == nil, "status survives malformed error; missing ETag stays nil")
        }
        BridgeMockProtocol.handler = { _ in (401, Data("{\"error\":{\"code\":\"token_revoked\"}}".utf8)) }
        do { let _: LAAUsagePage = try await client.get("/v1/example", credentials: creds); require(false, "401 must fail") }
        catch let e as LAABridgeError { require(e == .revoked, "401 envelope") }
        BridgeMockProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do { let _: LAAUsagePage = try await client.get("/v1/example", credentials: creds); require(false, "network must fail") }
        catch let e as LAABridgeError { require(e == .networkUnreachable, "network error") }
        BridgeMockProtocol.handler = { _ in throw URLError(.serverCertificateUntrusted) }
        do { let _: LAAUsagePage = try await client.get("/v1/example", credentials: creds); require(false, "TLS must fail") }
        catch let e as LAABridgeError { require(e == .tlsFailed, "TLS error") }
        if let address = ProcessInfo.processInfo.environment["LAA_BRIDGE_TIMEOUT_TEST_URL"] {
            guard let url = URL(string: address), url.scheme == "http", url.host == "127.0.0.1", url.port != nil else {
                require(false, "timeout test needs a loopback URL")
                return
            }
            let live = LAABridgeClient()
            let local = LAABridgeCredentials(baseURL: url, deviceID: "dev_test", token: "test-token")
            async let normal = timedRequest(live, credentials: local, timeout: nil)
            async let longPoll = timedRequest(live, credentials: local, timeout: 40)
            let (ordinary, extended) = await (normal, longPoll)
            require(ordinary.1 == .networkUnreachable && (17...27).contains(ordinary.0), "default timeout near 20 seconds")
            require(extended.1 == nil && (28...39).contains(extended.0), "40-second timeout survives a 30-second response")
            print(String(format: "Timeouts: default %.1fs, extended %.1fs", ordinary.0, extended.0))
        }
        print("Bridge client: fixtures, error mapping, URL policy and request headers passed")
    }
}
#endif
