#if LAA_BUILD
import SwiftUI
import UIKit

/// Duet's page in Chat: not a conversation. Duet's answers, morning brief
/// and alerts live in Duet's own app; this page says so, keeps a draft and
/// hands it over with one tap ("Duetで開く"). Once the LAA connector is set
/// up on the Mac (`feed.configured`), the same draft can instead be left as
/// a note Duet reads when it next uses the connector, and what Duet wrote
/// through the connector is listed below, as plain text.
struct LAADuetView: View {
    var feed: LAADuetFeed? = nil
    var leaveNote: ((String) async -> Bool)? = nil
    @Environment(\.openURL) private var openURL
    @Environment(\.laaDesktop) private var laaDesktop
    @AppStorage("laa.duet.draft") private var draft = ""
    @State private var copied = false
    @State private var noteLeft = false
    @FocusState private var editing: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x6) {
                header
                composer
                Text(verbatim: status)
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("laa.duet.status")
                Button(action: handOff) {
                    Text(verbatim: LAACopy.duetOpen)
                }
                .laaButton(.primary)
                .accessibilityHint(Text(verbatim: LAADuet.handoffText(draft) == nil ? "" : LAACopy.duetOpenHint))
                .accessibilityIdentifier("laa.duet.open")
                if let feed, feed.configured { connector(feed) }
            }
            .frame(maxWidth: laaDesktop ? 560 : .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, LAASpacing.x3)
            .padding(.bottom, LAASpacing.x8)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(LAAColor.background.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: draft) { _, new in
            // Clearing the draft after a note keeps "メモを残しました" on screen.
            if !new.isEmpty { copied = false; noteLeft = false }
        }
        .accessibilityIdentifier("laa.duet.page")
    }

    private var status: String {
        if copied { return LAACopy.duetCopied }
        if noteLeft { return LAACopy.duetNoteLeft }
        if let error = feed?.noteError { return error }
        return feed?.configured == true ? LAACopy.duetHowItWorksConnected : LAACopy.duetHowItWorks
    }

    @ViewBuilder
    private func connector(_ feed: LAADuetFeed) -> some View {
        Button(action: note) { Text(verbatim: LAACopy.duetLeaveNote) }
            .laaButton(.secondary)
            .disabled(LAADuet.handoffText(draft) == nil || feed.sending || leaveNote == nil)
            .accessibilityHint(Text(verbatim: LAACopy.duetLeaveNoteHint))
            .accessibilityIdentifier("laa.duet.note")
        if !feed.notes.isEmpty {
            VStack(alignment: .leading, spacing: LAASpacing.x2) {
                LAASectionHeader(LAACopy.duetNotesTitle)
                LAADuetNotesList(notes: feed.notes)
            }
        }
        if !feed.items.isEmpty {
            VStack(alignment: .leading, spacing: LAASpacing.x2) {
                LAASectionHeader(LAACopy.duetItemsTitle)
                Text(verbatim: LAACopy.duetItemsHow).laaTextStyle(.secondary)
                    .foregroundStyle(LAAColor.secondaryText).fixedSize(horizontal: false, vertical: true)
                LAADuetItemsList(items: feed.items)
            }
            .accessibilityIdentifier("laa.duet.items")
        }
    }

    private func note() {
        guard let leaveNote else { return }
        editing = false
        let text = draft
        Task {
            if await leaveNote(text) {
                draft = ""
                noteLeft = true
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: LAASpacing.x3) {
            LAADuetMark(size: 48)
            VStack(alignment: .leading, spacing: LAASpacing.x1) {
                Text(verbatim: LAADuet.name).font(LAAType.title(LAADuet.name, size: 28, relativeTo: .title))
                    .foregroundStyle(LAAColor.text)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: LAACopy.duetRole).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            TextField(text: $draft, axis: .vertical) {
                Text(verbatim: LAACopy.duetPlaceholder)
            }
            .font(Self.readingFont)
            .foregroundStyle(LAAColor.text)
            .lineLimit(4...12)
            .focused($editing)
            .accessibilityLabel(Text(verbatim: LAACopy.duetPlaceholder))
            .accessibilityIdentifier("laa.duet.draft")
            Rectangle().fill(LAAColor.separator).frame(height: 1)
        }
    }

    private static var readingFont: Font {
        LAAReadingStyle.uiFont(size: LAAReadingStyle.bodySize()).map { Font($0) } ?? .body
    }

    private func handOff() {
        editing = false
        copied = LAADuet.handOff(draft) { openURL($0) }
    }
}

/// Anthropic's Claude mark as issued (`LAAClaudeMark`, unaltered, original
/// colours) on a paper disc with clear space on every side: the same mark
/// Chat's model faces use (Anthropic Trademark Guidelines: no alteration,
/// a background that keeps it legible, space around it, no ™).
struct LAADuetMark: View {
    var size: CGFloat
    var body: some View {
        LAAModelMark(model: "claude", provider: "anthropic", size: size)
    }
}
#endif
