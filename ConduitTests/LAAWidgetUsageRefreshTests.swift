#if LAA_BUILD
import Foundation
import XCTest
@testable import Conduit

private final class UsageWidgetProtocol: URLProtocol {
    static var respond: (URLRequest) throws -> (Int, Data) = { _ in throw URLError(.notConnectedToInternet) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class LAAWidgetUsageRefreshTests: XCTestCase {
    private let connection = LAAWidgetUsageConnection(baseURL: URL(string: "https://fixture.ts.net:8445")!, deviceID: "fixture", token: "fixture-token-not-a-secret")

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UsageWidgetProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func withStore(_ body: (WidgetSnapshotStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(WidgetSnapshotStore(directory: directory))
    }

    private func historical(_ store: WidgetSnapshotStore) throws -> WidgetUsageSnapshot {
        let observed = Date().addingTimeInterval(-1800)
        let usage = WidgetUsageSnapshot(meters: [WidgetUsageMeter(id: "provider.claude.quota.weekly", label: "Claude", unit: .percent, amount: 42,
            observedAt: observed, freshUntil: observed.addingTimeInterval(600), resetsAt: nil, stale: false, retained: false)], checkedAt: observed)
        try store.writeUsage(usage)
        return usage
    }

    func testWidgetFetchesAuthenticatedUsageWithoutLaunchingApp() async throws {
        try await withStore { store in
            UsageWidgetProtocol.respond = { request in
                XCTAssertEqual(request.url?.path, "/v1/usage")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token-not-a-secret")
                let observed = ISO8601DateFormatter().string(from: Date())
                return (200, Data("""
                {"data":{"items":[{"id":"provider.claude.quota","kind":"quota","label":"Claude","value":33,"unit":"percent","source":"codexbar-usage-proxy","observedAt":"\(observed)","availability":"available","stale":false,"expired":false,"estimated":false,"detail":{"windows":[{"label":"Weekly","remainingPercent":33,"windowMinutes":10080}]}}],"nextCursor":null}}
                """.utf8))
            }
            let result = await LAAWidgetUsageRefresh.refresh(store: store, readConnection: { self.connection }, session: session())
            XCTAssertEqual(result?.usage?.meters.first?.amount, 33)
            XCTAssertFalse(try XCTUnwrap(result?.usage?.meters.first).isPast(at: Date()))
            let text = String(decoding: try JSONEncoder().encode(store.read()), as: UTF8.self)
            XCTAssertFalse(text.contains(self.connection.token))
        }
    }

    func testOlderResponseCannotOverwriteNewerAppObservation() async throws {
        try await withStore { store in
            let previous = try historical(store)
            UsageWidgetProtocol.respond = { _ in
                let observed = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
                return (200, Data("""
                {"data":{"items":[{"id":"provider.claude.quota","kind":"quota","label":"Claude","value":33,"unit":"percent","source":"codexbar-usage-proxy","observedAt":"\(observed)","availability":"available","stale":true,"expired":false,"estimated":false,"detail":{"windows":[{"label":"Weekly","remainingPercent":33,"windowMinutes":10080}]}}],"nextCursor":null}}
                """.utf8))
            }
            let result = await LAAWidgetUsageRefresh.refresh(store: store, readConnection: { self.connection }, session: session())
            XCTAssertEqual(result?.usage?.meters.first?.amount, 42)
            XCTAssertEqual(result?.usage?.meters.first?.observedAt, previous.meters.first?.observedAt)
        }
    }

    func testCacheRoundTripPreservesLocalReasonAndFreshnessAnchor() async throws {
        try await withStore { store in
            let data = Data("""
            {"id":"provider.claude.quota","kind":"quota","label":"Claude","value":42,"unit":"percent","source":"codexbar-usage-proxy","observedAt":"2026-11-10T12:00:00Z","availability":"available","stale":false,"expired":false,"estimated":false}
            """.utf8)
            var item = try JSONDecoder().decode(LAAUsageItem.self, from: data)
            item.freshnessAnchor = Date(timeIntervalSince1970: 1000)
            item.retainedReason = "fetch_failed"
            try store.writeUsageItems([item])
            let restored = try XCTUnwrap(store.readUsageItems()?.first)
            XCTAssertEqual(restored.value, 42)
            XCTAssertEqual(restored.observedAt, item.observedAt)
            XCTAssertEqual(restored.freshnessAnchor, item.freshnessAnchor)
            XCTAssertEqual(restored.retainedReason, "fetch_failed")
            try store.writeUsageItems(nil)
            XCTAssertNil(store.readUsageItems())
        }
    }

    func testThirtyMinuteNetworkOutageRetainsOriginalValueAndTime() async throws {
        try await withStore { store in
            let previous = try historical(store)
            UsageWidgetProtocol.respond = { _ in throw URLError(.notConnectedToInternet) }
            let result = await LAAWidgetUsageRefresh.refresh(store: store, readConnection: { self.connection }, session: session())
            XCTAssertEqual(result?.usage, previous)
            XCTAssertTrue(try XCTUnwrap(result?.usage?.meters.first).isPast(at: Date()))
        }
    }

    func testMissingProviderRetainsHistoryButNeverSynthesizesRecovery() async throws {
        try await withStore { store in
            let previous = try historical(store)
            UsageWidgetProtocol.respond = { _ in (200, Data("{\"data\":{\"items\":[],\"nextCursor\":null}}".utf8)) }
            let result = await LAAWidgetUsageRefresh.refresh(store: store, readConnection: { self.connection }, session: session())
            XCTAssertEqual(result?.usage?.meters.first?.amount, 42)
            XCTAssertEqual(result?.usage?.meters.first?.observedAt, previous.meters.first?.observedAt)
            XCTAssertEqual(result?.usage?.meters.first?.retained, true)
        }
    }

    func testAccessDeniedClearsValuesAndSharedCredential() async throws {
        for status in [401, 403] {
            try await withStore { store in
                _ = try historical(store)
                var cleared = false
                UsageWidgetProtocol.respond = { _ in (status, Data()) }
                let result = await LAAWidgetUsageRefresh.refresh(store: store, readConnection: { self.connection }, saveConnection: { value in
                    XCTAssertNil(value); cleared = true
                }, session: session())
                XCTAssertTrue(cleared)
                XCTAssertNil(result?.usage)
            }
        }
    }

    func testAccessDeniedClearsHistoryEvenIfKeychainDeletionFails() async throws {
        try await withStore { store in
            _ = try historical(store)
            UsageWidgetProtocol.respond = { _ in (403, Data()) }
            let result = await LAAWidgetUsageRefresh.refresh(store: store, readConnection: { self.connection },
                saveConnection: { _ in throw LAAWidgetUsageConnection.RefreshError.keychain }, session: session())
            XCTAssertNil(result?.usage)
        }
    }

    func testChangedConnectionCannotPublishInFlightResponse() async throws {
        try await withStore { store in
            let previous = try historical(store)
            var reads = 0
            UsageWidgetProtocol.respond = { _ in (200, Data("{\"data\":{\"items\":[],\"nextCursor\":null}}".utf8)) }
            let result = await LAAWidgetUsageRefresh.refresh(store: store, readConnection: {
                reads += 1; return reads == 1 ? self.connection : nil
            }, session: session())
            XCTAssertEqual(result?.usage, previous)
        }
    }

    func testMissingCredentialDoesNotAttemptNetwork() async throws {
        try await withStore { store in
            let previous = try historical(store)
            UsageWidgetProtocol.respond = { _ in XCTFail("No credential must not send a request"); throw URLError(.cancelled) }
            let result = await LAAWidgetUsageRefresh.refresh(store: store, readConnection: { nil }, session: session())
            XCTAssertEqual(result?.usage, previous)
        }
    }
}
#endif
