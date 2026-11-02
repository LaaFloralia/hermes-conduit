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
    func testRoutineExtraObservationsDecodeWithoutLosingHistory() throws {
        let data = Data(#"{"id":"mail","name":"メール","schedule":"毎日","state":"scheduled","destination":"Cielの定期実行チャット","businessStatus":"success","notificationStatus":"sent","result":"timeout","lastRunAt":"2026-11-02T00:00:00Z"}"#.utf8)
        let row = try JSONDecoder().decode(LAAWorkRoutine.self, from: data)
        XCTAssertEqual(row.state, "scheduled")
        XCTAssertEqual(row.result, "timeout")
        XCTAssertEqual(row.businessStatus, "success")
        XCTAssertEqual(row.destination, "Cielの定期実行チャット")
    }
}
#endif
