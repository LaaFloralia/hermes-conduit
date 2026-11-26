#if LAA_BUILD
import SwiftUI

/// The live Duet page: Stage 1's hand-off page plus, once the LAA connector
/// is set up on the Mac, what Duet wrote and the notes left for it.
struct LAADuetScreen: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @State private var feed = LAADuetFeed.shared

    var body: some View {
        LAADuetView(feed: feed, leaveNote: { await feed.leaveNote($0, bridge: bridge) })
            .task(id: bridge.revision) { await feed.load(bridge) }
            .refreshable { await feed.load(bridge) }
    }
}

/// Notes the owner left for Duet's next connector call. Plain text only.
struct LAADuetNotesList: View {
    let notes: [LAADuetNote]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(notes.prefix(5)) { note in
                VStack(alignment: .leading, spacing: LAASpacing.x1) {
                    HStack(spacing: LAASpacing.x2) {
                        Text(verbatim: LAADuetFormat.state(note.state)).laaTextStyle(.note)
                            .foregroundStyle(note.state == .read ? LAAColor.text : LAAColor.secondaryText)
                        Text(verbatim: LAADuetFormat.time(note.createdAt)).laaTextStyle(.note)
                            .foregroundStyle(LAAColor.secondaryText)
                    }
                    Text(verbatim: note.text).laaTextStyle(.body).foregroundStyle(LAAColor.text)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, LAASpacing.x3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                Rectangle().fill(LAAColor.separator).frame(height: 1)
            }
        }
        .accessibilityIdentifier("laa.duet.notes")
    }
}

/// What Duet posted through the connector. Untrusted: every field is shown
/// verbatim as text; a link is offered only when it is https.
struct LAADuetItemsList: View {
    let items: [LAADuetItem]
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: LAASpacing.x1) {
                    HStack(spacing: LAASpacing.x2) {
                        Text(verbatim: LAADuetFormat.kind(item.kind)).laaTextStyle(.note)
                            .foregroundStyle(item.kind == .needsOwner ? LAAColor.text : LAAColor.secondaryText)
                        Text(verbatim: LAADuetFormat.time(item.createdAt)).laaTextStyle(.note)
                            .foregroundStyle(LAAColor.secondaryText)
                    }
                    Text(verbatim: item.title).laaTextStyle(.rowTitle).foregroundStyle(LAAColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if !item.body.isEmpty {
                        Text(verbatim: item.body).laaTextStyle(.body).foregroundStyle(LAAColor.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if let url = item.safeLink {
                        Button { openURL(url) } label: {
                            Text(verbatim: url.host() ?? url.absoluteString).lineLimit(1)
                        }
                        .laaButton(.text)
                        .accessibilityHint(Text(verbatim: url.absoluteString))
                    }
                }
                .padding(.vertical, LAASpacing.x3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("laa.duet.item.\(item.id)")
                Rectangle().fill(LAAColor.separator).frame(height: 1)
            }
        }
    }
}

enum LAADuetFormat {
    static func kind(_ kind: LAADuetItem.Kind) -> String {
        switch kind {
        case .brief: "Brief"
        case .update: "Update"
        case .done: "Done"
        case .needsOwner: "Needs you"
        case .other: "Note"
        }
    }

    static func state(_ state: LAADuetNote.State) -> String {
        switch state {
        case .queued: "Waiting"
        case .sent: "Sent"
        case .read: "Read"
        }
    }

    /// "11/26 08:05" in the device's zone; an unreadable stamp shows nothing.
    static func time(_ stamp: String, calendar: Calendar = .current) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp) else { return "" }
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        return String(format: "%d/%d %02d:%02d", parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
    }
}
#endif
