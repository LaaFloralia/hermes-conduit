#if LAA_BUILD
import XCTest
@testable import Conduit

final class LAALinearTaskTests: XCTestCase {
    private func task(priority: Int = 0, dueDate: String? = nil, status: String = "todo") -> LAALinearTask {
        LAALinearTask(id: UUID().uuidString, identifier: "BUS-1", title: "確認", description: nil,
                      dueDate: dueDate, priority: priority, status: status, stateName: "Todo", updatedAt: "now", url: nil)
    }
    func testPriorityIncludesUrgentHighAndTodayOrOverdueOnly() {
        let today = "2026-11-02"
        XCTAssertTrue(task(priority: 1).needsAttention(today: today))
        XCTAssertTrue(task(priority: 2).needsAttention(today: today))
        XCTAssertTrue(task(dueDate: today).needsAttention(today: today))
        XCTAssertTrue(task(dueDate: "2026-11-01").needsAttention(today: today))
        XCTAssertFalse(task(priority: 3, dueDate: "2026-11-03").needsAttention(today: today))
        XCTAssertFalse(task().needsAttention(today: today))
    }
    func testClosedTasksNeverAppearInPriority() {
        XCTAssertFalse(task(priority: 1, dueDate: "2020-01-01", status: "done").needsAttention(today: "2026-11-02"))
        XCTAssertFalse(task(priority: 2, status: "canceled").needsAttention(today: "2026-11-02"))
    }
    func testTodayUsesCalendarDayAtOwnerTimezoneBoundary() throws {
        let at = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T16:00:00Z"))
        XCTAssertEqual(LAALinearTask.today(at, timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))), "2026-11-02")
        XCTAssertEqual(LAALinearTask.today(at, timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0))), "2026-11-01")
    }
    func testMutationArchivePreservesExactBodyAndVersion() throws {
        let id = UUID().uuidString.lowercased()
        let body = Data(#"{"title":"入力","dueDate":null}"#.utf8)
        let request = LAALinearTaskMutation(method: "PATCH", id: id, body: body, version: "2026-11-02T00:00:00Z")
        let restored = try JSONDecoder().decode(LAALinearTaskMutation.self, from: JSONEncoder().encode(request))
        XCTAssertTrue(restored.isValid)
        XCTAssertEqual(restored.body, body)
        XCTAssertEqual(restored.version, request.version)
        XCTAssertEqual(restored.path, "/v1/linear-owner-tasks/\(id)")
        XCTAssertFalse(LAALinearTaskMutation(method: "POST", id: "../../other", body: body, version: nil).isValid)
        XCTAssertFalse(LAALinearTaskMutation(method: "GET", id: id, body: body, version: nil).isValid)
    }
    func testArchiveAndRestoreHaveSeparateReplayTargetsAndReflectOnlyTheirOwnState() throws {
        var current = task()
        let archive = LAALinearTaskMutation(method: "POST", id: current.id, body: nil, version: "now", action: "archive")
        let restore = LAALinearTaskMutation(method: "POST", id: current.id, body: nil, version: "now", action: "restore")
        XCTAssertTrue(archive.isValid)
        XCTAssertEqual(archive.path, "/v1/linear-owner-tasks/\(current.id)/archive")
        XCTAssertEqual(restore.path, "/v1/linear-owner-tasks/\(current.id)/restore")
        XCTAssertFalse(archive.isReflected(in: current))
        current.archivedAt = "now"
        XCTAssertTrue(archive.isReflected(in: current))
        XCTAssertFalse(restore.isReflected(in: current))
        XCTAssertFalse(current.needsAttention(today: "2026-11-02"))
        XCTAssertFalse(LAALinearTaskMutation(method: "DELETE", id: current.id, body: nil, version: "now").isValid)
    }
    @MainActor func testRestartDiscardsRetiredLinearIntentsAndKeepsCurrentOperations() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("work-drafts.json")
        let first = ComposerDraftStore(capacity: .max, fileURL: url)
        let id = UUID().uuidString
        let mutations = [
            LAALinearTaskMutation(method: "DELETE", id: id, body: nil, version: "before"),
            LAALinearTaskMutation(method: "PATCH", id: id, body: Data(#"{"completed":true}"#.utf8), version: "before"),
            LAALinearTaskMutation(method: "PATCH", id: id, body: Data(#"{"title":"保持"}"#.utf8), version: "before"),
            LAALinearTaskMutation(method: "POST", id: id, body: nil, version: "before", action: "archive")
        ]
        let payloads = try mutations.map { try JSONEncoder().encode($0) }
        for index in mutations.indices {
            let key = LAAWorkDrafts.key(deviceID: "device-\(index)", target: "linear-owner-operation")
            let item = try XCTUnwrap(LAAWorkDrafts.reserve(first, key: key, text: "Linearの変更",
                body: payloads[index], idempotency: LAABridgeIdempotencyKey()))
            first.markSubmissionUnknown(item.id)
        }
        let restored = LAAWorkDrafts.makeStore(fileURL: url)
        for index in 0..<2 {
            XCTAssertNil(LAAWorkDrafts.pending(restored, key: LAAWorkDrafts.key(deviceID: "device-\(index)", target: "linear-owner-operation")))
        }
        XCTAssertEqual(restored.unknownSubmissions.count, 2)
        for index in 2..<4 {
            let key = LAAWorkDrafts.key(deviceID: "device-\(index)", target: "linear-owner-operation")
            let remaining = try XCTUnwrap(LAAWorkDrafts.pending(restored, key: key))
            XCTAssertEqual(LAAWorkDrafts.request(remaining)?.0, payloads[index])
        }
        // Cleanup is durable, so a second launch cannot bring back a warning.
        XCTAssertEqual(ComposerDraftStore(capacity: .max, fileURL: url).submissions.count, 2)
    }
    func testSuccessfulTaskReadbackClearsOnlyMatchingEdit() throws {
        let current = task(priority: 2)
        let body = Data(#"{"title":"確認","description":"","priority":2,"dueDate":null}"#.utf8)
        let edit = LAALinearTaskMutation(method: "PATCH", id: current.id, body: body, version: "before")
        XCTAssertTrue(edit.isReflected(in: current))
        var changed = current; changed.title = "別の内容"
        XCTAssertFalse(edit.isReflected(in: changed))
        let unsupported = LAALinearTaskMutation(method: "PATCH", id: current.id, body: Data(#"{"unknown":true}"#.utf8), version: "before")
        XCTAssertFalse(unsupported.isValid)
        XCTAssertFalse(unsupported.isReflected(in: current))
    }
    func testRoutineExtraObservationsDecodeWithoutLosingHistory() throws {
        let data = Data(#"{"id":"mail","name":"メール","schedule":"毎日","state":"scheduled","triggerKind":"scheduled","destination":"Cielの定期実行チャット","businessStatus":"success","notificationStatus":"sent","result":"timeout","lastRunAt":"2026-11-02T00:00:00Z"}"#.utf8)
        let row = try JSONDecoder().decode(LAAWorkRoutine.self, from: data)
        XCTAssertEqual(row.state, "scheduled")
        XCTAssertEqual(row.triggerKind, "scheduled")
        XCTAssertEqual(row.result, "timeout")
        XCTAssertEqual(row.businessStatus, "success")
        XCTAssertEqual(row.destination, "Cielの定期実行チャット")
    }
    func testPreviousRoutineRunCombinesTimeAndOutcomeWithoutDeliveryNoise() throws {
        let data = Data(#"{"id":"daily","name":"朝","lastRunAt":"2026-11-01T22:30:00.000Z","businessStatus":"completed","notificationStatus":"sent"}"#.utf8)
        var row = try JSONDecoder().decode(LAAWorkRoutine.self, from: data)
        let japan = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        XCTAssertEqual(row.previousRunSummary(timeZone: japan), "11月2日 7:30・完了")
        row.notificationStatus = "failed"
        XCTAssertEqual(row.previousRunSummary(timeZone: japan), "11月2日 7:30・完了・配信失敗")
        row.businessStatus = "error"
        XCTAssertEqual(row.previousRunSummary(timeZone: japan), "11月2日 7:30・業務エラー・配信失敗")
        row.notificationStatus = "pending"; row.businessStatus = "success"
        XCTAssertEqual(row.previousRunSummary(timeZone: japan), "11月2日 7:30・完了")
        let missing = try JSONDecoder().decode(LAAWorkRoutine.self, from: Data(#"{"id":"missing","name":"未確認"}"#.utf8))
        XCTAssertEqual(missing.previousRunSummary(timeZone: japan), "未確認")
    }
}
#endif
