#if LAA_BUILD
import Foundation

/// A Chat message whose send outcome the app lost (it stopped before the
/// answer came back) is not a delivery problem when Hermes already holds it.
/// The conversation Hermes keeps is the authority: once its newest saved
/// message from the owner carries the same words, the message arrived, and
/// asking the owner to check and resend would only send it twice (owner,
/// 2026-11-14, after a crash at 21:49).
enum LAAUnknownDelivery {
    /// The newest persisted owner row carries `draftText`. A reply quote or a
    /// side agent's command can lead the persisted text, so the words may end
    /// it rather than fill it.
    static func landed(_ draftText: String, messages: [ChatMessage], durableIDs: Set<String>) -> Bool {
        let words = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty,
              let last = messages.last(where: { $0.role == .user && durableIDs.contains($0.id) }) else { return false }
        let row = last.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return row == words || row.hasSuffix("\n" + words) || row.hasSuffix(" " + words)
    }
}
#endif
