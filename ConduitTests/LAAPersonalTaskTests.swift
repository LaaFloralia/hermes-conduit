#if LAA_BUILD
import Foundation
#if !LAATASK_STANDALONE
import XCTest
@testable import Conduit
#endif

final class LAAPersonalTaskTests: XCTestCase {
    private func task(title: String = "Original", description: String = "古い本文", version: String? = "v1",
                      owner: String = "person", labelsComplete: Bool = true, dueDate: String = "2026-11-01", estimate: Double = 0.5) throws -> LAAPersonalTask {
        let value: [String: Any] = ["id": "linear:T-1", "sourceId": "T-1", "linearId": "issue-id", "title": title,
            "description": description, "updatedAt": version as Any? ?? NSNull(), "team": ["id": "team"],
            "owner": ["id": owner, "name": "Owner", "kind": "person"],
            "status": ["id": "todo", "name": "Todo", "type": "unstarted"],
            "priority": 2.0, "estimate": estimate, "dueDate": dueDate,
            "labels": [["id": "label-a", "name": "A"]], "labelsComplete": labelsComplete]
        return try JSONDecoder().decode(LAAPersonalTask.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func payload(_ draft: LAAPersonalTaskDraft) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: draft.requestBody()) as? [String: Any])
    }

    func testChangedFieldsAreBoundToViewerAndDoNotOverwriteOtherAttributes() throws {
        var draft = LAAPersonalTaskDraft(viewerId: "viewer-a", task: try task())
        draft.title = "新しい名前"
        draft.assigneeId = ""
        let body = try payload(draft)
        XCTAssertEqual(body["expectedViewerId"] as? String, "viewer-a")
        XCTAssertEqual(body["title"] as? String, "新しい名前")
        XCTAssertTrue(body["assigneeId"] is NSNull)
        XCTAssertNil(body["description"])
        XCTAssertNil(body["priority"])
        XCTAssertNil(body["labelIds"])
        let restored = try JSONDecoder().decode(LAAPersonalTaskDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(restored, draft)
        XCTAssertEqual(restored.base?.estimate, 0.5)
    }

    func testDescriptionRequiresBaseVersionAndPartialLabelsCannotBeReplaced() throws {
        var noVersion = LAAPersonalTaskDraft(viewerId: "viewer", task: try task(version: nil))
        noVersion.description = "変更"
        XCTAssertThrowsError(try noVersion.requestBody()) { XCTAssertTrue($0 is LAAPersonalTaskDraft.Validation) }
        var partial = LAAPersonalTaskDraft(viewerId: "viewer", task: try task(labelsComplete: false))
        partial.labelIds.append("label-b")
        XCTAssertThrowsError(try partial.requestBody())
    }

    func testConflictRebaseRetainsEditsAndPreservesUnchangedRemoteFields() throws {
        var draft = LAAPersonalTaskDraft(viewerId: "viewer", task: try task())
        draft.title = "Mine"
        draft.description = "私の本文"
        let remote = try task(title: "Remote", description: "相手の本文", version: "v2", owner: "someone-else", dueDate: "2026-12-01")
        draft.rebase(on: remote)
        XCTAssertEqual(draft.title, "Mine")
        XCTAssertEqual(draft.description, "私の本文")
        XCTAssertEqual(draft.assigneeId, "someone-else")
        XCTAssertEqual(draft.dueDate, "2026-12-01")
        XCTAssertEqual(draft.base?.updatedAt, "v2")
        let body = try payload(draft)
        XCTAssertNil(body["assigneeId"])
        XCTAssertNil(body["dueDate"])
        XCTAssertEqual(body["description"] as? String, "私の本文")
        let lines = LAAPersonalTaskDiff.changes(current: "一行\n古い", mine: "一行\n新しい")
        XCTAssertEqual(lines, ["− 2: 古い", "+ 2: 新しい"])
        let repeated = LAAPersonalTaskDiff.changes(current: "同じ\n古い\n同じ\n別", mine: "同じ\n新しい\n同じ\n修正")
        XCTAssertEqual(repeated, ["− 2: 古い", "+ 2: 新しい", "− 4: 別", "+ 4: 修正"])
        let long = LAAPersonalTaskDiff.changes(current: Array(repeating: "a", count: 1_100).joined(separator: "\n"),
                                              mine: Array(repeating: "b", count: 1_100).joined(separator: "\n"))
        XCTAssertTrue(long.count <= 202)
    }

    func testCreateAndEstimateInput() throws {
        var draft = LAAPersonalTaskDraft(viewerId: "viewer", task: nil)
        draft.teamId = "team"; draft.title = "起票"; draft.estimate = "3"; draft.parentId = "parent-id"
        let body = try payload(draft)
        XCTAssertEqual(body["teamId"] as? String, "team")
        XCTAssertEqual(body["expectedViewerId"] as? String, "viewer")
        XCTAssertEqual(body["estimate"] as? Int, 3)
        XCTAssertEqual(body["parentId"] as? String, "parent-id")
        var oldDraft = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        oldDraft.removeValue(forKey: "parentId")
        let restoredOldDraft = try JSONDecoder().decode(LAAPersonalTaskDraft.self, from: JSONSerialization.data(withJSONObject: oldDraft))
        XCTAssertNil(restoredOldDraft.parentId)
        draft.estimate = "1.5"
        XCTAssertThrowsError(try draft.requestBody())
        draft.estimate = "NaN"
        XCTAssertThrowsError(try draft.requestBody())
    }

    func testExistingEstimateRendersAsUsableIntegerAndPreservesFraction() throws {
        var whole = LAAPersonalTaskDraft(viewerId: "viewer", task: try task(estimate: 3))
        XCTAssertEqual(whole.estimate, "3")
        whole.estimate += "5"
        XCTAssertEqual(try payload(whole)["estimate"] as? Int, 35)
        var fractional = LAAPersonalTaskDraft(viewerId: "viewer", task: try task(estimate: 0.5))
        XCTAssertEqual(fractional.estimate, "0.5")
        fractional.title = "Updated"
        XCTAssertNil(try payload(fractional)["estimate"])
        XCTAssertEqual(LAAPersonalTaskDraft(viewerId: "viewer", task: try task(estimate: 1e100)).estimate, "1e+100")
    }

    func testHorizontalSwipeRequiresClearIntent() {
        XCTAssertNil(LAAPersonalTaskSwipe.action(width: -30, height: 15))
        XCTAssertNil(LAAPersonalTaskSwipe.action(width: -20, height: 0))
        XCTAssertEqual(LAAPersonalTaskSwipe.action(width: -40, height: 5), true)
        XCTAssertEqual(LAAPersonalTaskSwipe.action(width: 40, height: 5), false)
    }

    private func operation(status: String, kind: String = "create", result: String? = "7ae6f09d-3879-47ea-8e0d-72cd834ac5bc",
                           resolution: String? = nil, rejection: String? = nil) throws -> LAAPersonalOperationResponse.Operation {
        let data: [String: Any] = ["operationId": "operation", "kind": kind,
            "targetId": "7ae6f09d-3879-47ea-8e0d-72cd834ac5bc", "status": status,
            "resultId": result as Any? ?? NSNull(), "resolution": resolution as Any? ?? NSNull(), "rejection": rejection as Any? ?? NSNull()]
        return try JSONDecoder().decode(LAAPersonalOperationResponse.Operation.self, from: JSONSerialization.data(withJSONObject: data))
    }

    func testReconciliationRestoresOnlyKnownUnappliedAndRejectsUnsafeRetryAssumptions() throws {
        for status in ["outcome_unknown", "in_progress"] {
            XCTAssertEqual(LAAPersonalReconciliation.disposition(try operation(status: status), mayCompare: false), .wait)
        }
        XCTAssertEqual(LAAPersonalReconciliation.disposition(try operation(status: "preflight_retryable"), mayCompare: false), .unsent)
        XCTAssertEqual(LAAPersonalReconciliation.disposition(try operation(status: "resolved", resolution: "applied"), mayCompare: false), .complete)
        XCTAssertEqual(LAAPersonalReconciliation.disposition(try operation(status: "resolved", resolution: "not_applied"), mayCompare: false), .restore)
        XCTAssertEqual(LAAPersonalReconciliation.disposition(try operation(status: "resolved"), mayCompare: false), .invalid)
        XCTAssertEqual(LAAPersonalReconciliation.disposition(try operation(status: "rejected", rejection: "linear_rejected"), mayCompare: true), .restore)
        XCTAssertEqual(LAAPersonalReconciliation.disposition(try operation(status: "rejected", rejection: "version_mismatch"), mayCompare: true), .compare)
        for code in ["insufficient_scope", "task_not_found", "notification_not_found", "linear_rejected", "payload_invalid"] {
            XCTAssertTrue(LAAPersonalReconciliation.isDefiniteRefusal(code: code))
        }
        XCTAssertTrue(!LAAPersonalReconciliation.isDefiniteRefusal(code: "idempotency_outcome_unknown"))
        XCTAssertTrue(!LAAPersonalReconciliation.isDefiniteRefusal(code: "task_operation_compacted", status: 410))
        XCTAssertTrue(LAAPersonalReconciliation.isDefiniteRefusal(code: "linear_request_failed", status: 403))
        XCTAssertTrue(!LAAPersonalReconciliation.isDefiniteRefusal(code: "linear_request_failed", status: 503))
    }
    private func verifiedTask(viewer: String = "viewer-a", issue: String = "7ae6f09d-3879-47ea-8e0d-72cd834ac5bc") throws -> LAAPersonalTaskResponse {
        let data: [String: Any] = ["viewerId": viewer, "task": ["id": "linear:T-1", "sourceId": "T-1",
                                                                   "linearId": issue, "title": "Parent"]]
        return try JSONDecoder().decode(LAAPersonalTaskResponse.self, from: JSONSerialization.data(withJSONObject: data))
    }

    func testPendingTaskLinkUsesOnlyAReadBackMatchingTheViewerAndReservedIssue() throws {
        let create = try operation(status: "outcome_unknown", result: nil)
        XCTAssertEqual(LAAPersonalReconciliation.taskLookup(create), "7ae6f09d-3879-47ea-8e0d-72cd834ac5bc")
        XCTAssertEqual(LAAPersonalReconciliation.verifiedTaskID(try verifiedTask(), operation: create, viewer: "viewer-a"), "linear:T-1")
        XCTAssertNil(LAAPersonalReconciliation.verifiedTaskID(try verifiedTask(viewer: "other"), operation: create, viewer: "viewer-a"))
        XCTAssertNil(LAAPersonalReconciliation.verifiedTaskID(try verifiedTask(issue: "b71cc6b7-0656-4ce7-aa19-0bfa867ec2b9"), operation: create, viewer: "viewer-a"))
        let differentResult = try operation(status: "succeeded", result: "b71cc6b7-0656-4ce7-aa19-0bfa867ec2b9")
        XCTAssertNil(LAAPersonalReconciliation.verifiedTaskID(try verifiedTask(), operation: differentResult, viewer: "viewer-a"))
        XCTAssertNil(LAAPersonalReconciliation.taskLookup(try operation(status: "outcome_unknown", kind: "comment")))
    }

    func testFollowUpWaitsForConfirmedParentAndReadback() throws {
        let saved = LAAPersonalDependency(viewerId: "viewer-a", deviceId: "device-a", parentKey: "parent-key",
                                          childKey: "child-key", teamId: "team", kind: .comment, first: "返信ではないコメント")
        let restored = try JSONDecoder().decode(LAAPersonalDependency.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(saved, restored)
        let verified = try verifiedTask()
        for status in ["in_progress", "outcome_unknown", "rejected"] {
            XCTAssertNil(restored.request(parent: try operation(status: status), verified: verified, device: "device-a", viewer: "viewer-a"))
        }
        XCTAssertNil(restored.request(parent: try operation(status: "resolved", resolution: "not_applied"),
                                      verified: verified, device: "device-a", viewer: "viewer-a"))
        XCTAssertNil(restored.request(parent: try operation(status: "succeeded", result: "b71cc6b7-0656-4ce7-aa19-0bfa867ec2b9"),
                                      verified: verified, device: "device-a", viewer: "viewer-a"))
        let parent = try operation(status: "succeeded")
        XCTAssertNil(restored.request(parent: parent, verified: verified, device: "other-device", viewer: "viewer-a"))
        XCTAssertNil(restored.request(parent: parent, verified: verified, device: "device-a", viewer: "other-viewer"))
        XCTAssertNil(restored.request(parent: parent, verified: try verifiedTask(viewer: "other-viewer"), device: "device-a", viewer: "viewer-a"))
        XCTAssertNil(restored.request(parent: parent, verified: try verifiedTask(issue: "b71cc6b7-0656-4ce7-aa19-0bfa867ec2b9"), device: "device-a", viewer: "viewer-a"))
        let request = try XCTUnwrap(restored.request(parent: parent, verified: verified, device: "device-a", viewer: "viewer-a"))
        XCTAssertEqual(request.path, "/v1/personal-tasks/7ae6f09d-3879-47ea-8e0d-72cd834ac5bc/comments")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: String])
        XCTAssertEqual(payload["expectedViewerId"], "viewer-a")
        XCTAssertEqual(payload["body"], "返信ではないコメント")
        let reconciled = try operation(status: "resolved", result: nil, resolution: "applied")
        XCTAssertEqual(restored.request(parent: reconciled, verified: verified, device: "device-a", viewer: "viewer-a")?.body, request.body)
    }

    func testFollowUpKindsAndInvalidInputs() throws {
        var value = LAAPersonalDependency(viewerId: "viewer-a", deviceId: "device-a", parentKey: "parent-key",
                                          childKey: "child-key", teamId: "team", kind: .subtask, first: "Child")
        let parent = try operation(status: "succeeded"), verified = try verifiedTask()
        let request = try XCTUnwrap(value.request(parent: parent, verified: verified, device: "device-a", viewer: "viewer-a"))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: String])
        XCTAssertEqual(request.path, "/v1/personal-tasks")
        XCTAssertEqual(payload["parentId"], parent.targetId)
        XCTAssertEqual(payload["teamId"], "team")
        value.kind = .relation; value.first = "T-2"; value.relationType = "blocks"
        XCTAssertTrue(value.request(parent: parent, verified: verified, device: "device-a", viewer: "viewer-a")?.path.hasSuffix("/relations") == true)
        value.relationType = "unsupported"; XCTAssertTrue(!value.valid)
        value.kind = .link; value.first = "Docs"; value.second = "https://example.com/doc"
        XCTAssertTrue(value.request(parent: parent, verified: verified, device: "device-a", viewer: "viewer-a")?.path.hasSuffix("/attachments") == true)
        value.second = "https://user:password@example.com/doc"; XCTAssertTrue(!value.valid)
        value.kind = .comment; value.first = String(repeating: "x", count: 48 * 1024 + 1)
        XCTAssertTrue(!value.valid)
    }

    func testInboxPagesKeepUnreadExplicitAndRejectViewerOrCursorChanges() throws {
        func row(_ id: String, readAt: Any = NSNull()) -> [String: Any] {
            ["id": id, "type": "issue", "title": "Fixture", "createdAt": "created", "updatedAt": "updated",
             "readAt": readAt, "archivedAt": NSNull(), "issue": ["id": "issue", "identifier": "T-1", "title": "Task"]]
        }
        func page(_ rows: [[String: Any]], viewer: String = "viewer-a", cursor: String? = nil) throws -> LAAPersonalPage<LAAPersonalNotification> {
            let data: [String: Any] = ["items": rows, "viewerId": viewer, "nextCursor": cursor as Any? ?? NSNull(), "observedAt": "now"]
            return try JSONDecoder().decode(LAAPersonalPage<LAAPersonalNotification>.self, from: JSONSerialization.data(withJSONObject: data))
        }
        var missing = row("missing"); missing.removeValue(forKey: "readAt")
        XCTAssertThrowsError(try page([missing]))
        var snapshot = LAAPersonalInboxSnapshot(viewerId: "viewer-a")
        try snapshot.merge(page([row("a", readAt: "read")], cursor: "page-2"), reset: true)
        XCTAssertEqual(snapshot.summary, "一部取得・未読未確認")
        XCTAssertThrowsError(try snapshot.merge(page([row("b")], viewer: "viewer-b"), reset: false))
        XCTAssertEqual(snapshot.items.map(\.id), ["a"])
        XCTAssertThrowsError(try snapshot.merge(page([row("b")], cursor: "page-2"), reset: false))
        try snapshot.merge(page([row("a", readAt: "read"), row("b")]), reset: false)
        XCTAssertEqual(snapshot.items.map(\.id), ["a", "b"])
        XCTAssertEqual(snapshot.summary, "未読あり")
        XCTAssertEqual(snapshot.items.last?.issue?.identifier, "T-1")
        var complete = LAAPersonalInboxSnapshot(viewerId: "viewer-a")
        try complete.merge(page([row("a", readAt: "read")]), reset: true)
        XCTAssertEqual(complete.summary, "取得分に未読なし")
    }
}
#endif
