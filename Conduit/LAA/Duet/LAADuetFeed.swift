#if LAA_BUILD
import Foundation
import Observation

/// What Claude Duet wrote into Hortensia through the owner-connected LAA
/// connector, and the notes the owner left for Duet's next check. The Mac
/// mini's Bridge pulls the items from the connector; nothing here talks to
/// Duet. Every field is untrusted text from outside LAA: it is shown as
/// plain text and never acted on.
struct LAADuetItem: Decodable, Equatable, Identifiable, Sendable {
    enum Kind: String, Decodable, Sendable { case brief, update, done, needsOwner = "needs_owner", other }
    let id: String
    let kind: Kind
    let title: String
    let body: String
    let link: String?
    let createdAt: String

    init(id: String, kind: Kind, title: String, body: String, link: String? = nil, createdAt: String) {
        self.id = id; self.kind = kind; self.title = title; self.body = body; self.link = link; self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        enum Key: String, CodingKey { case id, kind, title, body, link, createdAt }
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .other
        title = try c.decode(String.self, forKey: .title)
        body = (try? c.decode(String.self, forKey: .body)) ?? ""
        link = try? c.decodeIfPresent(String.self, forKey: .link)
        createdAt = (try? c.decode(String.self, forKey: .createdAt)) ?? ""
    }

    /// Only an https link is offered, and only as a link to open outside.
    var safeLink: URL? {
        guard let link, let url = URL(string: link), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}

struct LAADuetNote: Decodable, Equatable, Identifiable, Sendable {
    enum State: String, Decodable, Sendable { case queued, sent, read }
    let id: String
    let text: String
    let createdAt: String
    let state: State
}

struct LAADuetItemsPage: Decodable, Sendable {
    struct Status: Decodable, Sendable { let configured: Bool }
    let items: [LAADuetItem]
    let status: Status
}

@MainActor @Observable
final class LAADuetFeed {
    enum Phase: Equatable { case idle, loaded, unavailable }
    private(set) var items: [LAADuetItem] = []
    private(set) var notes: [LAADuetNote] = []
    /// The connector is set up on the Mac: only then is the feed shown.
    private(set) var configured = false
    private(set) var phase: Phase = .idle
    private(set) var sending = false
    private(set) var noteError: String?

    static let shared = LAADuetFeed()

    /// A Bridge without these routes, or without the connector set up,
    /// leaves the page as Stage 1: no section, no apology.
    func load(_ bridge: LAABridgeSession) async {
        guard bridge.status == .paired else { phase = .idle; configured = false; return }
        do {
            let page: LAADuetItemsPage = try await bridge.read("/v1/duet/items?limit=50")
            let notes: [LAADuetNote] = page.status.configured ? (try await bridge.read("/v1/duet/notes")) : []
            items = page.items
            self.notes = notes
            configured = page.status.configured
            phase = .loaded
        } catch is CancellationError {
        } catch {
            if items.isEmpty { configured = false }
            phase = .unavailable
        }
    }

    /// Leaves the note for Duet's next check. Returns whether the Mac took it.
    func leaveNote(_ text: String, bridge: LAABridgeSession) async -> Bool {
        guard let text = LAADuet.handoffText(text), !sending else { return false }
        struct Body: Encodable { let text: String }
        struct Result: Decodable { let id: String; let state: LAADuetNote.State }
        sending = true
        noteError = nil
        defer { sending = false }
        do {
            let body = try JSONEncoder().encode(Body(text: String(text.prefix(LAADuet.noteLimit))))
            let result: Result = try await LAAWorkHTTP.write(bridge, path: "/v1/duet/notes", body: body,
                                                             key: LAABridgeIdempotencyKey())
            notes.insert(LAADuetNote(id: result.id, text: text, createdAt: ISO8601DateFormatter().string(from: Date()),
                                     state: result.state), at: 0)
            return true
        } catch is CancellationError {
            return false
        } catch {
            noteError = LAACopy.duetNoteFailed
            return false
        }
    }

    #if DEBUG
    func setForTesting(items: [LAADuetItem], notes: [LAADuetNote], configured: Bool = true) {
        self.items = items; self.notes = notes; self.configured = configured; phase = .loaded
    }
    #endif
}
#endif
