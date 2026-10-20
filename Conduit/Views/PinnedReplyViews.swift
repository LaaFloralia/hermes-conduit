//
//  PinnedReplyViews.swift
//  Conduit
//
//  Pinned replies (#918): the Pin button under a reply, the bar over the
//  open chat, and the overview of every pinned reply (AppState+PinnedReplies).
//

import SwiftUI

/// Pin or unpin a reply, beside Quote and Read aloud.
struct PinReplyButton: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let message: ChatMessage
    @Environment(\.chatRowState) private var rowState
    @Environment(\.chatRowActions) private var rowActions
    /// Acted on, not observed: what a row shows comes from `rowState`.
    private var appState: AppState { rowActions.required }

    private var isPinned: Bool { rowState.pinnedMessageIDs.contains(message.id) }

    var body: some View {
        Button {
            Haptics.light()
            appState.togglePinnedReply(message)
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.subheadline.weight(.semibold))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isPinned ? Color.conduitAccent : Color.secondary)
        .accessibilityLabel(isPinned
            ? AppLocalization.string("Unpin this response")
            : AppLocalization.string("Pin this response to the top of the chat"))
        .accessibilityIdentifier("chat.pinReply")
    }
}

/// The slim bar over the open chat showing one pinned reply. A tap goes to
/// that reply and moves the bar to the one before it, round to the latest
/// again, as Telegram does; a long press offers Unpin and the overview.
struct PinnedReplyBar: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    /// Oldest first, as the replies sit in the chat.
    let pins: [PinnedReply]
    let jump: (PinnedReply) -> Void
    let unpin: (PinnedReply) -> Void
    let showAll: () -> Void
    /// Into `pins`; nil shows the latest.
    @State private var shownIndex: Int?

    private var index: Int {
        guard let shownIndex else { return pins.count - 1 }
        return min(max(shownIndex, 0), pins.count - 1)
    }

    private var title: String {
        pins.count > 1
            ? AppLocalization.string("Pinned reply \(String(index + 1)) of \(String(pins.count))")
            : AppLocalization.string("Pinned reply")
    }

    var body: some View {
        if let pin = pins.indices.contains(index) ? pins[index] : nil {
            Button {
                Haptics.selection()
                jump(pin)
                shownIndex = PinnedReplies.nextBarIndex(after: index, count: pins.count)
            } label: {
                HStack(spacing: 10) {
                    PinnedReplyBarIndicator(count: pins.count, selected: index)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.conduitAccent)
                        Text(pin.excerpt)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "pin.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            // The transcript scrolls under the bar: a near-solid fill keeps
            // the excerpt readable over it.
            .background(
                Color(uiColor: .systemBackground).opacity(0.88),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .conduitGlassControl(cornerRadius: 14, tint: .conduitAccent.opacity(0.10))
            .contextMenu {
                Button(role: .destructive) {
                    Haptics.light()
                    shownIndex = nil
                    unpin(pin)
                } label: {
                    Label(AppLocalization.string("Unpin"), systemImage: "pin.slash")
                }
                Button {
                    showAll()
                } label: {
                    Label(AppLocalization.string("All pinned replies"), systemImage: "pin")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(title), \(pin.excerpt)"))
            .accessibilityHint(AppLocalization.string("Goes to the pinned reply"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: AppLocalization.string("Unpin")) {
                shownIndex = nil
                unpin(pin)
            }
            .accessibilityAction(named: AppLocalization.string("All pinned replies")) { showAll() }
            .accessibilityIdentifier("chat.pinnedReplyBar")
            // Pins added, removed or reordered (earlier messages loaded):
            // back to the latest, so the index never names another reply.
            .onChange(of: pins.map(\.id)) { _, _ in shownIndex = nil }
        }
    }
}

/// Telegram's segments beside the bar: one per pin, the shown one lit. Past
/// a few pins it draws one bar with the shown position lit.
private struct PinnedReplyBarIndicator: View {
    let count: Int
    let selected: Int

    private static let height: CGFloat = 30
    private static let maxSegments = 4

    var body: some View {
        VStack(spacing: 2) {
            if count <= 1 {
                Capsule().fill(Color.conduitAccent)
            } else {
                let segments = min(count, Self.maxSegments)
                let lit = count <= Self.maxSegments
                    ? selected
                    : Int((Double(selected) / Double(count - 1) * Double(segments - 1)).rounded())
                ForEach(0..<segments, id: \.self) { segment in
                    Capsule()
                        .fill(Color.conduitAccent.opacity(segment == lit ? 1 : 0.3))
                }
            }
        }
        .frame(width: 3, height: Self.height)
        .accessibilityHidden(true)
    }
}

/// Every pinned reply of the profile, a section per chat. A tap opens the
/// chat at the reply.
struct PinnedRepliesSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let sections = PinnedReplies.overview(appState.activePinnedReplies)
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                List {
                    if sections.isEmpty {
                        ContentUnavailableView(
                            AppLocalization.string("No pinned replies"),
                            systemImage: "pin",
                            description: Text(AppLocalization.string("Pin a reply with the pin button under it to keep it at the top of its chat and find it here."))
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    } else {
                        ForEach(sections, id: \.sessionID) { section in
                            Section {
                                ForEach(section.pins) { pin in
                                    row(pin)
                                }
                            } header: {
                                Text(section.pins.first.map(appState.pinnedReplyChatTitle) ?? "")
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.insetGrouped)
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                ConduitSheetHeader(title: AppLocalization.string("Pinned replies"), close: { dismiss() })
            }
        }
        .accessibilityIdentifier("pinnedReplies.sheet")
    }

    private func row(_ pin: PinnedReply) -> some View {
        Button {
            Haptics.selection()
            dismiss()
            // After the sheet goes, so the chat it opens is the one shown.
            DispatchQueue.main.async { appState.showPinnedReply(pin) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(pin.excerpt)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Text(pin.pinnedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                appState.unpinReply(pin)
            } label: {
                Label(AppLocalization.string("Unpin"), systemImage: "pin.slash")
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                appState.unpinReply(pin)
            } label: {
                Label(AppLocalization.string("Unpin"), systemImage: "pin.slash")
            }
        }
        .accessibilityHint(AppLocalization.string("Opens the chat at this reply"))
        .accessibilityAction(named: AppLocalization.string("Unpin")) { appState.unpinReply(pin) }
        .accessibilityIdentifier("pinnedReplies.row")
    }
}
