#if LAA_BUILD
import SwiftUI

struct LAAPersonalComment: Decodable, Identifiable {
    struct User: Decodable { let id: String; let name: String?; let app: Bool? }
    let id: String
    let body: String
    let issueId: String?
    let parentId: String?
    let createdAt: String?
    let updatedAt: String?
    let user: User?
}
struct LAAPersonalHistory: Decodable, Identifiable {
    struct Name: Decodable { let id: String; let name: String?; let identifier: String?; let title: String?; let displayName: String? }
    struct RelationChange: Decodable { let identifier: String; let type: String }
    let id: String
    let createdAt: String?
    let actor: Name?
    let fromState: Name?
    let toState: Name?
    let fromAssignee: Name?
    let toAssignee: Name?
    let fromPriority: Double?
    let toPriority: Double?
    let fromTitle: String?
    let toTitle: String?
    let updatedDescription: Bool?
    let fromDelegate: Name?; let toDelegate: Name?
    let fromCycle: Name?; let toCycle: Name?
    let fromProject: Name?; let toProject: Name?
    let fromProjectMilestone: Name?; let toProjectMilestone: Name?
    let fromTeam: Name?; let toTeam: Name?
    let fromParent: Name?; let toParent: Name?
    let fromEstimate: Double?; let toEstimate: Double?
    let fromDueDate: String?; let toDueDate: String?
    let addedLabels: [Name]?; let removedLabels: [Name]?
    let addedToReleases: [Name]?; let removedFromReleases: [Name]?
    let relationChanges: [RelationChange]?
    let archived: Bool?; let autoArchived: Bool?; let autoClosed: Bool?; let trashed: Bool?
    let fromSlaType: String?; let toSlaType: String?
    let fromSlaBreached: Bool?; let toSlaBreached: Bool?
    let fromSlaBreachesAt: String?; let toSlaBreachesAt: String?
    let attachment: Name?; let toConvertedProject: Name?; let issueImport: Name?
    let customerNeedId: String?; let triageResponsibilityAutoAssigned: Bool?

    var lines: [String] {
        var result: [String] = []
        func change(_ label: String, _ before: String?, _ after: String?) {
            if before != nil || after != nil { result.append("\(label): \(before ?? "—") → \(after ?? "—")") }
        }
        func name(_ item: Name?) -> String? { item?.name ?? item?.identifier ?? item?.title ?? item?.displayName }
        change("タイトル", fromTitle, toTitle)
        change("状態", name(fromState), name(toState))
        change("担当", name(fromAssignee), name(toAssignee))
        change("委任先", name(fromDelegate), name(toDelegate))
        change("優先度", fromPriority.map { String($0) }, toPriority.map { String($0) })
        change("見積り", fromEstimate.map { String($0) }, toEstimate.map { String($0) })
        change("期限", fromDueDate, toDueDate)
        change("Cycle", name(fromCycle), name(toCycle))
        change("Project", name(fromProject), name(toProject))
        change("Milestone", name(fromProjectMilestone), name(toProjectMilestone))
        change("チーム", name(fromTeam), name(toTeam))
        change("親課題", name(fromParent), name(toParent))
        if updatedDescription == true { result.append("本文を更新") }
        if let labels = addedLabels, !labels.isEmpty { result.append("ラベルを追加: " + labels.compactMap(name).joined(separator: ", ")) }
        if let labels = removedLabels, !labels.isEmpty { result.append("ラベルを削除: " + labels.compactMap(name).joined(separator: ", ")) }
        if let releases = addedToReleases, !releases.isEmpty { result.append("Releaseに追加: " + releases.compactMap(name).joined(separator: ", ")) }
        if let releases = removedFromReleases, !releases.isEmpty { result.append("Releaseから削除: " + releases.compactMap(name).joined(separator: ", ")) }
        for relation in relationChanges ?? [] { result.append("関連: \(relation.identifier) · \(relation.type)") }
        if archived == true { result.append("アーカイブ") }
        if autoArchived == true { result.append("自動アーカイブ") }
        if autoClosed == true { result.append("自動クローズ") }
        if trashed == true { result.append("ゴミ箱へ移動") }
        change("SLA", fromSlaType, toSlaType)
        change("SLA超過", fromSlaBreached.map(String.init), toSlaBreached.map(String.init))
        change("SLA期限", fromSlaBreachesAt, toSlaBreachesAt)
        if let value = name(attachment) { result.append("添付: " + value) }
        if let value = name(toConvertedProject) { result.append("Projectへ変換: " + value) }
        if let value = name(issueImport) { result.append("インポート: " + value) }
        if customerNeedId != nil { result.append("顧客ニーズを更新") }
        if triageResponsibilityAutoAssigned == true { result.append("トリアージ担当を自動設定") }
        return result.isEmpty ? ["その他の更新（詳細は未対応）"] : result
    }
}
struct LAAPersonalRelation: Decodable, Identifiable {
    struct Issue: Decodable { let id: String; let identifier: String; let title: String }
    let id: String
    let type: String
    let issue: Issue
    let relatedIssue: Issue
}
struct LAAPersonalAttachment: Decodable, Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let url: String
    let sourceType: String?
}

