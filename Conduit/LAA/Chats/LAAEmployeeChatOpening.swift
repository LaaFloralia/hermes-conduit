#if LAA_BUILD
import SwiftUI

extension AppState {
    func laaCancelOpeningEmployeeChat() { laaDismissEmployeeChatPreview() }
}

struct LAAConversationRoute: View {
    @EnvironmentObject private var appState: AppState
    @State private var composingProfile: String?
    var body: some View {
        Group {
            if let profile = appState.laaOpeningEmployeeChat ?? composingProfile {
                LAAEmployeeChatOpeningView(profile: profile, preview: appState.laaEmployeeChatPreview,
                    compositionChanged: { composingProfile = $0 ? profile : nil })
            } else { V2ConversationScreen() }
        }.toolbar(.hidden, for: .tabBar)
    }
}

/// Never adopts the previous employee's live identity or pending send.
struct LAAEmployeeChatOpeningView: View {
    let profile: String
    @ObservedObject var preview: LAAEmployeeChatPreview
    var compositionChanged: (Bool) -> Void = { _ in }
    @EnvironmentObject private var appState: AppState
    @State private var draft = ""
    @State private var focused = false
    @State private var retainedMessages: [ChatMessage] = []
    @State private var savedKey: ComposerDraftKey?
    private var name: String { LAAStaff(profile: profile)?.name ?? "AI社員" }
    private var messages: [ChatMessage] { (preview.presentation?.displayedMessages ?? retainedMessages).filter(LAAChatVisibility.shows) }
    private var draftKey: ComposerDraftKey? {
        guard let workspace = preview.workspace else { return nil }
        return ComposerDraftKey(profile: profile,
            sessionID: preview.presentation?.composerSessionID ?? ComposerDraftKey.newConversationSessionID,
            dashboardID: workspace.dashboardID)
    }
    private var previewComposer: some View {
        var field = ReturnKeyTextEditor(text: $draft, isFocused: $focused,
            accessibilityLabel: "メッセージ", accessibilityIdentifier: "laa.chats.preview.composer",
            maxLines: 8, canSubmitFromReturn: false, onSubmitFromReturn: { false })
        field.onCompositionChanged = compositionChanged
        return field.frame(minHeight: 22).background(alignment: .topLeading) {
            if draft.isEmpty { Text(verbatim: "メッセージ").foregroundStyle(LAAColor.secondaryText).allowsHitTesting(false) }
        }
    }
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                if messages.isEmpty {
                    VStack(spacing: 8) {
                        StaffAvatarView(profile: profile, name: name, size: 132)
                        Text(verbatim: name).font(LAAType.employeeName)
                    }.padding(.top, 100)
                }
                ForEach(messages) { message in
                    if message.role == .user {
                        LAAOwnerMessageRow(timestamp: message.timestamp) {
                            Text(verbatim: ReplyQuoteEnvelope.parse(message.content)?.message ?? message.content)
                                .padding(.horizontal, 14).padding(.vertical, 10).foregroundStyle(LAAColor.filledButtonText)
                                .background(LAAColor.ownBubble, in: RoundedRectangle(cornerRadius: 18))
                                .laaMessageMenu(text: message.content)
                        }
                    } else if message.role == .assistant || message.role == .partial {
                        LAAAgentMessageRow(name: LAAChatPerson.name(name), role: LAAChatPerson.role(profile: profile), timestamp: message.timestamp) {
                            StaffAvatarView(profile: profile, name: name, size: 30, scrolling: true).frame(width: 30, height: 30)
                        } content: {
                            MarkdownText(source: message.content).padding(.horizontal, 14).padding(.vertical, 10)
                                .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: 18))
                                .laaMessageMenu(text: message.content)
                        }
                    }
                }
            }.padding(.horizontal, 20).padding(.top, 76).padding(.bottom, 12)
        }.defaultScrollAnchor(.bottom)
            .background(LAAColor.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                HStack(alignment: .bottom, spacing: 8) {
                    previewComposer
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .laaComposerGlass(in: LAAComposerShape.field, interactive: false)
                        .accessibilityIdentifier("laa.chats.preview.composer")
                }.padding(.horizontal, 20).padding(.vertical, 8)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        StaffAvatarView(profile: profile, name: name, size: 64)
                        HStack(spacing: 6) {
                            Text(verbatim: LAAChatPerson.name(name)).font(.custom("Georgia", size: 17, relativeTo: .headline))
                            if let role = LAAChatPerson.role(profile: profile) { LAARoleBadge(role: role) }
                        }.padding(.horizontal, 8).padding(.vertical, 5).laaComposerGlass(in: Capsule(), interactive: false)
                        HStack(spacing: 6) {
                            Text(verbatim: preview.failure == nil ? "接続中…" : "Macに接続できません").font(.caption2)
                            if preview.failure != nil { Button(String("再試行")) { appState.laaRetryEmployeeChat() }.font(.caption2) }
                        }.foregroundStyle(LAAColor.secondaryText)
                    }.fixedSize().frame(height: 44, alignment: .top)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { retainedMessages = preview.presentation?.displayedMessages ?? [] }
            .onChange(of: preview.presentation?.displayedMessages) { _, value in
                if let value { retainedMessages = value }
            }
            .task(id: draftKey) {
                guard let key = draftKey else { return }
                if let savedKey, savedKey != key, !draft.isEmpty { saveDraft(to: key) }
                else if draft.isEmpty { draft = appState.composerDraftStore.draft(for: key).text }
                savedKey = key
            }
            .onChange(of: draft) { _, _ in if let savedKey { saveDraft(to: savedKey) } }
            .onDisappear {
                if appState.conversationIdentityProfile == profile, let id = appState.activeSessionId,
                   let dashboard = savedKey?.dashboardID, !draft.isEmpty {
                    let key = ComposerDraftKey(profile: profile, sessionID: id, dashboardID: dashboard)
                    if appState.composerDraftStore.draft(for: key).text.isEmpty { saveDraft(to: key) }
                }
            }
            .accessibilityIdentifier("laa.chats.opening")
    }
    private func saveDraft(to key: ComposerDraftKey) {
        var value = appState.composerDraftStore.draft(for: key)
        value.text = draft
        _ = appState.composerDraftStore.save(value, for: key)
    }
}
#endif
