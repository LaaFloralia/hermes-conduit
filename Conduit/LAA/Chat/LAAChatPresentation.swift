#if LAA_BUILD
import SwiftUI
import UIKit

enum LAAChatPerson {
    static func name(_ value: String) -> String {
        value.replacingOccurrences(of: "（Dots）", with: " · Dots").replacingOccurrences(of: "（無検閲）", with: " · 無検閲").replacingOccurrences(of: "[（(].*?[）)]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func role(profile: String?, name: String = "", existingRole: String? = nil) -> String? {
        if let existingRole, !existingRole.isEmpty, existingRole != "社長秘書・総合アドバイザー" { return existingRole }
        let staff = profile.flatMap(LAAStaff.init(profile:))
            ?? LAAStaff.allCases.first { Self.name($0.name).localizedCaseInsensitiveCompare(Self.name(name)) == .orderedSame }
        guard let staff else { return nil }
        return [.monet, .monetDots, .monetUncensored].contains(staff) ? "Secretary" : staff.role
    }
    static func staff(member: GroupMember?, name: String) -> LAAStaff? {
        member?.profile.flatMap(LAAStaff.init(profile:))
            ?? LAAStaff.allCases.first { Self.name($0.name).localizedCaseInsensitiveCompare(Self.name(name)) == .orderedSame }
    }
}

struct LAARoleBadge: View {
    let role: String
    var body: some View {
        Text(verbatim: role)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(LAAColor.link).lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(LAAColor.selectionFill, in: RoundedRectangle(cornerRadius: 4))
    }
}

enum LAAChatVisibility {
    static func shows(_ message: ChatMessage) -> Bool {
        switch message.role {
        case .reasoning: return false
        case .tool:
            // Questions and delivered cards are conversation content.
            guard let tool = message.tool else { return false }
            return ClarifyActivity.historyRecord(for: tool, rowID: message.id) != nil || !RichCard.cards(for: tool).isEmpty
        default: return true
        }
    }
    static let reactions = ["❤️", "👍", "👎", "‼️", "😂", "✅"]
}

/// The system context menu floats the selected bubble and supplies the
/// glass palette. All mutations use the existing conversation actions.
private struct LAAChatMessageMenu: ViewModifier {
    let text: String
    var reply: (() -> Void)?
    var react: ((String) -> Void)?
    var read: (() -> Void)?
    @State private var selecting = false
    @State private var moreReactions = false
    @State private var customReaction = ""

    func body(content: Content) -> some View {
        content.environment(\.laaUsesMessageMenu, true).contextMenu {
            if let react {
                ControlGroup {
                    ForEach(LAAChatVisibility.reactions, id: \.self) { emoji in
                        Button(emoji) { react(emoji) }
                            .accessibilityLabel(String("スタンプ \(emoji)")).accessibilityIdentifier("chat.reaction.\(emoji)")
                    }
                    Button(String("スタンプを追加"), systemImage: "plus") { moreReactions = true }
                }.controlGroupStyle(.palette)
            }
            Button(String("コピー"), systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
            Button(String("テキストを選択"), systemImage: "text.cursor") { selecting = true }
            Button(String("返信"), systemImage: "arrowshape.turn.up.left") { reply?() }.disabled(reply == nil)
            Button(String("読み上げ"), systemImage: "speaker.wave.2") { read?() }.disabled(read == nil)
        }
        .sheet(isPresented: $selecting) {
            NavigationStack {
                LAASelectableMessageText(text: text)
                    .navigationTitle(String("テキストを選択")).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String("完了")) { selecting = false } } }
            }.laaSheetSize(.page)
        }
        .alert(String("スタンプを追加"), isPresented: $moreReactions) {
            TextField(String("絵文字"), text: $customReaction)
            Button(String("追加")) {
                let emoji = customReaction.trimmingCharacters(in: .whitespacesAndNewlines)
                if !emoji.isEmpty { react?(String(emoji.prefix(1))) }
                customReaction = ""
            }
            Button("キャンセル", role: .cancel) { customReaction = "" }
        }
    }
}

extension View {
    func laaMessageMenu(text: String, reply: (() -> Void)? = nil,
                        react: ((String) -> Void)? = nil, read: (() -> Void)? = nil) -> some View {
        modifier(LAAChatMessageMenu(text: text, reply: reply, react: react, read: read))
    }
}