private enum LAAPersonalPath {
    static func task(_ id: String) -> String {
        "/v1/personal-tasks/" + (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")
    }
    static func component(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
    }
}

@MainActor private final class LAAPersonalConnection<Item: Decodable & Identifiable>: ObservableObject {
    @Published var items: [Item] = []
    @Published var cursor: String?
    @Published var observedAt: String?
    @Published var loaded = false
    @Published var loading = false
    @Published var error: String?
    private var cursors = Set<String>()
    private var generation = UUID()

    func load(bridge: LAABridgeSession, path: String, viewerId: String, reset: Bool) async {
        if !reset && (loading || cursor == nil) { return }
        let current = reset ? UUID() : generation
        if reset { generation = current; cursor = nil; cursors = [] }
        loading = true; error = nil
        defer { if generation == current { loading = false } }
        var query = [URLQueryItem(name: "limit", value: "50")]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        do {
            let page: LAAPersonalPage<Item> = try await bridge.read(LAAWorkPresentation.path(path, query: query))
            guard !Task.isCancelled, generation == current else { return }
            guard page.viewerId == viewerId else { throw LAABridgeError.conflict }
            if let next = page.nextCursor, !cursors.insert(next).inserted { throw LAABridgeError.invalidResponse }
            if reset { items = [] }
            var known = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { known.insert($0.id).inserted })
            cursor = page.nextCursor; observedAt = page.observedAt; loaded = true
        } catch is CancellationError {
        } catch let failure as LAABridgeError {
            if generation == current { error = failure.japaneseText }
        } catch { if generation == current { self.error = "読み取れませんでした。" } }
    }
}

private struct LAAPersonalDetailSection<Item: Decodable & Identifiable, Row: View>: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @StateObject private var state = LAAPersonalConnection<Item>()
    let title: String
    let path: String
    let viewerId: String
    let revision: Int
    let row: (Item) -> Row

    init(_ title: String, path: String, viewerId: String, revision: Int, @ViewBuilder row: @escaping (Item) -> Row) {
        self.title = title; self.path = path; self.viewerId = viewerId; self.revision = revision; self.row = row
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            Text(verbatim: title).fontWeight(.semibold).accessibilityAddTraits(.isHeader)
            if let error = state.error {
                Text(verbatim: error).foregroundStyle(LAAColor.attention)
                if !state.items.isEmpty { Text(verbatim: "前回取得した内容です。") }
                Button(LAACopy.WorkTab.retry) { Task { await load(reset: true) } }
            }
            if state.loading && state.items.isEmpty { LAALoadingDots() }
            if state.loaded && state.items.isEmpty && state.error == nil && !state.loading {
                Text(verbatim: "表示する項目はありません。 ").foregroundStyle(LAAColor.secondaryText)
            }
            ForEach(state.items) { item in row(item) }
            if state.cursor != nil {
                Text(verbatim: "続きがあります。").foregroundStyle(LAAColor.secondaryText)
                Button(LAACopy.WorkTab.loadMore) { Task { await load(reset: false) } }.disabled(state.loading)
            }
            if let date = state.observedAt {
                Text(verbatim: "取得: \(LAAWorkPresentation.date(date))").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
        }.workCard().task(id: "\(bridge.revision)-\(revision)-\(path)-\(viewerId)") { await load(reset: true) }
    }
    private func load(reset: Bool) async { await state.load(bridge: bridge, path: path, viewerId: viewerId, reset: reset) }
}

