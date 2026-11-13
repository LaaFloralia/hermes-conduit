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

struct LAAChatMenuSelection {
    let text: String
    let isMine: Bool
    let reply: (() -> Void)?
    let react: ((String) -> Void)?
    let read: (() -> Void)?
    let select: () -> Void
    let moreReactions: () -> Void
}

private struct LAAPresentChatMenuKey: EnvironmentKey {
    static let defaultValue: ((LAAChatMenuSelection) -> Void)? = nil
}

extension EnvironmentValues {
    @Entry var laaOpenMessageMenu: (() -> Void)? = nil

    var laaPresentChatMenu: ((LAAChatMenuSelection) -> Void)? {
        get { self[LAAPresentChatMenuKey.self] }
        set { self[LAAPresentChatMenuKey.self] = newValue }
    }
}

struct LAAChatMenuOverlay: View {
    let selection: LAAChatMenuSelection
    let dismiss: () -> Void
    @AccessibilityFocusState private var menuFocused: Bool

    var body: some View {
        ZStack {
            LAAColor.background.opacity(0.84).ignoresSafeArea()
                .onTapGesture(perform: dismiss)
                .accessibilityHidden(true)
            ViewThatFits(in: .vertical) {
                contents
                ScrollView { contents }.scrollBounceBehavior(.basedOnSize)
            }
            .padding(20)
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, dismiss)
        .onAppear { menuFocused = true }
    }

