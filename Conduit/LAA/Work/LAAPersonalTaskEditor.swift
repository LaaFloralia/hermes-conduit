#if LAA_BUILD
import SwiftUI

struct LAAPersonalTaskEditor: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var drafts: ComposerDraftStore
    private let initialTask: LAAPersonalTask?
    private let parentTask: LAAPersonalTask?
    private let viewerId: String
    @State private var draft: LAAPersonalTaskDraft
    @State private var metadata: LAAPersonalMetadata?
    @State private var teams: [LAAPersonalChoice] = []
    @State private var users: [LAAPersonalChoice] = []
    @State private var states: [LAAPersonalChoice] = []
    @State private var labels: [LAAPersonalChoice] = []
    @State private var projects: [LAAPersonalChoice] = []
    @State private var milestones: [LAAPersonalChoice] = []
    @State private var cycles: [LAAPersonalChoice] = []
    @State private var choiceCursors: [String: String] = [:]
    @State private var choicesDone = Set<String>()
    @State private var incompleteChoices = false
    @State private var ready = false
    @State private var identityOK = false
    @State private var busy = false
    @State private var error: String?
    @State private var remote: LAAPersonalTask?
    @State private var confirmedRejection = false
    @State private var operation: LAAPersonalOperationResponse.Operation?
    @State private var showFollowup = false

    init(task: LAAPersonalTask?, viewerId: String, drafts: ComposerDraftStore, parent: LAAPersonalTask? = nil) {
        initialTask = task; parentTask = parent; self.viewerId = viewerId; self.drafts = drafts
        var initial = LAAPersonalTaskDraft(viewerId: viewerId, task: task)
        if task == nil, let parent { initial.parentId = parent.linearId; initial.teamId = parent.team?.id ?? "" }
        _draft = State(initialValue: initial)
    }
    private var key: ComposerDraftKey? {
        bridge.deviceID.map { LAAWorkDrafts.key(deviceID: $0, target: "linear:\(viewerId):\(initialTask?.id ?? parentTask.map { "new-subtask:\($0.id)" } ?? "new")") }
    }
    private var pending: ComposerDraftStore.Submission? { key.flatMap { LAAWorkDrafts.pending(drafts, key: $0) } }
    private var hasFullTask: Bool { initialTask == nil || draft.base?.description != nil }

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Text(verbatim: error).foregroundStyle(LAAColor.attention)
                    if !identityOK { Button(LAACopy.WorkTab.retry) { Task { await prepare() } } }
                }
                if let pending {
                    pendingSection(pending)
                }
                if let remote, let pending, confirmedRejection {
                    Section("Compare Description") {
                        Text(verbatim: "− 現在の版 / + あなたの変更").foregroundStyle(LAAColor.secondaryText)
                        ForEach(Array(LAAPersonalTaskDiff.changes(current: remote.description ?? "", mine: draft.description).enumerated()), id: \.offset) { _, line in
                            Text(verbatim: line).textSelection(.enabled)
                        }
                        Text(verbatim: "現在の本文").fontWeight(.semibold)
                        Text(verbatim: remote.description ?? "").textSelection(.enabled)
                        Text(verbatim: "あなたの本文").fontWeight(.semibold)
                        Text(verbatim: draft.description).textSelection(.enabled)
                        Button(LAACopy.WorkTab.useCurrent) { choose(remote, pending: pending, mine: false) }
                        Button(LAACopy.WorkTab.saveMine) { choose(remote, pending: pending, mine: true) }
                            .disabled(remote.updatedAt == nil || busy)
                    }
                }
                Section("Title") {
                    if let parentTask { Text(verbatim: "Parent: \(parentTask.sourceId) · \(parentTask.title)") }
                    TextField("Task Title", text: $draft.title, axis: .vertical)
                        .accessibilityIdentifier("work.task.title")
                }.disabled(!ready || pending != nil)
                Section("Description") {
                    TextEditor(text: $draft.description).frame(minHeight: 180)
                        .accessibilityIdentifier("work.task.description")
                }.disabled(!ready || pending != nil)
                Section("Properties") {
                    Picker("Team", selection: teamBinding) {
                        Text("Select Team").tag("")
                        ForEach(teams) { Text(verbatim: $0.displayName).tag($0.id) }
                    }
                    Picker("Status", selection: $draft.stateId) {
                        Text("Default").tag("")
                        ForEach(states.filter { $0.team?.id == draft.teamId }) { Text(verbatim: $0.displayName).tag($0.id) }
                    }
                    Picker("Assignee", selection: $draft.assigneeId) {
                        Text("Unassigned").tag("")
                        ForEach(users.filter { $0.active != false }) { Text(verbatim: $0.displayName).tag($0.id) }
                    }
                    Picker("Priority", selection: $draft.priority) {
                        if let metadata { ForEach(metadata.priorities) { Text(verbatim: $0.label).tag($0.priority) } }
                        else { ForEach(0...4, id: \.self) { Text(verbatim: String($0)).tag($0) } }
                    }
                    Picker("Project", selection: projectBinding) {
                        Text("None").tag("")
                        ForEach(projects) { Text(verbatim: $0.displayName).tag($0.id) }
                    }
                    Picker("Milestone", selection: $draft.milestoneId) {
                        Text("None").tag("")
                        ForEach(milestones.filter { $0.project?.id == draft.projectId }) { Text(verbatim: $0.displayName).tag($0.id) }
                    }
                    Picker("Cycle", selection: $draft.cycleId) {
                        Text("None").tag("")
                        ForEach(cycles.filter { $0.team?.id == draft.teamId }) { Text(verbatim: $0.displayName).tag($0.id) }
                    }
                    TextField("Estimate (whole number)", text: $draft.estimate).keyboardType(.numberPad)
                    TextField("Due date (YYYY-MM-DD)", text: $draft.dueDate).textInputAutocapitalization(.never)
                    if incompleteChoices {
                        Text(verbatim: "選択肢は一部のみ取得しています。未表示の値は変更されません。")
                            .foregroundStyle(LAAColor.attention)
                        Button(LAACopy.WorkTab.loadMore) { Task { await loadMoreChoices() } }
                    }
                }.disabled(!ready || pending != nil)
                Section("Labels") {
                    if draft.base != nil && draft.base?.labelsComplete != true {
                        Text(verbatim: "ラベルをすべて取得できていないため、ここでは変更できません。")
                    } else {
                        ForEach(labels.filter { $0.team == nil || $0.team?.id == draft.teamId }) { label in
                            Toggle(label.displayName, isOn: Binding(
                                get: { draft.labelIds.contains(label.id) },
                                set: { selected in
                                    if selected { if !draft.labelIds.contains(label.id) { draft.labelIds.append(label.id) } }
                                    else { draft.labelIds.removeAll { $0 == label.id } }
                                }))
                        }
                    }
                }.disabled(!ready || pending != nil)
                Button(initialTask == nil ? LAACopy.WorkTab.create : LAACopy.WorkTab.save) { save() }
                    .disabled(!ready || !identityOK || !hasFullTask || pending != nil || busy || drafts.persistenceFailed)
                    .accessibilityIdentifier("work.task.save")
                if !identityOK {
                    Button("Queue Until Connected") { save(sendImmediately: false) }
                        .disabled(!ready || pending != nil || busy || drafts.persistenceFailed)
                    Text(verbatim: "端末に保存し、本人を確認できる接続に戻った時に送信します。")
                        .laaTextStyle(.secondary)
                }
            }
            .disabled(busy)
            .navigationTitle(Text(verbatim: initialTask == nil ? LAACopy.WorkTab.newTask : LAACopy.WorkTab.editTask))
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(LAACopy.WorkTab.close) { dismiss() } } }
            .onChange(of: draft) { _, _ in if ready && pending == nil { saveDraft() } }
            .task { await prepare() }
            .sheet(isPresented: $showFollowup) {
                if let pending, let (_, requestKey) = LAAWorkDrafts.request(pending), let device = bridge.deviceID,
                   let data = pending.draft.text.data(using: .utf8),
                   let original = try? JSONDecoder().decode(LAAPersonalTaskDraft.self, from: data), original.viewerId == viewerId {
                    LAAPersonalDependencyEditor(drafts: drafts, viewer: viewerId, device: device,
                                                parentKey: requestKey.value, team: original.teamId)
                }
            }
        }
    }

    private var teamBinding: Binding<String> {
        Binding(get: { draft.teamId }, set: { value in
            if draft.teamId != value { draft.teamId = value; draft.stateId = ""; draft.cycleId = "" }
        })
    }
    private var projectBinding: Binding<String> {
        Binding(get: { draft.projectId }, set: { value in
            if draft.projectId != value { draft.projectId = value; draft.milestoneId = "" }
        })
    }
    @ViewBuilder private func pendingSection(_ item: ComposerDraftStore.Submission) -> some View {
        Section("Pending") {
            Text(verbatim: "保存結果は未確認です。同じ要求の状態を先に確認してください。")
            if let operation {
                Text(verbatim: "\(operation.status) · \(operation.targetId)").textSelection(.enabled)
            }
            Button(LAACopy.WorkTab.checkStatus) { Task { await check(item) } }
            if initialTask == nil {
                Button("Add Follow-up") { showFollowup = true }
                Text(verbatim: "コメント・子課題・関連・リンクは、作成を確認した後に送ります。")
                    .laaTextStyle(.secondary)
            }
            if !confirmedRejection && LAAWorkDrafts.canRepeat(item) {
                Button(LAACopy.WorkTab.retrySameRequest) { Task { await perform(item, firstAttempt: false) } }
            }
            if !LAAWorkDrafts.canRepeat(item) {
                Text(verbatim: "再送期限を過ぎています。保存先を確認して照合してください。")
            }
        }
    }

    @MainActor private func prepare() async {
        ready = false; identityOK = false
        do {
            if let initialTask, initialTask.description == nil {
                let detail: LAAPersonalTaskResponse = try await bridge.read(taskPath(initialTask.id))
                guard detail.viewerId == viewerId else { throw LAABridgeError.conflict }
                draft = LAAPersonalTaskDraft(viewerId: viewerId, task: detail.task)
            }
            let options: LAAPersonalMetadata = try await bridge.read("/v1/task-metadata")
            guard options.viewer.id == viewerId else { throw LAABridgeError.conflict }
            metadata = options; identityOK = true
            teams = options.teams.items; users = options.users.items; states = options.workflowStates.items
            labels = options.issueLabels.items; projects = options.projects.items
            milestones = options.projectMilestones.items; cycles = options.cycles.items
            incompleteChoices = [options.teams, options.users, options.workflowStates, options.issueLabels,
                                 options.projects, options.projectMilestones, options.cycles].contains { !$0.complete }
            let collections: [(String, LAAPersonalChoices)] = [("teams", options.teams), ("users", options.users),
                ("states", options.workflowStates), ("labels", options.issueLabels), ("projects", options.projects),
                ("milestones", options.projectMilestones), ("cycles", options.cycles)]
            choicesDone = Set(collections.filter { $0.1.complete }.map { $0.0 }); choiceCursors = [:]
            if initialTask == nil && draft.teamId.isEmpty && teams.count == 1 { draft.teamId = teams[0].id }
            restoreDraft()
            ready = true
            if let pending, LAAWorkConflictJournal.contains(pending.id) {
                confirmedRejection = true; await loadConflict()
            }
        } catch is CancellationError {
        } catch let failure as LAABridgeError {
            error = failure.japaneseText
            // A full previously read task can still be edited as a protected
            // local draft; sending waits for a verified viewer.
            restoreDraft(); ready = hasFullTask
        } catch { self.error = "タスクの選択肢を読み取れませんでした。"; restoreDraft(); ready = hasFullTask }
    }

    @MainActor private func loadMoreChoices() async {
        busy = true; defer { busy = false }
        for kind in ["teams", "users", "states", "labels", "projects", "milestones", "cycles"] where !choicesDone.contains(kind) {
            do {
                let base: String
                if kind == "projects" { base = "/v1/task-projects" }
                else if kind == "cycles" { base = "/v1/task-cycles" }
                else { base = "/v1/task-options" }
                var query = [URLQueryItem(name: "limit", value: "100")]
                if base == "/v1/task-options" { query.append(URLQueryItem(name: "kind", value: kind)) }
                if let cursor = choiceCursors[kind] { query.append(URLQueryItem(name: "cursor", value: cursor)) }
                let page: LAAPersonalPage<LAAPersonalChoice> = try await bridge.read(LAAWorkPresentation.path(base, query: query))
                guard page.viewerId == viewerId, page.nextCursor == nil || page.nextCursor != choiceCursors[kind] else { throw LAABridgeError.conflict }
                switch kind {
                case "teams": teams = merge(teams, page.items)
                case "users": users = merge(users, page.items)
                case "states": states = merge(states, page.items)
                case "labels": labels = merge(labels, page.items)
                case "projects": projects = merge(projects, page.items)
                case "milestones": milestones = merge(milestones, page.items)
                case "cycles": cycles = merge(cycles, page.items)
                default: break
                }
                if let next = page.nextCursor { choiceCursors[kind] = next }
                else { choicesDone.insert(kind); choiceCursors.removeValue(forKey: kind) }
            } catch { self.error = "選択肢の続きを読み取れませんでした。"; break }
        }
        incompleteChoices = choicesDone.count < 7
    }
    private func merge(_ old: [LAAPersonalChoice], _ more: [LAAPersonalChoice]) -> [LAAPersonalChoice] {
        let known = Set(old.map(\.id))
        return old + more.filter { !known.contains($0.id) }
    }

    private func taskPath(_ id: String) -> String {
        "/v1/personal-tasks/" + (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")
    }
    private func restoreDraft() {
        let text: String?
        if let pending { text = pending.draft.text }
        else if let key, drafts.hasDraft(for: key) { text = drafts.draft(for: key).text }
        else { text = nil }
        if let text, let bytes = text.data(using: .utf8),
           let saved = try? JSONDecoder().decode(LAAPersonalTaskDraft.self, from: bytes), saved.viewerId == viewerId {
            draft = saved
        }
    }
    private func saveDraft() {
        guard let key, pending == nil, let bytes = try? JSONEncoder().encode(draft),
              drafts.save(ComposerDraft(text: String(decoding: bytes, as: UTF8.self), attachments: []), for: key) else {
            error = "下書きを端末に保存できませんでした。"; return
        }
    }
    private func save(sendImmediately: Bool = true) {
        guard let key else { return }
        do {
            let body = try draft.requestBody()
            let encoded = try JSONEncoder().encode(draft)
            guard let item = LAAWorkDrafts.reserve(drafts, key: key, text: String(decoding: encoded, as: UTF8.self),
                body: body, idempotency: LAABridgeIdempotencyKey(), expectedVersion: draft.base?.updatedAt) else {
                error = "保存要求を端末に記録できませんでした。"; return
            }
            if sendImmediately { Task { await perform(item, firstAttempt: true) } }
            else { drafts.markSubmissionUnknown(item.id); error = "要求を端末に保存しました。接続後に送信を試みます。" }
        } catch LAAPersonalTaskDraft.Validation.missingTitle { error = "タイトルを入力してください。" }
        catch LAAPersonalTaskDraft.Validation.missingTeam { error = "チームを選んでください。" }
        catch LAAPersonalTaskDraft.Validation.invalidEstimate { error = "見積りは0以上の整数で入力してください。" }
        catch LAAPersonalTaskDraft.Validation.missingVersion { error = "本文の版を確認してから保存してください。" }
        catch LAAPersonalTaskDraft.Validation.incompleteLabels { error = "ラベルをすべて取得するまで変更できません。" }
        catch LAAPersonalTaskDraft.Validation.noChanges { error = "変更はありません。" }
        catch { self.error = "保存要求を作れませんでした。" }
    }

    @MainActor private func perform(_ item: ComposerDraftStore.Submission, firstAttempt: Bool) async {
        guard LAAWorkDrafts.canRepeat(item), let (body, requestKey) = LAAWorkDrafts.request(item) else {
            error = LAAWorkDrafts.expiredMessage; return
        }
        busy = true; defer { busy = false }
        do {
            let response: LAABridgeResponse<LAAPersonalOperationResponse> = try await bridge.request(
                method: initialTask == nil ? "POST" : "PATCH", path: initialTask.map { taskPath($0.id) } ?? "/v1/personal-tasks",
                jsonBody: body, idempotencyKey: requestKey, ifMatch: item.screenshotID, timeout: 90)
            guard response.data.operation.status == "succeeded" else { throw LAABridgeError.invalidResponse }
            guard drafts.finishSubmission(item.id, restoring: false) else { error = "保存結果を端末に記録できません。"; return }
            LAAWorkConflictJournal.clear(item.id); dismiss()
        } catch let failure as LAABridgeHTTPError {
            drafts.markSubmissionUnknown(item.id)
            if failure.status == 412 {
                if LAAWorkConflictJournal.mark(item.id) { confirmedRejection = true; await loadConflict() }
                else { error = "競合の記録を保存できません。変更は保留しています。" }
            } else if firstAttempt && ["payload_invalid", "expected_viewer_required", "if_match_required", "linear_viewer_changed"].contains(failure.code ?? "") {
                if drafts.finishSubmission(item.id, restoring: true) { restoreDraft() }
                if failure.code == "linear_viewer_changed" { identityOK = false; error = "Linearの本人が変わりました。元の本人を確認してください。" }
                else { error = LAAWorkHTTP.message(failure) }
            } else { error = LAAWorkHTTP.message(failure) }
        } catch let failure as LAABridgeError {
            drafts.markSubmissionUnknown(item.id); error = failure.japaneseText
        } catch { drafts.markSubmissionUnknown(item.id); self.error = "保存結果を確認できませんでした。" }
    }

    @MainActor private func check(_ item: ComposerDraftStore.Submission) async {
        guard let (_, requestKey) = LAAWorkDrafts.request(item) else { error = "保存要求を読み取れません。"; return }
        busy = true; defer { busy = false }
        do {
            let result: LAABridgeResponse<LAAPersonalOperationResponse> = try await bridge.request(
                method: "GET", path: "/v1/task-operations/by-key", idempotencyKey: requestKey)
            operation = result.data.operation
            switch result.data.operation.status {
            case "succeeded":
                if drafts.finishSubmission(item.id, restoring: false) { dismiss() }
                else { error = "保存結果を端末に記録できません。" }
            case "resolved":
                guard ["applied", "not_applied"].contains(result.data.operation.resolution ?? "") else { throw LAABridgeError.invalidResponse }
                let restore = result.data.operation.resolution == "not_applied"
                if drafts.finishSubmission(item.id, restoring: restore) { if restore { restoreDraft() } else { dismiss() } }
                else { error = "照合結果を端末に記録できません。" }
            case "rejected":
                if initialTask != nil && draft.descriptionChanged &&
                    (result.data.operation.rejection == nil || result.data.operation.rejection == "version_mismatch") {
                    if LAAWorkConflictJournal.mark(item.id) { confirmedRejection = true; await loadConflict() }
                    else { error = "確認結果を端末に保存できません。" }
                } else if drafts.finishSubmission(item.id, restoring: true) { restoreDraft(); error = "保存前に拒否されました。下書きを確認してください。" }
            default: error = "結果を確認できません。保存先を調べてから照合してください。"
            }
        } catch let failure as LAABridgeHTTPError {
            error = failure.code == "operation_not_found" ? "要求記録がまだありません。同じ要求を再試行できます。" : LAAWorkHTTP.message(failure)
        } catch { self.error = "保存状況を読み取れませんでした。" }
    }

    @MainActor private func loadConflict() async {
        guard let id = initialTask?.id else { return }
        do {
            let current: LAAPersonalTaskResponse = try await bridge.read(taskPath(id))
            guard current.viewerId == viewerId else { throw LAABridgeError.conflict }
            remote = current.task; error = nil
        } catch { self.error = "現在の本文を読み取れませんでした。" }
    }
    private func choose(_ current: LAAPersonalTask, pending: ComposerDraftStore.Submission, mine: Bool) {
        guard confirmedRejection, current.updatedAt != nil else { return }
        guard drafts.finishSubmission(pending.id, restoring: true) else { error = "選択を保存できませんでした。"; return }
        LAAWorkConflictJournal.clear(pending.id)
        draft.rebase(on: current)
        if !mine { draft.description = current.description ?? "" }
        confirmedRejection = false; remote = nil; operation = nil
        saveDraft()
        if mine && !drafts.persistenceFailed { save() }
    }
}
#endif