struct LAATypingDots: View {
    var startedAt: Date? = nil
    var records: [ChatMessage] = []
    @State private var showingRecords = false
    var body: some View {
        Button { showingRecords = true } label: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 8) {
                    LAAActivityDots()
                        .frame(width: 64, height: 36)
                        .background(LAAColor.surface, in: Capsule())
                    if let startedAt, context.date.timeIntervalSince(startedAt) > 60 {
                        Text(verbatim: "\(Int(context.date.timeIntervalSince(startedAt) / 60))分")
                            .font(.caption2).foregroundStyle(LAAColor.secondaryText)
                    }
                }.frame(minHeight: 44)
            }
        }.buttonStyle(.plain)
            .accessibilityLabel(String("入力中、作業の記録を表示"))
            .accessibilityIdentifier("chat.typing")
            .sheet(isPresented: $showingRecords) {
                NavigationStack {
                    List {
                        if records.isEmpty { Text(verbatim: "記録はありません").foregroundStyle(LAAColor.secondaryText) }
                        ForEach(records) { record in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(verbatim: record.role == .reasoning ? "思考" : "道具の実行").font(.caption).foregroundStyle(LAAColor.secondaryText)
                                Text(verbatim: record.content).font(.body).textSelection(.enabled)
                            }
                        }
                    }.navigationTitle(String("作業の記録")).navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String("完了")) { showingRecords = false } } }
                }.laaSheetSize(.page)
            }
    }
}

enum LAAChatReadReceipt {
    static func wasRead(_ id: String, messages: [ChatMessage], hasLiveResponse: Bool = false) -> Bool {
        guard messages.last(where: { $0.role == .user && !$0.isSteer })?.id == id,
              let index = messages.firstIndex(where: { $0.id == id }) else { return false }
        return hasLiveResponse || messages.dropFirst(index + 1).contains {
            [.assistant, .partial, .tool, .reasoning].contains($0.role)
        }
    }
}
struct LAAChatDelivery: View {
    let message: ChatMessage
    @EnvironmentObject private var appState: AppState
    var body: some View {
        if appState.messages.last(where: { $0.role == .user && !$0.isSteer })?.id == message.id {
            LAAChatLiveDelivery(message: message, messages: appState.messages, projection: appState.liveTurn)
        }
    }
}
private struct LAAChatLiveDelivery: View {
    let message: ChatMessage
    let messages: [ChatMessage]
    @ObservedObject var projection: LiveTurnProjection
    var body: some View {
        if LAAChatReadReceipt.wasRead(message.id, messages: messages,
            hasLiveResponse: !projection.streamingText.isEmpty || projection.reasoningSegment != nil) {
            Text(verbatim: "既読").font(.system(size: 11)).foregroundStyle(LAAColor.secondaryText)
                .accessibilityIdentifier("chat.delivery.read")
        }
    }
}
#endif
#if LAA_BUILD
struct LAAChatTypingRow: View {
    var startedAt: Date?
    @ObservedObject var projection: LiveTurnProjection
    @EnvironmentObject private var appState: AppState
    var body: some View {
        HStack(spacing: 10) {
            StaffAvatarView(profile: appState.conversationIdentityProfile,
                name: appState.conversationAgentIdentity.name, size: 30, scrolling: true)
                .frame(width: 30, height: 30)
            LAATypingDots(startedAt: startedAt, records: records)
            Spacer(minLength: 0)
        }.laaChatColumn(.leading)
    }
    private var records: [ChatMessage] {
        var result = appState.messages.filter { $0.role == .tool || $0.role == .reasoning }
        if let segment = projection.reasoningSegment, !result.contains(where: { $0.id == segment.id }) {
            result.append(ChatMessage(id: segment.id, role: .reasoning, content: segment.content, timestamp: segment.timestamp))
        }
        return result
    }
}
#endif
#if LAA_BUILD
struct LAAConversationSearchView: View {
    @EnvironmentObject private var appState: AppState
    @State private var query = ""
    var body: some View {
        List {
            if appState.activeRoomSurface != nil {
                ForEach(appState.activeRoomReplay.events.filter { GroupRoomTurns.isVisible($0) && !query.isEmpty && ($0.messageText ?? "").localizedCaseInsensitiveContains(query) }) { event in
                    Text(verbatim: event.messageText ?? "").textSelection(.enabled)
                }
            } else {
                ForEach(appState.messages.filter { LAAChatVisibility.shows($0) && !query.isEmpty && $0.content.localizedCaseInsensitiveContains(query) }) { message in
                    Text(verbatim: message.content).textSelection(.enabled)
                }
            }
        }.searchable(text: $query, prompt: "検索").navigationTitle(String("会話内を検索"))
    }
}
struct LAAConversationHistoryView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.laaDismissConversationInfo) private var dismissInfo
    var body: some View {
        List(appState.listedSessions.filter { $0.source == .chat && ($0.profile ?? appState.activeProfile) == appState.conversationIdentityProfile }) { session in
            Button { dismissInfo(); appState.requestOpenSession(session.id) } label: {
                Text(verbatim: session.title).foregroundStyle(LAAColor.text)
            }
        }.navigationTitle(String("これまでの会話"))
    }
}
#endif
#if LAA_BUILD
struct LAAGroupMemberMessage: View {
    let member: GroupMember?
    let name: String
    let text: String
    let members: [GroupMember]
    let timestamp: Double?
    let continues: Bool
    let eventID: String?
    @EnvironmentObject private var appState: AppState
    var body: some View {
        let parts = GroupMessageParts(text)
        let reply = GroupRoomReplyQuote.parse(parts.text)
        let ownText = reply?.message ?? parts.text
        LAAAgentMessageRow(name: LAAChatPerson.name(name), continues: continues,
            role: LAAChatPerson.role(profile: member?.profile, name: name),
            timestamp: timestamp.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0)) }) {
                GroupMemberAvatar(member: member, name: name, size: 30)
            } content: {
                VStack(alignment: .leading, spacing: 8) {
                    if let reply { ReplyReferenceQuoteCard(quote: reply.quote, onAccentSurface: false, authorName: reply.author) }
                    HugsIdealWidth { MarkdownText(source: GroupRoomMentions.linkingMarkdown(ownText, members: members)) }
                    // Preserve attachment rendering through the original component.
                    if !parts.files.isEmpty { GroupMessageFilesForLAA(text: text) }
                }.padding(.horizontal, 14).padding(.vertical, 10)
                    .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: 18))
                    .laaMessageMenu(text: GroupRoomMentions.refanged(ownText),
                        reply: appState.canQuoteIntoRoom() ? { appState.replyInRoomComposer(text: text, authorName: name, authorHandle: member?.handle) } : nil,
                        read: appState.isConnected ? eventID.map { id in { appState.toggleRoomReadAloud(eventID: id, text: ownText, memberProfile: member?.profile) } } : nil)
            }.laaChatColumn(.leading)
    }
}
#endif

