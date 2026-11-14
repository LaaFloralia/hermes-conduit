#if LAA_BUILD
import Foundation

/// A Chat message whose send outcome the app lost (it stopped before the
/// answer came back) is not a delivery problem when Hermes already holds it.
/// The conversation Hermes keeps is the authority: once its newest saved
/// message from the owner carries the same words, the message arrived, and
/// asking the owner to check and resend would only send it twice (owner,
/// 2026-11-14, after a crash at 21:49).
enum LAAUnknownDelivery {
    /// Hermes stamps rows on the Mac mini and the app reserves on its own
    /// clock; allow for the two clocks disagreeing by a few minutes.
    static let clockSkew: TimeInterval = 300
    /// A reservation saved by an older build has no time. Its words alone
    /// identify it only when they are long enough not to repeat by chance.
    static let distinctiveLength = 20

    /// Hermes's saved conversation holds the message reserved at
    /// `reservedAt` with the words `draftText`. Later turns, the owner's next
    /// messages and background notices may follow it, so the saved copy need
    /// not be the newest owner row (MacBook, 2026-11-15: a 20:11 message
    /// kept the warning after an hour of later turns). A reply quote or a side
    /// agent's command can lead the persisted text, so the words may end it.
    static func landed(_ draftText: String, reservedAt: Date? = nil,
                       messages: [ChatMessage], durableIDs: Set<String>) -> Bool {
        let words = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return false }
        let owned = messages.filter { $0.role == .user && durableIDs.contains($0.id) }
        let carrying = owned.filter { carries($0.content, words) }
        guard !carrying.isEmpty else { return false }
        if let reservedAt {
            let earliest = reservedAt.addingTimeInterval(-clockSkew)
            let dated = carrying.compactMap { MessageTimestampFormatter.date(from: $0.timestamp) }
            if !dated.isEmpty { return dated.contains { $0.timeIntervalSince(earliest) >= 0 } }
        }
        if let newest = owned.last, carrying.last?.id == newest.id { return true }
        return words.count >= distinctiveLength
    }

    private static func carries(_ content: String, _ words: String) -> Bool {
        let row = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return row == words || row.hasSuffix("\n" + words) || row.hasSuffix(" " + words)
    }
}
#endif
