#if LAA_BUILD
import Foundation
import XCTest
@testable import Conduit

@MainActor
final class LAAChatConnectionTests: XCTestCase {
    private let session = "fixture-live"
    private let stored = "fixture-stored"
    private let epoch = "epoch-a"

    func testCachedOpeningEnablesSendBeforeAttachAndKeepsOneEditableEcho() async throws {
        let dashboard = UUID()
        let profile = "laa-monet"
        let workspace = WidgetWorkspaceID(dashboardID: dashboard, profile: profile)
        let link = try XCTUnwrap(WidgetLaunchLink(action: .employeeChat, workspace: workspace, reference: nil))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = OfflineChatCacheStore(directory: directory)
        let row = SessionSummary(id: stored, alternateIds: [], title: "Fixture", model: "Fixture", updatedLabel: "now",
                                 profile: profile, source: .chat, isActive: false, isArchived: false, lineageRootId: nil)
        cache.record(dashboardID: dashboard, profile: profile, sessionID: stored, title: row.title,
                     messages: [.init(id: "saved", role: .assistant, content: "Fixture cached row", timestamp: "1")],
                     sessions: [row])
        for iteration in 1...5 {
            let defaults = makeScratchDefaults("LAAChatConnectionTests-opening")
            let state = AppState(defaults: defaults, loadSavedConnection: false,
                                 sessionPresentationCache: SessionPresentationCache(defaults: defaults), offlineChatCache: cache)
            let start = ContinuousClock.now
            state.widgetLaunchPendingLinkChanged(link)
            let preview = state.laaEmployeeChatPreview
            let newCanSend = start.duration(to: .now)
            XCTAssertTrue(preview.canQueue("fixture turn", isComposing: false))
            XCTAssertFalse(preview.canQueue("fixture turn", isComposing: true))
            try await wait { preview.presentation?.displayedMessages.first?.id == "saved" }
            let firstCachedRow = start.duration(to: .now)
            let key = ComposerDraftKey(profile: profile, sessionID: stored, dashboardID: dashboard)
            XCTAssertTrue(state.laaQueueEmployeeOpeningSend("fixture turn", draftKey: key))
            let echoID = try XCTUnwrap(preview.queuedSend?.id)
            XCTAssertFalse(state.laaQueueEmployeeOpeningSend("do not duplicate", draftKey: key))
            XCTAssertEqual(preview.queuedSend?.id, echoID)
            // Exercise the old rule against the same controlled timeline:
            // the enabled flag was false for the entire fixture attach delay.
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertNotNil(state.laaOpeningEmployeeChat)
            state.laaEmployeeChatLaunchEnded(link, outcome: .handled)
            XCTAssertNil(state.laaOpeningEmployeeChat)
            let oldAttachGate = start.duration(to: .now)
            XCTAssertNil(preview.queuedSend)
            XCTAssertEqual(state.composerDraftStore.draft(for: key).text, "fixture turn")
            print("LAA_PERF opening_run=\(iteration) old_send_gate=\(oldAttachGate) new_send_gate=\(newCanSend) cached_row_shared_path=\(firstCachedRow)")
        }
    }

    func testQueuedPreviewSubmitsOnceAfterItsOwnLiveAttach() async throws {
        let dashboard = SavedDashboard(id: UUID(), label: "Fixture", normalizedURL: "https://r1.invalid")
        let profile = "laa-monet"
        let workspace = WidgetWorkspaceID(dashboardID: dashboard.id, profile: profile)
        let link = try XCTUnwrap(WidgetLaunchLink(action: .employeeChat, workspace: workspace, reference: nil))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeScratchDefaults("LAAChatConnectionTests-attach")
        let state = AppState(defaults: defaults, loadSavedConnection: false,
                             dashboardRegistry: .init(activeDashboardID: dashboard.id, dashboards: [dashboard]),
                             sessionPresentationCache: SessionPresentationCache(defaults: defaults),
                             offlineChatCache: OfflineChatCacheStore(directory: directory))
        state.setActiveProfileForTesting(profile)
        let (client, socket) = try await connect(capabilities: ["client_turn_id": true])
        defer { client.disconnect() }
        state.client = client
        state.widgetLaunchPendingLinkChanged(link)
        let key = ComposerDraftKey(profile: profile, sessionID: ComposerDraftKey.newConversationSessionID, dashboardID: dashboard.id)
        XCTAssertTrue(state.laaQueueEmployeeOpeningSend("fixture turn", draftKey: key))
        let id = try XCTUnwrap(state.laaEmployeeChatPreview.queuedSend?.id)
        XCTAssertFalse(socket.methods.contains("prompt.submit"))
        try await attach(client, socket)
        state.activeSessionId = session
        state.isConnected = true
        state.laaEmployeeChatLaunchEnded(link, outcome: .handled)
        state.settlePendingComposerSend()
        let prompt = try await request("prompt.submit", socket)
        let params = try XCTUnwrap(prompt["params"] as? [String: Any])
        XCTAssertEqual(params["session_id"] as? String, session)
        XCTAssertEqual(params["client_turn_id"] as? String, id.uuidString)
        XCTAssertEqual(params["text"] as? String, "fixture turn")
        try socket.reply(prompt, ["status": "streaming"])
        state.settlePendingComposerSend()
        try await wait { state.deliveringPendingComposerSendIDs.isEmpty }
        XCTAssertEqual(socket.methods.filter { $0 == "prompt.submit" }.count, 1)
        XCTAssertEqual(state.messages.filter { $0.role == .user }.count, 1)
    }

