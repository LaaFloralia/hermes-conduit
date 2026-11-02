#if LAA_BUILD
import SwiftUI

struct LAAWorkSessionDetail: View {
    @EnvironmentObject private var bridge: LAABridgeSession
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
                    if let session {
                        sessionHeader(session)
                        if let notice { Label(notice, systemImage: "exclamationmark.triangle.fill").foregroundStyle(LAAColor.attention).workCard() }
                        if let failure {
                            VStack(alignment: .leading) {
                                Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(LAAColor.attention)
                                Button(LAACopy.WorkTab.reconnect) { observationEpoch += 1 }
                            }.workCard()
                        }
                        if session.needsDecision { LAAWorkSessionDecision(sessionID: id, drafts: drafts) { observationEpoch += 1 } }
                        conversation
                        Color.clear.frame(height: 1).id("conversation-end")
                            .onAppear { followsConversation = true }
                            .onDisappear { followsConversation = false }
                        actions(session)
                        LAAWorkMessageForm(sessionID: id, mode: .followUp, drafts: drafts,
                                           canStart: ["awaiting_review", "running"].contains(session.phase) && !session.needsDecision) { _ in
                            Task { await refreshSnapshot() }
                        }
                    } else if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(LAAColor.attention)
                        Button(LAACopy.WorkTab.retry) { observationEpoch += 1 }
                    } else { ProgressView().accessibilityLabel(Text(verbatim: "読み込み中")) }
                }
                .padding(.horizontal, LAASpacing.horizontal).padding(.vertical, LAASpacing.x4).frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .refreshable { await refreshSnapshot() }
            .onChange(of: messages.last?.text) { _, _ in
                if followsConversation { scroll.scrollTo("conversation-end", anchor: .bottom) }
            }
            }
        }
        .navigationTitle(Text(verbatim: session?.name ?? LAACopy.WorkTab.sessions))
        .tint(LAAColor.link)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task(id: "\(bridge.revision)-\(id)-\(observationEpoch)") { await observe() }
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x4) {
            if conversationUnavailable {
                Text(verbatim: "会話履歴を取得できません。更新して再確認してください。")
                    .foregroundStyle(LAAColor.attention)
            } else if messages.isEmpty {
                Text(verbatim: "会話はまだありません。") .foregroundStyle(LAAColor.secondaryText)
            }
            ForEach(messages) { message in
                VStack(alignment: .leading, spacing: LAASpacing.x2) {
                    Text(verbatim: message.role == "user" ? "あなた" : "回答")
                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    if message.role == "tool" {
                        DisclosureGroup {
                            Text(verbatim: message.text).laaTextStyle(.secondary)
                        } label: { Text(verbatim: (message.toolName ?? "ツール") + " · " + (message.toolStatus ?? "")) }
                    } else { MarkdownText(source: message.text, foregroundStyle: LAAColor.text)
                        .environment(\.chatTextSize, ChatTextAppearance(size: ChatTypography.resolve(rawValue: responseSize), style: .standard))
                    }
                    ForEach(message.images ?? [], id: \.self) { imageID in
                        LAAWorkSessionImage(sessionID: id, imageID: imageID)
                    }
                }.workCard()
            }
        }
    }

    private func sessionHeader(_ session: LAAWorkSession) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            Text(verbatim: session.name).font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
            Text(verbatim: LAAWorkPresentation.phaseSymbol(session.phase) + " " + LAAWorkPresentation.phase(session.phase))
                .foregroundStyle(LAAWorkPresentation.phaseNeedsAttention(session.phase) ? LAAColor.attention : LAAColor.link)
            Text(verbatim: session.observed?.model ?? session.requested?.model ?? "モデル未確認")
                .foregroundStyle(LAAColor.secondaryText)
            if session.modelMismatch {
                Label(LAAWorkPresentation.japanese("要求と観測が一致しません"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(LAAColor.attention)
            } else if session.runtimeVerified != true {
                Text(verbatim: "○ 実行時のモデルは未確認です。系統や設定の一致だけでは確定しません。")
                    .foregroundStyle(LAAColor.secondaryText)
            }
            Text(verbatim: "最終活動: " + LAAWorkPresentation.date(session.updatedAt)).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
        }.laaTextStyle(.secondary).workCard()
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
            } else {
                Button { beginStop() } label: { Text(verbatim: "中断") }.buttonStyle(.bordered).tint(LAAColor.end).disabled(stopping)
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
        guard await refreshSnapshot(), let initial = session else { return }
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
