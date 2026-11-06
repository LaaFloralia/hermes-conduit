#if LAA_BUILD
import SwiftUI

private struct LAAWorkScrollHeightReader: ViewModifier {
    let onChange: (CGFloat) -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height
            } action: { _, height in
                onChange(height)
            }
        } else {
            content
        }
    }
}

private struct LAAWorkContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

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
    @State private var contentHeight: CGFloat = 0
    @State private var scrollContentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
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
                VStack(alignment: .leading, spacing: LAASpacing.x4) {
                    // Only the transcript is lazy. The composer and the bottom
                    // sentinel are ordinary children, so scrollTo always has a
                    // real target instead of a position inside a lazy estimate.
                    LazyVStack(alignment: .leading, spacing: LAASpacing.x4) {
                        Color.clear.frame(height: 0).id("top-start")
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
                            if conversationUnavailable {
                                Text(verbatim: "会話履歴を取得できません。更新して再確認してください。")
                                    .foregroundStyle(LAAColor.attention)
                            } else if messages.isEmpty {
                                Text(verbatim: "会話はまだありません。").foregroundStyle(LAAColor.secondaryText)
                            }
                            ForEach(LAAWorkToolRuns.groups(messages)) { group in
                                switch group.kind {
                                case .message:
                                    if let message = group.messages.first { messageCard(message) }
                                case .tools:
                                    LAAWorkToolRunsView(tools: group.messages)
                                }
                            }
                            if !canInterrupt(session) || session.resumedTo != nil { actions(session) }
                        } else if let failure {
                            Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(LAAColor.attention)
                            Button(LAACopy.WorkTab.retry) { observationEpoch += 1 }
                        } else { ProgressView().accessibilityLabel(Text(verbatim: "読み込み中")) }
                    }
                    if let session {
                        LAAWorkMessageForm(sessionID: id, mode: .followUp, drafts: drafts,
                                           canStart: ["awaiting_review", "running"].contains(session.phase) && !session.needsDecision,
                                           headerAccessory: canInterrupt(session) ? AnyView(stopButton) : nil) { _ in
                            Task { await refreshSnapshot() }
                        }
                        LAAWorkSessionControls(session: session, options: options,
                                               changing: $changingEffort, notice: $effortNotice) {
                            _ = await refreshSnapshot()
                        }
                    }
                    // The end of the page, outside the lazy transcript. New
                    // arrivals follow only while this sentinel is on screen.
                    Color.clear.frame(height: 1).id("bottom-end")
                        .onAppear {
                            followsConversation = true
                            userDragged = false
                        }
                        .onDisappear { followsConversation = false }
                }
                .padding(.horizontal, LAASpacing.horizontal).padding(.vertical, LAASpacing.x4)
                .frame(maxWidth: laaDesktop ? LAADesktopMetrics.readingWidth : 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: laaDesktop ? .center : .leading)
                // The page's own height, used to tell a short page (no
                // scrolling needed) from a long one (open at the bottom).
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: LAAWorkContentHeightKey.self, value: proxy.size.height)
                })
            }
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { viewportHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, height in viewportHeight = height }
            })
            .modifier(LAAWorkScrollHeightReader { height in
                // Only growth matters here: a late image or a freshly measured
                // lazy row must still reach the bottom even after the first
                // placement. Scrolling itself does not change the content size,
                // and a real drag is excluded inside updateContentFit.
                let grew = height > scrollContentHeight + 1
                scrollContentHeight = height
                if !didInitialScroll || grew { updateContentFit(scroll) }
            })
            .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in userDragged = true })
            .refreshable { await refreshSnapshot() }
            .onPreferenceChange(LAAWorkContentHeightKey.self) { height in
                contentHeight = height
                updateContentFit(scroll)
            }
            .onChange(of: viewportHeight) { _, _ in updateContentFit(scroll) }
            .onChange(of: historyLoaded) { _, _ in updateContentFit(scroll) }
            .onChange(of: session?.needsDecision) { _, waiting in
                if didInitialScroll, waiting == true, !userDragged { scroll.scrollTo("decision-start", anchor: .top) }
            }
            .onChange(of: messages.count) { _, _ in
                updateContentFit(scroll)
                guard didInitialScroll else { return }
                if !userDragged && followsConversation && session?.needsDecision != true { scroll.scrollTo("bottom-end", anchor: .bottom) }
            }
            .onChange(of: messages.last?.text) { _, _ in
                guard didInitialScroll else { return }
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

    /// A page taller than the viewport is placed at its bottom explicitly; a
    /// shorter page stays at the top. An anchor cannot do this: a bottom anchor
    /// on a tall lazy stack can land in a blank region before its rows exist.
    /// A user drag stops all automatic placement.
    private func updateContentFit(_ scroll: ScrollViewProxy) {
        guard historyLoaded, viewportHeight > 0, contentHeight > 0 else { return }
        // Measured height only. A row count cannot tell a tall page: several
        // tool runs collapse into one short row, and a short page must never
        // receive the bottom placement that leaves blank space above.
        let measured = max(contentHeight, scrollContentHeight)
        let tall = measured > viewportHeight + 1
        guard !userDragged else { return }
        if tall {
            didInitialScroll = true
            DispatchQueue.main.async { scroll.scrollTo("bottom-end", anchor: .bottom) }
        } else {
            DispatchQueue.main.async { scroll.scrollTo("top-start", anchor: .top) }
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