    func testReasoningOptsInOnlyOnCreateAndEveryResumeWhenAdvertised() async throws {
        let capability = ["reasoning_delta_optin": true]
        for (ready, reply, expected) in [([:], [:], false), (capability, [:], true), ([:], capability, true)] {
            let (client, socket) = try await connect(capabilities: ready, capabilityReply: reply)
            defer { client.disconnect() }
            let create = Task { try await client.createSession() }
            let createRequest = try await request("session.create", socket)
            XCTAssertEqual((createRequest["params"] as? [String: Any])?["include_reasoning_deltas"] as? Bool,
                           expected ? true : nil)
            try socket.reply(createRequest, ["session_id": session, "stored_session_id": stored])
            _ = try await create.value
            for occurrence in 1...2 {
                let id = stored
                let resume = Task { try await client.openSession(id) }
                let resumeRequest = try await request("session.resume", socket, occurrence: occurrence)
                XCTAssertEqual((resumeRequest["params"] as? [String: Any])?["include_reasoning_deltas"] as? Bool,
                               expected ? true : nil)
                try socket.reply(resumeRequest, ["session_id": session, "stored_session_id": stored])
                _ = try await resume.value
            }
            XCTAssertFalse(socket.methods.contains("config.set"))
        }
    }

    func testFirstWireEventImmediatelyPublishesReasoningOrWork() async throws {
        for (event, text) in [("reasoning.delta", "first thought"), ("thinking.delta", "working"),
                              ("status.update", "preparing fixture turn"), ("message.start", ""), ("tool.start", "")] {
            let defaults = makeScratchDefaults("LAAChatConnectionTests")
            let state = AppState(defaults: defaults, loadSavedConnection: false,
                                 sessionPresentationCache: SessionPresentationCache(defaults: defaults))
            state.activeSessionId = session
            let (client, socket) = try await connect()
            var observed = false
            var wireArrival = ContinuousClock.now
            client.onEvent = { streamEvent in
                let started = ContinuousClock.now
                state.handleStreamEvent(streamEvent)
                XCTAssertTrue(state.isBusy, event)
                if event == "reasoning.delta" { XCTAssertEqual(state.liveReasoningSegment?.content, text) }
                else { XCTAssertNil(state.liveReasoningSegment, "status must not render as thought") }
                if event == "thinking.delta" || event == "status.update" {
                    XCTAssertEqual(state.liveTurn.thinkingStatus, LAACopy.chatThinking)
                }
                let now = ContinuousClock.now
                let elapsed = wireArrival.duration(to: now)
                XCTAssertLessThan(elapsed, .milliseconds(50))
                print("LAA_PERF first_event=\(event) wire_to_projection=\(elapsed) reducer=\(started.duration(to: now))")
                observed = true
            }
            wireArrival = .now
            try socket.event(frame(event, at: 1, text: text))
            try await wait { observed }
            client.disconnect()
        }
    }

    func testReadyStatusDoesNotStartWorkAndProgressYieldsToThought() async throws {
        let defaults = makeScratchDefaults("LAAChatConnectionTests-status")
        let state = AppState(defaults: defaults, loadSavedConnection: false,
                             sessionPresentationCache: SessionPresentationCache(defaults: defaults))
        state.activeSessionId = session
        state.handleStreamEvent(.statusUpdate(sessionId: session, kind: .other("status"), text: "ready"))
        XCTAssertFalse(state.isBusy)
        state.handleStreamEvent(.statusUpdate(sessionId: "different-chat", kind: .other("lifecycle"), text: "working"))
        XCTAssertFalse(state.isBusy)
        state.handleStreamEvent(.statusUpdate(sessionId: session, kind: .other("lifecycle"), text: "working"))
        XCTAssertTrue(state.isBusy)
        XCTAssertNil(state.liveReasoningSegment)
        state.handleStreamEvent(.reasoningDelta(sessionId: session, text: "first private thought"))
        XCTAssertEqual(state.liveReasoningSegment?.content, "first private thought")
    }

