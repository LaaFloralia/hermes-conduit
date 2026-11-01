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
        let result: LAABridgeResponse<LAAStudioProjectDetail> = try await bridge.request(
            method: "GET", path: "/v1/studio/projects/\(id)", timeout: 15)
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
            method: "POST", path: "/v1/studio/reviews", jsonBody: body, idempotencyKey: key, timeout: 15)
        guard [200, 201].contains(result.status), result.data.createdAt != nil,
              review.sameSubmission(as: result.data) else { throw LAABridgeError.invalidResponse }
        return result.data
    }

    #if DEBUG
    private static var fixtureReviews: [String: LAAStudioReview] = [:]
    static func sampleProject(_ mode: String) throws -> LAAStudioProjectDetail {
        let snapshot = try sample(mode)
        guard let project = snapshot.projects.first else { throw LAABridgeError.invalidResponse }
        let versionKey = String(repeating: "a", count: 64)
        let version = LAAStudioProjectDetail.Version(id: versionKey, revision: project.revision, kind: "other", name: "Website.zip",
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
    static func definitelyRejected(_ failure: LAABridgeHTTPError) -> Bool {
        (failure.status == 400 && failure.code == "studio_payload_invalid") ||
            (failure.status == 404 && ["studio_project_missing", "studio_review_target_missing"].contains(failure.code ?? "")) ||
            (failure.status == 409 && failure.code == "studio_revision_unknown")
    }
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
    private struct Record: Codable {
        let deviceID: String
        let projectID: String
        let target: LAAStudioReview.Target
        let targetName: String?
        let revision: Int?
        let state: LAAStudioReviewEditorState
    }
    struct DisplacedDraft: Identifiable {
        let target: LAAStudioReview.Target
        let targetName: String?
        let revision: Int?
        let state: LAAStudioReviewEditorState
        var id: String { target.id ?? "" }
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
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        let decoder = JSONDecoder()
        let state: LAAStudioReviewEditorState
        if let record = try? decoder.decode(Record.self, from: data) {
            guard record.deviceID == deviceID, record.projectID == projectID, record.target == target else { return .unreadable }
            state = record.state
        } else if let legacy = try? decoder.decode(LAAStudioReviewEditorState.self, from: data) {
            state = legacy
        } else { return .unreadable }
        guard
              state.pending.map({ $0.review.projectId == projectID && $0.review.target == target && $0.intact }) ?? true else { return .unreadable }
        return .loaded(state)
    }
    static func save(_ state: LAAStudioReviewEditorState, deviceID: String, projectID: String,
                     target: LAAStudioReview.Target, targetName: String? = nil, revision: Int? = nil,
                     directory: URL = LAAStudioDraftStore.directory()) -> Bool {
        guard state.pending.map({ $0.intact && $0.review.projectId == projectID && $0.review.target == target }) ?? true,
              let url = file(deviceID: deviceID, projectID: projectID, target: target, directory: directory) else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let record = Record(deviceID: deviceID, projectID: projectID, target: target, targetName: targetName, revision: revision, state: state)
            try JSONEncoder().encode(record).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { return false }
    }
    static func upgradeLegacy(deviceID: String, projectID: String, target: LAAStudioReview.Target,
                              targetName: String, revision: Int, directory: URL = LAAStudioDraftStore.directory()) -> Bool {
        guard let url = file(deviceID: deviceID, projectID: projectID, target: target, directory: directory) else { return false }
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        guard let data = try? Data(contentsOf: url) else { return false }
        let decoder = JSONDecoder()
        if let record = try? decoder.decode(Record.self, from: data) {
            return record.deviceID == deviceID && record.projectID == projectID && record.target == target &&
                (record.state.pending.map { $0.review.projectId == projectID && $0.review.target == target && $0.intact } ?? true)
        }
        guard let legacy = try? decoder.decode(LAAStudioReviewEditorState.self, from: data) else { return false }
        return save(legacy, deviceID: deviceID, projectID: projectID, target: target,
                    targetName: targetName, revision: revision, directory: directory)
    }
    // The server lists at most 50 versions; absence from that list does not prove deletion.
    static func displaced(deviceID: String, projectID: String, listedVersionIDs: Set<String>,
                          directory: URL = LAAStudioDraftStore.directory()) -> [DisplacedDraft] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        return files.compactMap { url -> DisplacedDraft? in
            guard url.lastPathComponent.hasPrefix("review-"), url.pathExtension == "json",
                  let data = try? Data(contentsOf: url) else { return nil }
            let target: LAAStudioReview.Target, name: String?, revision: Int?, state: LAAStudioReviewEditorState
            if let record = try? decoder.decode(Record.self, from: data), record.deviceID == deviceID, record.projectID == projectID {
                target = record.target; name = record.targetName; revision = record.revision; state = record.state
            } else if let legacy = try? decoder.decode(LAAStudioReviewEditorState.self, from: data), let pending = legacy.pending,
                      pending.review.projectId == projectID {
                target = pending.review.target; name = nil; revision = pending.review.revision; state = legacy
            } else { return nil }
            guard target.kind == "version", let id = target.id, !listedVersionIDs.contains(id),
                  file(deviceID: deviceID, projectID: projectID, target: target, directory: directory)?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath(),
                  state.pending.map({ $0.review.projectId == projectID && $0.review.target == target && $0.intact }) ?? true,
                  state.pending != nil || state.verdict != nil || !state.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .init(target: target, targetName: name, revision: revision, state: state)
        }.sorted { ($0.targetName ?? $0.id) < ($1.targetName ?? $1.id) }
    }
    static func clear(deviceID: String, projectID: String, target: LAAStudioReview.Target,
                      directory: URL = LAAStudioDraftStore.directory()) -> Bool {
        guard let url = file(deviceID: deviceID, projectID: projectID, target: target, directory: directory) else { return false }
        do { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }; return true }
        catch { return false }
    }
}
#endif
