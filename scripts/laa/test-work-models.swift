#if LAA_BUILD
import Foundation

@main struct WorkModelTests {
    static func main() throws {
        let messages = #"{"items":[{"id":"0","role":"user","text":"依頼","timestamp":null},{"id":"1","role":"assistant","text":"回答","timestamp":null}]}"#
        let page = try JSONDecoder().decode(LAAWorkPage<LAAWorkConversationMessage>.self, from: Data(messages.utf8))
        precondition(page.items.map(\.role) == ["user", "assistant"] && page.items.map(\.text) == ["依頼", "回答"], "conversation order")
        let job = #"{"id":"job","name":"定期処理","schedule":null,"nextRunAt":null,"lastRunAt":null,"result":null}"#
        let routine = try JSONDecoder().decode(LAAWorkRoutine.self, from: Data(job.utf8))
        precondition(routine.name == "定期処理" && routine.nextRunAt == nil && routine.result == nil, "routine missing values")
        precondition(LAAWorkPresentation.phase("unknown") != LAAWorkPresentation.phase("running"), "unknown phase")
        let fixture = #"{"id":"job","name":"fixture","runId":"execution-12345678","scheduledAt":"2026-11-08T00:00:00Z","startedAt":"2026-11-08T00:00:01Z","finishedAt":"2026-11-08T00:01:00Z","businessStatus":"completed","notificationStatus":"accepted"}"#
        var observed = try JSONDecoder().decode(LAAWorkRoutine.self, from: Data(fixture.utf8))
        precondition(observed.runId == "execution-12345678" && observed.startedAt != nil, "same execution")
        precondition(observed.previousRunSummary().contains("完了") && observed.previousRunSummary().contains("端末受信未確認"), "success is not device receipt")
        observed.businessStatus = "failed"
        precondition(observed.previousRunSummary().contains("業務エラー"), "business failure")
        observed.reasonCode = "schedule_overdue"
        precondition(observed.previousRunSummary().contains("予定超過・結果なし"), "missing slot")
        observed.reasonCode = "read_unavailable"
        precondition(observed.previousRunSummary().contains("取得不能"), "unavailable is distinct")
        observed.reasonCode = "observed"; observed.businessStatus = "completed"; observed.notificationStatus = "not_received"
        precondition(observed.previousRunSummary().contains("通知未到達"), "explicit delivery failure")
        observed.notificationStatus = "read_back"
        precondition(observed.notificationSummary == "端末受信確認済み", "device acknowledgement")
        print("Work model tests: 10 passed")
    }
}
#endif
