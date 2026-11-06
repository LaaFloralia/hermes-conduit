#if LAA_BUILD
import SwiftUI

struct LAAWorkSessionDetail: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.laaDesktop) private var laaDesktop
    @ObservedObject var drafts: ComposerDraftStore
    let id: String
    let projects: [LAAWorkProject]
    let workspaces: [LAAWorkWorkspace]
    @State private var session: LAAWorkSession?
    @State private var events: [LAAWorkEvent] = []
    @State private var messages: [LAAWorkConversationMessage] = []
    @State private var conversationUnavailable = false
    @State private var cursor: String?
    @State private var notice: String?
    @State private var failure: String?
    @State private var stopping = false
    @State private var historyGapSeen = false
    @State private var observationEpoch = 0
    @State private var followsConversation = true
    @State private var didInitialScroll = false
    @State private var historyLoaded = false
    @State private var userDragged = false
    @State private var options: LAAWorkSessionOptions?
    @State private var changingEffort = false
    @State private var effortNotice: String?
    @AppStorage(ChatTypography.preferenceKey) private var responseSize = ChatTypography.defaultSize.rawValue

    init(id: String, projects: [LAAWorkProject], workspaces: [LAAWorkWorkspace], drafts: ComposerDraftStore) {
        self.id = id; self.projects = projects; self.workspaces = workspaces; self.drafts = drafts
    }

    private var stopKey: ComposerDraftKey? {
        bridge.deviceID.map { LAAWorkDrafts.key(deviceID: $0, target: "interrupt:\(id)") }
    }
    private var pendingStop: ComposerDraftStore.Submission? {
        stopKey.flatMap { LAAWorkDrafts.pending(drafts, key: $0) }
    }

    var body: some View {
        ZStack {
            LAAColor.background.ignoresSafeArea()
            ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: LAASpacing.x4) {
                    if let session {
                        sessionHeader(session)
                        if let notice { Label(notice, systemImage: "exclamationmark.triangle.fill").foregroundStyle(LAAColor.attention).workCard() }
                        if let failure {
                            VStack(alignment: .leading) {
                                Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(LAAColor.attention)
                                Button(LAACopy.WorkTab.reconnect) { observationEpoch += 1 }
                            }.workCard()
                        }
                        if session.needsDecision { LAAWorkSessionDecision(sessionID: id, drafts: drafts) { observationEpoch += 1 }.id("decision-start") }
                        conversation
                        if !canInterrupt(session) || session.resumedTo != nil { actions(session) }
                        LAAWorkMessageForm(sessionID: id, mode: .followUp, drafts: drafts,
                                           canStart: ["awaiting_review", "running"].contains(session.phase) && !session.needsDecision,
                                           headerAccessory: canInterrupt(session) ? AnyView(stopButton) : nil) { _ in
                            Task { await refreshSnapshot() }
                        }
                        LAAWorkSessionControls(session: session, options: options,
                                               changing: $changingEffort, notice: $effortNotice) {
                            _ = await refreshSnapshot()
                        }
                    } else if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(LAAColor.attention)
                        Button(LAACopy.WorkTab.retry) { observationEpoch += 1 }
                    } else { ProgressView().accessibilityLabel(Text(verbatim: "読み込み中")) }
                    // The very bottom includes the follow-up field and the
                    // model bar. Opening always lands here (also with an empty
                    // or unavailable history); later arrivals follow only while
                    // this sentinel is on screen.
                    Color.clear.frame(height: 1).id("bottom-end")
                        .onAppear {
                            followsConversation = true
                            // Back at the bottom: the initial anchor may apply
                            // again on the next content change.
                            userDragged = false
                        }
                        .onDisappear { followsConversation = false }
                }
                .padding(.horizontal, LAASpacing.horizontal).padding(.vertical, LAASpacing.x4)
                .frame(maxWidth: laaDesktop ? LAADesktopMetrics.readingWidth : 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: laaDesktop ? .center : .leading)
            }
            // Until the owner drags the transcript, keep the bottom anchored:
            // a picture that finishes after the first layout must not leave the
            // composer below the screen. A drag removes the anchor until the
            // owner returns to the bottom, so reading history is not pulled
            // back by a later poll.
            .defaultScrollAnchor(userDragged ? nil : .bottom)
            .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in userDragged = true })
            .refreshable { await refreshSnapshot() }
            .onChange(of: historyLoaded) { _, _ in placeInitialScroll(scroll) }
            .onChange(of: session?.needsDecision) { _, waiting in
                guard didInitialScroll else { placeInitialScroll(scroll); return }
                if waiting == true { scroll.scrollTo("decision-start", anchor: .top) }
            }
            .onChange(of: messages.count) { _, _ in
                guard didInitialScroll else { placeInitialScroll(scroll); return }
                if !userDragged && followsConversation && session?.needsDecision != true { scroll.scrollTo("bottom-end", anchor: .bottom) }
            }
            .onChange(of: messages.last?.text) { _, _ in
                if !userDragged && followsConversation && session?.needsDecision != true { scroll.scrollTo("bottom-end", anchor: .bottom) }
            }
            }
        }
        .navigationTitle(Text(verbatim: session?.name ?? LAACopy.WorkTab.sessions))
        .tint(LAAColor.link)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(LAAColor.background, for: .navigationBar)
        .task(id: "\(bridge.revision)-\(id)-\(observationEpoch)") { await observe() }
        .task {
            if options == nil { options = try? await bridge.read("/v1/session-options") }
        }
    }

    /// Opening a session lands at the very bottom: the follow-up field and the
    /// model bar, whether the history is empty, unavailable or long, and also
    /// when a decision is waiting (the owner can still scroll up to it). Once
    /// placed, only messages that arrive while the bottom sentinel is on screen
    /// pull the view along.
    private func placeInitialScroll(_ scroll: ScrollViewProxy) {
        guard !didInitialScroll, historyLoaded else { return }
        didInitialScroll = true
        DispatchQueue.main.async {
            scroll.scrollTo("bottom-end", anchor: .bottom)
            // Correct the initial position even if a late image briefly
            // removed the bottom sentinel. Only a real drag cancels these.
            for delay in [0.6, 2.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard !userDragged else { return }
                    scroll.scrollTo("bottom-end", anchor: .bottom)
                }
            }
        }
    }

    private var conversation: some View {
        LazyVStack(alignment: .leading, spacing: LAASpacing.x4) {
            if conversationUnavailable {
                Text(verbatim: "会話履歴を取得できません。更新して再確認してください。")
                    .foregroundStyle(LAAColor.attention)
            } else if messages.isEmpty {
                Text(verbatim: "会話はまだありません。") .foregroundStyle(LAAColor.secondaryText)
            }
            ForEach(LAAWorkToolRuns.groups(messages)) { group in
                switch group.kind {
                case .message:
                    if let message = group.messages.first { messageCard(message) }
                case .tools:
                    LAAWorkToolRunsView(tools: group.messages)
                }
            }
        }
    }

    private func messageCard(_ message: LAAWorkConversationMessage) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            Text(verbatim: message.role == "user" ? "あなた" : "回答")
                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            MarkdownText(source: message.text, foregroundStyle: LAAColor.text)
                .environment(\.chatTextSize, ChatTextAppearance(size: ChatTypography.resolve(rawValue: responseSize), style: .standard))
            ForEach(message.images ?? [], id: \.self) { imageID in
                LAAWorkSessionImage(sessionID: id, imageID: imageID)
            }
        }.workCard()
    }

    /// The same short name the list shows. The navigation bar repeats it and
    /// stays fixed while the conversation scrolls; this card is the heading at
    /// the top of the transcript.
    private func sessionHeader(_ session: LAAWorkSession) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            Text(verbatim: session.name).font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
                .accessibilityIdentifier("work.session.detail.title")
            if session.modelMismatch {
                Label(LAAWorkPresentation.japanese("要求と観測が一致しません"), systemImage: "exclamationmark.triangle.fill")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
            }
        }
        .padding(LAASpacing.x4).frame(maxWidth: .infinity, alignment: .leading)
        .laaGlass(in: RoundedRectangle(cornerRadius: LAARadius.card))
    }

    private func canInterrupt(_ session: LAAWorkSession) -> Bool {
        pendingStop == nil && !["stop_unconfirmed", "stopped"].contains(session.phase)
    }

    private var stopButton: some View {
        Button { beginStop() } label: { Text(verbatim: "中断") }
            .buttonStyle(.bordered).tint(LAAColor.end).disabled(stopping)
            .accessibilityIdentifier("work.session.stop")
    }

    private func actions(_ session: LAAWorkSession) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            if pendingStop != nil {
                Label(LAAWorkPresentation.japanese("中断要求の結果は未確認です。状態を確認してから同じ要求を再照合できます。"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(LAAColor.attention)
                Button(LAACopy.WorkTab.checkStop) { Task { await refreshSnapshot() } }.disabled(stopping)
                Button(LAACopy.WorkTab.retryStop) { if let pendingStop { Task { await performStop(pendingStop) } } }
                    .disabled(stopping)
            } else if session.phase == "stop_unconfirmed" {
                Label(LAAWorkPresentation.japanese("停止はまだ確認できていません。"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(LAAColor.attention)
                Button(LAACopy.WorkTab.checkStop) { Task { await refreshSnapshot() } }
            } else if session.phase == "stopped" {
                Text(verbatim: "停止したセッションの再開は現在利用できません。")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
            if let nextID = session.resumedTo {
                NavigationLink(LAACopy.WorkTab.openSuccessor) {
                    LAAWorkSessionDetail(id: nextID, projects: projects, workspaces: workspaces, drafts: drafts)
                }
            }
        }.workCard()
    }

    @discardableResult @MainActor private func refreshSnapshot() async -> Bool {
        do {
            async let detailRead: LAAWorkSession = bridge.read("/v1/sessions/\(id)")
            async let historyRead: LAAWorkPage<LAAWorkConversationMessage> = bridge.read("/v1/sessions/\(id)/conversation")
            let detail = try await detailRead
            session = detail
            LAAWorkSessionCache.save(detail, store: drafts, device: bridge.deviceID, target: id)
            do {
                let history = try await historyRead
                messages = history.items
                LAAWorkSessionCache.save(messages, store: drafts, device: bridge.deviceID, target: id + ":messages")
                conversationUnavailable = false
            } catch {
                conversationUnavailable = true
            }
            failure = nil
            if detail.phase == "stopped", !stopping, let pendingStop,
               !drafts.finishSubmission(pendingStop.id, restoring: false) {
                failure = "確認した停止状態を端末に保存できませんでした。"
            }
            if detail.observation?.available == false {
                notice = "委譲先の状態を観測できていません。表示は最後に確認できた記録です。"
            }
            return true
        } catch is CancellationError {
        } catch let error as LAABridgeError { failure = error.japaneseText }
        catch { failure = "セッションを読み取れませんでした。" }
        return false
    }

    @MainActor private func observe() async {
        session = LAAWorkSessionCache.read(LAAWorkSession.self, store: drafts, device: bridge.deviceID, target: id)
        messages = LAAWorkSessionCache.read([LAAWorkConversationMessage].self, store: drafts, device: bridge.deviceID, target: id + ":messages") ?? []
        cursor = nil
        events.removeAll()
        let loaded = await refreshSnapshot()
        // Even when the detail or history read failed, opening is done: the
        // view can now place itself at the bottom instead of staying at the top.
        historyLoaded = true
        guard loaded, let initial = session else { return }
        var afterSeq: Int? = max(0, initial.events.oldestSeq - 1)
        var consecutiveGaps = 0
        while !Task.isCancelled {
            do {
                var query = [URLQueryItem(name: "wait", value: "2"), URLQueryItem(name: "limit", value: "100")]
                if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
                else if let afterSeq { query.append(URLQueryItem(name: "afterSeq", value: String(afterSeq))) }
                let response: LAABridgeResponse<LAAWorkEventPage> = try await bridge.request(
                    method: "GET", path: LAAWorkPresentation.path("/v1/sessions/\(id)/events", query: query), timeout: 20)
                let page = response.data
                consecutiveGaps = 0
                let known = Set(events.map(\.seq))
                events.append(contentsOf: page.items.filter { !known.contains($0.seq) })
                events.sort { $0.seq < $1.seq }
                cursor = page.nextCursor
                afterSeq = nil
                if page.resyncRequired {
                    notice = "委譲先を観測できず再同期が必要です。詳細と成果物を読み直しています。"
                    await refreshSnapshot()
                    try await Task.sleep(for: .seconds(5))
                } else {
                    await refreshSnapshot()
                    if !historyGapSeen && session?.observation?.available != false { notice = nil }
                }
            } catch is CancellationError { return }
            catch let error as LAABridgeHTTPError where error.status == 410 {
                historyGapSeen = true
                notice = "記録の取得位置が期限切れか、履歴に欠落があります。詳細と成果物を読み直しています。"
                guard await refreshSnapshot() else { return }
                notice = "記録の取得位置が期限切れか、履歴に欠落しました。詳細と成果物を読み直しました。"
                cursor = nil
                afterSeq = max(0, (session?.events.oldestSeq ?? 1) - 1)
                events.removeAll()
                consecutiveGaps += 1
                if consecutiveGaps >= 2 { return }
            } catch let error as LAABridgeError {
                failure = error.japaneseText
                return
            } catch let error as LAABridgeHTTPError {
                failure = LAAWorkHTTP.message(error)
                return
            } catch { failure = "経過を取得できませんでした。"; return }
        }
    }

    private func beginStop() {
        guard let key = stopKey, let body = "{}".data(using: .utf8),
              let item = LAAWorkDrafts.reserve(drafts, key: key, text: "中断要求", body: body,
                                               idempotency: LAABridgeIdempotencyKey()) else {
            failure = "中断要求を端末に安全に記録できませんでした。"; return
        }
        Task { await performStop(item) }
    }

    @MainActor private func performStop(_ item: ComposerDraftStore.Submission) async {
        guard LAAWorkDrafts.canRepeat(item) else { failure = LAAWorkDrafts.expiredMessage; return }
        guard let (body, key) = LAAWorkDrafts.request(item) else { failure = "中断要求の記録を読み取れません。"; return }
        stopping = true
        defer { stopping = false }
        do {
            let _: LAAWorkSession = try await LAAWorkHTTP.write(bridge, path: "/v1/sessions/\(id)/interrupt", body: body, key: key)
            if !drafts.finishSubmission(item.id, restoring: false) { failure = "結果を端末に保存できません。中断状態を確認してください。" }
            await refreshSnapshot()
        } catch let error as LAABridgeHTTPError {
            if LAAWorkHTTP.outcomeUnknown(error) { drafts.markSubmissionUnknown(item.id) }
            else { _ = drafts.finishSubmission(item.id, restoring: false) }
            let explanation = LAAWorkHTTP.message(error)
            await refreshSnapshot()
            notice = explanation
        } catch {
            drafts.markSubmissionUnknown(item.id)
            notice = "中断要求の結果は未確認です。中断済みとは表示しません。"
            await refreshSnapshot()
        }
    }
}
#endif
