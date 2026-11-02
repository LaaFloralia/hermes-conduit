#if LAA_BUILD
import Foundation
import CryptoKit
#if !LAATASK_QUEUE_STANDALONE
import XCTest
@testable import Conduit
#endif

@MainActor private final class QueueFixture: LAAPersonalQueueTransport {
    enum Failure: Error { case lostReply, compacted }
    var deviceID: String? = "device-a"
    var operations: [String: LAAPersonalOperationResponse.Operation] = [:]
    var calls: [String] = []
    var ifMatches: [String: String] = [:]
    var wrongViewer = false
    var loseChildReply = false
    var compactedKeys: Set<String> = []
    let target = "7ae6f09d-3879-47ea-8e0d-72cd834ac5bc"

    func operation(_ status: String, kind: String = "create", resolution: String? = nil,
                   rejection: String? = nil) throws -> LAAPersonalOperationResponse.Operation {
        let data: [String: Any] = ["operationId": "operation", "kind": kind, "targetId": target, "status": status,
            "resultId": status == "succeeded" ? target : NSNull(), "resolution": resolution as Any? ?? NSNull(),
            "rejection": rejection as Any? ?? NSNull()]
        return try JSONDecoder().decode(LAAPersonalOperationResponse.Operation.self, from: JSONSerialization.data(withJSONObject: data))
    }
    func queueOperation(_ key: LAABridgeIdempotencyKey) async throws -> LAAPersonalOperationResponse.Operation? {
        if compactedKeys.contains(key.value) { throw Failure.compacted }
        return operations[key.value]
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

@MainActor private final class AbandonFixture: LAAPersonalAbandonTransport {
    var calls = 0
    var status = "rejected"
    var onCall: (() -> Void)?
    func abandonUnsent(_ key: LAABridgeIdempotencyKey, viewer: String) async throws -> LAAPersonalOperationResponse.Operation {
        calls += 1
        onCall?()
        return try QueueFixture().operation(status, kind: "inbox_read")
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

    func testMovedFollowupRestoresOnlyAfterBothResultsAndParentAreVerified() async throws {
        let bridge = QueueFixture()
        let parent = try bridge.operation("succeeded")
        let verified = try await bridge.queueTask(bridge.target)
        for kind in LAAPersonalDependency.Kind.allCases {
            let store = ComposerDraftStore()
            let second = kind == .link ? "https://example.com/path" : ""
            let value = LAAPersonalDependency(viewerId: "viewer-a", deviceId: "device-a", parentKey: "parent-key",
                childKey: "child-key", teamId: "team", kind: kind, first: "Content", second: second)
            let bytes = try JSONEncoder().encode(value)
            let old = LAAWorkDrafts.key(deviceID: "device-a", target: "linear:viewer-a:dependency:child-key")
            let original = try XCTUnwrap(LAAWorkDrafts.reserve(store, key: old, text: String(decoding: bytes, as: UTF8.self),
                body: bytes, idempotency: try XCTUnwrap(LAABridgeIdempotencyKey(restoring: "child-key"))))
            let movedKey = LAAWorkDrafts.key(deviceID: "device-b", target: "linear:viewer-a:dependency:child-key")
            XCTAssertTrue(store.movePersonalSubmission(original.id, to: movedKey))
            let moved = try XCTUnwrap(store.submissions.first)
            let operationKind: String
            switch kind {
            case .comment: operationKind = "comment"
            case .subtask: operationKind = "create"
            case .relation: operationKind = "relation"
            case .link: operationKind = "attachment"
            }
            let unknown = try bridge.operation("outcome_unknown", kind: operationKind)
            XCTAssertTrue(!LAAPersonalTaskQueue.restoreMovedDependency(moved, drafts: store, device: "device-b", viewer: "viewer-a",
                child: unknown, parent: parent, verified: verified))
            let rejected = kind == .comment
                ? try bridge.operation("rejected", kind: "abandoned", rejection: "abandoned_before_reservation")
                : try bridge.operation("rejected", kind: operationKind)
            let unresolvedParent = try bridge.operation("outcome_unknown")
            XCTAssertTrue(!LAAPersonalTaskQueue.restoreMovedDependency(moved, drafts: store, device: "device-b", viewer: "viewer-a",
                child: rejected, parent: unresolvedParent, verified: verified))
            bridge.wrongViewer = true
            let wrongViewer = try await bridge.queueTask(bridge.target)
            bridge.wrongViewer = false
            XCTAssertTrue(!LAAPersonalTaskQueue.restoreMovedDependency(moved, drafts: store, device: "device-b", viewer: "viewer-a",
                child: rejected, parent: parent, verified: wrongViewer))
            let target: String
            switch kind {
            case .comment: target = "comment:linear:T-1:root"
            case .subtask: target = "new-subtask:linear:T-1"
            case .relation: target = "relation:linear:T-1"
            case .link: target = "attachment:linear:T-1"
            }
            let destination = LAAWorkDrafts.key(deviceID: "device-b", target: "linear:viewer-a:\(target)")
            XCTAssertTrue(store.save(ComposerDraft(text: "existing", attachments: []), for: destination))
            XCTAssertTrue(!LAAPersonalTaskQueue.restoreMovedDependency(moved, drafts: store, device: "device-b", viewer: "viewer-a",
                child: rejected, parent: parent, verified: verified))
            XCTAssertEqual(store.draft(for: destination).text, "existing")
            XCTAssertTrue(store.save(ComposerDraft(text: "", attachments: []), for: destination))
            XCTAssertTrue(LAAPersonalTaskQueue.restoreMovedDependency(moved, drafts: store, device: "device-b", viewer: "viewer-a",
                child: rejected, parent: parent, verified: verified))
            XCTAssertTrue(store.submissions.isEmpty)
            let restored = store.draft(for: destination).text
            if kind == .comment { XCTAssertEqual(restored, value.first) }
            else if kind == .subtask {
                let task = try JSONDecoder().decode(LAAPersonalTaskDraft.self, from: Data(restored.utf8))
                XCTAssertEqual(task.title, value.first); XCTAssertEqual(task.parentId, bridge.target); XCTAssertEqual(task.teamId, "team")
            } else {
                let fields = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(restored.utf8)) as? [String: String])
                XCTAssertEqual(fields["first"], value.first); XCTAssertEqual(fields["second"], value.second)
            }
        }
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

    func testMovedUnknownCreateKeepsOriginalKeyAndUUIDAndNeverAutomaticallyResends() async throws {
        let folder = location(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("drafts.json")
        let store = ComposerDraftStore(fileURL: file); try reserve(store)
        let original = try XCTUnwrap(store.submissions.first { $0.key.sessionID.hasSuffix(":new") })
        let originalKey = try XCTUnwrap(LAAWorkDrafts.originalRequest(original)?.1.value)
        let bridge = QueueFixture()
        let unknown = try bridge.operation("outcome_unknown")
        bridge.operations[originalKey] = unknown
        bridge.deviceID = "device-b"
        let destination = try XCTUnwrap(LAAWorkDrafts.destination(original, device: "device-b", viewer: "viewer-a"))
        XCTAssertTrue(store.movePersonalSubmission(original.id, to: destination))
        let reopened = ComposerDraftStore(fileURL: file)
        let moved = try XCTUnwrap(reopened.submissions.first { $0.id == original.id })
        XCTAssertEqual(moved.key, destination)
        XCTAssertEqual(moved.personalOrigin, original.key)
        XCTAssertEqual(LAAWorkDrafts.originalRequest(moved)?.1.value, originalKey)
        XCTAssertEqual(LAAWorkDrafts.originalRequest(moved)?.0, LAAWorkDrafts.originalRequest(original)?.0)
        XCTAssertEqual(LAAWorkDrafts.origin(moved)?.device, "device-a")
        XCTAssertEqual(bridge.operations[originalKey]?.targetId, unknown.targetId)
        XCTAssertEqual(bridge.operations[originalKey]?.status, "outcome_unknown")
        XCTAssertTrue(LAAWorkDrafts.request(moved) == nil)
        XCTAssertTrue(!LAAWorkDrafts.canRepeat(moved))
        await LAAPersonalTaskQueue.run(drafts: reopened, bridge: bridge, viewer: "viewer-a")
        XCTAssertTrue(bridge.calls.isEmpty)
        XCTAssertEqual(reopened.submissions.count, 2)

        // A further explicit move to another viewer keeps the first origin and
        // original request; neither the old nor the new viewer auto-sends it.
        let next = try XCTUnwrap(LAAWorkDrafts.destination(moved, device: "device-b", viewer: "viewer-b"))
        XCTAssertTrue(reopened.movePersonalSubmission(moved.id, to: next))
        let again = ComposerDraftStore(fileURL: file)
        let transferred = try XCTUnwrap(again.submissions.first { $0.id == original.id })
        XCTAssertEqual(transferred.personalOrigin, original.key)
        XCTAssertEqual(LAAWorkDrafts.originalRequest(transferred)?.1.value, originalKey)
        await LAAPersonalTaskQueue.run(drafts: again, bridge: bridge, viewer: "viewer-b")
        XCTAssertTrue(bridge.calls.isEmpty)
    }

    func testDiscardingAnOldCreateReopensTheNewTaskSlot() throws {
        let folder = location(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("drafts.json")
        let store = ComposerDraftStore(fileURL: file)
        let key = LAAWorkDrafts.key(deviceID: "device-a", target: "linear:viewer-a:new")
        let body = Data("{\"expectedViewerId\":\"viewer-a\",\"teamId\":\"team\",\"title\":\"old\"}".utf8)
        let old = try XCTUnwrap(LAAWorkDrafts.reserve(store, key: key, text: "old", body: body,
            idempotency: try XCTUnwrap(LAABridgeIdempotencyKey(restoring: "old-key")), now: Date(timeIntervalSinceNow: -8 * 24 * 60 * 60)))
        XCTAssertTrue(!LAAWorkDrafts.canRepeat(old))
        XCTAssertTrue(LAAWorkDrafts.reserve(store, key: key, text: "new", body: body,
            idempotency: try XCTUnwrap(LAABridgeIdempotencyKey(restoring: "new-key"))) == nil)
        XCTAssertTrue(store.finishSubmission(old.id, restoring: false))
        let reopened = ComposerDraftStore(fileURL: file)
        XCTAssertTrue(LAAWorkDrafts.pending(reopened, key: key) == nil)
        let next = try XCTUnwrap(LAAWorkDrafts.reserve(reopened, key: key, text: "new", body: body,
            idempotency: try XCTUnwrap(LAABridgeIdempotencyKey(restoring: "new-key"))))
        XCTAssertEqual(LAAWorkDrafts.originalRequest(next)?.1.value, "new-key")
    }

    func testDependencyWithCompactedParentRemainsUnsentAndCanBeDiscarded() async throws {
        let folder = location(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("drafts.json")
        let store = ComposerDraftStore(fileURL: file); try reserve(store)
        let parent = try XCTUnwrap(store.submissions.first { $0.key.sessionID.hasSuffix(":new") })
        XCTAssertTrue(store.finishSubmission(parent.id, restoring: false))
        let child = try XCTUnwrap(store.submissions.first)
        let bridge = QueueFixture(); bridge.compactedKeys.insert("parent-key")
        await LAAPersonalTaskQueue.run(drafts: store, bridge: bridge, viewer: "viewer-a")
        XCTAssertTrue(bridge.calls.isEmpty)
        XCTAssertEqual(LAAPersonalTaskQueue.dependency(child, device: "device-a", viewer: "viewer-a")?.first, "Child text")
        XCTAssertEqual(store.submissions.count, 1)
        XCTAssertTrue(store.finishSubmission(child.id, restoring: false))
        XCTAssertTrue(ComposerDraftStore(fileURL: file).submissions.isEmpty)
    }

    func testOfflinePendingListsOnlyPersonalRecordsAndExplicitRejectionRestoresSafely() throws {
        let folder = location(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("drafts.json")
        let store = ComposerDraftStore(fileURL: file); try reserve(store)
        let otherKey = LAAWorkDrafts.key(deviceID: "device-a", target: "project:unrelated")
        _ = try XCTUnwrap(LAAWorkDrafts.reserve(store, key: otherKey, text: "not a task", body: Data("{}".utf8),
            idempotency: try XCTUnwrap(LAABridgeIdempotencyKey(restoring: "other-key"))))
        XCTAssertEqual(LAAWorkDrafts.personalSubmissions(store).count, 2)
        let parent = try XCTUnwrap(store.submissions.first { $0.key.sessionID.hasSuffix(":new") })
        XCTAssertEqual(LAAWorkDrafts.restoreConfirmedRejection(store, item: parent, isInbox: false), .restored)
        XCTAssertEqual(ComposerDraftStore(fileURL: file).draft(for: parent.key).text, parent.draft.text)
        XCTAssertEqual(LAAWorkDrafts.personalSubmissions(store).count, 1)
        XCTAssertEqual(LAAWorkDrafts.restoreConfirmedRejection(store, item: parent, isInbox: false), .missing)
        let child = try XCTUnwrap(LAAWorkDrafts.personalSubmissions(store).first)
        XCTAssertTrue(store.save(ComposerDraft(text: "existing", attachments: []), for: child.key))
        XCTAssertEqual(LAAWorkDrafts.restoreConfirmedRejection(store, item: child, isInbox: false), .draftExists)
        XCTAssertEqual(store.draft(for: child.key).text, "existing")
        XCTAssertEqual(LAAWorkDrafts.personalSubmissions(store).count, 1)
    }


    func testInboxDefiniteRefusalClosesOnlyTheProvenUnsentKey() async throws {
        for (code, ledgerStatus, shouldRemove, expectedCalls) in [
            ("insufficient_scope", "rejected", true, 1), ("notification_not_found", "rejected", true, 1),
            ("payload_invalid", "in_progress", false, 1), ("linear_viewer_changed", "outcome_unknown", false, 1),
            ("idempotency_outcome_unknown", "rejected", false, 0)
        ] {
            let store = ComposerDraftStore()
            let localKey = LAAWorkDrafts.key(deviceID: "device-a", target: "linear:viewer-a:inbox:n")
            let body = Data("{\"expectedViewerId\":\"viewer-a\",\"action\":\"read\"}".utf8)
            let item = try XCTUnwrap(LAAWorkDrafts.reserve(store, key: localKey, text: "read", body: body,
                idempotency: try XCTUnwrap(LAABridgeIdempotencyKey(restoring: "inbox-key"))))
            let bridge = AbandonFixture(); bridge.status = ledgerStatus
            let recovered = await LAAPersonalRefusalRecovery.recover(code: code, status: 403, item: item,
                                                                       drafts: store, viewer: "viewer-a", bridge: bridge)
            XCTAssertEqual(recovered, shouldRemove)
            XCTAssertEqual(store.submissions.isEmpty, shouldRemove)
            XCTAssertEqual(bridge.calls, expectedCalls)
        }
        // Re-pairing and a user move during the status request must not let
        // its old completion discard the newly moved protected record.
        let store = ComposerDraftStore()
        let localKey = LAAWorkDrafts.key(deviceID: "device-a", target: "linear:viewer-a:inbox:n")
        let body = Data("{\"expectedViewerId\":\"viewer-a\",\"action\":\"read\"}".utf8)
        let item = try XCTUnwrap(LAAWorkDrafts.reserve(store, key: localKey, text: "read", body: body,
            idempotency: try XCTUnwrap(LAABridgeIdempotencyKey(restoring: "inbox-key"))))
        let bridge = AbandonFixture()
        let destination = try XCTUnwrap(LAAWorkDrafts.destination(item, device: "device-b", viewer: "viewer-a"))
        bridge.onCall = { XCTAssertTrue(store.movePersonalSubmission(item.id, to: destination)) }
        let recovered = await LAAPersonalRefusalRecovery.recover(code: "notification_not_found", status: 404,
            item: item, drafts: store, viewer: "viewer-a", bridge: bridge)
        XCTAssertTrue(!recovered)
        XCTAssertEqual(store.submissions.first?.key, destination)
        XCTAssertEqual(store.submissions.first?.personalOrigin, localKey)
    }

}
#endif
