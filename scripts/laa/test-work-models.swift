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
        print("Work model tests: 3 passed")
    }
}
#endif
