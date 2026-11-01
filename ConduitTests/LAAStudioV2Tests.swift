#if LAA_BUILD
import Foundation
import XCTest
@testable import Conduit

final class LAAStudioV2Tests: XCTestCase {
    private let id = "0f6b1c2e-6f1a-4c55-9d43-0d5f6f3b8a11"
    private let projectID = "70175325-5cf4-421f-8a6f-95beae8fca92"

    func testSnapshotContractKeepsV1AndEnablesV2() throws {
        let old = #"{"online":true,"accepting":true,"projects":[],"principles":[],"requests":[]}"#
        let v1 = try JSONDecoder().decode(LAAStudioSnapshot.self, from: Data(old.utf8))
        let v2 = try JSONDecoder().decode(LAAStudioSnapshot.self, from: Data(old.dropLast().utf8) + Data(",\"contract\":2}".utf8))
        XCTAssertFalse(v1.supportsV2)
        XCTAssertTrue(v2.supportsV2)
    }

    func testReviewProjectTargetOmitsIDAndAbsentFields() throws {
        let review = LAAStudioReview(id: id, projectId: projectID, revision: 3, target: .project,
                                     verdict: nil, comment: "コメントのみ")
        let data = try JSONEncoder().encode(review)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let target = try XCTUnwrap(object["target"] as? [String: Any])
        XCTAssertEqual(target["kind"] as? String, "project")
        XCTAssertNil(target["id"])
        XCTAssertNil(object["verdict"])
        XCTAssertNil(object["createdAt"])
        var withNull = object; withNull["verdict"] = NSNull()
        let decoded = try JSONDecoder().decode(LAAStudioReview.self, from: JSONSerialization.data(withJSONObject: withNull))
        XCTAssertTrue(review.sameSubmission(as: decoded))
    }

    func testReviewValidationAllowsEitherFieldAndCountsUTF16() {
        XCTAssertFalse(LAAStudioReview.canSubmit(verdict: nil, comment: "  \n"))
        XCTAssertTrue(LAAStudioReview.canSubmit(verdict: "adopt", comment: ""))
        XCTAssertTrue(LAAStudioReview.canSubmit(verdict: nil, comment: "コメント"))
        XCTAssertTrue(LAAStudioReview.canSubmit(verdict: nil, comment: String(repeating: "😀", count: 2000)))
        XCTAssertFalse(LAAStudioReview.canSubmit(verdict: nil, comment: String(repeating: "😀", count: 2001)))
        XCTAssertFalse(LAAStudioReview.canSubmit(verdict: "unknown", comment: "comment"))
    }

    func testReviewHistoryKeepsServerOrderWhenAnOlderSavedReviewIsRetried() {
        func review(_ id: String, _ createdAt: String) -> LAAStudioReview {
            LAAStudioReview(id: id, projectId: projectID, revision: 3, target: .project,
                            verdict: "revise", comment: nil, createdAt: createdAt)
        }
        let latest = review("latest", "2026-11-01T10:00:00Z")
        let old = review("old", "2026-11-01T09:00:00.000Z")
        XCTAssertEqual(LAAStudioReview.history([latest], target: .project, including: old).map(\.id), ["latest", "old"])
        XCTAssertEqual(LAAStudioReview.history([latest], target: .project, including: latest).map(\.id), ["latest"])
        XCTAssertEqual(LAAStudioReview.history([old], target: .project, including: latest).map(\.id), ["latest", "old"])
    }

    func testUncertainReviewKeepsUUIDAndExactBytesWhenKeyRotates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("studio-review-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = LAAStudioReview.Target.version(String(repeating: "a", count: 64))
        let review = LAAStudioReview(id: id, projectId: projectID, revision: 3, target: target,
                                     verdict: "revise", comment: "18秒の入りを早く")
        var draft = try LAAStudioReviewDraft(review: review)
        draft.pending = true
        var state = LAAStudioReviewEditorState(); state.pending = draft
        XCTAssertTrue(LAAStudioReviewStore.save(state, deviceID: "device-1", projectID: projectID, target: target, directory: directory))
        guard case .loaded(let restored) = LAAStudioReviewStore.load(deviceID: "device-1", projectID: projectID, target: target, directory: directory),
              var retry = restored.pending else { return XCTFail("pending review not restored") }
        let originalBody = retry.body, originalKey = retry.key
        retry.rotateKey()
        XCTAssertNotEqual(retry.key, originalKey)
        XCTAssertEqual(retry.body, originalBody)
        XCTAssertEqual(retry.review.id, id)
        XCTAssertTrue(retry.intact)
        guard case .missing = LAAStudioReviewStore.load(deviceID: "device-1", projectID: projectID, target: .project, directory: directory) else {
            return XCTFail("another target must have its own draft")
        }
        XCTAssertTrue(LAAStudioReviewStore.clear(deviceID: "device-1", projectID: projectID, target: target, directory: directory))
    }

