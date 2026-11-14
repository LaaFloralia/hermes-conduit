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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var draft = ""
    @State private var focused = false
    @State private var composing = false
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
        field.onCompositionChanged = { value in
            composing = value
            handoffIfReady()
        }
        return field.frame(minHeight: 22).background(alignment: .topLeading) {
            if draft.isEmpty { Text(verbatim: "メッセージ").foregroundStyle(LAAColor.secondaryText).allowsHitTesting(false) }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
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
            }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            }.defaultScrollAnchor(.bottom)
        }
            // The same heading, in the same place and size as the connected
            // conversation's, so nothing moves when it takes over.
            .v2EdgeBar(.top) {
                LAAEmployeeHeader(profile: profile, name: name,
                    status: preview.failure == nil ? "接続中…" : "Macに接続できません",
                    compact: dynamicTypeSize.isAccessibilitySize)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.top, -LAAConversationHeaderLayout.controlHeight)
            }
            .background(LAAColor.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: LAASpacing.x2) {
                    if preview.failure != nil {
                        Button { appState.laaRetryEmployeeChat() } label: {
                            Label("接続を再試行", systemImage: "arrow.clockwise")
                        }.accessibilityIdentifier("laa.chats.preview.retry")
                    }
                    previewComposer
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .laaComposerGlass(in: LAAComposerShape.field, interactive: false)
                        .accessibilityIdentifier("laa.chats.preview.composer")
                    HStack(spacing: LAASpacing.x2) {
                        LAAModelEffortPickers(model: nil, provider: nil, effort: nil,
                            identifier: "laa.chats.preview.runtime", modelHint: "接続後に変更できます", effortHint: "接続後に変更できます") {
                            LAAMenuReason(text: "接続後にモデルを変更できます")
                        } effortMenu: {
                            LAAMenuReason(text: "接続後に推論の強さを変更できます")
                        }
                        Spacer(minLength: 0)
                        Button { focused = false } label: {
                            Image(systemName: "arrow.up").frame(width: ComposerShared.rowControlSize, height: ComposerShared.rowControlSize)
                        }.buttonStyle(.plain)
                            .disabled(appState.laaOpeningEmployeeChat != nil)
                            .accessibilityLabel(Text(verbatim: appState.laaOpeningEmployeeChat == nil ? "入力を確定してチャットへ" : "接続後に送信できます"))
                            .accessibilityIdentifier("laa.chats.preview.send")
                    }
                }.fixedSize(horizontal: false, vertical: true).padding(.horizontal, 20).padding(.vertical, 8)
            }
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // Keep the route mounted through connection completion until
                // its draft is saved, including an active Japanese composition.
                compositionChanged(true)
                retainedMessages = preview.presentation?.displayedMessages ?? []
            }
            .onChange(of: appState.laaOpeningEmployeeChat) { _, _ in handoffIfReady() }
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
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("laa.chats.opening")
    }
    private func handoffIfReady() {
        guard appState.laaOpeningEmployeeChat == nil, !composing else { return }
        if appState.conversationIdentityProfile == profile, appState.activeSessionId != nil,
           let dashboardID = savedKey?.dashboardID, dashboardID == appState.activeDashboardID, !draft.isEmpty {
            let key = appState.composerDraftKeyOnScreen
            if appState.composerDraftStore.draft(for: key).text.isEmpty { saveDraft(to: key) }
        }
        compositionChanged(false)
    }

    private func saveDraft(to key: ComposerDraftKey) {
        var value = appState.composerDraftStore.draft(for: key)
        value.text = draft
        _ = appState.composerDraftStore.save(value, for: key)
    }
}
#endif
