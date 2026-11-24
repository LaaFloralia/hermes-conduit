#if LAA_BUILD
import Foundation

/// A bounded, process-local event journal. Hermes has no durable seek cursor
/// on the WebSocket today, so replay outside this journal is not implied.
@MainActor final class HermesChatTimeline {
    typealias Identity = (profile: String, model: String?, provider: String?, effort: String?)
    private struct Turn {
        let began: TimeInterval
        let identity: Identity
        var metrics: TurnMetrics
        var started = false
        var terminal: Terminal?
        var toolCalls = 0
        var compactions = 0
    }
    private enum Terminal {
        case completed(String?, String?)
        case failed(ChatRuntimeFailure)
    }
    private let now: () -> TimeInterval
    private let wall: () -> Date
    private let record: @MainActor (TurnMetrics) -> Void
    private var turns: [String: Turn] = [:]
    private var waiting: [String: [Turn]] = [:]
    private var sequences: [String: UInt64] = [:]
    private var journal: [String: [ChatRuntimeEvent]] = [:]
    private var listeners: [String: [UUID: AsyncStream<ChatRuntimeEvent>.Continuation]] = [:]

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         wall: @escaping () -> Date = Date.init,
         record: @escaping @MainActor (TurnMetrics) -> Void = { metrics in
             Task { await ChatTurnMetricsStore.shared.append(metrics) }
         }) {
        self.now = now
        self.wall = wall
        self.record = record
    }

    func turnID(_ conversationID: String) -> UUID? { turns[conversationID]?.metrics.turn_id }

    func begin(_ id: String, turnID: UUID, identity: Identity) {
        let began = now()
        let submitted = Int64(wall().timeIntervalSince1970 * 1_000)
        let model = identity.model.flatMap { model in
            let standard = model.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-_").contains($0) }
                && ["gemini-", "gpt-", "claude-", "deepseek-"].contains { model.hasPrefix($0) }
            return standard || LAAChatModelAllowList.current()?.allows(model) == true ? model : TurnMetrics.opaque(model)
        }
        let turn = Turn(began: began, identity: identity, metrics: TurnMetrics(
            turn_id: turnID, conversation_id: TurnMetrics.opaque(id), profile: TurnMetrics.profileLabel(identity.profile),
            model: model, effort: identity.effort.flatMap { LAAEffort.order.contains($0) ? $0 : nil },
            client: .init(t_submit: submitted)))
        if turns[id] == nil, waiting[id]?.isEmpty != false { turns[id] = turn }
        else { waiting[id, default: []].append(turn) }
    }

    func accept(_ id: String, turnID: UUID, queued: Bool = false) {
        if var turn = turns[id], turn.metrics.turn_id == turnID {
            turn.metrics.client.t_accepted_ms = turn.metrics.client.t_accepted_ms ?? elapsed(turn)
            if queued && !turn.started {
                turns[id] = nil
                waiting[id, default: []].insert(turn, at: 0)
            } else {
                turns[id] = turn
                if turn.metrics.client.t_settled_ms != nil { finish(id) }
            }
        } else if let index = waiting[id]?.firstIndex(where: { $0.metrics.turn_id == turnID }),
                  var turn = waiting[id]?[index] {
            turn.metrics.client.t_accepted_ms = turn.metrics.client.t_accepted_ms ?? elapsed(turn)
            waiting[id]?[index] = turn
        }
    }

    func discardUnstarted(_ id: String, turnID: UUID) {
        if let turn = turns[id], turn.metrics.turn_id == turnID, !turn.started { turns[id] = nil }
        _ = removeWaiting(id, turnID: turnID)
    }

    private func removeWaiting(_ id: String, turnID: UUID) -> Turn? {
        guard let index = waiting[id]?.firstIndex(where: { $0.metrics.turn_id == turnID }) else { return nil }
        let removed = waiting[id]?.remove(at: index)
        if waiting[id]?.isEmpty == true { waiting[id] = nil }
        return removed
    }

    func fail(_ id: String, turnID: UUID, failure: ChatRuntimeFailure) {
        if var turn = turns[id], turn.metrics.turn_id == turnID, turn.terminal == nil {
            start(id, turn: &turn)
            turn.metrics.client.t_complete_ms = elapsed(turn)
            turn.terminal = .failed(failure)
            turns[id] = turn
            finish(id)
        } else if var turn = removeWaiting(id, turnID: turnID) {
            // A definite rejection of a second submission is its own edge,
            // not the end of the currently streaming turn.
            start(id, turn: &turn)
            turn.metrics.client.t_complete_ms = elapsed(turn)
            recordTerminal(id, turn: turn, terminal: .failed(failure))
        }
    }

    func recoveredSettlement(_ id: String, turnID: UUID) {
        guard var turn = turns[id], turn.metrics.turn_id == turnID, turn.terminal == nil else { return }
        start(id, turn: &turn)
        turn.terminal = .completed(nil, nil)
        turns[id] = turn
        finish(id)
    }

    func visible(_ id: String) {
        guard var turn = turns[id], turn.started, turn.metrics.client.t_first_visible_ms == nil else { return }
        turn.metrics.client.t_first_visible_ms = elapsed(turn)
        turns[id] = turn
    }

    func settled(_ id: String) {
        guard var turn = turns[id], turn.terminal != nil else { return }
        turn.metrics.client.t_settled_ms = turn.metrics.client.t_settled_ms ?? elapsed(turn)
        turns[id] = turn
        if turn.metrics.client.t_accepted_ms != nil { finish(id) }
    }

    /// Date is reconstructed from the monotonic offset to the submit anchor,
    /// so a wall clock correction cannot reorder events within a turn.
    private func emit(_ id: String, turn: Turn, _ produce: (ChatEventStamp) -> ChatRuntimeEvent) {
        let seq = (sequences[id] ?? 0) + 1
        sequences[id] = seq
        let millis = turn.metrics.client.t_submit + elapsed(turn)
        let event = produce(.init(conversationID: id, turnID: turn.metrics.turn_id, seq: seq,
                                  at: Date(timeIntervalSince1970: Double(millis) / 1_000)))
        journal[id, default: []].append(event)
        if let count = journal[id]?.count, count > 512 { journal[id]?.removeFirst(count - 512) }
        if journal.count > 12, let oldestInactive = journal.keys.first(where: { $0 != id && listeners[$0] == nil && turns[$0] == nil }) {
            journal[oldestInactive] = nil
        }
        listeners[id]?.values.forEach { $0.yield(event) }
    }

    func replay(_ id: String, after seq: UInt64) -> [ChatRuntimeEvent] {
        journal[id]?.filter { seq < $0.stamp.seq } ?? []
    }

    func events(_ id: String, sinceSeq: UInt64?) -> AsyncStream<ChatRuntimeEvent> {
        let token = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1_024)) { continuation in
            if let sinceSeq { replay(id, after: sinceSeq).forEach { continuation.yield($0) } }
            listeners[id, default: [:]][token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.listeners[id]?[token] = nil
                    if self?.listeners[id]?.isEmpty == true { self?.listeners[id] = nil }
                }
            }
        }
    }

    private func elapsed(_ turn: Turn) -> Int64 { Int64(max(0, now() - turn.began) * 1_000) }

    private func start(_ id: String, turn: inout Turn) {
        guard !turn.started else { return }
        turn.started = true
        let identity = turn.identity
        emit(id, turn: turn) { .started($0, model: identity.model, provider: identity.provider, effort: identity.effort) }
    }

    private func finish(_ id: String) {
        guard let turn = turns[id], let terminal = turn.terminal else { return }
        turns[id] = nil
        recordTerminal(id, turn: turn, terminal: terminal)
    }

    private func recordTerminal(_ id: String, turn: Turn, terminal: Terminal) {
        let metrics = turn.metrics
        emit(id, turn: turn) { stamp in
            switch terminal {
            case .completed(let text, let messageID): return .completed(stamp, text: text, messageID: messageID, metrics: metrics)
            case .failed(let failure): return .failed(stamp, failure, metrics: metrics)
            }
        }
        record(metrics)
    }

    func flushTerminal(_ id: String, turnID: UUID) {
        guard turns[id]?.metrics.turn_id == turnID else { return }
        finish(id)
    }

    /// `observe` takes the same parsed delta as production (including aliases)
    /// plus the raw usage fields discarded by the older UI projection.
    func observe(_ id: String, wire: [String: AnyCodable], parsed: StreamEvent?) -> UUID? {
        guard let type = wire["type"]?.stringValue else { return nil }
        if type == "message.start", let next = waiting[id]?.first,
           turns[id] == nil || (turns[id]?.terminal != nil && next.metrics.client.t_accepted_ms != nil) {
            finish(id)
            turns[id] = removeWaiting(id, turnID: next.metrics.turn_id)
        }
        guard var turn = turns[id], turn.terminal == nil else { return nil }
        let payload = wire["payload"]?.objectValue ?? [:]
        let failure = HermesChatFailure.terminal(type: type, payload: payload)
        let usage = payload["usage"]?.objectValue ?? payload
        var event: ((ChatEventStamp) -> ChatRuntimeEvent)?
        switch parsed {
        case .messageStart:
            break
        case .reasoningDelta(_, let text): event = { .thoughtDelta($0, text: text) }
        case .messageDelta(_, let text):
            turn.metrics.client.t_first_text_ms = turn.metrics.client.t_first_text_ms ?? elapsed(turn)
            event = { .textDelta($0, text: text) }
        case .messageInterim(_, let text, _):
            turn.metrics.client.t_first_text_ms = turn.metrics.client.t_first_text_ms ?? elapsed(turn)
            event = { .textInterim($0, text: text) }
        case .toolStart(_, let name, _, let id):
            turn.toolCalls += 1
            if let id { event = { .toolStarted($0, callID: id, name: name, summary: payload["summary"]?.stringValue) } }
        case .toolComplete(_, _, _, let id):
            if let id { event = { .toolFinished($0, callID: id, ok: payload["ok"]?.boolValue, summary: payload["summary"]?.stringValue, card: payload["card"]?.stringValue) } }
        case .contextUpdate(_, _, let used, let max):
            turn.metrics.runtime.context_tokens = used ?? turn.metrics.runtime.context_tokens
            turn.metrics.runtime.context_window = max ?? turn.metrics.runtime.context_window
            event = { .contextUpdated($0, used: used, window: max) }
        case .sessionInfo(_, let snapshot):
            turn.metrics.runtime.context_tokens = snapshot.contextUsed ?? turn.metrics.runtime.context_tokens
            turn.metrics.runtime.context_window = snapshot.contextMax ?? turn.metrics.runtime.context_window
            event = { .contextUpdated($0, used: snapshot.contextUsed, window: snapshot.contextMax) }
        case .statusUpdate(_, let kind, _):
            switch kind {
            case .compacting:
                turn.compactions += 1
                event = { .compactionProgress($0, started: true) }
            case .compacted: event = { .compactionProgress($0, started: false) }
            default: return nil
            }
        default:
            if type == "session.usage", turn.started {
                event = { .contextUpdated($0, used: usage["context_used"]?.intValue, window: usage["context_max"]?.intValue) }
            } else if type == "request.cancel", let requestID = payload["id"]?.stringValue {
                event = { .requestClosed($0, requestID: requestID) }
            } else if type == "request.open", let requestID = payload["id"]?.stringValue,
                      let kind = payload["kind"]?.stringValue.flatMap(ChatOpenRequest.Kind.init(rawValue:)) {
                event = { .requestOpened($0, .init(id: requestID, kind: kind)) }
            } else if type != "message.complete" && type != "session.usage" && failure == nil { return nil }
        }
        // Usage can be an idle-period periodic tick before the RPC is
        // actually received. Hold data but don't invent a started edge.
        turn.metrics.runtime.observe(usage)
        if !turn.started && ["session.info", "session.usage", "context.update", "session.context"].contains(type) {
            turns[id] = turn
            return nil
        }
        turn.metrics.client.t_first_event_ms = turn.metrics.client.t_first_event_ms ?? elapsed(turn)
        start(id, turn: &turn)
        if let event { emit(id, turn: turn, event) }
        if let failure {
            turn.terminal = .failed(failure)
        } else if case .messageComplete(_, let messageID, let text, _, _) = parsed {
            if text?.isEmpty == false {
                turn.metrics.client.t_first_text_ms = turn.metrics.client.t_first_text_ms ?? elapsed(turn)
            }
            turn.terminal = .completed(text, messageID)
        }
        if turn.terminal != nil {
            turn.metrics.client.t_complete_ms = elapsed(turn)
            if turn.compactions > 0 { turn.metrics.runtime.compactions = turn.metrics.runtime.compactions ?? turn.compactions }
            if turn.toolCalls > 0 { turn.metrics.runtime.tool_calls = turn.metrics.runtime.tool_calls ?? turn.toolCalls }
        }
        turns[id] = turn
        return turn.terminal != nil ? turn.metrics.turn_id : nil
    }
}
#endif
