#if LAA_BUILD
import Foundation
import SwiftUI

/// The board's state, shared by the Work hub (pill count, default section)
/// and the list. Reads and writes go through the existing Bridge session.
@MainActor final class LAADecisionBoard: ObservableObject {
    enum Phase: Equatable { case idle, loaded, unsupported, failed(String) }
    enum Outcome: Equatable {
        /// Delivered to the conversation, or stored for an agent without one.
        case done(stored: Bool)
        /// The answer is saved but the conversation did not receive it.
        case notDelivered(String)
        /// Nothing was recorded, or the result is unknown; the same request can be sent again.
        case failed(String)
    }

    @Published private(set) var items: [LAADecision] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var loading = false
    /// The hub picks the board once, the first time it has something waiting.
    var choseDefaultSection = false
    /// A link's decision id, consumed once the list can present it.
    @Published var linkedID: String?
    /// Same request id for a repeat after an unknown outcome, so the Bridge
    /// replays instead of answering twice.
    private var requestIDs: [String: LAABridgeIdempotencyKey] = [:]

    private var loadedAt: Date?

    var count: Int { items.count }

    func reset() {
        items = []; phase = .idle; loadedAt = nil
    }

    func restoreIfNeeded(_ cached: [LAADecision]) {
        guard phase == .idle, items.isEmpty else { return }
        items = LAADecisionOrder.sorted(cached)
    }

    /// The hub's first read: true once, when the board has something waiting
    /// and the owner has not been sent elsewhere by a link.
    func loadForDefaultSection(_ bridge: LAABridgeSession) async -> Bool {
        await load(bridge)
        guard phase == .loaded, !choseDefaultSection else { return false }
        choseDefaultSection = true
        return !items.isEmpty
    }

    /// The list's read on appear, skipped right after the hub's own read.
    func refreshIfStale(_ bridge: LAABridgeSession) async {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < 5, phase == .loaded { return }
        await load(bridge)
    }

    func load(_ bridge: LAABridgeSession) async {
        guard bridge.status == .paired else { items = []; phase = .idle; return }
        loading = true
        defer { loading = false }
        do {
            let page: LAADecisionPage = try await bridge.read("/v1/decisions")
            items = LAADecisionOrder.sorted(page.items)
            phase = .loaded
            loadedAt = Date()
        } catch is CancellationError {
        } catch let error as LAABridgeError {
            if case .other(status: 404, code: _) = error { items = []; phase = .unsupported }
            else { phase = .failed(error.japaneseText) }
        } catch {
            phase = .failed(LAABridgeError.invalidResponse.japaneseText)
        }
    }

    #if DEBUG
    /// Snapshot and unit tests set a state directly.
    func setForTesting(_ items: [LAADecision], phase: Phase = .loaded) {
        self.items = LAADecisionOrder.sorted(items); self.phase = phase
    }
    #endif

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
    }

    /// The answer body. A free answer keeps `optionIndex` null on the wire
    /// (not omitted) and carries the words in `note`; choosing an option may
    /// still add a short note beside it.
    struct AnswerBody: Encodable {
        let optionIndex: Int?
        let note: String?
        let requestId: String

        private enum CodingKeys: String, CodingKey { case optionIndex, note, requestId }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            if let optionIndex { try values.encode(optionIndex, forKey: .optionIndex) }
            else { try values.encodeNil(forKey: .optionIndex) }
            if let note { try values.encode(note, forKey: .note) }
            else { try values.encodeNil(forKey: .note) }
            try values.encode(requestId, forKey: .requestId)
        }
    }

    static func answerBody(optionIndex: Int?, note: String?, requestId: String) -> AnswerBody {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AnswerBody(optionIndex: optionIndex, note: trimmed?.isEmpty == false ? trimmed : nil, requestId: requestId)
    }

    func answer(_ item: LAADecision, optionIndex: Int?, note: String?, bridge: LAABridgeSession) async -> Outcome {
        let key = requestIDs[item.id] ?? LAABridgeIdempotencyKey()
        requestIDs[item.id] = key
        return await send(item, path: "/v1/decisions/\(item.id)/answer", key: key, bridge: bridge,
                          body: Self.answerBody(optionIndex: optionIndex, note: note, requestId: key.value))
    }

    func retry(_ item: LAADecision, bridge: LAABridgeSession) async -> Outcome {
        struct Body: Encodable { let requestId: String }
        let key = LAABridgeIdempotencyKey()
        requestIDs[item.id] = key
        return await send(item, path: "/v1/decisions/\(item.id)/retry", key: key, bridge: bridge, body: Body(requestId: key.value))
    }

    private func send<B: Encodable>(_ item: LAADecision, path: String, key: LAABridgeIdempotencyKey,
                                    bridge: LAABridgeSession, body: B) async -> Outcome {
        do {
            let data = try JSONEncoder().encode(body)
            let result: LAADecisionAnswerResult = try await LAAWorkHTTP.write(bridge, path: path, body: data, key: key)
            requestIDs[item.id] = nil
            return Self.outcome(of: result.decision, replacing: item, in: self)
        } catch let error as LAABridgeHTTPError {
            // A refusal the Bridge confirms means nothing was recorded; a new
            // request may follow. Anything else keeps the id for a replay.
            if !LAAWorkHTTP.outcomeUnknown(error) { requestIDs[item.id] = nil }
            return .failed(LAADecisionCopy.answerError(error))
        } catch {
            return .failed(LAADecisionCopy.answerError(error))
        }
    }

    private static func outcome(of decision: LAADecision, replacing item: LAADecision, in board: LAADecisionBoard) -> Outcome {
        switch decision.delivery?.state {
        case "failed":
            // Keep the row with its new delivery state; it stays on the board.
            let merged = LAADecision(kind: .board, id: decision.id, ref: decision.ref ?? item.ref, status: decision.status,
                                     title: decision.title, summary: decision.summary, options: decision.options,
                                     allowOther: decision.allowOther, impact: decision.impact, deadline: decision.deadline,
                                     source: decision.source, sourceRef: decision.sourceRef ?? item.sourceRef,
                                     createdAt: decision.createdAt ?? item.createdAt, answer: decision.answer,
                                     delivery: decision.delivery)
            if let index = board.items.firstIndex(where: { $0.id == item.id }) { board.items[index] = merged }
            else { board.items.append(merged) }
            board.items = LAADecisionOrder.sorted(board.items)
            return .notDelivered(LAADecisionCopy.deliveryError(decision.delivery?.error))
        case "stored": return .done(stored: true)
        default: return .done(stored: false)
        }
    }
}
#endif
