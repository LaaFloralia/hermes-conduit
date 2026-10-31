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
        draft.teamId = "team"; draft.title = "起票"; draft.estimate = "3"
        let body = try payload(draft)
        XCTAssertEqual(body["teamId"] as? String, "team")
        XCTAssertEqual(body["expectedViewerId"] as? String, "viewer")
        XCTAssertEqual(body["estimate"] as? Int, 3)
        draft.estimate = "1.5"
        XCTAssertThrowsError(try draft.requestBody())
        draft.estimate = "NaN"
        XCTAssertThrowsError(try draft.requestBody())
    }
}
#endif
