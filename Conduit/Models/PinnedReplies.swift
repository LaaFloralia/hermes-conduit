//
//  PinnedReplies.swift
//  Conduit
//
//  Replies pinned to the top of their chat (#918), like a pinned message in
//  Telegram or WhatsApp: a long answer worked through point by point stays
//  one tap away however far the chat has moved on. Pins are kept on this
//  device, per profile. Pure list shaping, so finding a pin's row in a
//  transcript and the bar's order stay testable without a view.
//

import Foundation

/// One pinned reply. Saved with enough of the reply to show it in the bar
/// and the overview before its chat is open, and to find it again after
/// the transcript reloads.
struct PinnedReply: Codable, Equatable, Identifiable, Hashable {
    let id: String
    /// The chat it was pinned in: the chat's row id when it had one, else
    /// its durable id, else the open session's id. A pin made before the
    /// chat had a row moves to the row's id once it has one.
    var sessionID: String
    /// Hermes' durable `messages.id`, once the row has one. A reply pinned
    /// as it arrived gets it when the transcript reloads.
    var rowId: Int?
    /// The transcript row's id when it was pinned (or last found).
    var messageID: String
    /// The start of the reply, whitespace folded, for the bar and the list.
    /// It also finds the reply again when neither id matches any more.
    let excerpt: String
    /// The chat's title when it was pinned; the overview shows the current
    /// one while the chat is in the list.
    var chatTitle: String
    let pinnedAt: Date

    /// How much of a reply a pin keeps.
    static let excerptLength = 280

    init(
        id: String = UUID().uuidString,
        sessionID: String,
        message: ChatMessage,
        chatTitle: String,
        pinnedAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.rowId = message.rowId
        self.messageID = message.id
        self.excerpt = Self.excerpt(of: message.content)
        self.chatTitle = chatTitle
        self.pinnedAt = pinnedAt
    }

    /// The reply's text on one line, cut to `excerptLength`. Reads only as
    /// much of a long reply as the excerpt needs.
    static func excerpt(of content: String) -> String {
        var folded = ""
        var pendingSpace = false
        for character in content {
            if character.isWhitespace {
                pendingSpace = !folded.isEmpty
                continue
            }
            if pendingSpace {
                folded.append(" ")
                pendingSpace = false
            }
            folded.append(character)
            if folded.count >= excerptLength { break }
        }
        return String(folded.prefix(excerptLength))
    }

    /// Whether `message` is the reply this pin was made on, by id alone.
    func isExactly(_ message: ChatMessage) -> Bool {
        guard message.role == .assistant else { return false }
        if let rowId, let other = message.rowId { return rowId == other }
        return message.id == messageID
    }

    /// Whether `message` reads as this pin's reply: the fallback for a reply
    /// pinned before it had a durable id, which a reload gave a new row id.
    func matchesText(of message: ChatMessage) -> Bool {
        guard rowId == nil, message.role == .assistant, !excerpt.isEmpty else { return false }
        return Self.excerpt(of: message.content) == excerpt
    }
}

enum PinnedReplies {
    /// The transcript row each pin shows, by pin id; a pin whose reply
    /// isn't loaded (an older part of a long chat) has none. Resolved in one
    /// pass so no two pins land on the same reply: ids claim their rows
    /// first, then a pin matched by its text takes the latest reply reading
    /// that way that no other pin has, the newest pin first.
    static func resolved(_ pins: [PinnedReply], in messages: [ChatMessage]) -> [String: String] {
        guard !pins.isEmpty else { return [:] }
        var result: [String: String] = [:]
        var claimed = Set<String>()
        for pin in pins where result[pin.id] == nil {
            // A durable id is exact: a reply with the same opening words
            // never wins over it.
            let exact: ChatMessage?
            if let rowId = pin.rowId {
                exact = messages.first { $0.role == .assistant && $0.rowId == rowId }
            } else {
                exact = messages.first { pin.isExactly($0) }
            }
            if let exact, !claimed.contains(exact.id) {
                result[pin.id] = exact.id
                claimed.insert(exact.id)
            }
        }
        // Replies that open the same way: a pin without a durable id was
        // made recently, so the latest reply is the likelier, and the
        // newest pin gets it.
        let byText = pins.enumerated()
            .filter { result[$0.element.id] == nil && $0.element.rowId == nil }
            .sorted { lhs, rhs in
                lhs.element.pinnedAt == rhs.element.pinnedAt
                    ? lhs.offset > rhs.offset
                    : lhs.element.pinnedAt > rhs.element.pinnedAt
            }
            .map(\.element)
        for pin in byText {
            guard let match = messages.last(where: { !claimed.contains($0.id) && pin.matchesText(of: $0) })
            else { continue }
            result[pin.id] = match.id
            claimed.insert(match.id)
        }
        return result
    }