struct LAAPersonalTaskConnections: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @ObservedObject var drafts: ComposerDraftStore
    let task: LAAPersonalTask
    let viewerId: String
    @State private var revision = 0
    @State private var reply: LAAPersonalCommentTarget?
    @State private var showSubtask = false
    @State private var showUpload = false
    @State private var itemMode: LAAPersonalItemMode?
    private var path: String { LAAPersonalPath.task(task.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x4) {
            Button() { reply = LAAPersonalCommentTarget(parentId: nil) } label: { Text(verbatim: "コメントを追加") }.buttonStyle(.bordered)
                .accessibilityIdentifier("work.task.new-comment")
            LAAPersonalDetailSection("Comments", path: path + "/comments", viewerId: viewerId, revision: revision) { (comment: LAAPersonalComment) in
                LAAPersonalCommentRow(comment: comment, taskPath: path, viewerId: viewerId, revision: revision) { parent in
                    reply = LAAPersonalCommentTarget(parentId: parent)
                }
            }
            Button() { showSubtask = true } label: { Text(verbatim: "サブ課題を追加") }.buttonStyle(.bordered).disabled(task.linearId == nil || task.team == nil)
            LAAPersonalDetailSection("Subtasks", path: path + "/children", viewerId: viewerId, revision: revision) { (child: LAAPersonalTask) in
                NavigationLink(destination: LAAPersonalTaskDetailView(id: child.id, drafts: drafts)) {
                    Text(verbatim: "\(child.sourceId) · \(child.title)")
                }
            }
            Button() { itemMode = .relation } label: { Text(verbatim: "関連を追加") }.buttonStyle(.bordered)
            relationSection("Relations", section: "relations")
            relationSection("Referenced By", section: "inverse-relations")
            Button() { itemMode = .attachment } label: { Text(verbatim: "リンクを追加") }.buttonStyle(.bordered)
            Button() { showUpload = true } label: { Text(verbatim: "ファイルを追加") }.buttonStyle(.bordered)
            LAAPersonalDetailSection("Attachments", path: path + "/attachments", viewerId: viewerId, revision: revision) { (item: LAAPersonalAttachment) in
                VStack(alignment: .leading) {
                    if let url = URL(string: item.url), url.scheme?.lowercased() == "https",
                       url.host?.lowercased() != "uploads.linear.app", url.user == nil, url.password == nil {
                        Link(item.title, destination: url)
                    } else if let url = URL(string: item.url), url.scheme?.lowercased() == "https",
                              url.host?.lowercased() == "uploads.linear.app" {
                        LAAPersonalFileButton(title: item.title,
                            path: path + "/attachments/" + LAAPersonalPath.component(item.id) + "/content", viewerId: viewerId)
                    } else {
                        Text(verbatim: item.title)
                        Text(verbatim: "この添付先は開けません。").laaTextStyle(.secondary)
                    }
                    if let subtitle = item.subtitle { Text(verbatim: subtitle).laaTextStyle(.secondary) }
                }
            }
            Text(verbatim: "活動の一部は詳細を表示できない場合があります。")
                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            LAAPersonalDetailSection("Activity", path: path + "/history", viewerId: viewerId, revision: revision) { (item: LAAPersonalHistory) in
                LAAPersonalHistoryRow(item: item)
            }
        }
        .sheet(item: $reply, onDismiss: { revision += 1 }) { target in
            LAAPersonalCommentEditor(taskId: task.id, viewerId: viewerId, parentId: target.parentId, drafts: drafts)
                .environmentObject(bridge)
        }
        .sheet(isPresented: $showSubtask, onDismiss: { revision += 1 }) {
            LAAPersonalTaskEditor(task: nil, viewerId: viewerId, drafts: drafts, parent: task)
                .environmentObject(bridge)
        }
        .sheet(isPresented: $showUpload, onDismiss: { revision += 1 }) {
            LAAPersonalTaskUpload(drafts: drafts, taskId: task.id, viewerId: viewerId)
                .environmentObject(bridge)
        }
        .sheet(item: $itemMode, onDismiss: { revision += 1 }) { mode in
            LAAPersonalItemEditor(mode: mode, taskId: task.id, viewerId: viewerId, drafts: drafts)
                .environmentObject(bridge)
        }
    }

    private func relationSection(_ title: String, section: String) -> some View {
        LAAPersonalDetailSection(title, path: path + "/" + section, viewerId: viewerId, revision: revision) { (relation: LAAPersonalRelation) in
            VStack(alignment: .leading) {
                Text(verbatim: "\(relation.issue.identifier) → \(relation.relatedIssue.identifier) · \(relation.type)")
                    .laaTextStyle(.secondary)
                let other = section == "relations" ? relation.relatedIssue : relation.issue
                NavigationLink(destination: LAAPersonalTaskDetailView(id: "linear:\(other.identifier)", drafts: drafts)) {
                    Text(verbatim: other.title)
                }
            }
        }
    }
}

