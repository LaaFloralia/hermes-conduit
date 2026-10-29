#if LAA_BUILD
import XCTest
@testable import Conduit

@MainActor
final class LAAWorkTests: XCTestCase {
    private func session(_ id: String, name: String, parent: String? = nil,
                         updated: String, requested: [String: String] = [:],
                         observed: [String: String]? = nil) throws -> LAAWorkSession {
        let json: [String: Any] = [
            "id": id, "name": name, "nameSource": "owner", "requestId": id,
            "parentId": parent as Any? ?? NSNull(), "workspaceId": "ws_test",
            "profile": "test", "requested": requested, "observed": observed as Any? ?? NSNull(),
            "phase": "running", "createdAt": updated, "updatedAt": updated,
            "events": ["lastSeq": 1, "oldestSeq": 1, "cursor": "cursor"]
        ]
        return try JSONDecoder().decode(LAAWorkSession.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testSessionsShowChildrenBeneathParentsAndRetainManualNames() throws {
        let parent = try session("p", name: "社長の名前", updated: "2026-10-01T00:00:00Z")
        let child = try session("c", name: "子｜調査", parent: "p", updated: "2026-10-03T00:00:00Z")
        let newest = try session("n", name: "別の仕事", updated: "2026-10-04T00:00:00Z")
        let rows = LAAWorkPresentation.sessionRows([parent, child, newest])
        XCTAssertEqual(rows.map(\.session.id), ["n", "p", "c"])
        XCTAssertEqual(rows.map(\.depth), [0, 0, 1])
        XCTAssertEqual(rows.last?.session.name, "子｜調査")
    }

    func testMissingObservationIsNotTreatedAsMatchOrMismatch() throws {
        let requested = ["provider": "dsh", "model": "expected", "effort": "high"]
        let missing = try session("a", name: "a", updated: "1", requested: requested)
        let mismatched = try session("b", name: "b", updated: "2", requested: requested,
                                     observed: ["provider": "dsh", "model": "different"])
        XCTAssertFalse(missing.modelMismatch)
        XCTAssertFalse(missing.runtimeVerified ?? false)
        XCTAssertTrue(mismatched.modelMismatch)
    }

    func testFilteredChildKeepsItsParentForContext() throws {
        let parent = try session("p", name: "親", updated: "2026-10-01T00:00:00Z")
        let childData = Data(#"{"id":"c","name":"子｜調査","requestId":"c","parentId":"p","workspaceId":"ws","profile":"test","phase":"stopped","createdAt":"2026-10-02T00:00:00Z","updatedAt":"2026-10-02T00:00:00Z","events":{"lastSeq":1,"oldestSeq":1,"cursor":"c"}}"#.utf8)
        let child = try JSONDecoder().decode(LAAWorkSession.self, from: childData)
        let rows = LAAWorkPresentation.filteredSessionRows([parent, child], projectID: "", phase: "stopped")
        XCTAssertEqual(rows.map(\.session.id), ["p", "c"])
        XCTAssertEqual(rows.map(\.depth), [0, 1])
        XCTAssertTrue(LAAWorkPresentation.filteredSessionRows([parent, child], projectID: "", phase: "error").isEmpty)
    }

    func testDecisionShortcutRequiresReportedPendingWorkOrDecisionPhase() throws {
        func decode(_ phase: String, pending: Int?) throws -> LAAWorkSession {
            var json: [String: Any] = ["id": "s", "name": "Session", "requestId": "s", "workspaceId": "ws",
                                       "profile": "test", "phase": phase, "createdAt": "1", "updatedAt": "1",
                                       "events": ["lastSeq": 1, "oldestSeq": 1, "cursor": "c"]]
            if let pending { json["pending"] = ["count": pending] }
            return try JSONDecoder().decode(LAAWorkSession.self, from: JSONSerialization.data(withJSONObject: json))
        }
        XCTAssertTrue(try decode("awaiting_decision", pending: nil).needsDecision)
        XCTAssertTrue(try decode("running", pending: 1).needsDecision)
        XCTAssertFalse(try decode("running", pending: 0).needsDecision)
        XCTAssertFalse(try decode("awaiting_review", pending: nil).needsDecision)
    }

    func testDecisionShortcutExcludesContextParentsOutsideTheSelectedProject() throws {
        let parentData = Data(#"{"id":"p","name":"親","requestId":"p","workspaceId":"ws","profile":"test","phase":"awaiting_decision","createdAt":"1","updatedAt":"1","events":{"lastSeq":1,"oldestSeq":1,"cursor":"c"}}"#.utf8)
        let childData = Data(#"{"id":"c","name":"子｜調査","requestId":"c","parentId":"p","projectId":"target","workspaceId":"ws","profile":"test","phase":"awaiting_decision","createdAt":"2","updatedAt":"2","events":{"lastSeq":1,"oldestSeq":1,"cursor":"c"}}"#.utf8)
        let decoder = JSONDecoder()
        let sessions = try [decoder.decode(LAAWorkSession.self, from: parentData), decoder.decode(LAAWorkSession.self, from: childData)]
        let rows = LAAWorkPresentation.filteredSessionRows(sessions, projectID: "target", phase: "awaiting_decision")
        XCTAssertEqual(rows.map(\.session.id), ["p", "c"])
        XCTAssertEqual(LAAWorkPresentation.decisionRows(rows, projectID: "target", phase: "awaiting_decision").map(\.session.id), ["c"])
    }

    func testInstructionEditingRequiresBodyFromServer() throws {
        let old = try JSONDecoder().decode(LAAWorkProject.self, from: Data(#"{"id":"p","name":"旧","etag":"\"1\""}"#.utf8))
        let new = try JSONDecoder().decode(LAAWorkProject.self, from: Data(#"{"id":"p","name":"新","etag":"\"2\"","instructions":"共有"}"#.utf8))
        XCTAssertFalse(old.hasInstructionBody)
        XCTAssertTrue(new.hasInstructionBody)
        XCTAssertEqual(new.instructions, "共有")
    }

    func testWorkspaceBranchNameChangesAreReported() {
        XCTAssertNil(LAAWorkWorkspaceCreator.branchNotice(requested: "feature", actual: "feature"))
        let notice = LAAWorkWorkspaceCreator.branchNotice(requested: "laa/example", actual: "laa-example")
        XCTAssertTrue(notice?.contains("laa/example") == true)
        XCTAssertTrue(notice?.contains("laa-example") == true)
        XCTAssertNotNil(LAAWorkWorkspaceCreator.branchNotice(requested: "feature", actual: nil))
    }

    func testLinearTaskDetailDecodesTaskInsideResponse() throws {
        // Bridge data contains a task plus optional comments and links.
        let data = Data(#"{"task":{"id":"linear:BUS-123","source":"linear","sourceId":"BUS-123","title":"依頼","description":"詳細","status":{"name":"Todo","type":"unstarted","category":"open"}},"comments":[],"links":[]}"#.utf8)
        let task = try JSONDecoder().decode(LAAWorkTaskDetailResponse.self, from: data).task
        XCTAssertEqual(task.id, "linear:BUS-123")
        XCTAssertEqual(task.description, "詳細")
        XCTAssertEqual(task.status?.name, "Todo")
    }

    func testLegacyProjectReferenceCanOnlyBeClearedExplicitly() throws {
        let encoder = JSONEncoder()
        let rename = LAAWorkProjectChanges(name: "名前", instructions: nil)
        let untouched = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(rename)) as? [String: Any])
        XCTAssertNil(untouched["instructionRef"])
        XCTAssertNil(untouched["instructions"])

        let remove = LAAWorkProjectChanges(name: "名前", instructions: "本文", clearInstructionRef: true)
        let cleared = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(remove)) as? [String: Any])
        XCTAssertTrue(cleared["instructionRef"] is NSNull)
        XCTAssertEqual(cleared["instructions"] as? String, "本文")
        let restored = try JSONDecoder().decode(LAAWorkProjectChanges.self, from: encoder.encode(remove))
        XCTAssertTrue(restored.clearInstructionRef)
    }

    func testInterruptedIntentRestoresExactRequestAndKeyWithoutResending() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("work-drafts.json")
        let key = LAAWorkDrafts.key(deviceID: "device-a", target: "new-session")
        let other = LAAWorkDrafts.key(deviceID: "device-b", target: "new-session")
        let payload = Data(#"{"prompt":"日本語","requestId":"request-1","workspaceId":"ws-1"}"#.utf8)
        let idempotency = try XCTUnwrap(LAABridgeIdempotencyKey(restoring: "intent-1"))
        let first = ComposerDraftStore(capacity: .max, fileURL: url)
        XCTAssertTrue(first.save(.init(text: "日本語", attachments: []), for: key))
        _ = try XCTUnwrap(LAAWorkDrafts.reserve(first, key: key, text: "日本語", body: payload, idempotency: idempotency))
        XCTAssertNil(LAAWorkDrafts.reserve(first, key: key, text: "重複", body: payload, idempotency: idempotency))

        let restored = ComposerDraftStore(capacity: .max, fileURL: url)
        let item = try XCTUnwrap(LAAWorkDrafts.pending(restored, key: key))
        let request = try XCTUnwrap(LAAWorkDrafts.request(item))
        XCTAssertEqual(restored.unknownSubmissions.count, 1)
        XCTAssertEqual(request.0, payload)
        XCTAssertEqual(request.1.value, "intent-1")
        XCTAssertNil(LAAWorkDrafts.pending(restored, key: other))
        XCTAssertEqual(item.draft.text, "日本語")
    }

    func testOldUnknownIntentCanBeReadButCannotBeRepeatedAfterRetentionWindow() throws {
        let store = ComposerDraftStore(capacity: .max)
        let key = LAAWorkDrafts.key(deviceID: "device-a", target: "message:session")
        let reserved = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = Data(#"{"message":"continued"}"#.utf8)
        let idempotency = try XCTUnwrap(LAABridgeIdempotencyKey(restoring: "intent-2"))
        let item = try XCTUnwrap(LAAWorkDrafts.reserve(store, key: key, text: "continued", body: payload,
                                                       idempotency: idempotency, now: reserved))
        XCTAssertTrue(LAAWorkDrafts.canRepeat(item, now: reserved.addingTimeInterval(5 * 24 * 60 * 60)))
        XCTAssertFalse(LAAWorkDrafts.canRepeat(item, now: reserved.addingTimeInterval(6 * 24 * 60 * 60)))
        XCTAssertFalse(LAAWorkDrafts.canRepeat(item, now: reserved.addingTimeInterval(-1)))
        XCTAssertEqual(LAAWorkDrafts.request(item)?.0, payload)

        var oldItem = item
        oldItem.groupOutboundText = String(decoding: payload, as: UTF8.self)
        XCTAssertFalse(LAAWorkDrafts.canRepeat(oldItem, now: reserved))
        XCTAssertEqual(LAAWorkDrafts.request(oldItem)?.0, payload)
    }

    func testServerRefusalsAndUnknownOutcomesAreDistinguished() {
        func error(_ status: Int, _ code: String) -> LAABridgeHTTPError {
            LAABridgeHTTPError(status: status, code: code, message: nil, retryable: nil,
                               details: nil, requestId: nil, currentETag: nil)
        }
        XCTAssertFalse(LAAWorkHTTP.outcomeUnknown(error(409, "pending_decision_requires_reply")))
        XCTAssertFalse(LAAWorkHTTP.outcomeUnknown(error(409, "session_busy")))
        XCTAssertTrue(LAAWorkHTTP.outcomeUnknown(error(409, "idempotency_outcome_unknown")))
        XCTAssertTrue(LAAWorkHTTP.outcomeUnknown(error(409, "send_outcome_unknown")))
        XCTAssertTrue(LAAWorkHTTP.outcomeUnknown(error(409, "message_id_conflict")))
        XCTAssertFalse(LAAWorkHTTP.outcomeUnknown(error(409, "message_limit_reached")))
        XCTAssertTrue(LAAWorkHTTP.outcomeUnknown(error(503, "delegation_timeout")))
        XCTAssertTrue(LAAWorkHTTP.isVersionConflict(error(412, "version_mismatch")))
    }

    func testProjectConflictRecordSurvivesUntilTheOwnerChooses() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rejected = UUID()
        let unknown = UUID()
        XCTAssertFalse(LAAWorkConflictJournal.contains(rejected, in: folder))
        XCTAssertTrue(LAAWorkConflictJournal.mark(rejected, in: folder))
        XCTAssertTrue(LAAWorkConflictJournal.contains(rejected, in: folder))
        XCTAssertFalse(LAAWorkConflictJournal.contains(unknown, in: folder))
        LAAWorkConflictJournal.clear(rejected, in: folder)
        XCTAssertFalse(LAAWorkConflictJournal.contains(rejected, in: folder))
    }
}
#endif
