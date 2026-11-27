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
                    .id(profile)
            } else { V2ConversationScreen() }
        }.laaHidesTabBar()
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
    /// The draft key the field reads and writes. It follows `draftKey` only
    /// when that moves no one's draft (`bind`), so each key keeps its own.
    @State private var savedKey: ComposerDraftKey?
    /// `savedKey`'s whole stored draft when the field took it up.
    @State private var boundDraft = ComposerDraft.empty
    @State private var connectingFired: LAAConnectionWait.Key?
    @State private var connectingStalled: LAAConnectionWait.Key?
    @State private var retries = 0
    private var name: String { LAAStaff(profile: profile)?.name ?? "AI社員" }
    /// Exactly the rows the transcript below draws: the avatar shows when
    /// there are none, never a blank body (D-25).
    private var messages: [ChatMessage] {
        LAAEmployeeChatPreview.renderable(preview.presentation?.displayedMessages ?? retainedMessages)
    }
    private var draftKey: ComposerDraftKey? {
        guard let workspace = preview.workspace else { return nil }
        return ComposerDraftKey(profile: profile,
            sessionID: preview.queueTargetSessionID ?? ComposerDraftKey.newConversationSessionID,
            dashboardID: workspace.dashboardID)
    }
    /// Still opening this employee's own route (AppState decides: a failure,
    /// a route kept up only for a composition, a preview cleared or for
    /// someone else, an inactive scene, no network and a sign-in wait are
    /// not a wait; D-15).
    private var isWaiting: Bool {
        guard let workspace = preview.workspace, workspace.profile == profile else { return false }
        return appState.laaIsEmployeeChatWaiting(for: workspace)
    }
    /// The 0.5 s and 10 s waits start over for another dashboard, employee
    /// or Retry.
    private var connectingScope: String {
        "\(preview.workspace?.dashboardID.uuidString ?? "")|\(profile)|\(retries)"
    }
    private var phase: LAAConnectionWait.Phase {
        LAAConnectionWait.phase(isWaiting ? LAAConnectionWait.connecting : "", scope: connectingScope,
                                fired: connectingFired, stalled: connectingStalled,
                                reason: appState.laaConnectionStallReason)
    }
    private var isStalled: Bool {
        if case .stalled = phase { return true }
        return false
    }
    private var status: String {
        preview.failure == nil ? connectingWords : "Macに接続できません"
    }
    private var connectingWords: String { LAAConnectionWait.text(phase) }
    /// The capsules before the live chat: the last confirmed model and
    /// effort (最終確認), else 確認中… while it opens and 未確認 with
    /// the reason once it stalled or failed; never a bare 不明 (D-25).
    private var runtimeDisplay: LAAChatRuntimeDisplay.Value {
        let last = preview.workspace.flatMap { LAAChatRuntimeCache.last(dashboardID: $0.dashboardID, profile: profile) }
        let wait: LAAChatRuntimeDisplay.Wait = preview.failure != nil
            ? .unavailable(preview.failure ?? LAAConnectionWait.slowMac)
            : isStalled ? .unavailable(appState.laaConnectionStallReason) : .checking
        return LAAChatRuntimeDisplay.resolve(live: LAAChatRuntime.Shown(model: nil, provider: nil, effort: nil),
                                             lastConfirmed: last, wait: wait)
    }
    /// Only the field's own key may send, and only text: the target is the
    /// key's chat, and a quote or attachment the preview can't show stays put.
    private var canQueue: Bool {
        appState.laaOpeningEmployeeChat == profile && preview.queueTargetSessionID != nil
            && savedKey != nil && savedKey == draftKey
            && boundDraft.attachments.isEmpty && boundDraft.replyReference == nil
            && preview.canQueue(draft, isComposing: composing)
    }
    private func queueSend() -> Bool {
        guard canQueue, let key = savedKey,
              appState.laaQueueEmployeeOpeningSend(draft, draftKey: key) else { return false }
        draft = ""
        return true
    }
    private var previewComposer: some View {
        var field = ReturnKeyTextEditor(text: $draft, isFocused: $focused,
            accessibilityLabel: "メッセージ", accessibilityIdentifier: "laa.chats.preview.composer",
            maxLines: 8, canSubmitFromReturn: canQueue, onSubmitFromReturn: queueSend)
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
            LazyVStack(spacing: LAATranscriptMetrics.rowGap) {
                if messages.isEmpty {
                    VStack(spacing: 8) {
                        StaffAvatarView(profile: profile, name: name, size: 132)
                        Text(verbatim: name).font(LAAType.employeeName)
                    }.padding(.top, 100)
                }
                ForEach(messages) { message in
                    // The live conversation's own rows (LAATranscript), so the
                    // preview hands over to it without a jump.
                    if message.role == .user {
                        LAATranscriptOwnerTurn(timestamp: message.timestamp) {
                            // Selectable text, as in the conversation: a hold selects it.
                            HugsIdealWidth {
                                MarkdownText(source: ReplyQuoteEnvelope.parse(message.content)?.message ?? message.content,
                                             foregroundStyle: LAAColor.text)
                            }
                            .laaTranscriptOwnerBubble()
                        }.laaChatColumn(.trailing)
                    } else if message.role == .assistant || message.role == .partial {
                        LAATranscriptAgentTurn(name: LAAChatPerson.name(name), role: LAAChatPerson.role(profile: profile), timestamp: message.timestamp) {
                            StaffAvatarView(profile: profile, name: name, size: LAATranscriptMetrics.avatar, scrolling: true)
                        } content: {
                            MarkdownText(source: message.content)
                        }.laaChatColumn(.leading)
                    }
                }
                if let pending = preview.queuedSend {
                    PendingComposerSendBubble(pending: pending)
                }
            }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            }.defaultScrollAnchor(.bottom)
                .onChange(of: preview.queuedSend?.id) { old, new in
                    if old != nil, new == nil, let savedKey { adoptStoredDraft(savedKey) }
                    bind(to: draftKey)
                }
            // The live chat's typography, so the hand-over keeps every line.
            .environment(\.chatTextSize, LAAReadingStyle.reading(ChatTextAppearance(size: ChatTypography.stored(),
                style: ChatTypography.resolveStyle(rawValue: UserDefaults.standard.string(forKey: ChatTypography.fontStylePreferenceKey)))))
        }
            // The same heading, in the same place and size as the connected
            // conversation's, so nothing moves when it takes over.
            .v2EdgeBar(.top) {
                LAAEmployeeHeader(profile: profile, name: name,
                    status: status,
                    compact: dynamicTypeSize.isAccessibilitySize)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.top, -LAAConversationHeaderLayout.controlHeight)
                    #if DEBUG
                    .background { LAAConnectionWaitTestHook(words: preview.failure == nil ? connectingWords : "",
                        identifier: "laa.chats.opening.connecting") }
                    #endif
            }
            .background(LAAColor.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: LAASpacing.x2) {
                    if preview.failure != nil || isStalled {
                        // Keeps the copy on screen and any queued message,
                        // which still goes once (D-15 begin()).
                        Button {
                            retries &+= 1
                            appState.laaRetryEmployeeChat()
                        } label: {
                            Label { Text(verbatim: LAAConnectionWait.retry) } icon: { Image(systemName: "arrow.clockwise") }
                        }.accessibilityIdentifier("laa.chats.preview.retry")
                    }
                    previewComposer
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .laaComposerGlass(in: LAAComposerShape.field, interactive: false)
                        .accessibilityIdentifier("laa.chats.preview.composer")
                    HStack(spacing: LAASpacing.x2) {
                        let runtime = runtimeDisplay
                        LAAModelEffortPickers(harness: runtime.provider.map { LAAHarness.chat(provider: $0) },
                            model: runtime.model, provider: runtime.provider, effort: runtime.effort,
                            current: runtime.current,
                            identifier: "laa.chats.preview.runtime", modelHint: "接続後に変更できます", effortHint: "接続後に変更できます",
                            placeholder: runtime.placeholder) {
                            if let reason = runtime.reason { LAAMenuReason(text: reason) }
                            LAAMenuReason(text: "接続後にモデルを変更できます")
                        } effortMenu: {
                            if let reason = runtime.reason { LAAMenuReason(text: reason) }
                            LAAMenuReason(text: "接続後に推論の強さを変更できます")
                        }
                        Spacer(minLength: 0)
                        Button { _ = queueSend() } label: {
                            Image(systemName: "arrow.up").frame(width: ComposerShared.rowControlSize, height: ComposerShared.rowControlSize)
                        }.buttonStyle(.plain)
                            .disabled(!canQueue)
                            .accessibilityLabel(Text(verbatim: LAACopy.chatSend))
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
            .laaConnectionWait(isWaiting ? LAAConnectionWait.connecting : "", scope: connectingScope, fired: $connectingFired,
                               stalled: $connectingStalled)
            .onChange(of: appState.laaOpeningEmployeeChat) { _, _ in handoffIfReady() }
            .onChange(of: preview.presentation?.displayedMessages) { _, value in
                if let value { retainedMessages = value }
            }
            .task(id: draftKey) {
                bind(to: draftKey)
                // Queueable from here: the field has its chat's key (D-25).
                if draftKey != nil, preview.queueTargetSessionID != nil { preview.noteComposerEditable() }
            }
            .onChange(of: draft) { _, value in
                if let savedKey { saveDraft(to: savedKey) }
                if value.isEmpty { bind(to: draftKey) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("laa.chats.opening")
    }
    /// Every keystroke is already saved under the field's own key, so the
    /// live chat finds it there; nothing is copied into another chat's key.
    private func handoffIfReady() {
        guard appState.laaOpeningEmployeeChat == nil, !composing else { return }
        compositionChanged(false)
    }

    /// Follows the preview's key (a cached chat arriving late, a dashboard)
    /// without moving anyone's draft. Untouched text stays where it was and
    /// the field shows the new key's own. Edited text keeps its own key,
    /// which cannot send to the other chat (`canQueue`), and the live chat
    /// takes over with each draft in its own place.
    private func bind(to key: ComposerDraftKey?) {
        guard let key, key != savedKey, preview.queuedSend == nil else { return }
        let stored = appState.composerDraftStore.draft(for: key)
        if !draft.isEmpty, draft != boundDraft.text {
            if savedKey != nil { return }
            // Typed before any key: it may only start an empty one.
            guard stored.isEmpty else { return }
            savedKey = key
            boundDraft = .empty
            saveDraft(to: key)
            return
        }
        savedKey = key
        boundDraft = stored
        if draft != stored.text { draft = stored.text }
    }

    /// A reservation on the field's key ended (edited, released, sent). The
    /// store holds the result, merged with what was typed meanwhile, so the
    /// field takes it rather than saving its own older words over it. Only
    /// an empty result leaves the field's words, which are then the copy.
    private func adoptStoredDraft(_ key: ComposerDraftKey) {
        let stored = appState.composerDraftStore.draft(for: key)
        boundDraft = stored
        if stored.text.isEmpty {
            if !draft.isEmpty { saveDraft(to: key) }
        } else if draft != stored.text {
            draft = stored.text
        }
    }

    private func saveDraft(to key: ComposerDraftKey) {
        var value = appState.composerDraftStore.draft(for: key)
        value.text = draft
        _ = appState.composerDraftStore.save(value, for: key)
    }
}
#endif
