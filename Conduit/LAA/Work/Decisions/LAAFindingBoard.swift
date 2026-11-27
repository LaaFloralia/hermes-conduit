#if LAA_BUILD
import Foundation
import SwiftUI

/// The Findings side of the board (D-18): read `GET /v1/findings`, hand one
/// to Monet or let it go. Nothing here stops a session or sends a notice.
@MainActor final class LAAFindingBoard: ObservableObject {
    enum Phase: Equatable { case idle, loaded, unsupported, failed(String) }

    @Published private(set) var items: [LAAFinding] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var loading = false
    /// A delegate or dismiss the Bridge did not take; shown above the list.
    @Published var failure: String?
    @Published private(set) var sendingIDs = Set<String>()

    private var loadedAt: Date?
    private var loadsStarted = 0
    /// Dismissed from this device: a read that crossed the dismissal must not
    /// bring the row back.
    private var dismissedHere = Set<String>()
    /// Changed from this device while a read was under way.
    private var writeRevision = 0

    /// Open and delegated, the menu's number; nil until the first read.
    var count: Int? { phase == .loaded ? items.filter(\.counts).count : nil }

    func reset() {
        items = []; phase = .idle; loadedAt = nil; dismissedHere = []; failure = nil
    }

    func refreshIfStale(_ bridge: LAABridgeSession) async {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < 5, phase == .loaded { return }
        await load(bridge)
    }

    func load(_ bridge: LAABridgeSession) async {
        guard bridge.status == .paired else { items = []; phase = .idle; return }
        loading = true
        defer { loading = false }
        loadsStarted += 1
        let start = loadsStarted, revision = writeRevision
        do {
            let page: LAAFindingPage = try await bridge.read("/v1/findings")
            guard start == loadsStarted, revision == writeRevision else { return }
            apply(page.items)
            loadedAt = Date()
        } catch is CancellationError {
        } catch let error as LAABridgeError {
            if case .other(status: 404, code: _) = error { items = []; phase = .unsupported }
            else { phase = .failed(error.japaneseText) }
        } catch {
            phase = .failed(LAABridgeError.invalidResponse.japaneseText)
        }
    }

    private func apply(_ fresh: [LAAFinding]) {
        items = Self.visible(fresh, dismissedHere: dismissedHere)
        phase = .loaded
    }

    /// One read's rows: known listed states only, minus what this device let go.
    static func visible(_ items: [LAAFinding], dismissedHere: Set<String>) -> [LAAFinding] {
        LAAFindingOrder.sorted(items.filter { $0.listed && !dismissedHere.contains($0.id) })
    }

    /// Open → delegated. The row stays and reads 「Monetが対応中」.
    @discardableResult
    func delegate(_ item: LAAFinding, bridge: LAABridgeSession) async -> Bool {
        guard item.isOpen, LAAFinding.validID(item.id), sendingIDs.insert(item.id).inserted else { return false }
        defer { sendingIDs.remove(item.id) }
        failure = nil
        writeRevision += 1
        do {
            let result: LAAFindingResult = try await post(bridge, path: "/v1/findings/\(item.id)/delegate")
            replace(result.finding.id == item.id ? result.finding : item.with(status: .delegated))
            return true
        } catch {
            failure = LAAFindingCopy.actionError(error)
            return false
        }
    }

    /// Open → dismissed. The row leaves at once and comes back if the Bridge refuses.
    @discardableResult
    func dismiss(_ item: LAAFinding, bridge: LAABridgeSession) async -> Bool {
        guard item.isOpen, LAAFinding.validID(item.id), sendingIDs.insert(item.id).inserted else { return false }
        defer { sendingIDs.remove(item.id) }
        failure = nil
        writeRevision += 1
        let snapshot = items
        dismissedHere.insert(item.id)
        items.removeAll { $0.id == item.id }
        do {
            let _: LAAFindingResult = try await post(bridge, path: "/v1/findings/\(item.id)/dismiss")
            return true
        } catch {
            dismissedHere.remove(item.id)
            items = Self.restored(snapshot, current: items, id: item.id)
            failure = LAAFindingCopy.actionError(error)
            return false
        }
    }

    /// The list after a refused dismissal: the row back in its place, with
    /// whatever else changed meanwhile kept.
    static func restored(_ before: [LAAFinding], current: [LAAFinding], id: String) -> [LAAFinding] {
        guard let row = before.first(where: { $0.id == id }), !current.contains(where: { $0.id == id }) else { return current }
        return LAAFindingOrder.sorted(current + [row])
    }

    private func replace(_ record: LAAFinding) {
        if !record.listed { items.removeAll { $0.id == record.id }; return }
        if let index = items.firstIndex(where: { $0.id == record.id }) { items[index] = record }
        else { items = LAAFindingOrder.sorted(items + [record]) }
    }

    private func post<T: Decodable>(_ bridge: LAABridgeSession, path: String) async throws -> T {
        guard bridge.status == .paired else { throw LAABridgeError.invalidResponse }
        // Both routes are idempotent by state, so a fresh key per press is safe.
        return try await LAAWorkHTTP.write(bridge, path: path, body: Data("{}".utf8), key: LAABridgeIdempotencyKey())
    }

    #if DEBUG
    /// Snapshot and unit tests set a state directly.
    func setForTesting(_ items: [LAAFinding], phase: Phase = .loaded) {
        self.items = Self.visible(items, dismissedHere: dismissedHere); self.phase = phase
    }

    /// Unit tests: the optimistic half of `dismiss`, then its refusal or success.
    func dismissLocallyForTesting(_ id: String) -> [LAAFinding] {
        let snapshot = items
        dismissedHere.insert(id); items.removeAll { $0.id == id }
        return snapshot
    }

    func refuseDismissForTesting(_ id: String, snapshot: [LAAFinding]) {
        dismissedHere.remove(id)
        items = Self.restored(snapshot, current: items, id: id)
    }

    func finishLoadForTesting(_ items: [LAAFinding]) { apply(items) }
    #endif
}
#endif
