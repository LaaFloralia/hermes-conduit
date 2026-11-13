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

    @Published private(set) var records: [String: LAADecision] = [:]
    private var sendingIDs = Set<String>()
    private var writeRevisions: [String: Int] = [:]

    private var loadedAt: Date?

    var count: Int { items.count }

    func reset() {
        items = []; records = [:]; phase = .idle; loadedAt = nil
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
            for item in page.items { records[item.id] = item }
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
        for item in items { records[item.id] = item }
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
        let current = records[item.id] ?? item
        if current.answer != nil { return Self.outcome(of: current, replacing: item, in: self) }
        guard current.status == "open" else { return .failed("この判断はすでに閉じられています。") }
        let key = requestIDs[item.id] ?? LAABridgeIdempotencyKey()
        requestIDs[item.id] = key
        return await send(item, path: "/v1/decisions/\(item.id)/answer", key: key, bridge: bridge,
                          body: Self.answerBody(optionIndex: optionIndex, note: note, requestId: key.value))
    }

    func retry(_ item: LAADecision, bridge: LAABridgeSession) async -> Outcome {
        struct Body: Encodable { let requestId: String }
        // Read before retrying: another device or the original request may
        // already have delivered this saved answer.
        if let current = await refreshRecord(item.id, bridge: bridge), current.delivery?.state != "failed" {
            return Self.outcome(of: current, replacing: item, in: self)
        }
        let key = requestIDs[item.id] ?? LAABridgeIdempotencyKey()
        requestIDs[item.id] = key
        return await send(item, path: "/v1/decisions/\(item.id)/retry", key: key, bridge: bridge, body: Body(requestId: key.value))
    }

    private func send<B: Encodable>(_ item: LAADecision, path: String, key: LAABridgeIdempotencyKey,
                                    bridge: LAABridgeSession, body: B) async -> Outcome {
        guard sendingIDs.insert(item.id).inserted else { return .failed("回答を送信中です。") }
        writeRevisions[item.id, default: 0] += 1
        defer {
            sendingIDs.remove(item.id)
            writeRevisions[item.id, default: 0] += 1
        }
        do {
            let data = try JSONEncoder().encode(body)
            let result: LAADecisionAnswerResult = try await LAAWorkHTTP.write(bridge, path: path, body: data, key: key)
            requestIDs[item.id] = nil
            return Self.outcome(of: result.decision, replacing: item, in: self)
        } catch let error as LAABridgeHTTPError {
            // A refusal the Bridge confirms means nothing was recorded; a new
            // request may follow. Anything else keeps the id for a replay.
            if let current = await refreshRecord(item.id, bridge: bridge), current.answer != nil {
                // A failed record may predate an unknown retry. Keep that
                // retry's key until its attempt or delivery is observed.
                if path.hasSuffix("/answer") || ["pending", "stored", "delivered"].contains(current.delivery?.state ?? "")
                    || (current.delivery?.attempts ?? 0) > (item.delivery?.attempts ?? 0) {
                    requestIDs[item.id] = nil
                }
                return Self.outcome(of: current, replacing: item, in: self)
            }
            if !LAAWorkHTTP.outcomeUnknown(error) { requestIDs[item.id] = nil }
            return .failed(LAADecisionCopy.answerError(error))
        } catch {
            if let current = await refreshRecord(item.id, bridge: bridge), current.answer != nil {
                // A failed record may predate an unknown retry. Keep that
                // retry's key until its attempt or delivery is observed.
                if path.hasSuffix("/answer") || ["pending", "stored", "delivered"].contains(current.delivery?.state ?? "")
                    || (current.delivery?.attempts ?? 0) > (item.delivery?.attempts ?? 0) {
                    requestIDs[item.id] = nil
                }
                return Self.outcome(of: current, replacing: item, in: self)
            }
            return .failed(LAADecisionCopy.answerError(error))
        }
    }

    /// Reconcile by reading only. Never replay a production answer to discover
    /// whether a timed-out response was actually accepted.
    func refreshRecord(_ id: String, bridge: LAABridgeSession) async -> LAADecision? {
        guard bridge.status == .paired else { return nil }
        let revision = bridge.revision
        let writeRevision = writeRevisions[id, default: 0]
        guard let record: LAADecision = try? await bridge.read("/v1/decisions/\(id)"),
              !Task.isCancelled, bridge.revision == revision,
              writeRevisions[id, default: 0] == writeRevision else { return nil }
        records[id] = record
        if let index = items.firstIndex(where: { $0.id == id }) { items[index] = record }
        return record
    }

    private static func outcome(of decision: LAADecision, replacing item: LAADecision, in board: LAADecisionBoard) -> Outcome {
        board.records[decision.id] = decision
        switch decision.delivery?.state {
        case "failed", "pending":
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
            return .notDelivered(decision.delivery?.state == "pending"
                                 ? LAADecisionCopy.pending(merged)
                                 : LAADecisionCopy.deliveryError(decision.delivery?.error))
        case "stored": return .done(stored: true)
        case "delivered": return .done(stored: false)
        default: return .failed("送信の結果を確認できません。読み直してください。")
        }
    }
}
#endif