    func testReconnectMergesBufferedAndReplayedDeltasAndOpenRequestsOnce() async throws {
        for cut in 1...3 {
            let (old, first) = try await connect()
            try await attach(old, first)
            var text = ""
            old.onEvent = { if case .messageDelta(_, let delta) = $0 { text += delta } }
            for sequence in 1...cut {
                try first.event(frame("message.delta", at: sequence, text: "\(sequence)"))
            }
            try await wait { text.count == cut }
            first.drop()
            try await wait { !old.isConnected }
            let cursor = try XCTUnwrap(old.laaReplayCursor(for: session))
            XCTAssertEqual(cursor.sequence, cut)

            let optedIn = cut == 2
            let (next, second) = try await connect(capabilities: optedIn ? ["reasoning_delta_optin": true] : [:])
            var clarify = 0
            next.onEvent = {
                if case .messageDelta(_, let delta) = $0 { text += delta }
                if case .clarify = $0 { clarify += 1 }
            }
            let runtimeID = session
            let durableID = stored
            let reattach = Task { await next.laaReplaySession(runtimeID, from: cursor, storedID: durableID,
                                                               profile: nil, isCurrent: { true }) }
            let activate = try await request(optedIn ? "session.resume" : "session.activate", second)
            let attachParams = try XCTUnwrap(activate["params"] as? [String: Any])
            XCTAssertEqual(attachParams["omit_messages"] as? Bool, true)
            XCTAssertEqual(attachParams["include_reasoning_deltas"] as? Bool, optedIn ? true : nil)
            XCTAssertEqual(attachParams["session_id"] as? String, optedIn ? stored : session)
            try second.reply(activate, ["session_id": session, "running": true])
            let since = try await request("session.events.since", second)
            XCTAssertEqual((since["params"] as? [String: Any])?["last_seen"] as? Int, cut)
            // Live 5 raced the snapshot, live 4 duplicates the last replay frame.
            try second.event(frame("message.delta", at: 5, text: "5"))
            try second.event(frame("message.delta", at: 4, text: "4"))
            let open: [String: Any] = ["jsonrpc": "2.0", "id": "srq-fixture", "method": "clarify",
                                      "params": ["session_id": session, "question": "Fixture question?"]]
            try second.deliver(open)
            try second.reply(since, ["epoch": epoch, "latest_seq": 5, "truncated": false,
                                    "events": ((cut + 1)...4).map { frame("message.delta", at: $0, text: "\($0)") },
                                    "open_requests": [open]])
            let result = await reattach.value
            XCTAssertEqual(result?.running, true)
            try second.event(frame("message.delta", at: 5, text: "duplicate"))
            try second.event(frame("message.delta", at: 6, text: "6"))
            try await wait { text.hasSuffix("6") }
            XCTAssertEqual(text, "123456", "disconnect after \(cut)")
            XCTAssertEqual(clarify, 1)
            XCTAssertFalse(second.methods.contains("prompt.submit"))
            XCTAssertFalse(second.methods.contains("config.set"))
            next.disconnect()
        }
    }

    func testTruncatedRingEpochChangeAndGapRefusePartialReplay() async throws {
        for variant in ["truncated", "changedEpoch", "gap"] {
            let (client, socket) = try await connect()
            var text = ""
            client.onEvent = { if case .messageDelta(_, let delta) = $0 { text += delta } }
            let runtimeID = session
            let cursor = LAAChatEventReplay.Cursor(epoch: epoch, sequence: 1)
            let reattach = Task { await client.laaReplaySession(runtimeID, from: cursor, storedID: nil,
                                                                 profile: nil, isCurrent: { true }) }
            try socket.reply(try await request("session.activate", socket), ["session_id": session, "running": true])
            try socket.reply(try await request("session.events.since", socket), [
                "epoch": variant == "changedEpoch" ? "epoch-b" : epoch,
                "latest_seq": 3, "truncated": variant == "truncated",
                "events": [frame("message.delta", at: variant == "gap" ? 3 : 2, text: "must not apply")],
            ])
            let result = await reattach.value
            XCTAssertNil(result, variant)
            XCTAssertEqual(text, "", variant)
            XCTAssertFalse(socket.methods.contains("prompt.submit"))
            client.disconnect()
        }
    }

