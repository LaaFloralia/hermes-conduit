#if LAA_BUILD
import SwiftUI

/// Transcript seam: live reasoning/status is the shared transcript's one
/// muted thought line on the canvas, never a message bubble. While reasoning
/// streams, the line carries its newest words; otherwise the status phrase.
struct LAAChatLiveThoughtRow: View {
    let phrase: String
    let detail: String?
    var isLive = true
    var state: LAAOrbState = .thinking

    var body: some View {
        let live = Self.liveLine(detail)
        LAAThoughtLine(text: live ?? phrase, isLive: isLive, state: state, streams: live != nil)
            .accessibilityIdentifier(live == nil ? "chat.thought.status" : "chat.thought.live")
    }

    /// The newest non-empty line of the reasoning so far, on one line.
    static func liveLine(_ detail: String?) -> String? {
        guard let detail else { return nil }
        guard let last = detail.split(whereSeparator: \.isNewline).last(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return nil }
        let line = last.trimmingCharacters(in: .whitespaces)
        return line.count > 160 ? String(line.suffix(160)) : line
    }
}
#endif
