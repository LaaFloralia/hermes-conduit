import XCTest
@testable import Conduit

final class LAAWorkToolRunTests: XCTestCase {
    private func message(_ id: String, _ role: String, tool: String? = nil, status: String? = nil) -> LAAWorkConversationMessage {
        LAAWorkConversationMessage(id: id, role: role, text: id, timestamp: nil, toolName: tool, toolStatus: status)
    }

    func testConsecutiveToolCallsBecomeOneGroup() {
        let groups = LAAWorkToolRuns.groups([
            message("u", "user"),
            message("t1", "tool", tool: "shell", status: "completed"),
            message("t2", "tool", tool: "read", status: "completed"),
            message("a", "assistant"),
            message("t3", "tool", tool: "write", status: "failed")
        ])
        XCTAssertEqual(groups.map(\.kind), [.message, .tools, .message, .tools])
        XCTAssertEqual(groups[1].messages.map(\.id), ["t1", "t2"])
        XCTAssertEqual(groups[3].messages.map(\.id), ["t3"])
    }

    func testFailureCountOnlyCountsKnownFailureStates() {
        let tools = [
            message("t1", "tool", status: "completed"),
            message("t2", "tool", status: "failed"),
            message("t3", "tool", status: "timeout"),
            message("t4", "tool", status: "running"),
            message("t5", "tool", status: nil)
        ]
        XCTAssertEqual(LAAWorkToolRuns.failureCount(tools), 2)
        XCTAssertTrue(LAAWorkToolRuns.isFailure("ERROR"))
        XCTAssertFalse(LAAWorkToolRuns.isFailure("completed"))
    }

    func testEveryNonToolMessageStaysItsOwnCard() {
        let groups = LAAWorkToolRuns.groups([
            message("u", "user"), message("a1", "assistant"), message("a2", "assistant")
        ])
        XCTAssertEqual(groups.count, 3)
        XCTAssertTrue(groups.allSatisfy { $0.kind == .message })
    }
}