#if LAA_BUILD
private struct LAAUsesMessageMenuKey: EnvironmentKey {
    static let defaultValue = false
}
private struct LAAConversationInfoDismissKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}
extension EnvironmentValues {
    var laaUsesMessageMenu: Bool {
        get { self[LAAUsesMessageMenuKey.self] }
        set { self[LAAUsesMessageMenuKey.self] = newValue }
    }
    var laaDismissConversationInfo: () -> Void {
        get { self[LAAConversationInfoDismissKey.self] }
        set { self[LAAConversationInfoDismissKey.self] = newValue }
    }
}

struct LAAReplyReferenceCard: View {
    let excerpt: String
    let author: String?
    var onAccent = false
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(onAccent ? Color.white.opacity(0.7) : LAAColor.link).frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: author.map(LAAChatPerson.name) ?? "返信").font(.caption.weight(.semibold))
                Text(verbatim: excerpt).font(.footnote).lineLimit(1)
            }
            Spacer(minLength: 0)
        }.foregroundStyle(onAccent ? Color.white : LAAColor.text)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}
#endif

#if LAA_BUILD
struct LAAComposerReplyReference: View {
    let reference: ComposerReplyReference
    let remove: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            LAAReplyReferenceCard(excerpt: reference.excerpt, author: reference.authorName)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                    .frame(width: 44, height: 44)
            }.buttonStyle(.plain).foregroundStyle(LAAColor.secondaryText)
                .accessibilityLabel(String("返信を取り消す"))
                .accessibilityIdentifier("composer.reply-reference.remove")
        }.padding(.leading, 12)
    }
}
#endif

#if LAA_BUILD
struct LAAGroupDelivery: View {
    let eventID: String
    @EnvironmentObject private var appState: AppState
    var body: some View {
        let events = appState.activeRoomReplay.events
        if events.last(where: \.isUserMessage)?.id == eventID,
           let index = events.firstIndex(where: { $0.id == eventID }),
           events.dropFirst(index + 1).contains(where: { $0.isMemberMessage || $0.kind == "turn.started" }) {
            Text(verbatim: "既読").font(.system(size: 11)).foregroundStyle(LAAColor.secondaryText)
                .accessibilityIdentifier("chat.delivery.read")
        }
    }
}
#endif

#if LAA_BUILD

#endif

#if LAA_BUILD
private struct LAASelectableMessageText: UIViewRepresentable {
    let text: String
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        view.tintColor = UIColor(LAAColor.link)
        view.accessibilityIdentifier = "chat.message.selection"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}
#endif
