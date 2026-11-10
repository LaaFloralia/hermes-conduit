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

/// Where the transcript should be placed. The iOS 18 path hands the request to
/// `ScrollPosition`; iOS 17 keeps the scroll-view proxy. Either way the decision
/// is made here, from measured heights, not from a row count.
private struct LAAWorkScrollRequest: Equatable {
    enum Target: Equatable { case top, bottom, decision }
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
                }
            }
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
    @State private var conversationMessages: [LAAWorkConversationMessage] = []
    @State private var historyReady = false
    @State private var workRecords: [LAAWorkConversationMessage] = []
    @State private var lastDetailData: Data?
    @State private var lastHistoryData: Data?
    @State private var conversationUnavailable = false
    @State private var cursor: String?
    @State private var notice: String?
    @State private var failure: String?
    @State private var stopping = false
    @State private var historyGapSeen = false
    @State private var observationEpoch = 0
    @State private var followsConversation = true
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
                followUp(session)
                    .padding(.horizontal, LAASpacing.horizontal).padding(.vertical, 8)
                    .frame(maxWidth: laaDesktop ? LAADesktopMetrics.readingWidth : 720)
                    .frame(maxWidth: .infinity)
                    .background(LAAColor.background)
            }
        }
        .navigationTitle(Text(verbatim: session?.name ?? LAACopy.WorkTab.sessions))
        .tint(LAAColor.link)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        // The bar keeps the system's glass, as in Chat; painting the paper
        // here flattened it under the session pill.
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            // The heading is the bar's own: the transcript has no second one.
            // The Mac window already carries the name in its title bar, so the
            // pill would read twice there.
            if let session, !laaDesktop {
                ToolbarItem(placement: .principal) {
                    LAAWorkSessionHeaderPill(session: session)
                        .frame(maxWidth: LAAConversationHeaderLayout.nameWidth(screenWidth: screenWidth))
                        .frame(minHeight: LAAConversationHeaderLayout.controlHeight)
                }
            }
        }
        .onChange(of: session?.needsDecision) { _, waiting in
            guard waiting == true else { parkedOnDecision = false; return }
            guard didInitialScroll, !userDragged else { return }
            parkedOnDecision = true
            scrollRequest.move(to: .decision)
        }
        .onChange(of: openingReady) { _, ready in
            if ready { place(measuredContent, measuredViewport) }
        }
        .onChange(of: messages.count) { _, _ in followNewArrival() }
        .onChange(of: messages.last?.text) { _, _ in followNewArrival() }
        .task(id: "\(bridge.revision)-\(id)-\(observationEpoch)") { await observe() }
        .task {
            if options == nil { options = try? await bridge.read("/v1/session-options") }
        }
    }

    // MARK: - The page

    private var page: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x4) {
            // The bottom sentinel stays outside the lazy transcript.
            LazyVStack(alignment: .leading, spacing: LAASpacing.x4) {
                Color.clear.frame(height: 0).id("top-start")
                if let session {
                    if session.modelMismatch { mismatchLabel }
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
                    // Tool calls are not part of the conversation the owner
                    // reads; only the messages they wrote or received are.
                    let shown = conversationMessages
                    let speakers = shown.map(LAAWorkSpeaker.speaker)
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, message in
                        LAAWorkMessageRow(message: message, sessionID: id,
                                          agentName: LAAWorkSpeaker.agentName(session, options: options),
                                          continues: LAASenderRun.continues(speakers, at: index),
                                          columnWidth: columnWidth, responseSize: responseSize)
                    }
                    if !workRecords.isEmpty { LAAWorkRecordDisclosure(records: workRecords) }
                    if !canInterrupt(session) || session.resumedTo != nil { actions(session) }
                } else if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(LAAColor.attention)
                    Button(LAACopy.WorkTab.retry) { observationEpoch += 1 }
                } else { LAALoadingDots() }
            }
            .accessibilityIdentifier(historyReady ? "work.session.history.ready" : "work.session.history.loading")
            // The end of the page, outside the lazy transcript. New arrivals
            // follow only while this sentinel is on screen.
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
        // The page's own height, used by the iOS 17 path to tell a short page
        // from a long one.
        .background(GeometryReader { proxy in
            Color.clear.preference(key: LAAWorkContentHeightKey.self, value: proxy.size.height)
        })
    }

    /// The one row under the field: picture, model, Fast, stop, Send.
    private func followUp(_ session: LAAWorkSession) -> some View {
        LAAWorkMessageForm(
            sessionID: id, mode: .followUp, drafts: drafts,
            canStart: ["awaiting_review", "running"].contains(session.phase) && !session.needsDecision,
            settingsRow: AnyView(
                LAAWorkSessionControls(session: session, options: options,
                                       changing: $changingEffort, changingFast: $changingFast,
                                       notice: $effortNotice) {
                    _ = await refreshSnapshot()
                }),
            interrupt: canStop(session) ? AnyView(stopButton) : nil,
            actionNotice: effortNotice
        ) { _ in
            Task { await refreshSnapshot() }
        }
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
        }
    }

    /// A new turn follows only while the owner is at the bottom and no decision
    /// is waiting for them.
    private func followNewArrival() {
        guard didInitialScroll, !userDragged, followsConversation, session?.needsDecision != true else { return }
        scrollRequest.move(to: .bottom)
    }


    /// The chat's 85% reading column, of the screen on a phone and of the
    /// reading width on a Mac.
    private var columnWidth: CGFloat? {
        guard screenWidth > 0 else { return nil }
        return min(screenWidth, laaDesktop ? LAADesktopMetrics.readingWidth : 720) * 0.85
    }

    /// The heading card is gone; a mismatch between what was asked for and
    /// what the daemon reports still belongs at the top of the conversation.
    private var mismatchLabel: some View {
        Label(LAAWorkPresentation.japanese("要求と観測が一致しません"), systemImage: "exclamationmark.triangle.fill")
            .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
            .accessibilityIdentifier("work.session.modelMismatch")
    }

    private func canInterrupt(_ session: LAAWorkSession) -> Bool {
        pendingStop == nil && !["stop_unconfirmed", "stopped"].contains(session.phase)
    }

    /// The stop control only appears while there is a turn to stop.
    private func canStop(_ session: LAAWorkSession) -> Bool {
        canInterrupt(session) && ["running", "awaiting_decision"].contains(session.phase)
    }

    private var stopButton: some View {
        Button { beginStop() } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LAAColor.end)
                .frame(width: 44, height: 44)
                .laaGlass(in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(stopping)
        .accessibilityLabel(Text(verbatim: "中断"))
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
            let detailData = try? snapshotData(detail)
            if detailData != lastDetailData {
                session = detail; lastDetailData = detailData
                LAAWorkSessionCache.save(detail, store: drafts, device: bridge.deviceID, target: id)
            }
            do {
                let history = try await historyRead
                let data = try? snapshotData(history.items)
                if data != lastHistoryData {
                    messages = history.items; lastHistoryData = data
                    prepareTranscript()
                    LAAWorkSessionCache.save(messages, store: drafts, device: bridge.deviceID, target: id + ":messages")
                }
                historyReady = true
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

    private func snapshotData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    private func prepareTranscript() {
        conversationMessages = messages.filter { $0.role != "tool" }
        workRecords = messages.filter { $0.role == "tool" }
    }

    @MainActor private func observe() async {
        session = LAAWorkSessionCache.read(LAAWorkSession.self, store: drafts, device: bridge.deviceID, target: id)
        let cachedHistory = LAAWorkSessionCache.read([LAAWorkConversationMessage].self, store: drafts, device: bridge.deviceID, target: id + ":messages")
        messages = cachedHistory ?? []; historyReady = cachedHistory != nil
        prepareTranscript()
        lastDetailData = session.flatMap { try? snapshotData($0) }
        lastHistoryData = try? snapshotData(messages)
        cursor = nil
        events.removeAll()
        // The remembered conversation is enough to place the page: waiting for
        // the Mac here left a long transcript at its top, and a touch in that
        // window stopped it from ever following to the bottom.
        openingReady = true
        let loaded = await refreshSnapshot()
        // Even when the detail or history read failed, opening is done: the
        // view can now place itself at the bottom instead of staying at the top.
        openingReady = true
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

/// The conversation's fixed heading: the name, and under it the short number
/// and phase, on the same small glass the employee chat uses in its bar.
struct LAAWorkSessionHeaderPill: View {
    let session: LAAWorkSession
    @Environment(\.laaClearGlassControls) private var clearGlass

    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            Text(verbatim: session.name)
                .font(.custom("Georgia", size: 16, relativeTo: .headline))
                .lineLimit(1).minimumScaleFactor(0.8).truncationMode(.tail)
                .accessibilityIdentifier("work.session.detail.title")
            HStack(spacing: 0) {
                Text(verbatim: LAAWorkPresentation.phaseSymbol(session.phase))
                    .foregroundStyle(LAAWorkSessionStyle.statusColor(session.phase))
                Text(verbatim: " " + LAAWorkPresentation.phase(session.phase)).foregroundStyle(.secondary)
            }
            .font(.caption2).lineLimit(1)
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

    @ViewBuilder func body(content: Content) -> some View {
        if clear {
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .conduitGlassControl(cornerRadius: 20, tint: .conduitAccent.opacity(0.06), interactive: false)
        } else {
            content
                .padding(.horizontal, LAASpacing.x2)
                .padding(.vertical, 5)
                .conduitGlassControl(cornerRadius: LAARadius.control, tint: LAAColor.link.opacity(0.06), interactive: false)
        }
    }
}
#endif