    /// The transcript row `pin` shows among `pins` (the chat's other pins,
    /// which may already have claimed a reply reading the same), or nil
    /// when the reply isn't loaded.
    static func messageID(
        for pin: PinnedReply,
        in messages: [ChatMessage],
        among pins: [PinnedReply] = []
    ) -> String? {
        let all = pins.contains(where: { $0.id == pin.id }) ? pins : pins + [pin]
        return resolved(all, in: messages)[pin.id]
    }

    /// The rows of `messages` that are pinned.
    static func pinnedMessageIDs(_ pins: [PinnedReply], in messages: [ChatMessage]) -> Set<String> {
        Set(resolved(pins, in: messages).values)
    }

    /// The pin that is `message` in this transcript, if any: the pin whose
    /// reply resolves to it, so a second reply reading like a pinned one is
    /// not taken for it.
    static func pin(for message: ChatMessage, in pins: [PinnedReply], messages: [ChatMessage]) -> PinnedReply? {
        let ids = resolved(pins, in: messages)
        return pins.first { ids[$0.id] == message.id }
    }

    /// The pins with the ids their rows have now: a reply pinned as it
    /// arrived takes its durable id once the transcript has it, so a later
    /// reload finds it exactly. Nil when nothing changed.
    static func refreshed(_ pins: [PinnedReply], in messages: [ChatMessage]) -> [PinnedReply]? {
        let ids = resolved(pins, in: messages)
        guard !ids.isEmpty else { return nil }
        var byID: [String: ChatMessage] = [:]
        for message in messages { byID[message.id] = message }
        var changed = false
        let refreshed = pins.map { pin -> PinnedReply in
            guard let id = ids[pin.id], let message = byID[id] else { return pin }
            var updated = pin
            if updated.rowId == nil, let rowId = message.rowId { updated.rowId = rowId }
            if updated.messageID != message.id { updated.messageID = message.id }
            if updated != pin { changed = true }
            return updated
        }
        return changed ? refreshed : nil
    }

    /// The bar's order, oldest first, as the replies sit in the chat. A pin
    /// whose reply isn't loaded is further back, so it comes first; those
    /// keep the order they were pinned in.
    static func barOrder(_ pins: [PinnedReply], in messages: [ChatMessage]) -> [PinnedReply] {
        guard pins.count > 1 else { return pins }
        var position: [String: Int] = [:]
        for (index, message) in messages.enumerated() { position[message.id] = index }
        let ids = resolved(pins, in: messages)
        let placed = pins.enumerated().map { offset, pin -> (pin: PinnedReply, index: Int?, offset: Int) in
            (pin, ids[pin.id].flatMap { position[$0] }, offset)
        }
        return placed.sorted { lhs, rhs in
            switch (lhs.index, rhs.index) {
            case let (l?, r?): return l < r
            case (nil, _?): return true
            case (_?, nil): return false
            case (nil, nil):
                return lhs.pin.pinnedAt == rhs.pin.pinnedAt
                    ? lhs.offset < rhs.offset
                    : lhs.pin.pinnedAt < rhs.pin.pinnedAt
            }
        }.map(\.pin)
    }

    /// The bar's next pin after jumping to `current` (an index into the bar's
    /// order): the one before it in the chat, back to the latest after the
    /// first, as Telegram cycles.
    static func nextBarIndex(after current: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let clamped = min(max(current, 0), count - 1)
        return clamped == 0 ? count - 1 : clamped - 1
    }

    /// The overview: a section per chat, the chat with the latest pin
    /// first, each chat's pins newest first.
    static func overview(_ pins: [PinnedReply]) -> [(sessionID: String, pins: [PinnedReply])] {
        var bySession: [String: [PinnedReply]] = [:]
        var order: [String] = []
        for pin in pins {
            if bySession[pin.sessionID] == nil { order.append(pin.sessionID) }
            bySession[pin.sessionID, default: []].append(pin)
        }
        let sections = order.map { id in
            (sessionID: id, pins: bySession[id, default: []].sorted { $0.pinnedAt > $1.pinnedAt })
        }
        return sections.sorted { lhs, rhs in
            (lhs.pins.first?.pinnedAt ?? .distantPast) > (rhs.pins.first?.pinnedAt ?? .distantPast)
        }
    }
}

/// A pinned reply to scroll to once its chat's transcript has it.
struct PinnedReplyReveal: Equatable {
    let pin: PinnedReply
    /// The chat being opened for it; nil when it's the open chat.
    let opening: String?
    let expires: Date

    init(pin: PinnedReply, opening: String? = nil, now: Date = Date()) {
        self.pin = pin
        self.opening = opening
        // As ArtifactReveal: a chat that takes long to open doesn't jump
        // later, out of nowhere.
        self.expires = now.addingTimeInterval(20)
    }
}
