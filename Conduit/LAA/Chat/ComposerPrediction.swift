import Foundation

/// What the composer offers above the input line: the owner's own recent
/// sentences from this conversation, then staff names. Pure functions only —
/// display, focus and IME checks stay in the view, and insertion goes through
/// the existing single write path (`ComposerBar.replaceComposerText`).
///
/// Deliberately never competes with the IME: while text is marked (converting)
/// no candidate is returned at all, and mid-sentence drafts stay quiet.
enum ComposerPrediction {
    struct Candidate: Equatable, Identifiable {
        /// The exact text inserted at the caret.
        let text: String
        /// What the row shows; equals `text` for recent sentences.
        let title: String

        var id: String { text }
    }

    /// Longest sentence head we offer, in characters.
    static let maxHeadLength = 80
    /// How many recent sentences we consider.
    static let maxRecent = 20

    /// Local, device-only switch, backed by @AppStorage like
    /// `ComposerReturnKey.preferenceKey`. Off restores the plain composer.
    static let preferenceKey = "laa.composerPrediction"

    /// The row is on until this device turns it off.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: preferenceKey) as? Bool ?? true
    }

    /// Whether the draft is at a boundary where a prediction may appear:
    /// empty, or ending in sentence punctuation or a newline. A draft that is
    /// mid-sentence keeps the row hidden so it never competes with the IME.
    static func isAtBoundary(_ text: String) -> Bool {
        guard let last = text.last else { return true }
        if last.isNewline { return true }
        return "。．.!?！？".contains(last)
    }

    /// Recent sentences from `sentences` (newest first), de-duplicated,
    /// trimmed to `maxHeadLength`, capped at `maxRecent`.
    static func recentCandidates(_ sentences: [String]) -> [Candidate] {
        var seen = Set<String>()
        var result: [Candidate] = []
        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let head = String(trimmed.prefix(maxHeadLength))
            guard seen.insert(head).inserted else { continue }
            result.append(Candidate(text: head, title: head))
            if result.count >= maxRecent { break }
        }
        return result
    }

    /// Recent sentences first, then names, minus entries whose text is
    /// already a recent sentence. Empty while the IME has marked text.
    static func candidates(
        draft: String,
        recentSentences: [String],
        names: [String],
        isComposing: Bool
    ) -> [Candidate] {
        guard !isComposing, isAtBoundary(draft) else { return [] }
        let recent = recentCandidates(recentSentences)
        var seen = Set(recent.map(\.text))
        var result = recent
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(Candidate(text: trimmed, title: trimmed))
        }
        return result
    }

    /// The draft with `candidate` appended at the end, spaced off unless the
    /// draft is empty or already ends in whitespace.
    static func inserting(_ draft: String, with candidate: Candidate) -> String {
        let separator = draft.isEmpty || draft.last?.isWhitespace == true ? "" : " "
        return draft + separator + candidate.text
    }
}
