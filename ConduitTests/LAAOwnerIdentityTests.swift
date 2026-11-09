#if LAA_BUILD
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// A Mac that answers the owner-avatar endpoint from a script, and records
/// what the app sent.
private final class OwnerAvatarProtocol: URLProtocol {
    struct Reply { let status: Int; let body: Data; let headers: [String: String] }
    nonisolated(unsafe) static var replies: [Reply] = []
    nonisolated(unsafe) static var requests: [(method: String, path: String, ifNoneMatch: String?, body: Data?)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let read = stream.read(&buffer, maxLength: buffer.count); if read <= 0 { break }; data.append(buffer, count: read) }
            body = data
        }
        Self.requests.append((request.httpMethod ?? "GET", request.url?.path ?? "",
                              request.value(forHTTPHeaderField: "If-None-Match"), body))
        let reply = Self.replies.isEmpty ? Reply(status: 503, body: Data(), headers: [:]) : Self.replies.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class LAAOwnerIdentityTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private let suite = "LAAOwnerIdentityTests"

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("owner-\(UUID().uuidString)")
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
        OwnerAvatarProtocol.replies = []
        OwnerAvatarProtocol.requests = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func pairedBridge() -> LAABridgeSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OwnerAvatarProtocol.self]
        let credentials = LAABridgeCredentials(baseURL: URL(string: "http://127.0.0.1:9")!, deviceID: "device", token: "token")
        return LAABridgeSession(client: LAABridgeClient(session: URLSession(configuration: configuration)),
                                readCredentials: { credentials })
    }

    private func picture(_ width: CGFloat, _ height: CGFloat, color: UIColor = .systemTeal) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func envelope(_ data: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["data": data, "requestId": "test"])
    }

    private func payload(_ image: UIImage, etag: String) -> Data {
        envelope(["contentType": "image/jpeg", "etag": etag, "updatedAt": "2026-11-09T00:00:00Z", "size": 1,
                  "data": image.jpegData(compressionQuality: 0.9)!.base64EncodedString()])
    }

    // MARK: - Identity

    func testOwnerIdentityReadsAsOnePhrase() {
        XCTAssertEqual(LAAOwnerIdentity.name, "LAA")
        XCTAssertEqual(LAAOwnerIdentity.role, "Administration")
        XCTAssertEqual(LAAOwnerIdentity.spokenHeader, "LAA、Administration")
    }

    func testRunsShowTheSpeakerOncePerRun() {
        let speakers: [LAASenderRun.Speaker] = [.owner, .owner, .agent, .agent, .other, .agent, .owner]
        XCTAssertEqual(speakers.indices.map { LAASenderRun.continues(speakers, at: $0) },
                       [false, true, false, true, false, false, false])
    }

    func testWorkSpeakersAndAgentName() throws {
        let owner = LAAWorkConversationMessage(id: "1", role: "user", text: "依頼", timestamp: nil)
        let agent = LAAWorkConversationMessage(id: "2", role: "assistant", text: "回答", timestamp: nil)
        let tool = LAAWorkConversationMessage(id: "3", role: "tool", text: "ls", timestamp: nil)
        XCTAssertEqual([owner, agent, tool].map(LAAWorkSpeaker.speaker), [.owner, .agent, .other])
        let json = """
        {"id":"ses_1111111111111111","name":"n","requestId":"r","workspaceId":"w","profile":"opus-high",
         "requested":{"provider":"claude","model":"claude-opus-5-5","effort":"high"},
         "observed":{"provider":"claude","model":"claude-opus-5-5","effort":"high"},
         "phase":"running","createdAt":"x","updatedAt":"x","events":{"lastSeq":1,"oldestSeq":1,"cursor":"c"}}
        """
        let session = try JSONDecoder().decode(LAAWorkSession.self, from: Data(json.utf8))
        let options = try JSONDecoder().decode(LAAWorkSessionOptions.self, from: Data("""
        {"profiles":[{"id":"opus-high","label":"Claude Opus 5.5","provider":"claude","model":"claude-opus-5-5","effort":"high","fast":true}]}
        """.utf8))
        XCTAssertEqual(LAAWorkSpeaker.agentName(session, options: options), "Opus 5.5")
        XCTAssertEqual(LAAWorkSpeaker.agentName(session, options: nil), "claude-opus-5-5")
    }

    // MARK: - Picture

    func testPreparedPictureIsACentredSquareJPEG() throws {
        let wide = try XCTUnwrap(LAAOwnerAvatarStore.prepared(picture(900, 600)))
        let image = try XCTUnwrap(UIImage(data: wide))
        XCTAssertEqual(image.size.width * image.scale, 256)
        XCTAssertEqual(image.size.height * image.scale, 256)
        XCTAssertEqual(Array(wide.prefix(3)), [0xFF, 0xD8, 0xFF], "JPEG")
        XCTAssertLessThan(wide.count, 512 * 1024)
        // A small picture is cropped, not enlarged.
        let small = try XCTUnwrap(UIImage(data: try XCTUnwrap(LAAOwnerAvatarStore.prepared(picture(120, 80)))))
        XCTAssertEqual(small.size.width * small.scale, 80)
        XCTAssertEqual(small.size.height * small.scale, 80)
    }

    func testSaveSendsJPEGAndKeepsTheCopy() async throws {
        let bridge = pairedBridge()
        let store = LAAOwnerAvatarStore(directory: directory, defaults: defaults)
        OwnerAvatarProtocol.replies = [.init(status: 200, body: envelope(["contentType": "image/jpeg", "etag": "\"e1\"",
                                                                           "updatedAt": "x", "size": 1]), headers: ["ETag": "\"e1\""])]
        try await store.save(picture(600, 400), bridge: bridge)
        let sent = try XCTUnwrap(OwnerAvatarProtocol.requests.last)
        XCTAssertEqual(sent.method, "PUT")
        XCTAssertEqual(sent.path, "/v1/owner/avatar")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(sent.body)) as? [String: String])
        XCTAssertEqual(body["contentType"], "image/jpeg")
        let bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(body["data"])))
        XCTAssertEqual(Array(bytes.prefix(3)), [0xFF, 0xD8, 0xFF])
        XCTAssertNotNil(store.image)
        XCTAssertEqual(store.etag, "\"e1\"")
        // The next launch shows it before the Mac answers.
        XCTAssertNotNil(LAAOwnerAvatarStore(directory: directory, defaults: defaults).image)
    }

    func testRefreshAdoptsTheMacPictureThenAsksOnlyForChanges() async {
        let bridge = pairedBridge()
        let store = LAAOwnerAvatarStore(directory: directory, defaults: defaults)
        OwnerAvatarProtocol.replies = [.init(status: 200, body: payload(picture(256, 256), etag: "\"e2\""), headers: ["ETag": "\"e2\""])]
        let first = await store.refresh(bridge: bridge)
        XCTAssertEqual(first, .updated)
        XCTAssertNil(OwnerAvatarProtocol.requests.last?.ifNoneMatch, "nothing cached yet")
        XCTAssertNotNil(store.image)
        OwnerAvatarProtocol.replies = [.init(status: 304, body: Data(), headers: ["ETag": "\"e2\""])]
        let second = await store.refresh(bridge: bridge)
        XCTAssertEqual(second, .unchanged)
        XCTAssertEqual(OwnerAvatarProtocol.requests.last?.ifNoneMatch, "\"e2\"")
        XCTAssertNotNil(store.image)
    }

    func testUnreachableMacKeepsTheCacheAndUnsetClearsIt() async throws {
        let bridge = pairedBridge()
        let store = LAAOwnerAvatarStore(directory: directory, defaults: defaults)
        XCTAssertTrue(store.apply(.init(contentType: "image/jpeg", etag: "\"e3\"",
                                        data: picture(64, 64).jpegData(compressionQuality: 0.9)!.base64EncodedString())))
        OwnerAvatarProtocol.replies = [.init(status: 503, body: envelope(["x": 1]), headers: [:])]
        let offline = await store.refresh(bridge: bridge)
        XCTAssertEqual(offline, .kept)
        XCTAssertNotNil(store.image, "an unreachable Mac keeps the last picture")
        let error = try JSONSerialization.data(withJSONObject: ["error": ["code": "owner_avatar_not_set", "message": "x", "retryable": false], "requestId": "t"])
        OwnerAvatarProtocol.replies = [.init(status: 404, body: error, headers: [:])]
        let unset = await store.refresh(bridge: bridge)
        XCTAssertEqual(unset, .cleared)
        XCTAssertNil(store.image, "removed on another device: back to the initial")
        XCTAssertNil(LAAOwnerAvatarStore(directory: directory, defaults: defaults).image)
    }

    func testBrokenPayloadAndUnpairedDeviceChangeNothing() async {
        let store = LAAOwnerAvatarStore(directory: directory, defaults: defaults)
        XCTAssertFalse(store.apply(.init(contentType: "image/jpeg", etag: "\"x\"", data: "bm90IGFuIGltYWdl")))
        XCTAssertNil(store.image)
        let unpaired = LAABridgeSession(statusForTesting: .unpaired)
        let outcome = await store.refresh(bridge: unpaired)
        XCTAssertEqual(outcome, .kept)
        XCTAssertTrue(OwnerAvatarProtocol.requests.isEmpty)
        do {
            try await store.save(picture(10, 10), bridge: unpaired)
            XCTFail("an unpaired device cannot save")
        } catch {
            XCTAssertEqual(error as? LAAOwnerAvatarStore.SaveError, .notPaired)
        }
    }

    func testRemoveClearsTheCopy() async throws {
        let bridge = pairedBridge()
        let store = LAAOwnerAvatarStore(directory: directory, defaults: defaults)
        XCTAssertTrue(store.apply(.init(contentType: "image/jpeg", etag: "\"e4\"",
                                        data: picture(32, 32).jpegData(compressionQuality: 0.9)!.base64EncodedString())))
        OwnerAvatarProtocol.replies = [.init(status: 200, body: envelope(["removed": true]), headers: [:])]
        try await store.remove(bridge: bridge)
        XCTAssertEqual(OwnerAvatarProtocol.requests.last?.method, "DELETE")
        XCTAssertNil(store.image)
    }
}
#endif
