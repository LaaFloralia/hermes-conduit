#if LAA_BUILD
import SwiftUI
import LAAKit

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

/// Where the transcript should be placed. The iOS 18 path hands the request to
/// `ScrollPosition`; iOS 17 keeps the scroll-view proxy. Either way the decision
/// is made here, from measured heights, not from a row count.
private struct LAAWorkScrollRequest: Equatable {
    enum Target: Equatable { case top, bottom, decision, message(String) }
    var target: Target = .top
    var token = 0
    mutating func move(to target: Target) {
        self.target = target
        token &+= 1
    }
}

/// iOS 18 placement. `ScrollPosition` holds the target itself, so a lazy row
/// that is still being measured — or an image that arrives later — keeps the
/// bottom in place instead of stopping short of it.
@available(iOS 18.0, *)
private struct LAAWorkPositionedScroll<Content: View>: View {
    let request: LAAWorkScrollRequest
    let onGeometry: (CGFloat, CGFloat) -> Void
    let onDrag: () -> Void
    let refresh: () async -> Void
    @ViewBuilder let content: () -> Content
    @State private var position = ScrollPosition()

    private struct Geometry: Equatable {
        let content: CGFloat
        let container: CGFloat
    }

    var body: some View {
        ScrollView { content() }
            .scrollPosition($position)
            .onScrollGeometryChange(for: Geometry.self) { value in
                Geometry(content: value.contentSize.height, container: value.containerSize.height)
            } action: { _, value in
                onGeometry(value.content, value.container)
            }
            .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in onDrag() })
            .refreshable { await refresh() }
            .onChange(of: request) { _, value in
                switch value.target {
                case .top: position.scrollTo(edge: .top)
                case .bottom: position.scrollTo(edge: .bottom)
                case .decision: position.scrollTo(id: "decision-start", anchor: .top)
                case .message(let id): position.scrollTo(id: id, anchor: .top)
                }
            }
    }
}

