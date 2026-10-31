#if LAA_BUILD
import Foundation
import CryptoKit

extension LAAStudioDraftStore {
    static func principleDraftID(_ id: String) -> String {
        let hex = SHA256.hash(data: Data("principle|\(id)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
    }
}

struct LAAStudioCatalogResult {
    let catalog: LAAStudioCatalog
    let stale: Bool
}

private struct LAAStudioCatalogCache: Codable {
    let etag: String
    let catalog: LAAStudioCatalog
}

private enum LAAStudioCatalogStore {
    static func file(deviceID: String) -> URL? {
        guard let draft = LAAStudioDraftStore.file(deviceID: deviceID) else { return nil }
        return draft.deletingLastPathComponent().appendingPathComponent("catalog-\(deviceID).json")
    }
    static func load(deviceID: String) -> LAAStudioCatalogCache? {
        guard let url = file(deviceID: deviceID), let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(LAAStudioCatalogCache.self, from: data),
              validETag(cache.etag) else { return nil }
        return cache
    }
    static func save(_ cache: LAAStudioCatalogCache, deviceID: String) {
        guard let url = file(deviceID: deviceID), validETag(cache.etag) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(cache).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { /* Caching is optional; the network response remains usable. */ }
    }
    private static func validETag(_ value: String) -> Bool {
        value.count <= 512 && value.first == "\"" && value.last == "\"" &&
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

extension LAAStudioData {
    @MainActor static func catalog(_ bridge: LAABridgeSession) async throws -> LAAStudioCatalogResult {
        #if DEBUG
        if fixture != nil { return .init(catalog: try sampleCatalog(), stale: false) }
        #endif
        guard let deviceID = bridge.deviceID else { throw LAABridgeError.unauthorized }
        let revision = bridge.revision
        let cached = LAAStudioCatalogStore.load(deviceID: deviceID)
        do {
            let response: LAABridgeResponse<LAAStudioCatalog> = try await bridge.request(
                method: "GET", path: "/v1/studio/catalog", ifNoneMatch: cached?.etag, timeout: 45)
            if let etag = response.etag {
                LAAStudioCatalogStore.save(.init(etag: etag, catalog: response.data), deviceID: deviceID)
            }
            return .init(catalog: response.data, stale: false)
        } catch let failure as LAABridgeHTTPError where failure.status == 304 {
            guard bridge.revision == revision, bridge.deviceID == deviceID,
                  let cached, failure.currentETag == cached.etag else { throw LAABridgeError.invalidResponse }
            return .init(catalog: cached.catalog, stale: false)
        } catch let failure as LAABridgeError where failure == .networkUnreachable {
            guard bridge.revision == revision, bridge.deviceID == deviceID, let cached else { throw failure }
            return .init(catalog: cached.catalog, stale: true)
        }
    }

    @MainActor static func project(_ id: String, bridge: LAABridgeSession) async throws -> LAAStudioProjectDetail {
        guard id.range(of: #"^[A-Za-z0-9-]{1,100}$"#, options: .regularExpression) != nil else { throw LAABridgeError.invalidResponse }
        #if DEBUG
        if let fixture { return try sampleProject(fixture) }
        #endif
        let result: LAABridgeResponse<LAAStudioProjectDetail> = try await bridge.request(method: "GET", path: "/v1/studio/projects/\(id)")
        guard result.data.project.id == id else { throw LAABridgeError.invalidResponse }
        return result.data
    }

    @MainActor static func review(_ review: LAAStudioReview, body: Data, key: LAABridgeIdempotencyKey,
                                  bridge: LAABridgeSession) async throws -> LAAStudioReview {
        #if DEBUG
        if fixture != nil {
            var saved = review; saved.createdAt = "2026-11-01T09:00:00Z"
            fixtureReviews[review.id] = saved
            return saved
        }
        #endif
        let result: LAABridgeResponse<LAAStudioReview> = try await bridge.request(
            method: "POST", path: "/v1/studio/reviews", jsonBody: body, idempotencyKey: key, timeout: 30)
        guard [200, 201].contains(result.status), result.data.createdAt != nil,
              review.sameSubmission(as: result.data) else { throw LAABridgeError.invalidResponse }
        return result.data
    }

    #if DEBUG
    private static var fixtureReviews: [String: LAAStudioReview] = [:]
    static func sampleProject(_ mode: String) throws -> LAAStudioProjectDetail {
        let snapshot = try sample(mode)
        guard let project = snapshot.projects.first else { throw LAABridgeError.invalidResponse }
        let sha = String(repeating: "a", count: 64)
        let version = LAAStudioProjectDetail.Version(id: sha, revision: project.revision, kind: "other", name: "Website.zip",
            createdAt: "2026-11-01T09:00:00Z", bytes: 1024, media: nil, poster: nil, width: nil, height: nil,
            duration: nil, previewOnly: nil, preparing: nil, unavailable: "unsupported_format", usdz: nil)
        return .init(project: project, versions: [version], delivery: .init(driveUrl: project.driveUrl ?? "", revision: project.revision),
                     reviews: Array(fixtureReviews.values).sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") })
    }
    static func sampleCatalog() throws -> LAAStudioCatalog {
        let json = ##"{"etag":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","updatedAt":"2026-11-01T09:00:00Z","principles":[{"id":"principle1","name":"Sample","version":"1","revision":1,"status":"adopted","description":"Fixture principle","colors":[{"name":"Ink","value":"#222222","rgb":[34,34,34]}],"fonts":[{"name":"Body","family":"System","weight":400,"size":16}],"references":[{"name":"Example","role":"primary","adoptedElements":"余白"}],"templates":["Cards"],"priorities":[{"title":"Clarity","description":"Keep the purpose clear."}]}],"adoptedPrincipleId":"principle1","documents":[{"id":"fixture-document","title":"Sample document","category":"Cards","detail":"Fixture","format":"PDF","driveUrl":"https://drive.google.com/file/d/1234567890/view"}],"capabilities":[{"id":"image","title":"Image","description":"Sample","prompt":"画像を作ってください。"}],"brief":["用途と相手"]}"##
        return try JSONDecoder().decode(LAAStudioCatalog.self, from: Data(json.utf8))
    }
    #endif
}

struct LAAStudioReviewDraft: Codable, Equatable {
    var review: LAAStudioReview
    var body: Data
    var key: String
    var pending: Bool

    init(review: LAAStudioReview) throws {
        self.review = review
        self.body = try JSONEncoder().encode(review)
        self.key = LAABridgeIdempotencyKey().value
        self.pending = false
    }
    mutating func rotateKey() { key = LAABridgeIdempotencyKey().value }
    var submissionKey: LAABridgeIdempotencyKey? { LAABridgeIdempotencyKey(restoring: key) }
    var intact: Bool { (try? JSONDecoder().decode(LAAStudioReview.self, from: body)).map { $0.sameSubmission(as: review) } ?? false }
}

struct LAAStudioReviewEditorState: Codable, Equatable {
    var verdict: String?
    var comment = ""
    var pending: LAAStudioReviewDraft?
}

enum LAAStudioReviewStore {
    enum LoadResult {
        case missing, loaded(LAAStudioReviewEditorState), unreadable
    }
    static func file(deviceID: String, projectID: String, target: LAAStudioReview.Target,
                     directory: URL = LAAStudioDraftStore.directory()) -> URL? {
        guard LAAStudioDraftStore.file(deviceID: deviceID, directory: directory) != nil,
              projectID.range(of: #"^[A-Za-z0-9-]{1,100}$"#, options: .regularExpression) != nil else { return nil }
        let input = "\(deviceID)|\(projectID)|\(target.kind)|\(target.id ?? "")"
        let digest = SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("review-\(digest).json")
    }
    static func load(deviceID: String, projectID: String, target: LAAStudioReview.Target,
                     directory: URL = LAAStudioDraftStore.directory()) -> LoadResult {
        guard let url = file(deviceID: deviceID, projectID: projectID, target: target, directory: directory) else { return .unreadable }
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(LAAStudioReviewEditorState.self, from: data),
              state.pending.map({ $0.review.projectId == projectID && $0.review.target == target && $0.intact }) ?? true else { return .unreadable }
        return .loaded(state)
    }
    static func save(_ state: LAAStudioReviewEditorState, deviceID: String, projectID: String,
                     target: LAAStudioReview.Target, directory: URL = LAAStudioDraftStore.directory()) -> Bool {
        guard state.pending.map({ $0.intact && $0.review.projectId == projectID && $0.review.target == target }) ?? true,
              let url = file(deviceID: deviceID, projectID: projectID, target: target, directory: directory) else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { return false }
    }
    static func clear(deviceID: String, projectID: String, target: LAAStudioReview.Target,
                      directory: URL = LAAStudioDraftStore.directory()) -> Bool {
        guard let url = file(deviceID: deviceID, projectID: projectID, target: target, directory: directory) else { return false }
        do { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }; return true }
        catch { return false }
    }
}
#endif