private struct LAAPersonalCommentRow: View {
    let comment: LAAPersonalComment
    let taskPath: String
    let viewerId: String
    let revision: Int
    let onReply: (String) -> Void
    @State private var showReplies = false
    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            Text(verbatim: "\(comment.user?.name ?? "不明") · \(LAAWorkPresentation.date(comment.createdAt))")
                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            if comment.parentId != nil { Text(verbatim: "返信").laaTextStyle(.secondary) }
            MarkdownText(source: comment.body, foregroundStyle: LAAColor.text)
            if comment.body.lowercased().contains("https://uploads.linear.app/") {
                LAAPersonalMarkdownFiles(taskPath: taskPath, viewerId: viewerId, commentId: comment.id)
            }
            HStack {
                Button() { onReply(comment.id) } label: { Text(verbatim: "返信") }
                Button() { showReplies.toggle() } label: { Text(verbatim: showReplies ? "返信を閉じる" : "返信を表示") }
            }.buttonStyle(.bordered)
            if showReplies {
                LAAPersonalDetailSection("Replies", path: taskPath + "/comments/" + LAAPersonalPath.component(comment.id) + "/replies",
                                         viewerId: viewerId, revision: revision) { (child: LAAPersonalComment) in
                    AnyView(LAAPersonalCommentRow(comment: child, taskPath: taskPath, viewerId: viewerId,
                                                  revision: revision, onReply: onReply))
                }
            }
        }.padding(.vertical, LAASpacing.x2)
    }
}

private struct LAAPersonalHistoryRow: View {
    let item: LAAPersonalHistory
    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x1) {
            Text(verbatim: "\(item.actor?.name ?? "不明") · \(LAAWorkPresentation.date(item.createdAt))").laaTextStyle(.secondary)
            ForEach(Array(item.lines.enumerated()), id: \.offset) { _, line in Text(verbatim: line) }
        }.padding(.vertical, LAASpacing.x1)
    }
}

private struct LAAPersonalCommentTarget: Identifiable {
    let parentId: String?
    var id: String { parentId ?? "root" }
}

private enum LAAPersonalItemMode: String, Identifiable {
    case relation, attachment
    var id: String { rawValue }
    var section: String { self == .relation ? "relations" : "attachments" }
    var caption: String { self == .relation ? "関連を追加" : "リンクを追加" }
}