struct LAAWorkSessionDetail: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.laaDesktop) private var laaDesktop
    /// The working capsule's height follows the text size (the transcript's end room).
    @Environment(\.dynamicTypeSize) private var typeSize
    @ObservedObject var drafts: ComposerDraftStore
    let id: String
    let projects: [LAAWorkProject]
    let workspaces: [LAAWorkWorkspace]
    @State private var showingInitialInstruction = false
    @State private var session: LAAWorkSession?
    @State private var events: [LAAWorkEvent] = []
    @State private var messages: [LAAWorkConversationMessage] = []
    @State private var historyReady = false
    /// Older pages are offered above the newest one, as in Chat.
    @State private var canLoadOlder = false
    @State private var backfilled = false
    @State private var loadingOlder = false
    /// The provider is compacting the conversation's context now.
    @State private var compacting = false
    /// Messages this device sent that the conversation does not show yet: a
    /// follow-up the Bridge holds until the running turn ends is not in
    /// Paseo's history, so without these it looked lost, pictures and all.
    @State private var sentEchoes: [LAAWorkSentEcho] = []
    @State private var lastDetailData: Data?
    @State private var lastHistoryData: Data?
    @State private var conversationUnavailable = false
    @State private var cursor: String?
    @State private var notice: String?
    @State private var failure: String?
    @State private var stopping = false
    @State private var historyGapSeen = false
    @State private var observationEpoch = 0
    @State private var appliedObservationEpoch = 0
    @Environment(\.scenePhase) private var scenePhase
    @State private var transcriptVisible = false
    @State private var poll = LAAWorkTranscriptPoll()
    @State private var snapshotInFlight = false
    @State private var cacheIdentity: String?
    @State private var followsConversation = true
    /// This session's children (`parentId`), for the working pill and the
    /// subagent cards; read at most every `childrenInterval` seconds.
    @State private var workChildren: [LAAWorkSession] = []
    @State private var childrenReadAt: Date?
    @State private var openedChildID: String?
    @State private var showingChildren = false
    @State private var showingLauncher = false
    @State private var didInitialScroll = false
    /// True once the transcript can be placed: the cached copy counts, so a
    /// remembered conversation opens at its bottom without waiting for the Mac.
    @State private var openingReady = false
    @State private var userDragged = false
    @State private var contentHeight: CGFloat = 0
    @State private var scrollContentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    /// The last measurement, so the first placement can happen as soon as the
    /// remembered conversation is loaded instead of waiting for another one.
    @State private var measuredContent: CGFloat = 0
    @State private var measuredViewport: CGFloat = 0
    @State private var scrollRequest = LAAWorkScrollRequest()
    /// True while the page is showing a waiting decision. Measuring rows keep
    /// growing underneath it; pulling the page back to the bottom would hide
    /// the very card the owner was moved to.
    @State private var parkedOnDecision = false
    @State private var screenWidth: CGFloat = 0
    @State private var options: LAAWorkSessionOptions?
    @State private var changingEffort = false
    @State private var changingFast = false
    @State private var effortNotice: String?
    /// The last message the owner asked to quote into the follow-up field.
    @State private var quote: LAAWorkQuoteRequest?
    @AppStorage(ChatTypography.preferenceKey) private var responseSize = ChatTypography.defaultSize.rawValue

    /// Told each time the session's own record changes, so a Mac pane's
    /// heading shows the live phase and model rather than the list's copy.
    var onSession: ((LAAWorkSession) -> Void)?

    init(id: String, projects: [LAAWorkProject], workspaces: [LAAWorkWorkspace], drafts: ComposerDraftStore,
         onSession: ((LAAWorkSession) -> Void)? = nil) {
        self.id = id; self.projects = projects; self.workspaces = workspaces; self.drafts = drafts
        self.onSession = onSession
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
            if #available(iOS 18.0, *) {
                LAAWorkPositionedScroll(request: scrollRequest, onGeometry: place,
                                        onDrag: { userDragged = true; parkedOnDecision = false },
                                        refresh: { await refreshSnapshot() }) { page }
            } else {
                legacyScroll
            }
        }
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { viewportHeight = proxy.size.height }
                .onChange(of: proxy.size.height) { _, height in viewportHeight = height }
        })
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { screenWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in screenWidth = width }
        })
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let session {
                // The working pill and the jump button float above the field,
                // in its glass group (LAAWorkingCluster).
                LAAWorkingCluster(status: workingStatus(session), showsJump: didInitialScroll && !followsConversation,
                                  jump: returnToEnd, openChildren: openChildren, identifier: "work.working") {
                    followUp(session)
                }
                    .padding(.horizontal, LAASpacing.horizontal).padding(.vertical, 8)
                    // The Mac window's rounded bottom edge: the field's last
                    // row keeps clear of it rather than resting on it.
                    .padding(.bottom, laaDesktop ? LAASpacing.x2 : 0)
                    .frame(maxWidth: laaDesktop ? LAADesktopMetrics.readingWidth : 720)
                    .frame(maxWidth: .infinity)
                    .background(LAAColor.background)
            }
        }
        .navigationTitle(Text(verbatim: session?.name ?? LAACopy.WorkTab.sessions))
        .tint(LAAColor.link)
        .navigationBarTitleDisplayMode(.inline)
        .laaHidesTabBar()
        // The bar keeps the system's glass, as in Chat; painting the paper
        // here flattened it under the session pill.
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            // The heading is the bar's own: the transcript has no second one.
            // The Mac window already carries the name in its title bar, so the
            // pill would read twice there.
            if let session, !laaDesktop {
                ToolbarItem(placement: .principal) {
                    Button { showingInitialInstruction = true } label: {
                        LAAWorkSessionHeaderPill(session: session)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: session.name + "、" + LAAWorkPresentation.phase(session.phase)))
                    .accessibilityHint(Text(verbatim: "Show First Prompt"))
                    .accessibilityIdentifier("work.session.detail.title")
                        .frame(maxWidth: LAAConversationHeaderLayout.nameWidth(screenWidth: screenWidth))
                        .frame(minHeight: LAAConversationHeaderLayout.controlHeight)
                }
            }
            if !laaDesktop {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingLauncher = true } label: { Label("New", systemImage: "plus") }
                        .accessibilityIdentifier("work.session.detail.new")
                        .disabled(bridge.status != .paired)
                }
            }
        }
        .sheet(isPresented: $showingLauncher) {
            LAAWorkSessionLauncher(projects: projects, options: options, drafts: drafts) { created in
                showingLauncher = false
                openedChildID = created.id
            }
            .environmentObject(bridge)
            .laaSheetSize(.form)
        }
        .navigationDestination(item: $openedChildID) { childID in
            LAAWorkSessionDetail(id: childID, projects: projects, workspaces: workspaces, drafts: drafts)
        }
        .sheet(isPresented: $showingChildren) {
            LAASubagentSheet(children: childRows, open: { child in
                showingChildren = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    openedChildID = child.id
                }
            }, done: { showingChildren = false })
        }
        .sheet(isPresented: $showingInitialInstruction) {
            LAAWorkInitialInstruction(sessionID: id, sessionName: session?.name ?? "", session: session,
                                      projects: projects) { moved in session = moved }
                .environmentObject(bridge)
        }
        .onChange(of: session?.needsDecision) { _, waiting in
            guard waiting == true else { parkedOnDecision = false; return }
            guard didInitialScroll, !userDragged else { return }
            parkedOnDecision = true
            scrollRequest.move(to: .decision)
        }
        .onChange(of: lastDetailData, initial: true) { _, _ in
            if let session { onSession?(session) }
        }
        .onChange(of: openingReady) { _, ready in
            if ready { place(measuredContent, measuredViewport) }
        }
        .onChange(of: messages.count) { _, _ in followNewArrival() }
        .onChange(of: sentEchoes.count) { _, _ in followNewArrival() }
        .onChange(of: messages.last?.text) { _, _ in followNewArrival() }
        .onAppear { transcriptVisible = true }
        .onDisappear { transcriptVisible = false }
        .task(id: "\(bridge.revision)-\(id)-\(observationEpoch)-\(scenePhase)-\(transcriptVisible)") {
            guard transcriptVisible, scenePhase == .active else { return }
            await observe()
        }
        .task {
            if options == nil { options = try? await bridge.read("/v1/session-options") }
        }
    }

    // MARK: - The page

    private var page: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x4) {
            // The bottom sentinel stays outside the lazy transcript.
            LazyVStack(alignment: .leading, spacing: LAATranscriptMetrics.rowGap) {
                Color.clear.frame(height: 0).id("top-start")
                if let session {
                    if session.modelMismatch { mismatchLabel(session) }
                    if let notice { Label(notice, systemImage: "exclamationmark.triangle.fill").foregroundStyle(LAAColor.attention).workCard() }
                    if let failure {
                        VStack(alignment: .leading) {
                            Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(LAAColor.attention)
                            Button(LAACopy.WorkTab.reconnect) { observationEpoch += 1 }
                        }.workCard()
                    }
                    if session.needsDecision { LAAWorkSessionDecision(sessionID: id, drafts: drafts) { observationEpoch += 1 }.id("decision-start") }
                    if conversationUnavailable {
                        Text(verbatim: "履歴の応答がありません。接続を確認し、もう一度お試しください。")
                            .foregroundStyle(LAAColor.attention)
                    } else if messages.isEmpty && sentEchoes.isEmpty && !canStop(session) && !session.needsDecision {
                        // Only a quiet, idle session is empty: while it thinks
                        // or waits on a decision the line would contradict it.
                        Text(verbatim: "会話はまだありません。").foregroundStyle(LAAColor.secondaryText)
                    }
                    if canLoadOlder, !messages.isEmpty, !conversationUnavailable {
                        TranscriptBackfillControl(isLoading: loadingOlder) { loadOlder() }
                            .accessibilityIdentifier("work.session.loadOlder")
                    }
                    let shown = messages
                    let speakers = shown.map(LAAWorkSpeaker.speaker)
                    // The children, one card per spawn batch, after the
                    // message each batch followed (LAASubagentGroup).
                    let placements = LAAWorkChildren.placements(workChildren, messages: shown)
                    ForEach(placements.filter { $0.afterMessageID == nil }, id: \.id) { placement in
                        subagentGroup(placement)
                    }
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, message in
                        LAAWorkMessageRow(message: message, sessionID: id,
                                          agentName: LAAWorkSpeaker.replyName(message, session: session, options: options),
                                          continues: LAASenderRun.continues(speakers, at: index),
                                          responseSize: responseSize,
                                          model: LAAWorkSpeaker.replyModel(message, session: session),
                                          onQuote: { text in
                                              quote = LAAWorkQuoteRequest(text: text, token: (quote?.token ?? 0) &+ 1)
                                          }, cwd: session.cwd)
                        .id(message.id)
                        ForEach(placements.filter { $0.afterMessageID == message.id }, id: \.id) { placement in
                            subagentGroup(placement)
                        }
                    }
                    ForEach(sentEchoes) { echo in
                        LAAWorkSentEchoRow(echo: echo, queued: (session.queue?.count ?? 0) > 0)
                    }
                    // One line while the turn runs, in place of the tool
                    // traffic the transcript no longer lists (owner, 2026-11-12).
                    if canStop(session) { LAAWorkProgressLine(compacting: compacting) }
                    if !canInterrupt(session) || session.resumedTo != nil { actions(session) }
                } else if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(LAAColor.attention)
                    Button(LAACopy.WorkTab.retry) { observationEpoch += 1 }
                } else { LAALoadingDots() }
            }
            .accessibilityIdentifier(historyReady ? "work.session.history.ready" : "work.session.history.loading")
            // The end of the page, outside the lazy transcript. New arrivals
            // follow only while this sentinel is on screen.
            // Keeps the working pill's room free while the turn runs.
            Color.clear.frame(height: session.flatMap(workingStatus).map {
                LAAWorkingControlMetrics.coverage(children: $0.children.count, typeSize: typeSize)
            } ?? 1).id("bottom-end")
                .onAppear {
                    followsConversation = true
                    userDragged = false
                }
                .onDisappear { followsConversation = false }
        }
        .padding(.horizontal, LAASpacing.horizontal).padding(.vertical, LAASpacing.x4)
        .frame(maxWidth: laaDesktop ? LAADesktopMetrics.readingWidth : 720, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: laaDesktop ? .center : .leading)
        // The page's own height, used by the iOS 17 path to tell a short page
        // from a long one.
        .background(GeometryReader { proxy in
            Color.clear.preference(key: LAAWorkContentHeightKey.self, value: proxy.size.height)
        })
    }

    // MARK: - Working control and children

    /// How often the children list is read again while the page is open.
    private static let childrenInterval: TimeInterval = 10

    private var childRows: [LAAWorkingChild] {
        workChildren.map { LAAWorkChildren.child($0, options: options) }
    }

    /// The pill while the turn runs: the phase, the time since the owner's
    /// last message, and the children.
    private func workingStatus(_ session: LAAWorkSession) -> LAAWorkingStatus? {
        guard canStop(session) else { return nil }
        let start = LAAWorkChildren.turnStart(messages)
        let children = workChildren.filter { child in
            ["running", "created", "awaiting_decision", "stop_unconfirmed", "error"].contains(child.phase)
                || (start.map { start in (LAAWorkChildren.date(child.updatedAt)?.timeIntervalSince(start) ?? 0) > 0 } ?? false)
        }
        return LAAWorkingStatus(word: compacting ? LAAWorkPresentation.compacting : LAAWorkPresentation.phase(session.phase), startedAt: start,
                                orb: .thinking, children: children.map { LAAWorkChildren.child($0, options: options) })
    }

    /// A spawn batch's card; a row opens that child's session here.
    private func subagentGroup(_ placement: LAAWorkChildren.Placement) -> some View {
        LAASubagentGroup(children: placement.children.map { LAAWorkChildren.child($0, options: options) },
                         open: { openedChildID = $0.id }, identifier: "work.session.subagents")
            .padding(.top, LAATranscriptMetrics.turnGap - LAATranscriptMetrics.rowGap)
            .id("children-" + placement.id)
    }

    /// One child opens itself; two or more open the list.
    private func openChildren() {
        guard let session, let children = workingStatus(session)?.children, !children.isEmpty else { return }
        if children.count == 1 { openedChildID = children[0].id } else { showingChildren = true }
    }

    @MainActor private func refreshChildren() async {
        if let last = childrenReadAt, Date().timeIntervalSince(last) < Self.childrenInterval { return }
        childrenReadAt = Date()
        let query = [URLQueryItem(name: "parentId", value: id)]
        if let loaded: [LAAWorkSession] = try? await LAAWorkPaging.all(bridge, "/v1/sessions", query: query) {
            // An older Bridge ignores the query and lists every session.
            workChildren = loaded.filter { $0.parentId == id }
        }
    }

    /// The one row under the field: picture, model, Fast, stop, Send.
    @ViewBuilder private func followUp(_ session: LAAWorkSession) -> some View {
        let pendingMessage = bridge.deviceID.flatMap {
            LAAWorkDrafts.pending(drafts, key: LAAWorkDrafts.key(deviceID: $0, target: "message:\(id)"))
        }
        if let nextID = session.resumedTo, pendingMessage == nil {
            successorLink(nextID)
        } else {
            messageForm(session)
        }
    }

    private func messageForm(_ session: LAAWorkSession) -> some View {
        LAAWorkMessageForm(
            sessionID: id,
            readiness: .resolve(phase: session.phase, needsDecision: session.needsDecision,
                                stopPending: pendingStop != nil, hasSuccessor: session.resumedTo != nil), drafts: drafts,
            settingsRow: AnyView(
                LAAWorkSessionControls(session: session, options: options,
                                       changing: $changingEffort, changingFast: $changingFast,
                                       notice: $effortNotice) {
                    _ = await refreshSnapshot()
                }),
            interrupt: canStop(session) ? AnyView(stopButton) : nil,
            actionNotice: effortNotice,
            quote: quote,
            onCheckState: { Task { await refreshSnapshot() } },
            onDecision: { parkedOnDecision = true; scrollRequest.move(to: .decision) },
            onSent: { text, attachments in
                sentEchoes.append(LAAWorkSentEcho(text: text, attachments: attachments, after: messages.last?.id))
                returnToEnd()
            }
        ) { _ in
            Task { await refreshSnapshot() }
        }
    }

    private func successorLink(_ id: String) -> some View {
        NavigationLink(LAACopy.WorkTab.openSuccessor) {
            LAAWorkSessionDetail(id: id, projects: projects, workspaces: workspaces, drafts: drafts)
        }
        .accessibilityIdentifier("work.session.successor")
    }

    private var legacyScroll: some View {
        ScrollViewReader { scroll in
            ScrollView { page }
                .modifier(LAAWorkScrollHeightReader { height in
                    // Only growth matters here: a late image or a freshly
                    // measured lazy row must still reach the bottom.
                    let grew = height > scrollContentHeight + 1
                    scrollContentHeight = height
                    if !openingReady || grew { place(max(contentHeight, scrollContentHeight), viewportHeight) }
                })
                .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in
                    userDragged = true; parkedOnDecision = false
                })
                .refreshable { await refreshSnapshot() }
                .onPreferenceChange(LAAWorkContentHeightKey.self) { height in
                    contentHeight = height
                    place(max(height, scrollContentHeight), viewportHeight)
                }
                .onChange(of: scrollRequest) { _, value in apply(value, to: scroll) }
        }
    }

    /// iOS 18 measures the scroll view itself; the legacy path passes the
    /// page's measured height and the viewport.
    private func place(_ height: CGFloat, _ viewport: CGFloat) {
        measuredContent = height
        measuredViewport = viewport
        guard openingReady, viewport > 0, height > 0 else { return }
        guard !userDragged else { return }
        // A decision card is the destination while it is waiting, even when a
        // late row or image makes the page taller.
        guard !(parkedOnDecision && session?.needsDecision == true) else { return }
        if height > viewport + 1 {
            didInitialScroll = true
            // A waiting decision is the reason the page is tall: land on the
            // question, not at the end of the transcript below it.
            if session?.needsDecision == true {
                parkedOnDecision = true
                scrollRequest.move(to: .decision)
            } else {
                scrollRequest.move(to: .bottom)
            }
        } else {
            scrollRequest.move(to: .top)
        }
    }

    private func apply(_ request: LAAWorkScrollRequest, to scroll: ScrollViewProxy) {
        switch request.target {
        case .top:
            DispatchQueue.main.async { scroll.scrollTo("top-start", anchor: .top) }
        case .bottom:
            DispatchQueue.main.async { scroll.scrollTo("bottom-end", anchor: .bottom) }
        case .decision:
            DispatchQueue.main.async { scroll.scrollTo("decision-start", anchor: .top) }
        case .message(let id):
            DispatchQueue.main.async { scroll.scrollTo(id, anchor: .top) }
        }
    }

    /// Sending is an explicit "back to the end" (owner, 2026-11-12): wherever
    /// the owner had scrolled, the page moves to the message just sent and the
    /// progress line under it, and follows again. Placed once now and once
    /// after the new row has been laid out, as a late row or picture would
    /// otherwise stop it short. A reply that only arrives still leaves the
    /// reading position alone (followNewArrival).
    private func returnToEnd() {
        userDragged = false
        parkedOnDecision = false
        followsConversation = true
        didInitialScroll = true
        scrollRequest.move(to: .bottom)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !userDragged else { return }
            scrollRequest.move(to: .bottom)
        }
    }

    /// A new turn follows only while the owner is at the bottom and no decision
    /// is waiting for them.
    private func followNewArrival() {
        guard didInitialScroll, !userDragged, followsConversation, session?.needsDecision != true else { return }
        scrollRequest.move(to: .bottom)
    }


    /// The heading card is gone; a mismatch between what was asked for and
    /// what the daemon reports still belongs at the top of the conversation,
    /// named: "依頼 Fable 5.2 → 実行 Opus 4.8", and when the Bridge saw the
    /// switch itself, when.
    @ViewBuilder private func mismatchLabel(_ session: LAAWorkSession) -> some View {
        if let mismatch = LAAWorkSessionStyle.mismatch(session, options: options) {
            LAAWorkMismatchLine(mismatch: mismatch)
                .accessibilityIdentifier("work.session.modelMismatch")
        } else {
            Label(LAAWorkPresentation.japanese("要求と観測が一致しません"), systemImage: "exclamationmark.triangle.fill")
                .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                .accessibilityIdentifier("work.session.modelMismatch")
        }
    }

    private func canInterrupt(_ session: LAAWorkSession) -> Bool {
        pendingStop == nil && !["stop_unconfirmed", "stopped"].contains(session.phase)
    }

    /// The stop control only appears while there is a turn to stop.
    private func canStop(_ session: LAAWorkSession) -> Bool {
        canInterrupt(session) && ["running", "awaiting_decision"].contains(session.phase)
    }

    /// The same 36 pt glass circle as Send beside it (owner, 2026-11-11: the
    /// stop's ring was larger than Send's); only the square and its colour
    /// say which one ends the turn.
    private var stopButton: some View {
        LAAGlassActionButton(systemImage: "stop.fill", label: LAACopy.WorkTab.stop, role: .stop, enabled: !stopping,
                             identifier: "work.session.stop") { beginStop() }
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
            }
        }.workCard()
    }

    @discardableResult @MainActor private func refreshSnapshot(
        _ trigger: LAAWorkTranscriptPoll.Trigger = .user
    ) async -> Bool {
        guard !Task.isCancelled, transcriptVisible, scenePhase == .active,
              !snapshotInFlight, poll.allows(trigger) else { return session != nil }
        snapshotInFlight = true
        defer { snapshotInFlight = false }
        do {
            let response: LAABridgeResponse<LAAWorkSession> = try await bridge.request(
                method: "GET", path: "/v1/sessions/\(id)")
            try Task.checkCancellation()
            let detail = response.data
            await refreshChildren()
            let detailData = try? snapshotData(detail)
            if detailData != lastDetailData {
                session = detail; lastDetailData = detailData
                LAAWorkSessionCache.save(detail, store: drafts, device: bridge.deviceID, target: id)
            }
            let retired = detail.isArchived || ["retired", "closed"].contains(detail.phase) || detail.resumedTo != nil
            if retired { poll.complete(.stopped) }
            else if poll.isStopped { poll = LAAWorkTranscriptPoll() }
            // Opening or explicitly refreshing an archived conversation is a
            // one-shot read, not an automated transcript poll.
            if retired && trigger != .user { failure = nil; return true }
            do {
                let response: LAABridgeResponse<LAAWorkConversationPage> = try await bridge.request(
                    method: "GET", path: LAAWorkTranscriptPages.latestPath(id))
                try Task.checkCancellation()
                let history = response.data
                if !retired { poll.complete(.success) }
                compacting = history.compacting == true
                // An older Bridge still sends tool rows; they are not part of
                // the conversation the owner reads.
                let items = history.items.filter { $0.role != "tool" }
                let data = try? snapshotData(items)
                if data != lastHistoryData {
                    let shown = LAAWorkTranscriptPages.latest(items, hasOlder: history.hasOlder, onto: shownPages)
                    messages = shown.messages; canLoadOlder = shown.canLoadOlder; backfilled = shown.backfilled
                    lastHistoryData = data
                    // Only the latest page is remembered, so a long session
                    // reopens as fast as a short one.
                    LAAWorkSessionCache.save(items, store: drafts, device: bridge.deviceID, target: id + ":messages")
                } else if !backfilled {
                    // The remembered page matches; only the Bridge knows
                    // whether older pages exist.
                    canLoadOlder = history.hasOlder ?? false
                }
                sentEchoes = LAAWorkSentEcho.pending(sentEchoes, in: messages)
                historyReady = true
                conversationUnavailable = false
            } catch is CancellationError {
                return false
            } catch {
                guard !Task.isCancelled else { return false }
                if !retired { poll.complete(Self.pollOutcome(for: error)) }
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
        } catch let error as LAABridgeError {
            poll.complete(Self.pollOutcome(for: error))
            failure = error.japaneseText
        } catch {
            poll.complete(Self.pollOutcome(for: error))
            failure = (error as? LAABridgeHTTPError).map(LAAWorkHTTP.message) ?? "セッションを読み取れませんでした。"
        }
        return false
    }

    private static func pollOutcome(for error: Error) -> LAAWorkTranscriptPoll.Outcome {
        if let status = (error as? LAABridgeHTTPError)?.status, [401, 403, 404, 410].contains(status) {
            return .stopped
        }
        return .unavailable
    }

    private var shownPages: LAAWorkTranscriptPages.Shown {
        LAAWorkTranscriptPages.Shown(messages: messages, canLoadOlder: canLoadOlder, backfilled: backfilled)
    }

    /// "Load earlier messages": the page before the oldest message shown lands
    /// above it, and the page is held on that message, so what the owner was
    /// reading stays where it was. Holding counts as the owner's own scroll:
    /// nothing pulls the page back to the end until they return there.
    private func loadOlder() {
        guard !loadingOlder, let anchor = messages.first?.id else { return }
        loadingOlder = true
        userDragged = true; parkedOnDecision = false
        Task { @MainActor in
            defer { loadingOlder = false }
            do {
                // `request` keeps the HTTP status, so a cursor the Bridge no
                // longer has (410) is told apart from a failed read.
                let response: LAABridgeResponse<LAAWorkConversationPage> = try await bridge.request(
                    method: "GET", path: LAAWorkTranscriptPages.olderPath(id, before: anchor))
                let page = response.data
                guard messages.first?.id == anchor else { return }
                let older = page.items.filter { $0.role != "tool" }
                let shown = LAAWorkTranscriptPages.prepend(older, hasOlder: page.hasOlder, onto: shownPages)
                messages = shown.messages; canLoadOlder = shown.canLoadOlder; backfilled = shown.backfilled
                scrollRequest.move(to: .message(anchor))
            } catch let error as LAABridgeHTTPError where error.status == 410 {
                // The history was rewritten under the page: start again from
                // the latest page.
                lastHistoryData = nil; backfilled = false
                await refreshSnapshot()
            } catch {}
        }
    }

    private func snapshotData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    @MainActor private func observe() async {
        let identity = "\(bridge.revision)-\(id)"
        let opening = cacheIdentity != identity
        if opening {
            cacheIdentity = identity
            poll = LAAWorkTranscriptPoll()
            restoreTranscriptCache()
        }
        let retry = observationEpoch != appliedObservationEpoch
        appliedObservationEpoch = observationEpoch
        let loaded = await refreshSnapshot(opening || retry ? .user : .heartbeat)
        guard !poll.isStopped else { return }
        var afterSeq: Int? = cursor == nil ? max(0, (session?.events.oldestSeq ?? 1) - 1) : nil
        var consecutiveGaps = 0
        if !loaded { try? await Task.sleep(for: .seconds(2)) }
        while !Task.isCancelled && !poll.isStopped {
            do {
                var query = [URLQueryItem(name: "wait", value: "2"), URLQueryItem(name: "limit", value: "100")]
                if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
                else if let afterSeq { query.append(URLQueryItem(name: "afterSeq", value: String(afterSeq))) }
                let response: LAABridgeResponse<LAAWorkEventPage> = try await bridge.request(
                    method: "GET", path: LAAWorkPresentation.path("/v1/sessions/\(id)/events", query: query), timeout: 20)
                try Task.checkCancellation()
                let page = response.data
                let known = Set(events.map(\.seq))
                let fresh = page.items.filter { !known.contains($0.seq) }
                // Existing events on initial catch-up aren't a change signal.
                let changed = cursor != nil && !fresh.isEmpty
                consecutiveGaps = 0
                events.append(contentsOf: fresh)
                events.sort { $0.seq < $1.seq }
                cursor = page.nextCursor
                afterSeq = nil
                if page.resyncRequired {
                    notice = "委譲先を観測できず再同期が必要です。詳細と成果物を読み直しています。"
                    await refreshSnapshot(changed ? .changed : .heartbeat)
                    try await Task.sleep(for: .seconds(5))
                } else {
                    await refreshSnapshot(changed ? .changed : .heartbeat)
                    if !historyGapSeen && session?.observation?.available != false { notice = nil }
                    // Archived/finished feeds may return empty immediately.
                    if fresh.isEmpty { try await Task.sleep(for: .seconds(1)) }
                }
            } catch is CancellationError { return }
            catch let error as LAABridgeHTTPError where error.status == 410 {
                historyGapSeen = true
                notice = "記録の取得位置が期限切れか、履歴に欠落があります。詳細と成果物を読み直しています。"
                await refreshSnapshot(consecutiveGaps == 0 ? .changed : .heartbeat)
                cursor = nil
                afterSeq = max(0, (session?.events.oldestSeq ?? 1) - 1)
                events.removeAll()
                consecutiveGaps += 1
                if consecutiveGaps >= 2 { return }
            } catch {
                guard !Task.isCancelled else { return }
                guard Self.pollOutcome(for: error) != .stopped else { poll.complete(.stopped); return }
                // Losing the event feed shouldn't prevent the deadline from
                // reopening the transcript once the Bridge becomes reachable.
                await refreshSnapshot(.heartbeat)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func restoreTranscriptCache() {
        session = LAAWorkSessionCache.read(LAAWorkSession.self, store: drafts, device: bridge.deviceID, target: id)
        let cachedHistory = LAAWorkSessionCache.read([LAAWorkConversationMessage].self, store: drafts, device: bridge.deviceID, target: id + ":messages")
        // A copy saved before paging may hold the whole history: open on its
        // latest page, and let the first read say whether older ones exist.
        messages = Array((cachedHistory ?? []).filter { $0.role != "tool" }.suffix(LAAWorkTranscriptPages.pageSize))
        historyReady = cachedHistory != nil
        canLoadOlder = false; backfilled = false; loadingOlder = false
        sentEchoes = []
        compacting = false
        lastDetailData = session.flatMap { try? snapshotData($0) }
        lastHistoryData = try? snapshotData(messages)
        cursor = nil
        events.removeAll()
        // The remembered conversation is enough to place the page: waiting for
        // the Mac here left a long transcript at its top, and a touch in that
        // window stopped it from ever following to the bottom.
        openingReady = true
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

/// The conversation's fixed heading: the name, and under it the short number
/// and phase, on the same small glass the employee chat uses in its bar.
struct LAAWorkSessionHeaderPill: View {
    let session: LAAWorkSession
    @Environment(\.laaClearGlassControls) private var clearGlass

    var body: some View {
        HStack(spacing: 8) {
            // Who the owner is talking to, as in the transcript below.
            LAAHarnessMark(harness: LAAHarness.work(session.harness ?? (session.observed ?? session.requested)?.provider), size: 26)
            VStack(alignment: .center, spacing: 2) {
                Text(verbatim: session.name)
                    .laaTextStyle(.body).fontWeight(.semibold)
                    .foregroundStyle(LAAColor.text)
                    .lineLimit(1).truncationMode(.middle)
                    .accessibilityIdentifier("work.session.detail.title")
                let status = LAAWorkStatus.session(session.phase)
                HStack(spacing: LAASpace.s4) {
                    Text(verbatim: LAAWorkPresentation.phaseSymbol(session.phase))
                        .foregroundStyle(status.color).accessibilityHidden(true)
                    Text(verbatim: status.displayLabel).foregroundStyle(LAAColor.secondaryText)
                }
                .laaTextStyle(.note).fixedSize()
            }
        }
        .modifier(LAAWorkSessionHeaderGlass(clear: clearGlass))
        .accessibilityElement(children: .combine)
        // The combined element is what VoiceOver and the UI tests see, so the
        // name's own identifier is repeated here.
        .accessibilityIdentifier("work.session.detail.title")
    }
}

private struct LAAWorkSessionHeaderGlass: ViewModifier {
    let clear: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, LAASpace.s8)
            .padding(.vertical, LAASpace.s4)
            .background {
                if clear { Capsule().fill(LAAColor.surface) }
            }
            .laaGlassCapsule(interactive: false, tinted: false)
    }
}
#endif