    func testUnreadableReviewDraftIsNotTreatedAsMissing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("studio-review-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = try XCTUnwrap(LAAStudioReviewStore.file(deviceID: "device-1", projectID: projectID, target: .project, directory: directory))
        let broken = Data("unreadable".utf8); try broken.write(to: url)
        guard case .unreadable = LAAStudioReviewStore.load(deviceID: "device-1", projectID: projectID, target: .project, directory: directory) else {
            return XCTFail("damaged draft must block an overwrite")
        }
        XCTAssertEqual(try Data(contentsOf: url), broken)
    }

    func testUnreadableRequestDraftIsNotTreatedAsMissing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("studio-request-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = try XCTUnwrap(LAAStudioDraftStore.file(deviceID: "device-1", directory: directory))
        let broken = Data("unreadable".utf8); try broken.write(to: url)
        guard case .unreadable = LAAStudioDraftStore.loadResult(deviceID: "device-1", directory: directory) else {
            return XCTFail("damaged request draft must block an overwrite")
        }
        XCTAssertEqual(try Data(contentsOf: url), broken)
    }

    func testPrincipleDraftIDIsStableAndSeparate() {
        let first = LAAStudioDraftStore.principleDraftID("principle-1")
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(first, LAAStudioDraftStore.principleDraftID("principle-1"))
        XCTAssertNotEqual(first, LAAStudioDraftStore.principleDraftID("principle-2"))
    }

    func testCatalogAuthorizationFailuresIncludeLocalAndHTTPFailures() {
        XCTAssertTrue(LAAStudioData.isAuthorizationFailure(LAABridgeError.unauthorized))
        XCTAssertTrue(LAAStudioData.isAuthorizationFailure(LAABridgeError.revoked))
        XCTAssertTrue(LAAStudioData.isAuthorizationFailure(LAABridgeError.keychain))
        let denied = LAABridgeHTTPError(status: 403, code: "insufficient_scope", message: nil,
                                        retryable: false, details: nil, requestId: nil, currentETag: nil)
        XCTAssertTrue(LAAStudioData.isAuthorizationFailure(denied))
        XCTAssertFalse(LAAStudioData.isAuthorizationFailure(LAABridgeError.networkUnreachable))
    }

    func testUnavailableDocumentRetainsDriveFallback() throws {
        let json = #"{"id":"fixture-document","title":"Sample document","category":"Cards","detail":"Fixture","format":"PDF","driveUrl":"https://drive.google.com/file/d/1234567890/view","unavailable":"source_unreadable"}"#
        let document = try JSONDecoder().decode(LAAStudioCatalog.Document.self, from: Data(json.utf8))
        XCTAssertEqual(document.unavailable, "source_unreadable")
        XCTAssertNil(document.media)
        XCTAssertNotNil(LAAStudioMedia.driveURL(document.driveUrl))
    }

    #if DEBUG
    func testV2CatalogAndOtherVersionFixture() throws {
        let catalog = try LAAStudioData.sampleCatalog()
        XCTAssertEqual(catalog.principles.first?.colors.first?.rgb?.text, "34, 34, 34")
        XCTAssertEqual(catalog.documents.count, 1)
        let project = try LAAStudioData.sampleProject("v2")
        XCTAssertEqual(project.versions.first?.kind, "other")
        XCTAssertNil(project.versions.first?.media)
        XCTAssertEqual(project.versions.first?.unavailable, "unsupported_format")
    }
    #endif
}
#endif
