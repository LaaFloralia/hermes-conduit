#if LAA_BUILD
import XCTest
@testable import Conduit

/// The task list's execution record: the contract's Japanese status labels,
/// the three filters, the create body and the completion request. The
/// completion runs against a real loopback HTTP server, so the path, If-Match
/// and Idempotency-Key are the ones the Bridge receives.
@MainActor
final class LAATaskRunTests: XCTestCase {
    private let completedID = UUID(uuidString: "0B5B9A76-3A0E-4D6F-9C11-4C0D0D2B6A01")!

    private func task(id: String? = nil, state: String? = nil, session: String? = nil,
                      ref: String? = nil, status: String = "todo") -> LAALinearTask {
        let run = state.map { state in
            LAATaskRun(creator: "owner",
                       assignee: .init(kind: "staff", staff: "monet", name: "Monet"),
                       profile: "opus-high", profileLabel: "Opus 5.5 · High",
                       state: state, sessionId: session, sessionRef: ref,
                       decisionRef: nil, report: nil, error: nil)
        }
        return LAALinearTask(id: id ?? completedID.uuidString.lowercased(), identifier: "BUS-1", title: "確認",
                             description: nil, dueDate: nil, priority: 0, status: status, stateName: "Todo",
                             updatedAt: "2026-11-09T00:00:00Z", url: nil, run: run)
    }

    func testStatusLabelsFollowTheContract() throws {
        XCTAssertNil(task().runStatus, "The owner's own task carries no badge")
        XCTAssertEqual(task().assigneeDisplay, "社長")
        let cases: [(String, String, LAATaskRunStatus.Tone)] = [
            ("queued", "取得待ち（S5）", .quiet),
            ("running", "実施中（S5）", .quiet),
            ("awaiting_decision", "判断待（S5）", .attention),
            ("done", "完了（S5）", .link),
            ("stopped", "停止（S5）", .attention),
            ("failed", "取得できません（S5）", .attention),
        ]
        for (state, label, tone) in cases {
            let row = task(state: state, session: "ses_0123456789abcdef", ref: "S5")
            let status = try XCTUnwrap(row.runStatus)
            XCTAssertEqual(status.label, label, state)
            XCTAssertEqual(status.tone, tone, state)
            XCTAssertEqual(status.sessionID, "ses_0123456789abcdef")
            XCTAssertEqual(row.assigneeDisplay, "Monet")
            XCTAssertEqual(row.isAgentActive, ["queued", "running", "awaiting_decision"].contains(state), state)
            XCTAssertEqual(row.completionBlockedReason != nil, state == "running", state)
        }
        // Without a session number the label is still readable.
        XCTAssertEqual(task(state: "running").runStatus?.label, "実施中")
        XCTAssertNil(task(state: "running").runStatus?.sessionID)
    }

