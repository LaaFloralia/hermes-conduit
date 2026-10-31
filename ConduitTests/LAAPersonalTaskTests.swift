#if LAA_BUILD
import Foundation
#if !LAATASK_STANDALONE
import XCTest
@testable import Conduit
#endif

final class LAAPersonalTaskTests: XCTestCase {
    private func task(title: String = "Original", description: String = "古い本文", version: String? = "v1",
                      owner: String = "person", labelsComplete: Bool = true, dueDate: String = "2026-11-01") throws -> LAAPersonalTask {
        let value: [String: Any] = ["id": "linear:T-1", "sourceId": "T-1", "linearId": "issue-id", "title": title,
            "description": description, "updatedAt": version as Any? ?? NSNull(), "team": ["id": "team"],
            "owner": ["id": owner, "name": "Owner", "kind": "person"],
            "status": ["id": "todo", "name": "Todo", "type": "unstarted"],
            "priority": 2.0, "estimate": 0.5, "dueDate": dueDate,
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
        XCTAssertTrue(lines.contains("− 古い")); XCTAssertTrue(lines.contains("+ 新しい"))
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

    private func operation(status: String, kind: String = "create", result: String? = "7ae6f09d-3879-47ea-8e0d-72cd834ac5bc",
                           resolution: String? = nil) throws -> LAAPersonalOperationResponse.Operation {
        let data: [String: Any] = ["operationId": "operation", "kind": kind,
            "targetId": "7ae6f09d-3879-47ea-8e0d-72cd834ac5bc", "status": status,
            "resultId": result as Any? ?? NSNull(), "resolution": resolution as Any? ?? NSNull()]
        return try JSONDecoder().decode(LAAPersonalOperationResponse.Operation.self, from: JSONSerialization.data(withJSONObject: data))
    }
    private func verifiedTask(viewer: String = "viewer-a", issue: String = "7ae6f09d-3879-47ea-8e0d-72cd834ac5bc") throws -> LAAPersonalTaskResponse {
        let data: [String: Any] = ["viewerId": viewer, "task": ["id": "linear:T-1", "sourceId": "T-1",
                                                                   "linearId": issue, "title": "Parent"]]
        return try JSONDecoder().decode(LAAPersonalTaskResponse.self, from: JSONSerialization.data(withJSONObject: data))
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
}
#endif