private struct LAAPersonalItemEditor: View {
    private struct Draft: Codable { var first = ""; var second = ""; var relationType = "related" }
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.dismiss) private var dismiss
    let mode: LAAPersonalItemMode
    let taskId: String
    let viewerId: String
    @ObservedObject var drafts: ComposerDraftStore
    @State private var draft = Draft()
    @State private var ready = false
    @State private var busy = false
    @State private var error: String?
    @State private var operation: LAAPersonalOperationResponse.Operation?
    private var key: ComposerDraftKey? {
        bridge.deviceID.map { LAAWorkDrafts.key(deviceID: $0, target: "linear:\(viewerId):\(mode.rawValue):\(taskId)") }
    }
    private var pending: ComposerDraftStore.Submission? { key.flatMap { LAAWorkDrafts.pending(drafts, key: $0) } }
    private var path: String { LAAPersonalPath.task(taskId) + "/" + mode.section }

    var body: some View {
        NavigationStack {
            Form {
                if let error { Text(verbatim: error).foregroundStyle(LAAColor.attention) }
                if let pending {
                    Section() {
                        if pending.personalOrigin != nil {
                            Text(verbatim: "移した下書きは送信待ちで元の要求を照合してください。")
                        } else {
                            Text(verbatim: "保存結果を確認してください。結果不明の間は新しい操作を始めません。")
                            if let operation { Text(verbatim: "\(operation.displayKind) · \(operation.displayStatus)").textSelection(.enabled) }
                            Button(LAACopy.WorkTab.checkStatus) { Task { await check(pending) } }
                            if LAAWorkDrafts.canRepeat(pending) {
                                Button(LAACopy.WorkTab.retrySameRequest) { Task { await perform(pending, firstAttempt: false) } }
                            }
                        }
                    } header: { Text(verbatim: "送信待ち") }
                }
                if mode == .relation {
                    Section() {
                        TextField(text: $draft.first) { Text(verbatim: "課題番号") }.textInputAutocapitalization(.characters)
                        Picker(selection: $draft.relationType) {
                            Text(verbatim: "関連").tag("related"); Text(verbatim: "ブロック").tag("blocks")
                            Text(verbatim: "重複").tag("duplicate"); Text(verbatim: "類似").tag("similar")
                        } label: { Text(verbatim: "関連") }
                        Text(verbatim: "このタスクから入力したタスクへの関係です。").laaTextStyle(.secondary)
                    } header: { Text(verbatim: "関連する課題") }.disabled(!ready || pending != nil)
                } else {
                    Section() {
                        TextField(text: $draft.first) { Text(verbatim: "題名") }
                        TextField(text: $draft.second) { Text(verbatim: "リンク") }.keyboardType(.URL).textInputAutocapitalization(.never)
                        Text(verbatim: "外部リンクを追加します。ファイルは別の操作でアップロードできます。").laaTextStyle(.secondary)
                    } header: { Text(verbatim: "リンク") }.disabled(!ready || pending != nil)
                }
                Button() { submit() } label: { Text(verbatim: LAACopy.save) }.disabled(!ready || busy || pending != nil || drafts.persistenceFailed || draft.first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(busy).navigationTitle(Text(verbatim: mode.caption))
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(LAACopy.WorkTab.close) { dismiss() } } }
            .task(id: bridge.revision) { restore() }
            .onChange(of: draft.first) { _, _ in saveDraft() }
            .onChange(of: draft.second) { _, _ in saveDraft() }
            .onChange(of: draft.relationType) { _, _ in saveDraft() }
        }
    }
    private func restore() {
        ready = false
        let value = pending?.draft.text ?? key.map { drafts.draft(for: $0).text } ?? ""
        if let bytes = value.data(using: .utf8), let saved = try? JSONDecoder().decode(Draft.self, from: bytes) { draft = saved }
        ready = key != nil
    }
    private func saveDraft() {
        guard ready, pending == nil else { return }
        guard let key, let data = try? JSONEncoder().encode(draft),
              drafts.save(ComposerDraft(text: String(decoding: data, as: UTF8.self), attachments: []), for: key) else {
            error = "下書きを端末に保存できませんでした。"; return
        }
    }
    private func submit() {
        guard let key, pending == nil else { return }
        let payload: [String: String] = mode == .relation
            ? ["expectedViewerId": viewerId, "relatedIssueId": draft.first.trimmingCharacters(in: .whitespacesAndNewlines), "type": draft.relationType]
            : ["expectedViewerId": viewerId, "title": draft.first, "url": draft.second.trimmingCharacters(in: .whitespacesAndNewlines)]
        guard let encoded = try? JSONEncoder().encode(draft),
              let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let item = LAAWorkDrafts.reserve(drafts, key: key, text: String(decoding: encoded, as: UTF8.self),
                                               body: body, idempotency: LAABridgeIdempotencyKey()) else {
            error = "保存前の記録を作れませんでした。"; return
        }
        Task { await perform(item, firstAttempt: true) }
    }
    @MainActor private func perform(_ item: ComposerDraftStore.Submission, firstAttempt: Bool) async {
        guard LAAWorkDrafts.canRepeat(item), let (body, requestKey) = LAAWorkDrafts.request(item) else {
            error = LAAWorkDrafts.expiredMessage; return
        }
        busy = true; defer { busy = false }
        do {
            let result: LAABridgeResponse<LAAPersonalOperationResponse> = try await bridge.request(
                method: "POST", path: path, jsonBody: body, idempotencyKey: requestKey, timeout: 90)
            guard result.data.operation.status == "succeeded" else { throw LAABridgeError.invalidResponse }
            if drafts.finishSubmission(item.id, restoring: false) { dismiss() }
            else { error = "保存結果を端末に記録できません。" }
        } catch let failure as LAABridgeHTTPError {
            drafts.markSubmissionUnknown(item.id)
            if firstAttempt && ["payload_invalid", "expected_viewer_required", "linear_viewer_changed"].contains(failure.code ?? "") {
                if drafts.finishSubmission(item.id, restoring: true) { restore() }
            }
            error = LAAWorkHTTP.message(failure)
        } catch let failure as LAABridgeError {
            drafts.markSubmissionUnknown(item.id); error = failure.japaneseText
        } catch { drafts.markSubmissionUnknown(item.id); self.error = "保存結果を確認できませんでした。" }
    }
    @MainActor private func check(_ item: ComposerDraftStore.Submission) async {
        guard let (_, requestKey) = LAAWorkDrafts.request(item) else { error = "要求記録を読み取れません。"; return }
        busy = true; defer { busy = false }
        do {
            let result: LAABridgeResponse<LAAPersonalOperationResponse> = try await bridge.request(
                method: "GET", path: "/v1/task-operations/by-key", idempotencyKey: requestKey)
            operation = result.data.operation
            switch result.data.operation.status {
            case "succeeded": if drafts.finishSubmission(item.id, restoring: false) { dismiss() }
            case "rejected": if drafts.finishSubmission(item.id, restoring: true) { restore(); error = "保存前に拒否されました。" }
            case "resolved":
                guard ["applied", "not_applied"].contains(result.data.operation.resolution ?? "") else { throw LAABridgeError.invalidResponse }
                let restoring = result.data.operation.resolution == "not_applied"
                if drafts.finishSubmission(item.id, restoring: restoring) { if restoring { restore() } else { dismiss() } }
            default: error = "結果を確認できません。保存先を調べてから照合してください。"
            }
        } catch let failure as LAABridgeHTTPError {
            error = failure.code == "operation_not_found" ? LAAWorkHTTP.operationNotFound(canRepeat: LAAWorkDrafts.canRepeat(item)) : LAAWorkHTTP.message(failure)
        } catch { self.error = "保存状況を読み取れませんでした。" }
    }
}

