#if LAA_BUILD
import SwiftUI
import UIKit

/// A message put into the follow-up field as a Markdown quote. The token makes
/// quoting the same message twice a second request.
struct LAAWorkQuoteRequest: Equatable {
    let text: String
    let token: Int

    /// The quoted lines, each behind "> ", cut at a readable length so a long
    /// reply does not fill the field; then an empty line for the owner's words.
    static func markdown(_ source: String, limit: Int = 400) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let cut = trimmed.count > limit ? String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : trimmed
        return cut.components(separatedBy: .newlines).map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n") + "\n\n"
    }

    /// Where the quote goes: at the end of what is already typed, after a
    /// blank line, so a draft in progress is never overwritten.
    static func inserting(_ quote: String, into draft: String) -> String {
        guard !quote.isEmpty else { return draft }
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return quote }
        return draft.hasSuffix("\n\n") ? draft + quote : draft.trimmingCharacters(in: .newlines) + "\n\n" + quote
    }
}

/// The owner's good marks on Work replies. The Bridge has no feedback route, so
/// the mark stays on this device: it is the owner's own bookmark, and nothing
/// is sent to the model.
enum LAAWorkLikes {
    static let storageKey = "laa.work.likes.v1"
    /// Old marks fall off past this many, oldest first.
    static let capacity = 500

    static func key(session: String, message: String) -> String { session + "/" + message }

    static func decode(_ raw: String) -> [String] {
        raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    static func toggled(_ raw: String, key: String) -> String {
        var keys = decode(raw)
        if let index = keys.firstIndex(of: key) { keys.remove(at: index) } else { keys.append(key) }
        if keys.count > capacity { keys.removeFirst(keys.count - capacity) }
        return keys.joined(separator: "\n")
    }
}

/// Copy, quote and good under a message, on the same line as its time, in
/// the transcript's secondary ink with no plate behind them: the bubble stays
/// the thing to read (owner, 2026-11-11: the actions were only in the long
/// press, or missing). Chat and Work draw the same bar.
struct LAAMessageActionBar: View {
    let text: String
    /// Puts the message into the composer as a quote; nil hides 引用.
    let onQuote: (() -> Void)?
    /// The good mark: whether it is on, and how to flip it. Nil hides it.
    var liked: Bool? = nil
    var onLike: (() -> Void)? = nil
    var identifierPrefix = "chat.message"
    @State private var copied = false

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(spacing: 0) {
            if hasText {
                action(copied ? "checkmark" : "doc.on.doc", label: copied ? "コピーしました" : "コピー",
                       id: "copy", tint: copied ? LAAColor.link : LAAColor.secondaryText) { copy() }
                if let onQuote {
                    action("text.quote", label: "引用", id: "quote", tint: LAAColor.secondaryText, perform: onQuote)
                }
            }
            if let liked, let onLike {
                action(liked ? "hand.thumbsup.fill" : "hand.thumbsup", label: "グッド", id: "like",
                       tint: liked ? LAAColor.link : LAAColor.secondaryText) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) { onLike() }
                }
                .accessibilityValue(Text(verbatim: liked ? "オン" : "オフ"))
                .accessibilityAddTraits(liked ? .isSelected : [])
                .scaleEffect(liked ? 1.06 : 1)
                .sensoryFeedback(.selection, trigger: liked)
            }
        }
        .sensoryFeedback(.success, trigger: copied) { _, now in now }
    }

    private func copy() {
        UIPasteboard.general.string = text
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        UIAccessibility.post(notification: .announcement, argument: "コピーしました")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(.easeOut(duration: 0.2)) { copied = false }
        }
    }

    private func action(_ symbol: String, label: String, id: String, tint: Color,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityIdentifier(identifierPrefix + "." + id)
        .help(Text(verbatim: label))
    }
}

/// Work's bar: the good mark is kept on this device.
struct LAAWorkMessageActions: View {
    let text: String
    let sessionID: String
    let messageID: String
    let isOwner: Bool
    let onQuote: ((String) -> Void)?
    @AppStorage(LAAWorkLikes.storageKey) private var likes = ""

    private var likeKey: String { LAAWorkLikes.key(session: sessionID, message: messageID) }

    var body: some View {
        LAAMessageActionBar(text: text, onQuote: onQuote.map { quote in { quote(text) } },
                            liked: isOwner ? nil : LAAWorkLikes.decode(likes).contains(likeKey),
                            onLike: isOwner ? nil : { likes = LAAWorkLikes.toggled(likes, key: likeKey) },
                            identifierPrefix: "work.message")
    }
}

/// The same three actions on a long press or, on the Mac, a right click.
struct LAAWorkMessageMenu: ViewModifier {
    let text: String
    let sessionID: String
    let messageID: String
    let isOwner: Bool
    let onQuote: ((String) -> Void)?
    @AppStorage(LAAWorkLikes.storageKey) private var likes = ""

    private var likeKey: String { LAAWorkLikes.key(session: sessionID, message: messageID) }

    func body(content: Content) -> some View {
        content.contextMenu {
            if !text.isEmpty {
                Button { UIPasteboard.general.string = text } label: { Label { Text(verbatim: "コピー") } icon: { Image(systemName: "doc.on.doc") } }
                if let onQuote {
                    Button { onQuote(text) } label: { Label { Text(verbatim: "引用") } icon: { Image(systemName: "text.quote") } }
                }
            }
            if !isOwner {
                let liked = LAAWorkLikes.decode(likes).contains(likeKey)
                Button { likes = LAAWorkLikes.toggled(likes, key: likeKey) } label: {
                    Label { Text(verbatim: liked ? "グッドを外す" : "グッド") }
                        icon: { Image(systemName: liked ? "hand.thumbsup.fill" : "hand.thumbsup") }
                }
            }
        }
    }
}
#endif
