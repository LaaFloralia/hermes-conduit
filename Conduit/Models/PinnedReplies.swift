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
    /// The transcript row a pin shows, or nil when the reply isn't loaded
    /// (an older part of a long chat).
    static func messageID(for pin: PinnedReply, in messages: [ChatMessage]) -> String? {
        // A durable id is exact: look for it first, so a reply with the
        // same opening words further down never wins.
        if let rowId = pin.rowId {
            return messages.first(where: { $0.role == .assistant && $0.rowId == rowId })?.id
        }
        if let exact = messages.first(where: { pin.isExactly($0) }) { return exact.id }
        // Replies that open the same way: a pin without a durable id was
        // made recently, so the latest one is the likelier.
        return messages.last(where: { pin.matchesText(of: $0) })?.id
    }

    /// The rows of `messages` that are pinned, for the rows' Pin buttons.
    static func pinnedMessageIDs(_ pins: [PinnedReply], in messages: [ChatMessage]) -> Set<String> {
        guard !pins.isEmpty else { return [] }
        return Set(pins.compactMap { messageID(for: $0, in: messages) })
    }

    /// The pin that is `message` in this transcript, if any: the pin whose
    /// reply resolves to it, so a second reply reading like a pinned one is
    /// not taken for it.
    static func pin(for message: ChatMessage, in pins: [PinnedReply], messages: [ChatMessage]) -> PinnedReply? {
        pins.first { messageID(for: $0, in: messages) == message.id }
    }

    /// The pins with the ids their rows have now: a reply pinned as it
    /// arrived takes its durable id once the transcript has it, so a later
    /// reload finds it exactly. Nil when nothing changed.
    static func refreshed(_ pins: [PinnedReply], in messages: [ChatMessage]) -> [PinnedReply]? {
        var changed = false
        let refreshed = pins.map { pin -> PinnedReply in
            guard let id = messageID(for: pin, in: messages),
                  let message = messages.first(where: { $0.id == id }) else { return pin }
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
        let placed = pins.enumerated().map { offset, pin -> (pin: PinnedReply, index: Int?, offset: Int) in
            (pin, messageID(for: pin, in: messages).flatMap { position[$0] }, offset)
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