private struct LAAPersonalCommentEditor: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.dismiss) private var dismiss
    let taskId: String
    let viewerId: String
    let parentId: String?
    @ObservedObject var drafts: ComposerDraftStore
    @State private var text = ""
    @State private var ready = false
    @State private var busy = false
    @State private var error: String?
    @State private var operation: LAAPersonalOperationResponse.Operation?
    private var path: String { LAAPersonalPath.task(taskId) + "/comments" }
    private var key: ComposerDraftKey? {
        bridge.deviceID.map { LAAWorkDrafts.key(deviceID: $0, target: "linear:\(viewerId):comment:\(taskId):\(parentId ?? "root")") }
    }
    private var pending: ComposerDraftStore.Submission? { key.flatMap { LAAWorkDrafts.pending(drafts, key: $0) } }

    var body: some View {
        NavigationStack {
            Form {
                if let error { Text(verbatim: error).foregroundStyle(LAAColor.attention) }
                if let pending {
                    Section() {
                        if pending.personalOrigin != nil {
                            Text(verbatim: "移した下書きは送信待ちで元の要求を照合してください。")
                        } else {
                            Text(verbatim: "送信結果を確認してください。結果が不明な間は新しい投稿を始めません。")
                            if let operation { Text(verbatim: "\(operation.displayKind) · \(operation.displayStatus)").textSelection(.enabled) }
                            Button(LAACopy.WorkTab.checkStatus) { Task { await check(pending) } }
                            if LAAWorkDrafts.canRepeat(pending) {
                                Button(LAACopy.WorkTab.retrySameRequest) { Task { await perform(pending, firstAttempt: false) } }
                            }
                        }
                    } header: { Text(verbatim: "送信待ち") }
                }
                Section() {
                    TextEditor(text: $text).frame(minHeight: 180).disabled(!ready || pending != nil)
                        .accessibilityIdentifier("work.task.comment")
                } header: { Text(verbatim: parentId == nil ? "コメント" : "返信") }
                Button() { submit() } label: { Text(verbatim: "投稿") }.disabled(!ready || busy || pending != nil || drafts.persistenceFailed || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(busy)
            .navigationTitle(Text(verbatim: parentId == nil ? "コメントを追加" : "返信"))
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(LAACopy.WorkTab.close) { dismiss() } } }
            .task(id: bridge.revision) { restore() }
            .onChange(of: text) { _, value in if ready && pending == nil { saveDraft(value) } }
        }
    }
    private func restore() {
        ready = false
        if let pending { text = pending.draft.text }
        else if let key { text = drafts.draft(for: key).text }
        ready = key != nil
    }
    private func saveDraft(_ value: String) {
        guard let key, drafts.save(ComposerDraft(text: value, attachments: []), for: key) else {
            error = "下書きを端末に保存できませんでした。"; return
        }
    }
    private func submit() {
        guard let key, pending == nil else { return }
        var payload: [String: String] = ["expectedViewerId": viewerId, "body": text]
        if let parentId { payload["parentId"] = parentId }
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let item = LAAWorkDrafts.reserve(drafts, key: key, text: text, body: body, idempotency: LAABridgeIdempotencyKey()) else {
            error = "送信前の記録を保存できませんでした。"; return
        }
        Task { await perform(item, firstAttempt: true) }
    }
    @MainActor private func perform(_ item: ComposerDraftStore.Submission, firstAttempt: Bool) async {
        guard LAAWorkDrafts.canRepeat(item), let (body, requestKey) = LAAWorkDrafts.request(item) else {
            error = LAAWorkDrafts.expiredMessage; return
        }
        busy = true; defer { busy = false }
        do {
            let response: LAABridgeResponse<LAAPersonalOperationResponse> = try await bridge.request(
                method: "POST", path: path, jsonBody: body, idempotencyKey: requestKey, timeout: 90)
            guard response.data.operation.status == "succeeded" else { throw LAABridgeError.invalidResponse }
            if drafts.finishSubmission(item.id, restoring: false) { dismiss() }
            else { error = "送信結果を端末に記録できません。" }
        } catch let failure as LAABridgeHTTPError {
            drafts.markSubmissionUnknown(item.id)
            if firstAttempt && ["payload_invalid", "expected_viewer_required", "linear_viewer_changed"].contains(failure.code ?? "") {
                if drafts.finishSubmission(item.id, restoring: true) { restore() }
            }
            error = LAAWorkHTTP.message(failure)
        } catch let failure as LAABridgeError {
            drafts.markSubmissionUnknown(item.id); error = failure.japaneseText
        } catch { drafts.markSubmissionUnknown(item.id); self.error = "送信結果を確認できませんでした。" }
    }
    @MainActor private func check(_ item: ComposerDraftStore.Submission) async {
        guard let (_, requestKey) = LAAWorkDrafts.request(item) else { error = "送信記録を読み取れません。"; return }
        busy = true; defer { busy = false }
        do {
            let response: LAABridgeResponse<LAAPersonalOperationResponse> = try await bridge.request(
                method: "GET", path: "/v1/task-operations/by-key", idempotencyKey: requestKey)
            operation = response.data.operation
            switch response.data.operation.status {
            case "succeeded": if drafts.finishSubmission(item.id, restoring: false) { dismiss() }
            case "rejected": if drafts.finishSubmission(item.id, restoring: true) { restore(); error = "送信前に拒否されました。" }
            case "resolved":
                guard ["applied", "not_applied"].contains(response.data.operation.resolution ?? "") else { throw LAABridgeError.invalidResponse }
                let restoring = response.data.operation.resolution == "not_applied"
                if drafts.finishSubmission(item.id, restoring: restoring) { if restoring { restore() } else { dismiss() } }
            default: error = "結果を確認できません。送信先を調べてから照合してください。"
            }
        } catch let failure as LAABridgeHTTPError {
            error = failure.code == "operation_not_found" ? LAAWorkHTTP.operationNotFound(canRepeat: LAAWorkDrafts.canRepeat(item)) : LAAWorkHTTP.message(failure)
        } catch { self.error = "送信状況を読み取れませんでした。" }
    }
}
#endif
