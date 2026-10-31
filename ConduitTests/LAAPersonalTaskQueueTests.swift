#if LAA_BUILD
import Foundation
import CryptoKit
#if !LAATASK_QUEUE_STANDALONE
import XCTest
@testable import Conduit
#endif

@MainActor private final class QueueFixture: LAAPersonalQueueTransport {
    enum Failure: Error { case lostReply }
    var deviceID: String? = "device-a"
    var operations: [String: LAAPersonalOperationResponse.Operation] = [:]
    var calls: [String] = []
    var ifMatches: [String: String] = [:]
    var wrongViewer = false
    var loseChildReply = false
    let target = "7ae6f09d-3879-47ea-8e0d-72cd834ac5bc"

    func operation(_ status: String, kind: String = "create", resolution: String? = nil) throws -> LAAPersonalOperationResponse.Operation {
        let data: [String: Any] = ["operationId": "operation", "kind": kind, "targetId": target, "status": status,
            "resultId": status == "succeeded" ? target : NSNull(), "resolution": resolution as Any? ?? NSNull()]
        return try JSONDecoder().decode(LAAPersonalOperationResponse.Operation.self, from: JSONSerialization.data(withJSONObject: data))
    }
    func queueOperation(_ key: LAABridgeIdempotencyKey) async throws -> LAAPersonalOperationResponse.Operation? {
        operations[key.value]
    }
    func queueTask(_ id: String) async throws -> LAAPersonalTaskResponse {
        let data: [String: Any] = ["viewerId": wrongViewer ? "other-viewer" : "viewer-a",
            "task": ["id": "linear:T-1", "sourceId": "T-1", "linearId": id, "title": "Parent"]]
        return try JSONDecoder().decode(LAAPersonalTaskResponse.self, from: JSONSerialization.data(withJSONObject: data))
    }
    func queueWrite(_ method: String, path: String, body: Data, key: LAABridgeIdempotencyKey,
                    ifMatch: String?) async throws -> LAAPersonalOperationResponse.Operation {
        calls.append("\(key.value):\(path)")
        if let ifMatch { ifMatches[key.value] = ifMatch }
        let kind = key.value == "parent-key" ? "create" : key.value == "edit-key" ? "update" : "comment"
        if kind == "comment" && loseChildReply {
            operations[key.value] = try operation("outcome_unknown", kind: kind)
            throw Failure.lostReply
        }
        let result = try operation("succeeded", kind: kind)
        operations[key.value] = result
        return result
    }
    func queueUpload(_ path: String, file: URL, metadata: LAAPersonalUploadMetadata,
                     key: LAABridgeIdempotencyKey) async throws -> LAAPersonalOperationResponse.Operation {
        calls.append("\(key.value):\(path)")
        return try operation("succeeded", kind: "file")
    }
}

