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
    static let rotatedTag = "\"" + String(repeating: "d", count: 64) + "\""
    static let projectID = "70175325-5cf4-421f-8a6f-95beae8fca92"
    static let media = "/api/studio/media/catalog/" + String(repeating: "a", count: 64) + ".pdf"
    static let nextMedia = "/api/studio/media/catalog/" + String(repeating: "9", count: 64) + ".pdf"
    static let oldVersion = String(repeating: "1", count: 64)
    static let newVersion = String(repeating: "2", count: 64)
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
        case 0, 1, 3:
            precondition(request.url?.path == "/v1/studio/catalog", "catalog path")
            precondition(request.value(forHTTPHeaderField: "If-None-Match") == (step == 0 ? nil : step == 1 ? Self.oldTag : Self.newTag), "catalog validator")
            let tag = step == 0 ? Self.oldTag : step == 1 ? Self.newTag : Self.rotatedTag
            let documents: [[String: Any]] = (1...8).map { index in
                var document: [String: Any] = ["id": "fixture-\(index)", "title": "Fixture \(index)",
                    "category": "Fixture", "detail": "Synthetic document", "format": "PDF",
                    "driveUrl": "https://drive.google.com/file/d/fixture-\(index)/view"]
                if step == 0 { document["unavailable"] = "source_unreadable" }
                else { document["media"] = step == 3 ? Self.nextMedia : Self.media; document["bytes"] = 321 }
                return document
            }
            let catalog: [String: Any] = ["etag": String(tag.dropFirst().dropLast()), "updatedAt": "2026-11-01T00:00:00Z",
                "principles": [], "adoptedPrincipleId": NSNull(), "documents": documents, "capabilities": [], "brief": []]
            body = try! JSONSerialization.data(withJSONObject: ["data": catalog, "requestId": "fixture"])
            status = 200
            etag = tag
        case 2, 4:
            precondition(request.url?.path == "/v1/studio/catalog", "cached catalog path")
            let tag = step == 2 ? Self.newTag : Self.rotatedTag
            precondition(request.value(forHTTPHeaderField: "If-None-Match") == tag, "new catalog validator")
            status = 304
            body = Data()
            etag = tag
        case 5:
            precondition(request.value(forHTTPHeaderField: "If-None-Match") == Self.rotatedTag, "offline catalog validator")
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        case 6, 7:
            precondition(request.url?.path == "/v1/studio/projects/\(Self.projectID)", "project path")
            let project: [String: Any] = ["id": Self.projectID, "title": "Fixture", "revision": 2, "pages": [], "assets": []]
            let versionID = step == 6 ? Self.oldVersion : Self.newVersion
            var version: [String: Any] = ["id": versionID, "revision": 2, "kind": "video", "name": "fixture.mp4",
                "createdAt": "2026-11-01T00:00:00Z", "bytes": 321,
                "media": "/api/studio/media/\(Self.projectID)/\(versionID).mp4"]
            if step == 7 { version["width"] = 1280; version["height"] = 720; version["duration"] = 12 }
            let detail: [String: Any] = ["project": project, "versions": [version], "delivery": NSNull(), "reviews": []]
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
        let rotated = try await LAAStudioData.catalog(bridge)
        precondition(!rotated.stale && rotated.catalog.etag != updated.catalog.etag && rotated.catalog.documents.allSatisfy { $0.media == StudioFixtureProtocol.nextMedia })
        let unchangedAgain = try await LAAStudioData.catalog(bridge)
        precondition(unchangedAgain.catalog.etag == rotated.catalog.etag && unchangedAgain.catalog.documents.allSatisfy { $0.media == StudioFixtureProtocol.nextMedia })
        let offline = try await LAAStudioData.catalog(bridge)
        precondition(offline.stale && offline.catalog.etag == rotated.catalog.etag)
        let project = try await LAAStudioData.project(StudioFixtureProtocol.projectID, bridge: bridge)
        precondition(project.project.revision == 2 && project.versions[0].id == StudioFixtureProtocol.oldVersion)
        precondition(project.versions[0].width == nil && project.versions[0].height == nil && project.versions[0].duration == nil)
        let projectAfter = try await LAAStudioData.project(StudioFixtureProtocol.projectID, bridge: bridge)
        precondition(projectAfter.versions[0].id == StudioFixtureProtocol.newVersion && projectAfter.versions[0].width == 1280 &&
                     projectAfter.versions[0].height == 720 && projectAfter.versions[0].duration == 12 && StudioFixtureProtocol.step == 8)
        let oldPath = LAAStudioMedia.bridgePath(project.versions[0].media, allowed: ["mp4"])
        let newPath = LAAStudioMedia.bridgePath(projectAfter.versions[0].media, allowed: ["mp4"])
        precondition(oldPath != nil && newPath != nil && oldPath != newPath && newPath!.contains(StudioFixtureProtocol.newVersion))
        try checkDraftRecovery(deviceID: deviceID)
        print("Studio v2 client: catalog key refresh/304/offline, video metadata, draft recovery and 45-second project timeout passed")
    }

    private static func checkDraftRecovery(deviceID: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("studio-review-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectID = StudioFixtureProtocol.projectID
        let old = LAAStudioReview.Target.version(StudioFixtureProtocol.oldVersion)
        let new = LAAStudioReview.Target.version(StudioFixtureProtocol.newVersion)
        var state = LAAStudioReviewEditorState()
        state.comment = "旧版への講評"; state.verdict = "revise"
        precondition(LAAStudioReviewStore.save(state, deviceID: deviceID, projectID: projectID, target: old,
                                              targetName: "fixture.mp4", revision: 2, directory: directory))
        guard case .missing = LAAStudioReviewStore.load(deviceID: deviceID, projectID: projectID, target: new, directory: directory) else {
            preconditionFailure("must not transfer a draft to a new key")
        }
        var lost = LAAStudioReviewStore.displaced(deviceID: deviceID, projectID: projectID,
                                                 listedVersionIDs: [StudioFixtureProtocol.newVersion], directory: directory)
        precondition(lost.count == 1 && lost[0].target == old && lost[0].targetName == "fixture.mp4" &&
                     lost[0].revision == 2 && lost[0].state == state)
        precondition(LAAStudioReviewStore.displaced(deviceID: "other-device", projectID: projectID, listedVersionIDs: [], directory: directory).isEmpty)
        precondition(LAAStudioReviewStore.displaced(deviceID: deviceID, projectID: projectID, listedVersionIDs: [StudioFixtureProtocol.oldVersion], directory: directory).isEmpty)

        let review = LAAStudioReview(id: UUID().uuidString.lowercased(), projectId: projectID, revision: 2,
                                     target: old, verdict: state.verdict, comment: state.comment)
        var draft = try LAAStudioReviewDraft(review: review); draft.pending = true
        state.pending = draft
        precondition(LAAStudioReviewStore.save(state, deviceID: deviceID, projectID: projectID, target: old,
                                              targetName: "fixture.mp4", revision: 2, directory: directory))
        lost = LAAStudioReviewStore.displaced(deviceID: deviceID, projectID: projectID, listedVersionIDs: [], directory: directory)
        guard lost.count == 1, var retry = lost[0].state.pending else { preconditionFailure("uncertain draft missing") }
        let body = retry.body, previousKey = retry.key
        retry.rotateKey()
        precondition(retry.body == body && retry.review.id == review.id && retry.review.target == old && retry.key != previousKey)

        let legacyTarget = LAAStudioReview.Target.version(String(repeating: "3", count: 64))
        let legacyReview = LAAStudioReview(id: UUID().uuidString.lowercased(), projectId: projectID, revision: 2,
                                           target: legacyTarget, verdict: nil, comment: "Legacy pending")
        var legacy = LAAStudioReviewEditorState(); legacy.comment = "Legacy pending"
        legacy.pending = try LAAStudioReviewDraft(review: legacyReview)
        let legacyFile = LAAStudioReviewStore.file(deviceID: deviceID, projectID: projectID, target: legacyTarget, directory: directory)!
        try JSONEncoder().encode(legacy).write(to: legacyFile)
        guard case .loaded(let loadedLegacy) = LAAStudioReviewStore.load(deviceID: deviceID, projectID: projectID,
                                                                         target: legacyTarget, directory: directory) else {
            preconditionFailure("legacy draft must still load")
        }
        precondition(loadedLegacy == legacy)
        precondition(LAAStudioReviewStore.displaced(deviceID: deviceID, projectID: projectID, listedVersionIDs: [], directory: directory)
            .contains { $0.target == legacyTarget && $0.state == legacy })
        precondition(LAAStudioReviewStore.upgradeLegacy(deviceID: deviceID, projectID: projectID, target: legacyTarget,
                                                       targetName: "legacy.mp4", revision: 2, directory: directory))
        precondition(LAAStudioReviewStore.displaced(deviceID: deviceID, projectID: projectID, listedVersionIDs: [], directory: directory)
            .contains { $0.target == legacyTarget && $0.targetName == "legacy.mp4" && $0.state == legacy })

        let unsentTarget = LAAStudioReview.Target.version(String(repeating: "4", count: 64))
        var unsent = LAAStudioReviewEditorState(); unsent.comment = "Legacy unsent"
        let unsentFile = LAAStudioReviewStore.file(deviceID: deviceID, projectID: projectID, target: unsentTarget, directory: directory)!
        try JSONEncoder().encode(unsent).write(to: unsentFile)
        precondition(LAAStudioReviewStore.upgradeLegacy(deviceID: deviceID, projectID: projectID, target: unsentTarget,
                                                       targetName: "unsent.mp4", revision: 2, directory: directory))
        precondition(LAAStudioReviewStore.displaced(deviceID: deviceID, projectID: projectID, listedVersionIDs: [], directory: directory)
            .contains { $0.target == unsentTarget && $0.targetName == "unsent.mp4" && $0.state == unsent })
        let invalidTarget = LAAStudioReview.Target.version(String(repeating: "5", count: 64))
        let invalidFile = LAAStudioReviewStore.file(deviceID: deviceID, projectID: projectID, target: invalidTarget, directory: directory)!
        let invalidData = Data("unreadable".utf8); try invalidData.write(to: invalidFile)
        precondition(!LAAStudioReviewStore.upgradeLegacy(deviceID: deviceID, projectID: projectID, target: invalidTarget,
                                                        targetName: "invalid.mp4", revision: 2, directory: directory))
        let preserved = try Data(contentsOf: invalidFile)
        precondition(preserved == invalidData)
        for (status, code, editable) in [(404, "studio_review_target_missing", true), (409, "studio_revision_unknown", true),
                                         (409, "studio_review_id_conflict", false), (503, "studio_not_connected", false)] {
            let error = LAABridgeHTTPError(status: status, code: code, message: nil, retryable: false, details: nil, requestId: nil, currentETag: nil)
            precondition(LAAStudioReviewDraft.definitelyRejected(error) == editable)
        }
    }
}
