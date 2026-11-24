#if LAA_BUILD
import SwiftUI

/// Transcript seam: live reasoning/status is a single muted line on the
/// canvas, not a message bubble. The orb keeps its existing records action.
struct LAAChatLiveThoughtRow: View {
    let startedAt: Date?
    let records: [ChatMessage]
    let state: LAAOrbState
    let phrase: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x1) {
            LAATypingDots(startedAt: startedAt, records: records, state: state, phrase: phrase)
            if let detail, !detail.isEmpty {
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(LAAColor.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .accessibilityIdentifier("chat.thought.live")
            }
        }
    }
}
#endif