    func testLegacyTaskWithoutRunReadsAsBefore() throws {
        let data = Data(#"""
        {"id":"b9d2f664-cda3-4c56-8d39-c4d6df597254","identifier":"BUS-1","title":"確認","description":null,
         "dueDate":null,"priority":0,"status":"todo","stateName":"Todo","updatedAt":"2026-11-09T00:00:00Z","url":null}
        """#.utf8)
        let decoded = try JSONDecoder().decode(LAALinearTask.self, from: data)
        XCTAssertNil(decoded.run)
        XCTAssertNil(decoded.runStatus)
        XCTAssertEqual(decoded.assigneeDisplay, "社長")
        XCTAssertFalse(decoded.isAgentActive)
        XCTAssertNil(decoded.completionBlockedReason)
        XCTAssertTrue(LAALinearTaskFilter.related.matches(decoded))
        XCTAssertFalse(LAALinearTaskFilter.created.matches(decoded))
        XCTAssertTrue(LAALinearTaskFilter.assigned.matches(decoded))
    }

    func testFiltersSeparateCreatedFromAssigned() {
        let created = task(state: "queued")
        let assignedByAgent = LAALinearTask(id: UUID().uuidString, identifier: "BUS-2", title: "登録", description: nil,
                                            dueDate: nil, priority: 0, status: "todo", stateName: "Todo",
                                            updatedAt: "now", url: nil)
        var ownerRun = assignedByAgent
        ownerRun.run = LAATaskRun(creator: "owner", assignee: .init(kind: "owner", staff: nil, name: nil),
                                 profile: nil, profileLabel: nil, state: nil, sessionId: nil, sessionRef: nil,
                                 decisionRef: nil, report: nil, error: nil)
        XCTAssertEqual(LAALinearTaskFilter.allCases.map(\.title), ["自分に関係", "自分が作成", "自分が担当"])
        XCTAssertTrue(LAALinearTaskFilter.related.matches(created))
        XCTAssertTrue(LAALinearTaskFilter.created.matches(created))
        XCTAssertFalse(LAALinearTaskFilter.assigned.matches(created))
        XCTAssertFalse(LAALinearTaskFilter.created.matches(assignedByAgent))
        XCTAssertTrue(LAALinearTaskFilter.assigned.matches(assignedByAgent))
        XCTAssertTrue(LAALinearTaskFilter.assigned.matches(ownerRun))
    }

    func testCreateBodyCarriesStaffAndProfile() throws {
        let id = UUID().uuidString.lowercased()
        let data = try XCTUnwrap(LAALinearTaskCreate.body(id: id, title: "見積り", description: "", priority: 2,
                                                          dueDate: "2026-11-20", staff: "cfo", profile: "opus-xhigh"))
        let fields = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(fields["id"] as? String, id)
        XCTAssertEqual(fields["title"] as? String, "見積り")
        XCTAssertEqual(fields["dueDate"] as? String, "2026-11-20")
        let assignee = try XCTUnwrap(fields["assignee"] as? [String: Any])
        XCTAssertEqual(assignee["kind"] as? String, "staff")
        XCTAssertEqual(assignee["staff"] as? String, "cfo")
        XCTAssertEqual(fields["profile"] as? String, "opus-xhigh")

        // The same body is what the protected mutation sends.
        let mutation = LAALinearTaskMutation(method: "POST", id: id, body: data, version: nil)
        XCTAssertTrue(mutation.isValid)
        XCTAssertEqual(mutation.path, "/v1/linear-owner-tasks")
        var created = task(id: id, state: "queued")
        created.title = "見積り"; created.description = ""; created.priority = 2; created.dueDate = "2026-11-20"
        created.run = LAATaskRun(creator: "owner", assignee: .init(kind: "staff", staff: "cfo", name: "Morgan"),
                                 profile: "opus-xhigh", profileLabel: "Opus 5.5 · XHigh", state: "queued",
                                 sessionId: nil, sessionRef: nil, decisionRef: nil, report: nil, error: nil)
        XCTAssertTrue(mutation.isReflected(in: created))
        XCTAssertFalse(mutation.isReflected(in: task(state: "queued")), "A different assignee is not reflected")

        // 社長: an explicit owner assignee, no profile.
        let owner = try XCTUnwrap(LAALinearTaskCreate.body(id: id, title: "確認", description: "", priority: 0,
                                                           dueDate: nil, staff: nil, profile: nil))
        let ownerFields = try XCTUnwrap(try JSONSerialization.jsonObject(with: owner) as? [String: Any])
        XCTAssertEqual((ownerFields["assignee"] as? [String: Any])?["kind"] as? String, "owner")
        XCTAssertNil(ownerFields["profile"])
        XCTAssertTrue(ownerFields["dueDate"] is NSNull)
        XCTAssertTrue(LAALinearTaskMutation(method: "POST", id: id, body: owner, version: nil).isValid)

        // A staff task without a profile cannot be built at all.
        XCTAssertNil(LAALinearTaskCreate.body(id: id, title: "確認", description: "", priority: 0,
                                              dueDate: nil, staff: "monet", profile: nil))
        XCTAssertFalse(LAALinearTaskMutation(method: "POST", id: id,
                                             body: Data(#"{"id":"\#(id)","assignee":{"kind":"staff","staff":"monet"}}"#.utf8),
                                             version: nil).isValid)
        XCTAssertFalse(LAALinearTaskMutation(method: "POST", id: id,
                                             body: Data(#"{"id":"\#(id)","assignee":{"kind":"owner"},"profile":"opus-high"}"#.utf8),
                                             version: nil).isValid)
        XCTAssertEqual(LAALinearTaskCreate.footer(staff: "monet"), "Monetが取得して、完了まで進めます。")
        XCTAssertNil(LAALinearTaskCreate.footer(staff: nil))
    }

    func testStaffCreateWithoutSessionScopeHasItsOwnWords() throws {
        let id = UUID().uuidString.lowercased()
        let staff = try XCTUnwrap(LAALinearTaskCreate.body(id: id, title: "見積り", description: "", priority: 0,
                                                           dueDate: nil, staff: "monet", profile: "opus-high"))
        let owner = try XCTUnwrap(LAALinearTaskCreate.body(id: id, title: "確認", description: "", priority: 0,
                                                           dueDate: nil, staff: nil, profile: nil))
        XCTAssertTrue(LAALinearTaskCreate.hasStaffAssignee(staff))
        XCTAssertFalse(LAALinearTaskCreate.hasStaffAssignee(owner))
        XCTAssertEqual(LAALinearTaskCreate.refusalMessage(status: 403, code: "insufficient_scope", body: staff),
                       "この端末からはAI社員に任せられません。担当を自分にするか、iPhoneから作成してください。")
        XCTAssertNil(LAALinearTaskCreate.refusalMessage(status: 403, code: "insufficient_scope", body: owner))
        XCTAssertNil(LAALinearTaskCreate.refusalMessage(status: 412, code: "insufficient_scope", body: staff))
        XCTAssertNil(LAALinearTaskCreate.refusalMessage(status: 403, code: "forbidden", body: staff))
    }

    func testCompletionMessageNamesTheSession() {
        XCTAssertEqual(LAATaskRunCopy.completionMessage(for: task()),
                       "一覧から消し、記録をHQに保管します。")
        XCTAssertEqual(LAATaskRunCopy.completionMessage(for: task(state: "running", session: "ses_0123456789abcdef", ref: "S5")),
                       "一覧から消し、記録をHQに保管します。セッション（S5）はアーカイブします。")
        XCTAssertEqual(LAATaskRunCopy.completionMessage(for: task(state: "stopped", session: "ses_0123456789abcdef")),
                       "一覧から消し、記録をHQに保管します。セッションはアーカイブします。")
    }

    func testCompleteSendsIfMatchAndRepeatsTheSameKey() async throws {
        let server = try LoopbackHTTPServer.start { request in
            if request.path.hasSuffix("/complete") {
                return .json(status: 200, body: #"{"data":{"id":"\#(request.path.split(separator: "/")[2])","completed":true,"sessionArchived":true,"archive":"queued"},"requestId":"test"}"#)
            }
            return .json(status: 404, body: #"{"error":{"code":"not_found"}}"#)
        }
        defer { server.stop() }
        let bridge = LAABridgeSession(credentialsForTesting:
            LAABridgeCredentials(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, deviceID: "test", token: "test"))
        let drafts = ComposerDraftStore(capacity: .max, fileURL: temporaryFile())
        let key = LAAWorkDrafts.key(deviceID: "test", target: "linear-owner-operation")
        let row = task(state: "queued", session: "ses_0123456789abcdef", ref: "S5")

        let outcome = await LAALinearTaskCompletion.complete(row, bridge: bridge, drafts: drafts, key: key)
        XCTAssertEqual(outcome, .completed)
        XCTAssertNil(LAAWorkDrafts.pending(drafts, key: key))
        let request = try XCTUnwrap(server.receivedRequests.last)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/linear-owner-tasks/\(row.id.lowercased())/complete")
        XCTAssertEqual(request.headers["if-match"], row.updatedAt)
        XCTAssertEqual(request.headers["idempotency-key"]?.isEmpty, false)
    }

    func testUnknownOutcomeKeepsTheRequestAndTheRetryReusesItsKey() async throws {
        let statuses = LockedStatus([500, 200])
        let server = try LoopbackHTTPServer.start { request in
            let status = statuses.next()
            if status == 200 {
                return .json(status: 200, body: #"{"data":{"id":"\#(request.path.split(separator: "/")[2])","completed":true,"sessionArchived":false},"requestId":"test"}"#)
            }
            return .json(status: status, body: #"{"error":{"code":"unavailable","message":"try later","retryable":true}}"#)
        }
        defer { server.stop() }
        let bridge = LAABridgeSession(credentialsForTesting:
            LAABridgeCredentials(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, deviceID: "test", token: "test"))
        let drafts = ComposerDraftStore(capacity: .max, fileURL: temporaryFile())
        let key = LAAWorkDrafts.key(deviceID: "test", target: "linear-owner-operation")
        let row = task()

        let first = await LAALinearTaskCompletion.complete(row, bridge: bridge, drafts: drafts, key: key)
        XCTAssertEqual(first, .unknown)
        let pending = try XCTUnwrap(LAAWorkDrafts.pending(drafts, key: key), "An unknown outcome keeps the request")
        let second = await LAALinearTaskCompletion.complete(row, bridge: bridge, drafts: drafts, key: key)
        XCTAssertEqual(second, .completed)
        XCTAssertNil(LAAWorkDrafts.pending(drafts, key: key))
        XCTAssertEqual(server.receivedRequests.count, 2)
        XCTAssertEqual(server.receivedRequests[0].headers["idempotency-key"],
                       server.receivedRequests[1].headers["idempotency-key"])
        XCTAssertEqual(server.receivedRequests[0].headers["if-match"], row.updatedAt)
    }

    func testCompletionDoesNotReuseAnotherPendingWrite() async throws {
        let bridge = LAABridgeSession(credentialsForTesting:
            LAABridgeCredentials(baseURL: URL(string: "https://fixture.ts.net")!, deviceID: "test", token: "test"))
        let drafts = ComposerDraftStore(capacity: .max, fileURL: temporaryFile())
        let key = LAAWorkDrafts.key(deviceID: "test", target: "linear-owner-operation")
        let edit = LAALinearTaskMutation(method: "PATCH", id: task().id,
                                         body: Data(#"{"title":"編集中"}"#.utf8), version: "2026-11-09T00:00:00Z")
        _ = try XCTUnwrap(LAAWorkDrafts.reserve(drafts, key: key, text: "Linearタスクの変更",
                                                body: try JSONEncoder().encode(edit),
                                                idempotency: LAABridgeIdempotencyKey()))
        let outcome = await LAALinearTaskCompletion.complete(task(), bridge: bridge, drafts: drafts, key: key)
        XCTAssertEqual(outcome, .failed("前の変更の結果を確認してから完了してください。"))
        XCTAssertNotNil(LAAWorkDrafts.pending(drafts, key: key), "The other write's key is untouched")
    }

    func testRunningAndChangedTasksAreRefusedWithTheirOwnWords() async throws {
        for (status, code, message) in [(409, "session_running", "実施中のため完了できません。"),
                                        (403, "insufficient_scope", "この端末からはAI社員のタスクを完了できません。iPhoneから完了してください。"),
                                        (412, "precondition_failed", "Linearで更新されています。読み直してから完了してください。")] {
            let server = try LoopbackHTTPServer.start { _ in
                .json(status: status, body: #"{"error":{"code":"\#(code)","message":"no","retryable":false}}"#)
            }
            defer { server.stop() }
            let bridge = LAABridgeSession(credentialsForTesting:
                LAABridgeCredentials(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, deviceID: "test", token: "test"))
            let drafts = ComposerDraftStore(capacity: .max, fileURL: temporaryFile())
            let key = LAAWorkDrafts.key(deviceID: "test", target: "linear-owner-operation")
            let outcome = await LAALinearTaskCompletion.complete(task(), bridge: bridge, drafts: drafts, key: key)
            XCTAssertEqual(outcome, .failed(message))
            XCTAssertNil(LAAWorkDrafts.pending(drafts, key: key), "A confirmed refusal leaves nothing to replay")
        }
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("laa-task-run-\(UUID().uuidString).json")
    }
}

/// The loopback handler runs off the main actor, so the sequence is locked.
private final class LockedStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int]
    init(_ values: [Int]) { self.values = values }
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        return values.isEmpty ? 500 : values.removeFirst()
    }
}
#endif
