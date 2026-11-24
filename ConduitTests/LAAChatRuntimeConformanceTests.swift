#if LAA_BUILD
import XCTest
@testable import Conduit

@MainActor final class LAAChatRuntimeConformanceTests: XCTestCase {
    private let durable = "fixture-durable-conversation"
    private let transport = "fixture-writer-a"
    private let turn = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

    private func wire(_ type: String, _ seq: Int, _ data: [String: Any] = [:], runtime: String? = nil) -> AnyCodable {
        AnyCodable.from(["type": type, "seq": seq, "session_id": runtime ?? transport, "payload": data])
    }

    private func replay(_ scenario: String, _ specs: [(String, [String: Any])], expectedText: String,
                        tools: Int? = nil, resend: Bool = false, saveSample: Bool = false) async throws {
        var time: TimeInterval = 0
        var receipts: [TurnMetrics] = []
        let timeline = HermesChatTimeline(now: { time }, wall: { Date(timeIntervalSince1970: 1_795_559_400) }) { receipts.append($0) }
        var writes = 0
        let adapter = HermesChatRuntime(timeline: timeline) { id, input in
            XCTAssertEqual(id, self.transport, scenario)
            XCTAssertEqual(input.turnID, self.turn, scenario)
            writes += 1
            time += 0.125
            return .accepted
        }
        let runtime: any ChatRuntime = adapter
        adapter.bind(conversationID: durable, runtimeID: transport, identity: ("laa-monet", "gemini-4-neon", "google", "high"))
        let request = ChatSubmitRequest(conversationID: durable, turnID: turn, text: "fixture prompt not for metrics")
        let acceptance = try await runtime.submit(request)
        XCTAssertEqual(acceptance, .started)
        for (idx, spec) in specs.enumerated() {
            time += 0.125
            let active = resend && idx >= 2 ? "fixture-writer-b" : transport
            if resend && idx == 2 {
                adapter.bind(conversationID: durable, runtimeID: active, identity: ("laa-monet", "gemini-4-neon", "google", "high"))
                let duplicate = try await runtime.submit(request)
                XCTAssertEqual(duplicate, acceptance)
                let stale = wire("message.delta", 999, ["text": "stale"], runtime: transport)
                adapter.observeWire(stale, parsed: StreamEventParser.parse(params: stale))
            }
            let params = wire(spec.0, idx + 1, spec.1, runtime: active)
            let parsed = StreamEventParser.parse(params: params)
            adapter.observeWire(params, parsed: parsed)
            // Replayed network duplicates must not add a second delta or terminal.
            adapter.observeWire(params, parsed: parsed)
            if spec.0.contains("delta"), idx == 1 || idx == 2 {
                time += 0.0625
                adapter.visible(runtimeID: active)
            }
        }
        time += 0.125
        adapter.settled(runtimeID: resend ? "fixture-writer-b" : transport)
        XCTAssertEqual(writes, 1, scenario)
        XCTAssertEqual(receipts.count, 1, scenario)
        let metrics = try XCTUnwrap(receipts.first)
        let end = try XCTUnwrap(metrics.client.t_settled_ms)
        XCTAssertLessThan(try XCTUnwrap(metrics.client.t_complete_ms), end)
        XCTAssertEqual(metrics.runtime.tool_calls, tools)
        if let receivedText = metrics.client.t_first_text_ms, scenario == "short" {
            XCTAssertLessThan(receivedText, try XCTUnwrap(metrics.client.t_first_visible_ms))
        }
        var stream = runtime.events(conversationID: durable, sinceSeq: 0).makeAsyncIterator()
        let expectedEvents = specs.count // only start + projected events + terminal in these fixtures
        guard timeline.replay(durable, after: 0).count == expectedEvents else { return XCTFail("\(scenario): wrong event count") }
        var text = "", terminalCount = 0, lastSeq: UInt64 = 0
        for idx in 0..<expectedEvents {
            guard let event = await stream.next() else { return XCTFail(scenario) }
            XCTAssertEqual(event.stamp.conversationID, durable)
            XCTAssertEqual(event.stamp.turnID, turn)
            XCTAssertEqual(event.stamp.seq, lastSeq + 1)
            lastSeq = event.stamp.seq
            switch event {
            case .started: XCTAssertEqual(idx, 0)
            case .textDelta(_, let chunk): text += chunk
            case .completed: terminalCount += 1; XCTAssertEqual(idx, expectedEvents - 1)
            default: break
            }
        }
        XCTAssertEqual(text, expectedText)
        XCTAssertEqual(terminalCount, 1)
        if resend {
            var missed = runtime.events(conversationID: durable, sinceSeq: lastSeq - 1).makeAsyncIterator()
            guard case .completed(let stamp, _, _, _) = await missed.next() else { return XCTFail("expected replay") }
            XCTAssertEqual(stamp.seq, lastSeq)
        }
        if saveSample {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            await ChatTurnMetricsStore(directory: directory).append(metrics)
            let data = try Data(contentsOf: directory.appendingPathComponent(ChatTurnMetricsStore.filename))
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("fixture prompt"))
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(durable))
            let row = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let counters = try XCTUnwrap(row["runtime"] as? [String: Any])
            XCTAssertTrue(counters["thought_tokens"] is NSNull)
            XCTAssertTrue(counters["steps"] is NSNull)
            XCTAssertEqual(counters["prompt_tokens"] as? Int, 11)
            let sample = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            sample.name = "chat-turn-metrics-fixture.jsonl"
            sample.lifetime = .keepAlways
            add(sample)
            print("R2_TURN_METRICS_SAMPLE \(String(decoding: data, as: UTF8.self))")
        }
    }

    func testShort() async throws {
        try await replay("short", [("message.start", [:]), ("message.delta", ["text": "2"]),
                                    ("message.complete", ["text": "2", "usage": ["turn_input_tokens": 11, "input": 900]])],
                         expectedText: "2", saveSample: true)
    }

    func testTools() async throws {
        try await replay("tools", [("message.start", [:]), ("reasoning.delta", ["text": "synthetic thought"]),
                                   ("message.interim", ["text": "checking"]),
                                   ("tool.start", ["name": "bench_lookup", "tool_id": "alpha"]),
                                   ("tool.complete", ["name": "bench_lookup", "tool_id": "alpha", "ok": true]),
                                   ("tool.start", ["name": "bench_lookup", "tool_id": "beta"]),
                                   ("tool.complete", ["name": "bench_lookup", "tool_id": "beta", "ok": true]),
                                   ("message.delta", ["text": "two values"]), ("message.complete", ["text": "two values"])],
                         expectedText: "two values", tools: 2)
    }

    func testLong() async throws {
        let text = (1...80).map { "chunk\($0);" }
        var frames: [(String, [String: Any])] = [("message.start", [:]), ("message.reasoning", ["text": "thought"])]
        frames += text.map { ("message.delta", ["text": $0]) }
        frames.append(("message.complete", ["text": text.joined()]))
        try await replay("long", frames, expectedText: text.joined())
    }

    func testResendReusesAckAndReplaysOnlyMissedCursor() async throws {
        try await replay("resend", [("message.start", [:]), ("message.delta", ["text": "04"]),
                                    ("message.delta", ["text": "0"]), ("message.complete", ["text": "040"])],
                         expectedText: "040", resend: true)
    }

    func testStructuredQuotaIsTerminalAndDoesNotInspectText() async throws {
        var metrics: [TurnMetrics] = []
        let timeline = HermesChatTimeline(record: { metrics.append($0) })
        let adapter = HermesChatRuntime(timeline: timeline) { _, _ in .accepted }
        adapter.bind(conversationID: durable, runtimeID: transport, identity: ("laa-monet", nil, nil, nil))
        _ = try await adapter.submit(.init(conversationID: durable, turnID: turn, text: "fixture"))
        let params = wire("message.complete", 1, ["status": "error", "error": ["code": "rate_limited", "retry_at": "2026-11-26T12:00:00Z"]])
        adapter.observeWire(params, parsed: StreamEventParser.parse(params: params))
        adapter.settled(runtimeID: transport)
        guard timeline.replay(durable, after: 0).count == 2 else { return XCTFail("wrong event count") }
        var events = adapter.events(conversationID: durable, sinceSeq: 0).makeAsyncIterator()
        _ = await events.next()
        guard case .failed(_, let failure, _) = await events.next() else { return XCTFail("expected failure") }
        XCTAssertEqual(failure.code, .quotaExhausted)
        XCTAssertNotNil(failure.retryAt)
        XCTAssertEqual(metrics.count, 1)
        let ordinary = wire("message.complete", 2, ["text": "Your request was not processed. Send it again if you still want me to carry it out."])
        guard case .messageComplete(_, _, let text, _, _) = StreamEventParser.parse(params: ordinary) else { return XCTFail("ordinary text changed type") }
        XCTAssertTrue(text?.hasPrefix("Your request") == true)
        XCTAssertEqual(HermesChatFailure.failure(["message": .string("quota exhausted, try in five minutes")]).code, .internal)
    }

    func testQueueTransfersOnlyOnTheNextTurnStart() async throws {
        var records: [TurnMetrics] = []
        let timeline = HermesChatTimeline(record: { records.append($0) })
        let adapter = HermesChatRuntime(timeline: timeline) { _, request in request.mode == .queued ? .queued : .accepted }
        adapter.bind(conversationID: durable, runtimeID: transport, identity: ("laa-monet", nil, nil, nil))
        let queued = UUID()
        _ = try await adapter.submit(.init(conversationID: durable, turnID: turn, text: "first"))
        let start = wire("message.start", 1)
        adapter.observeWire(start, parsed: StreamEventParser.parse(params: start))
        let ack = try await adapter.submit(.init(conversationID: durable, turnID: queued, text: "second", mode: .queued))
        XCTAssertEqual(ack, .queued)
        for (sequence, type) in [(2, "message.complete"), (3, "message.start"), (4, "message.complete")] {
            let params = wire(type, sequence, ["text": "fixture"])
            adapter.observeWire(params, parsed: StreamEventParser.parse(params: params))
            if type == "message.complete" { adapter.settled(runtimeID: transport) }
        }
        XCTAssertEqual(records.map(\.turn_id), [turn, queued])
        XCTAssertEqual(timeline.replay(durable, after: 0).map(\.stamp.turnID), [turn, turn, queued, queued])
    }

    func testCompactionUsesStructuredReceiptsAndContext() {
        let context = ChatContext(used: 89_000, window: 128_000, fixed: 53_000, recent: 36_000)
        func compact(_ fields: [String: Any], after: ChatContext? = nil) -> ContextCompactResult {
            HermesChatCompaction.resolve(SessionCompressResult(from: AnyCodable.from(fields)), before: context, after: after)
        }
        let nothing = compact(["status": "aborted", "summary": ["aborted": true, "failure_class": "empty_post_handoff_window"]])
        XCTAssertEqual(nothing.status, .nothingToCompact)
        XCTAssertEqual(nothing.message, "圧縮できる部分がありません（固定 53000・直近 36000）")
        XCTAssertNil(compact(["lock_held": true]).message)
        XCTAssertEqual(compact(["status": "pending"]).status, .inProgress)
        XCTAssertEqual(compact(["status": "aborted", "summary": ["failure_class": "context_overflow"]]).failure?.code, .contextOverflow)
        XCTAssertEqual(compact(["status": "compressed"], after: ChatContext(used: 61_000)).message, "圧縮しました（89000→61000）")
    }
}
#endif