    private var contents: some View {
        VStack(spacing: 8) {
            if let react = selection.react {
                HStack(spacing: 1) {
                    ForEach(LAAChatVisibility.reactions, id: \.self) { emoji in
                        Button { dismiss(); react(emoji) } label: {
                            Text(verbatim: emoji).font(.system(size: 24)).frame(width: 38, height: 44)
                        }
                        .accessibilityLabel(Text(verbatim: emoji))
                    }
                    Button { dismiss(); selection.moreReactions() } label: {
                        Image(systemName: "plus").font(.system(size: 18)).frame(width: 38, height: 44)
                    }.accessibilityLabel(Text(verbatim: "スタンプを追加"))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .laaGlass(in: Capsule())
            }
            MarkdownText(source: selection.text, usesAccentSurface: selection.isMine)
                .allowsHitTesting(false)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: 332, maxHeight: 160, alignment: .topLeading)
                .background(selection.isMine ? LAAColor.ownBubble : LAAColor.surface,
                            in: RoundedRectangle(cornerRadius: LAARadius.bubble))
                .clipped().accessibilityHidden(true)
            VStack(spacing: 0) {
                menuItem("返信", icon: "arrowshape.turn.up.left", action: selection.reply)
                    .accessibilityFocused($menuFocused)
                menuItem("コピー", icon: "doc.on.doc", action: { UIPasteboard.general.string = selection.text })
                menuItem("テキストを選択", icon: "text.cursor", action: selection.select)
                menuItem("読み上げ", icon: "speaker.wave.2", action: selection.read, last: true)
            }
            .frame(width: 250)
            .laaGlass(in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private func menuItem(_ title: String, icon: String, action: (() -> Void)?, last: Bool = false) -> some View {
        Button {
            dismiss()
            action?()
        } label: {
            HStack {
                Text(verbatim: title)
                Spacer()
                Image(systemName: icon).font(.system(size: 17))
            }
            .foregroundStyle(action == nil ? LAAColor.secondaryText : LAAColor.text)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if !last { Rectangle().fill(LAAColor.separator).frame(height: 1).padding(.horizontal, 16) }
            }
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

private struct LAAChatMessageMenu: ViewModifier {
    let text: String
    var isMine: Bool
    var reply: (() -> Void)?
    var react: ((String) -> Void)?
    var read: (() -> Void)?
    @Environment(\.laaPresentChatMenu) private var present
    @State private var selecting = false
    @State private var moreReactions = false
    @State private var customReaction = ""

    func body(content: Content) -> some View {
        surface(content.environment(\.laaUsesMessageMenu, true))
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

    @ViewBuilder private func surface<Content: View>(_ content: Content) -> some View {
        if let present {
            let open = {
                present(.init(text: text, isMine: isMine, reply: reply, react: react, read: read,
                              select: { selecting = true }, moreReactions: { moreReactions = true }))
            }
            content.environment(\.laaOpenMessageMenu, open)
                .contentShape(Rectangle())
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in open() })
                .accessibilityAction(named: Text(verbatim: "メッセージの操作"), open)
        } else {
            content.contextMenu {
                if let react {
                    ControlGroup {
                        ForEach(LAAChatVisibility.reactions, id: \.self) { emoji in
                            Button(emoji) { react(emoji) }
                        }
                        Button(String("スタンプを追加"), systemImage: "plus") { moreReactions = true }
                    }.controlGroupStyle(.palette)
                }
                Button(String("返信"), systemImage: "arrowshape.turn.up.left") { reply?() }.disabled(reply == nil)
                Button(String("コピー"), systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                Button(String("テキストを選択"), systemImage: "text.cursor") { selecting = true }
                Button(String("読み上げ"), systemImage: "speaker.wave.2") { read?() }.disabled(read == nil)
            }
        }
    }

}

extension View {
    func laaMessageMenu(text: String, isMine: Bool = false, reply: (() -> Void)? = nil,
                        react: ((String) -> Void)? = nil, read: (() -> Void)? = nil) -> some View {
        modifier(LAAChatMessageMenu(text: text, isMine: isMine, reply: reply, react: react, read: read))
    }
}

/// The working mark of every LAA chat: the orb (24 pt), what the agent is
/// doing when the caller knows it, and how long the turn has run. A room
/// passes neither words nor a start time and shows the orb alone.
struct LAATypingDots: View {
    var startedAt: Date? = nil
    var records: [ChatMessage] = []
    /// The real state only: thinking, a tool running, or idle while another device receives the reply.
    var state: LAAOrbState = .thinking
    var phrase: String? = nil
    /// False for the third and later orbs on one screen; they hold a still frame.
    var animates = true
    @State private var showingRecords = false
    var body: some View {
        Button { showingRecords = true } label: {
            HStack(spacing: LAASpacing.x2) {
                LAAOrbView(state: state, diameter: 24, isOnScreen: animates)
                if let phrase {
                    Text(verbatim: phrase)
                        .font(.subheadline).foregroundStyle(LAAColor.secondaryText)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .animation(.easeOut(duration: 0.22), value: phrase)
                }
                if let startedAt {
                    Spacer(minLength: LAASpacing.x2)
                    // Counts on its own; the row does not re-render each second.
                    Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                        .font(.caption.weight(.medium)).monospacedDigit()
                        .foregroundStyle(LAAColor.secondaryText)
                        .fixedSize()
                }
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(String("入力中、作業の記録を表示"))
            .accessibilityValue(phrase ?? "")
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
    /// The tool running now, its input and its own words for it, as the upstream working line reads them.
    var currentToolName: String? = nil
    var currentToolInput: String? = nil
    var currentToolTitle: String? = nil
    /// Another device is getting this chat's reply.
    var repliesElsewhere = false
    @EnvironmentObject private var appState: AppState
    @Environment(\.chatRowState) private var rowState
    var body: some View {
        HStack(spacing: LAASpacing.x3) {
            StaffAvatarView(profile: appState.conversationIdentityProfile,
                name: appState.conversationAgentIdentity.name, size: 30, scrolling: true)
                .frame(width: 30, height: 30)
            LAATypingDots(startedAt: startedAt, records: records, state: orbState, phrase: phrase)
        }.laaChatColumn(.leading)
    }
    private var orbState: LAAOrbState {
        if repliesElsewhere { return .idle }
        return currentToolName != nil || currentToolTitle != nil ? .tool : .thinking
    }
    private var phrase: String {
        if repliesElsewhere { return AppLocalization.string("Replying on another device") }
        if let currentToolTitle { return currentToolTitle }
        if let currentToolName {
            return ChatStepLabel(toolName: currentToolName, input: currentToolInput, catalog: rowState.toolCatalog).runningTitle
        }
        return AppLocalization.string("Thinking")
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
