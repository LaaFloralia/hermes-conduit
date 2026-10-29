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
    @State private var artifacts: [LAAWorkArtifact] = []
    @State private var cursor: String?
    @State private var notice: String?
    @State private var failure: String?
    @State private var showResume = false
    @State private var stopping = false
    @State private var successor: LAAWorkSession?
    @State private var historyGapSeen = false
    @State private var observationEpoch = 0
    @AppStorage(ChatTypography.preferenceKey) private var responseSize = ChatTypography.defaultSize.rawValue

    init(id: String, projects: [LAAWorkProject], workspaces: [LAAWorkWorkspace], drafts: ComposerDraftStore) {
        self.id = id; self.projects = projects; self.workspaces = workspaces; self.drafts = drafts
    }

    private var stopKey: ComposerDraftKey? {
        bridge.deviceID.map { LAAWorkDrafts.key(deviceID: $0, target: "stop:\(id)") }
    }
    private var pendingStop: ComposerDraftStore.Submission? {
        stopKey.flatMap { LAAWorkDrafts.pending(drafts, key: $0) }
    }

    var body: some View {
        ZStack {
            LAAColor.background.ignoresSafeArea()
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
                        if session.needsDecision { decisionBanner }
                        resultBody
                        timeline
                        actions(session)
                        LAAWorkMessageForm(sessionID: id, mode: .followUp, drafts: drafts,
                                           canStart: session.phase == "awaiting_review") { _ in
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
        }
        .navigationTitle(Text(verbatim: session?.name ?? LAACopy.WorkTab.sessions))
        .tint(LAAColor.link)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .sheet(isPresented: $showResume) {
            NavigationStack {
                LAAWorkMessageForm(sessionID: id, mode: .resume, drafts: drafts, canStart: true) { created in
                    successor = created
                    showResume = false
                    Task { await refreshSnapshot() }
                }
                .padding(LAASpacing.x4)
                .navigationTitle(Text(verbatim: LAACopy.WorkTab.successor))
                .background(LAAColor.background)
                .tint(LAAColor.link)
            }.environmentObject(bridge)
        }
        .task(id: "\(bridge.revision)-\(id)-\(observationEpoch)") { await observe() }
    }

    private func sessionHeader(_ session: LAAWorkSession) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            Text(verbatim: session.name).font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
            Text(verbatim: LAAWorkPresentation.phaseSymbol(session.phase) + " " + LAAWorkPresentation.phase(session.phase))
                .foregroundStyle(LAAWorkPresentation.phaseNeedsAttention(session.phase) ? LAAColor.attention : LAAColor.link)
            Text(verbatim: "プロジェクト: " + (projects.first { $0.id == session.projectId }?.name ?? (session.projectId == nil ? "なし" : "未確認")))
            Text(verbatim: "作業場所: " + workspace(session.workspaceId))
            Text(verbatim: "要求: " + (session.requested?.display ?? "未確認"))
            Text(verbatim: "観測: " + (session.observed?.display ?? "未確認"))
            if session.modelMismatch {
                Label(LAAWorkPresentation.japanese("要求と観測が一致しません"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(LAAColor.attention)
            } else if session.runtimeVerified != true {
                Text(verbatim: "○ 実行時のモデルは未確認です。系統や設定の一致だけでは確定しません。")
                    .foregroundStyle(LAAColor.secondaryText)
            }
            if let version = session.instructionVersion {
                Text(verbatim: "プロジェクト指示版: \(version) · \(session.instructionHash ?? "ハッシュ未確認")")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
            Text(verbatim: "最終活動: " + LAAWorkPresentation.date(session.updatedAt)).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
        }.laaTextStyle(.secondary).workCard()
    }

    private var decisionBanner: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            Label(LAAWorkPresentation.japanese("判断待ち"), systemImage: "exclamationmark.triangle.fill").laaTextStyle(.body).fontWeight(.semibold)
            Text(verbatim: "内容を表示しています。回答は後続の機能で対応します。")
            if let decision = artifacts.first(where: { $0.type == "decision" })?.content {
                Text(verbatim: decision).laaTextStyle(.secondary).textSelection(.enabled)
            } else { Text(verbatim: "判断内容を取得できていません。") }
        }.foregroundStyle(LAAColor.attention).workCard()
    }

    private var resultBody: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            Text(verbatim: "最新の回答").laaTextStyle(.body).fontWeight(.semibold)
            if let answer = artifacts.first(where: { $0.type == "message" }) {
                if let content = answer.content, !content.isEmpty {
                    MarkdownText(source: content, foregroundStyle: LAAColor.text)
                        .environment(\.chatTextSize, ChatTextAppearance(size: ChatTypography.resolve(rawValue: responseSize), style: .standard))
                    if answer.truncated == true { Text(verbatim: "回答は途中まで表示しています。") .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention) }
                } else {
                    Text(verbatim: answer.available == false ? "回答を取得できていません。" : "まだ回答はありません。")
                        .foregroundStyle(LAAColor.secondaryText)
                }
            } else { Text(verbatim: "まだ回答はありません。").foregroundStyle(LAAColor.secondaryText) }
        }.workCard()
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            Text(verbatim: "経過").laaTextStyle(.body).fontWeight(.semibold)
            if events.isEmpty { Text(verbatim: "記録を取得中です。").foregroundStyle(LAAColor.secondaryText) }
            ForEach(events) { event in
                HStack(alignment: .top) {
                    Text(verbatim: LAAWorkPresentation.event(event.type))
                    Spacer()
                    Text(verbatim: LAAWorkPresentation.date(event.occurredAt)).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                }
                Divider()
            }
            if let log = artifacts.first(where: { $0.type == "log" }) {
                DisclosureGroup(LAACopy.WorkTab.log) {
                    if let content = log.content { Text(verbatim: content).laaTextStyle(.secondary).monospaced().textSelection(.enabled) }
                    if log.truncated == true { Text(verbatim: "ログは途中まで表示しています。").laaTextStyle(.secondary).foregroundStyle(LAAColor.attention) }
                }
            }
        }.workCard()
    }

    private func actions(_ session: LAAWorkSession) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            if pendingStop != nil {
                Label(LAAWorkPresentation.japanese("停止要求の結果は未確認です。状態を確認してから同じ要求を再照合できます。"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(LAAColor.attention)
                Button(LAACopy.WorkTab.checkStop) { Task { await refreshSnapshot() } }.disabled(stopping)
                Button(LAACopy.WorkTab.retryStop) { if let pendingStop { Task { await performStop(pendingStop) } } }
                    .disabled(stopping)
            } else if session.phase == "stop_unconfirmed" {
                Label(LAAWorkPresentation.japanese("停止はまだ確認できていません。"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(LAAColor.attention)
                Button(LAACopy.WorkTab.checkStop) { Task { await refreshSnapshot() } }
            } else if session.phase == "stopped" {
                Text(verbatim: "再開は同じ作業場所・プロファイルの後継セッションです。履歴は自動では引き継がれません。")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                Button(LAACopy.WorkTab.resume) { showResume = true }
                    .buttonStyle(.borderedProminent).tint(LAAColor.filledButton)
                    .foregroundStyle(LAAColor.filledButtonText)
            } else {
                Button(LAACopy.WorkTab.stop) { beginStop() }.buttonStyle(.bordered).tint(LAAColor.end).disabled(stopping)
            }
            if let next = successor {
                NavigationLink("\(LAACopy.WorkTab.successor): \(next.name)") {
                    LAAWorkSessionDetail(id: next.id, projects: projects, workspaces: workspaces, drafts: drafts)
                }
            } else if let nextID = session.resumedTo {
                NavigationLink(LAACopy.WorkTab.openSuccessor) {
                    LAAWorkSessionDetail(id: nextID, projects: projects, workspaces: workspaces, drafts: drafts)
                }
            }
        }.workCard()
    }

    private func workspace(_ id: String) -> String {
        guard let item = workspaces.first(where: { $0.id == id }) else { return "未確認" }
        return (item.displayPath ?? item.path) + (item.branch.map { " · " + $0 } ?? "")
    }

    @discardableResult @MainActor private func refreshSnapshot() async -> Bool {
        do {
            let detail: LAAWorkSession = try await bridge.read("/v1/sessions/\(id)")
            let fetched: LAAWorkArtifacts = try await bridge.read("/v1/sessions/\(id)/artifacts")
            session = detail
            artifacts = fetched.items
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
        cursor = nil
        events.removeAll()
        guard await refreshSnapshot(), let initial = session else { return }
        var afterSeq: Int? = max(0, initial.events.oldestSeq - 1)
        var consecutiveGaps = 0
        while !Task.isCancelled {
            do {
                var query = [URLQueryItem(name: "wait", value: "10"), URLQueryItem(name: "limit", value: "100")]
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
                } else if !page.items.isEmpty {
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
              let item = LAAWorkDrafts.reserve(drafts, key: key, text: "停止要求", body: body,
                                               idempotency: LAABridgeIdempotencyKey()) else {
            failure = "停止要求を端末に安全に記録できませんでした。"; return
        }
        Task { await performStop(item) }
    }

    @MainActor private func performStop(_ item: ComposerDraftStore.Submission) async {
        guard LAAWorkDrafts.canRepeat(item) else { failure = LAAWorkDrafts.expiredMessage; return }
        guard let (body, key) = LAAWorkDrafts.request(item) else { failure = "停止要求の記録を読み取れません。"; return }
        stopping = true
        defer { stopping = false }
        do {
            let _: LAAWorkSession = try await LAAWorkHTTP.write(bridge, path: "/v1/sessions/\(id)/stop", body: body, key: key)
            if !drafts.finishSubmission(item.id, restoring: false) { failure = "結果を端末に保存できません。停止状態を確認してください。" }
            await refreshSnapshot()
        } catch let error as LAABridgeHTTPError {
            if LAAWorkHTTP.outcomeUnknown(error) { drafts.markSubmissionUnknown(item.id) }
            else { _ = drafts.finishSubmission(item.id, restoring: false) }
            let explanation = LAAWorkHTTP.message(error)
            await refreshSnapshot()
            notice = explanation
        } catch {
            drafts.markSubmissionUnknown(item.id)
            notice = "停止要求の結果は未確認です。停止済みとは表示しません。"
            await refreshSnapshot()
        }
    }
}
#endif