@MainActor final class LAAPersonalTaskQueueTests: XCTestCase {
    private func reserve(_ store: ComposerDraftStore, now: Date = Date()) throws {
        var parent = LAAPersonalTaskDraft(viewerId: "viewer-a", task: nil)
        parent.title = "Parent"; parent.teamId = "team"
        let parentText = String(decoding: try JSONEncoder().encode(parent), as: UTF8.self)
        let parentKey = try XCTUnwrap(LAABridgeIdempotencyKey(restoring: "parent-key"))
        _ = try XCTUnwrap(LAAWorkDrafts.reserve(store, key: LAAWorkDrafts.key(deviceID: "device-a", target: "linear:viewer-a:new"),
            text: parentText, body: try parent.requestBody(), idempotency: parentKey, now: now))
        let child = LAAPersonalDependency(viewerId: "viewer-a", deviceId: "device-a", parentKey: "parent-key",
                                         childKey: "child-key", teamId: "team", kind: .comment, first: "Child text")
        let bytes = try JSONEncoder().encode(child)
        let childKey = try XCTUnwrap(LAABridgeIdempotencyKey(restoring: "child-key"))
        _ = try XCTUnwrap(LAAWorkDrafts.reserve(store, key: LAAWorkDrafts.key(deviceID: "device-a", target: "linear:viewer-a:dependency:child-key"),
            text: String(decoding: bytes, as: UTF8.self), body: bytes, idempotency: childKey, now: now))
    }
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("linear-queue-test-\(UUID().uuidString)", isDirectory: true)
    }

    func testUnknownParentWaitsAcrossRestartAndNeedsVerifiedReadback() async throws {
        let folder = location(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("drafts.json")
        let original = ComposerDraftStore(fileURL: file)
        try reserve(original)
        let reopened = ComposerDraftStore(fileURL: file)
        let bridge = QueueFixture()
        bridge.operations["parent-key"] = try bridge.operation("outcome_unknown")
        await LAAPersonalTaskQueue.run(drafts: reopened, bridge: bridge, viewer: "viewer-a")
        XCTAssertEqual(bridge.calls.count, 0); XCTAssertEqual(reopened.submissions.count, 2)
        bridge.operations["parent-key"] = try bridge.operation("resolved", resolution: "applied")
        bridge.wrongViewer = true
        await LAAPersonalTaskQueue.run(drafts: reopened, bridge: bridge, viewer: "viewer-a")
        XCTAssertEqual(bridge.calls.count, 0); XCTAssertEqual(reopened.submissions.count, 2)
        bridge.wrongViewer = false
        await LAAPersonalTaskQueue.run(drafts: reopened, bridge: bridge, viewer: "viewer-a")
        XCTAssertEqual(bridge.calls, ["child-key:/v1/personal-tasks/\(bridge.target)/comments"])
        XCTAssertEqual(reopened.submissions.count, 1)
        XCTAssertEqual(ComposerDraftStore(fileURL: file).submissions.count, 1)
    }

    func testOrderedSendAndLostReplyNeverRepeatsAfterRestart() async throws {
        let folder = location(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("drafts.json")
        let original = ComposerDraftStore(fileURL: file)
        try reserve(original)
        let bridge = QueueFixture(); bridge.loseChildReply = true
        await LAAPersonalTaskQueue.run(drafts: original, bridge: bridge, viewer: "viewer-a")
        XCTAssertEqual(bridge.calls, ["parent-key:/v1/personal-tasks", "child-key:/v1/personal-tasks/\(bridge.target)/comments"])
        XCTAssertEqual(original.submissions.count, 1)
        let reopened = ComposerDraftStore(fileURL: file)
        await LAAPersonalTaskQueue.run(drafts: reopened, bridge: bridge, viewer: "viewer-a")
        XCTAssertEqual(bridge.calls.count, 2); XCTAssertEqual(reopened.submissions.count, 1)
        bridge.operations["child-key"] = try bridge.operation("resolved", kind: "comment", resolution: "applied")
        await LAAPersonalTaskQueue.run(drafts: reopened, bridge: bridge, viewer: "viewer-a")
        XCTAssertEqual(bridge.calls.count, 2); XCTAssertTrue(reopened.submissions.isEmpty)
        XCTAssertTrue(ComposerDraftStore(fileURL: file).submissions.isEmpty)
    }

    func testExpiredOrDifferentDeviceDoesNotSend() async throws {
        let store = ComposerDraftStore()
        try reserve(store, now: Date().addingTimeInterval(-7 * 24 * 60 * 60))
        let bridge = QueueFixture()
        await LAAPersonalTaskQueue.run(drafts: store, bridge: bridge, viewer: "viewer-a")
        XCTAssertTrue(bridge.calls.isEmpty); XCTAssertEqual(store.submissions.count, 2)
        bridge.deviceID = "other-device"
        await LAAPersonalTaskQueue.run(drafts: store, bridge: bridge, viewer: "viewer-a")
        XCTAssertTrue(bridge.calls.isEmpty); XCTAssertEqual(store.submissions.count, 2)
    }

    func testOfflineEditAndCommentReuseTheirOriginalKeysAndVersion() async throws {
        let folder = location(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("drafts.json")
        let store = ComposerDraftStore(fileURL: file)
        let raw: [String: Any] = ["id": "linear:T-1", "sourceId": "T-1", "linearId": "issue",
            "title": "Parent", "description": "Before", "updatedAt": "version-1", "team": ["id": "team"]]
        let task = try JSONDecoder().decode(LAAPersonalTask.self, from: JSONSerialization.data(withJSONObject: raw))
        var edit = LAAPersonalTaskDraft(viewerId: "viewer-a", task: task); edit.description = "After"
        let editText = String(decoding: try JSONEncoder().encode(edit), as: UTF8.self)
        _ = try XCTUnwrap(LAAWorkDrafts.reserve(store, key: LAAWorkDrafts.key(deviceID: "device-a", target: "linear:viewer-a:linear:T-1"),
            text: editText, body: try edit.requestBody(), idempotency: try XCTUnwrap(LAABridgeIdempotencyKey(restoring: "edit-key")),
            expectedVersion: "version-1"))
        let body = try JSONSerialization.data(withJSONObject: ["expectedViewerId": "viewer-a", "body": "Offline comment"], options: [.sortedKeys])
        _ = try XCTUnwrap(LAAWorkDrafts.reserve(store, key: LAAWorkDrafts.key(deviceID: "device-a", target: "linear:viewer-a:comment:linear:T-1:root"),
            text: "Offline comment", body: body, idempotency: try XCTUnwrap(LAABridgeIdempotencyKey(restoring: "comment-key"))))
        let bridge = QueueFixture()
        let reopened = ComposerDraftStore(fileURL: file)
        await LAAPersonalTaskQueue.run(drafts: reopened, bridge: bridge, viewer: "viewer-a")
        let encoded = try XCTUnwrap("linear:T-1".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed))
        XCTAssertEqual(bridge.calls, ["edit-key:/v1/personal-tasks/\(encoded)", "comment-key:/v1/personal-tasks/\(encoded)/comments"])
        XCTAssertEqual(bridge.ifMatches["edit-key"], "version-1")
        XCTAssertTrue(reopened.submissions.isEmpty)
    }

    func testQueuedUploadChecksProtectedCopyBeforeSending() async throws {
        let folder = location(); defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = folder.appendingPathComponent("input.txt"), data = Data("fixture".utf8)
        try data.write(to: input)
        let metadata = LAAPersonalUploadMetadata(viewerId: "viewer-a", filename: "input.txt", contentType: "text/plain",
            size: data.count, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        let bytes = try JSONEncoder().encode(metadata)
        let store = ComposerDraftStore(fileURL: folder.appendingPathComponent("drafts.json"))
        let attachment = Attachment(id: "attachment", name: "input.txt", uri: input.absoluteString, mimeType: "text/plain", kind: .document)
        _ = try XCTUnwrap(LAAWorkDrafts.reserve(store, key: LAAWorkDrafts.key(deviceID: "device-a", target: "linear:viewer-a:upload:linear:T-1"),
            text: String(decoding: bytes, as: UTF8.self), body: bytes,
            idempotency: try XCTUnwrap(LAABridgeIdempotencyKey(restoring: "upload-key")), attachments: [attachment]))
        let copy = try XCTUnwrap(URL(string: try XCTUnwrap(store.submissions.first).draft.attachments[0].uri))
        try Data("changed".utf8).write(to: copy)
        let bridge = QueueFixture()
        await LAAPersonalTaskQueue.run(drafts: store, bridge: bridge, viewer: "viewer-a")
        XCTAssertTrue(bridge.calls.isEmpty); XCTAssertEqual(store.submissions.count, 1)
        try data.write(to: copy)
        let reopened = ComposerDraftStore(fileURL: folder.appendingPathComponent("drafts.json"))
        await LAAPersonalTaskQueue.run(drafts: reopened, bridge: bridge, viewer: "viewer-a")
        let encoded = try XCTUnwrap("linear:T-1".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed))
        XCTAssertEqual(bridge.calls, ["upload-key:/v1/personal-tasks/\(encoded)/files"])
        XCTAssertTrue(reopened.submissions.isEmpty)
    }

    func testRetryablePreflightUsesSameKeysButUnknownNeverRepeats() async throws {
        let folder = location(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("drafts.json")
        let original = ComposerDraftStore(fileURL: file); try reserve(original)
        let bridge = QueueFixture()
        bridge.operations["parent-key"] = try bridge.operation("preflight_retryable")
        bridge.operations["child-key"] = try bridge.operation("preflight_retryable", kind: "comment")
        let reopened = ComposerDraftStore(fileURL: file)
        await LAAPersonalTaskQueue.run(drafts: reopened, bridge: bridge, viewer: "viewer-a")
        XCTAssertEqual(bridge.calls, ["parent-key:/v1/personal-tasks", "child-key:/v1/personal-tasks/\(bridge.target)/comments"])
        XCTAssertTrue(reopened.submissions.isEmpty)
    }

    func testReconciliationDurablyUnlocksOnlyConfirmedOrRejectedDrafts() throws {
        for (status, resolution, restores) in [("resolved", "not_applied", true), ("resolved", "applied", false), ("rejected", "", true)] {
            let folder = location(); defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("drafts.json")
            let store = ComposerDraftStore(fileURL: file); try reserve(store)
            let item = try XCTUnwrap(store.submissions.first { $0.key.sessionID.hasSuffix(":new") })
            let operation = try QueueFixture().operation(status, resolution: resolution.isEmpty ? nil : resolution)
            let result = LAAPersonalReconciliation.disposition(operation, mayCompare: false)
            XCTAssertEqual(result, restores ? .restore : .complete)
            XCTAssertTrue(store.finishSubmission(item.id, restoring: restores))
            let reopened = ComposerDraftStore(fileURL: file)
            XCTAssertTrue(!reopened.submissions.contains { $0.id == item.id })
            XCTAssertEqual(reopened.hasDraft(for: item.key), restores)
            if restores { XCTAssertEqual(reopened.draft(for: item.key).text, item.draft.text) }
        }
    }

    func testViewerChangeKeepsOriginalDraftPrivateAndUnsent() async throws {
        let folder = location(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("drafts.json")
        let original = ComposerDraftStore(fileURL: file); try reserve(original)
        let reopened = ComposerDraftStore(fileURL: file)
        let bridge = QueueFixture()
        await LAAPersonalTaskQueue.run(drafts: reopened, bridge: bridge, viewer: "viewer-b")
        XCTAssertTrue(bridge.calls.isEmpty)
        XCTAssertEqual(reopened.submissions.count, 2)
        let different = LAAWorkDrafts.key(deviceID: "device-a", target: "linear:viewer-b:new")
        XCTAssertTrue(LAAWorkDrafts.pending(reopened, key: different) == nil)
        XCTAssertEqual(ComposerDraftStore(fileURL: file).submissions.count, 2)
    }

    func testInboxRequestSurvivesRestartButTaskQueueNeverSendsIt() async throws {
        let folder = location(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("drafts.json")
        let store = ComposerDraftStore(fileURL: file)
        let body = try JSONSerialization.data(withJSONObject: ["expectedViewerId": "viewer-a", "action": "read"], options: [.sortedKeys])
        let localKey = LAAWorkDrafts.key(deviceID: "device-a", target: "linear:viewer-a:inbox:notification-a")
        _ = try XCTUnwrap(LAAWorkDrafts.reserve(store, key: localKey, text: "read", body: body,
            idempotency: try XCTUnwrap(LAABridgeIdempotencyKey(restoring: "inbox-key"))))
        let reopened = ComposerDraftStore(fileURL: file)
        let bridge = QueueFixture()
        await LAAPersonalTaskQueue.run(drafts: reopened, bridge: bridge, viewer: "viewer-a")
        XCTAssertTrue(bridge.calls.isEmpty)
        XCTAssertEqual(reopened.submissions.count, 1)
        let saved = try XCTUnwrap(LAAWorkDrafts.pending(reopened, key: localKey))
        XCTAssertEqual(LAAWorkDrafts.request(saved)?.1.value, "inbox-key")
        XCTAssertEqual(LAAWorkDrafts.request(saved)?.0, body)
    }
}
#endif