    func testContextWaitsForAttachmentAndRetriesOnlyOnceAfterNotInMemory() async throws {
        let (client, socket) = try await connect()
        do { _ = try await client.contextBreakdown(session); XCTFail("only a live attachment may read context") }
        catch { XCTAssertFalse(socket.methods.contains("session.context_breakdown")) }
        try await attach(client, socket)
        let runtimeID = session
        let read = Task { try await client.contextBreakdown(runtimeID, canReattach: { true }, adoptReattached: { _ in true }) }
        let first = try await request("session.context_breakdown", socket)
        try socket.deliver(["id": try XCTUnwrap(first["id"]), "jsonrpc": "2.0",
                            "error": ["code": 4001, "message": "not in memory"]])
        let resume = try await request("session.resume", socket, occurrence: 2)
        XCTAssertEqual((resume["params"] as? [String: Any])?["session_id"] as? String, stored)
        try socket.reply(resume, ["session_id": "fixture-rebound", "stored_session_id": stored])
        let second = try await request("session.context_breakdown", socket, occurrence: 2)
        XCTAssertEqual((second["params"] as? [String: Any])?["session_id"] as? String, "fixture-rebound")
        try socket.reply(second, [:])
        _ = try await read.value
        XCTAssertEqual(socket.methods.filter { $0 == "session.context_breakdown" }.count, 2)
        client.disconnect()
    }

    private func frame(_ type: String, at sequence: Int, text: String) -> [String: Any] {
        ["type": type, "session_id": session, "seq": sequence,
         "payload": ["text": text, "kind": "lifecycle", "tool": "fixture", "tool_use_id": "fixture-tool"]]
    }

    private func connect(capabilities: [String: Any] = [:], capabilityReply: [String: Any] = [:]) async throws -> (HermesClient, LaneR1Socket) {
        let transport = LaneR1Transport()
        let client = HermesClient(connection: .init(baseUrl: "https://r1.invalid", ticket: "fixture"),
                                  transportFactory: { transport }, monitorsPath: false)
        let connected = Task { try await client.connect() }
        try await wait { transport.open != nil }
        transport.open?(transport.socket)
        try await connected.value
        var payload = capabilities
        payload["replay_epoch"] = epoch
        try transport.socket.event(["type": "gateway.ready", "payload": payload])
        // Capabilities is the observable acknowledgement that ready was parsed.
        let handshake = try await request("client.capabilities", transport.socket)
        try transport.socket.reply(handshake, capabilityReply)
        return (client, transport.socket)
    }

    private func attach(_ client: HermesClient, _ socket: LaneR1Socket) async throws {
        let id = stored
        let attaching = Task { try await client.openSession(id) }
        try socket.reply(try await request("session.resume", socket), ["session_id": session, "stored_session_id": stored])
        _ = try await attaching.value
    }

    private func request(_ method: String, _ socket: LaneR1Socket, occurrence: Int = 1) async throws -> [String: Any] {
        try await wait { socket.requests.filter { $0["method"] as? String == method }.count >= occurrence }
        return socket.requests.filter { $0["method"] as? String == method }[occurrence - 1]
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        struct FixtureTimeout: Error {}
        XCTFail("Fixture did not reach expected state")
        throw FixtureTimeout()
    }
}

private final class LaneR1Transport: HermesWebSocketTransport {
    let socket = LaneR1Socket()
    var open: ((any HermesWebSocket) -> Void)?
    func makeSocket(request: URLRequest, onOpen: @escaping (any HermesWebSocket) -> Void,
                    onCloseBeforeOpen: @escaping (any HermesWebSocket) -> Void) -> any HermesWebSocket {
        open = onOpen
        return socket
    }
    func invalidate() {}
}

private final class LaneR1Socket: HermesWebSocket, @unchecked Sendable {
    private struct Disconnected: Error {}
    private let lock = NSLock()
    private var _requests: [[String: Any]] = []
    private let stream = AsyncThrowingStream<URLSessionWebSocketTask.Message, Error>.makeStream()
    // HermesClient has one receiver per socket; its iterator is never used concurrently.
    private lazy var iterator = stream.stream.makeAsyncIterator()
    var requests: [[String: Any]] { lock.withLock { _requests } }
    var methods: [String] { requests.compactMap { $0["method"] as? String } }
    var closeCode: URLSessionWebSocketTask.CloseCode { .invalid }
    func resume() {}
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) { drop() }
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        do {
            if case .string(let text) = message,
               let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                lock.withLock { _requests.append(object) }
            }
            completionHandler(nil)
        } catch { completionHandler(error) }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        guard let message = try await iterator.next() else { throw Disconnected() }
        return message
    }
    func drop() { stream.continuation.finish(throwing: Disconnected()) }
    func deliver(_ payload: [String: Any]) throws {
        let bytes = try JSONSerialization.data(withJSONObject: payload)
        stream.continuation.yield(.string(String(decoding: bytes, as: UTF8.self)))
    }
    func event(_ body: [String: Any]) throws { try deliver(["jsonrpc": "2.0", "method": "event", "params": body]) }
    func reply(_ request: [String: Any], _ result: [String: Any]) throws {
        try deliver(["jsonrpc": "2.0", "id": try XCTUnwrap(request["id"]), "result": result])
    }
}
#endif
