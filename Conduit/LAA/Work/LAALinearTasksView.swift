#if LAA_BUILD
import SwiftUI

struct LAALinearTasksView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @ObservedObject var drafts: ComposerDraftStore
    let priorityOnly: Bool
    var archivedOnly = false
    @State private var showingArchive = false
    @State private var items: [LAALinearTask] = []
    @State private var loading = false
    @State private var busy = false
    @State private var failure: String?
    @State private var loaded = false
    @State private var loadID = UUID()
    @State private var loadedDevice: String?
    @State private var editor: Editor?
    @State private var deleting: LAALinearTask?
    @State private var acknowledge = false
    private struct Editor: Identifiable {
        var id: String
        var task: LAALinearTask?
    }
    private var journalKey: ComposerDraftKey {
        LAAWorkDrafts.key(deviceID: bridge.deviceID ?? "unpaired", target: "linear-owner-operation")
    }
    private var pending: ComposerDraftStore.Submission? { LAAWorkDrafts.pending(drafts, key: journalKey) }
    private var rows: [LAALinearTask] {
        items.filter { archivedOnly ? $0.isArchived : ($0.isOpen && (!priorityOnly || $0.needsAttention(today: LAALinearTask.today()))) }
            .sorted {
                let a = $0.priority == 0 ? 5 : $0.priority
                let b = $1.priority == 0 ? 5 : $1.priority
                if a != b { return a < b }
                if $0.dueDate != $1.dueDate { return ($0.dueDate ?? "9999") < ($1.dueDate ?? "9999") }
                return $0.updatedAt > $1.updatedAt
            }
    }

    var body: some View {
        List {
            if let failure {
                Section {
                    Text(verbatim: failure).foregroundStyle(LAAColor.attention)
                    Button { Task { await load() } } label: { Text(verbatim: "読み直す") }
                }
            }
            if let pending, !busy {
                Section {
                    Text(verbatim: "保存結果を確認できませんでした。")
                    Button { startSend(pending, retry: true) } label: { Text(verbatim: "保存結果を確認") }
                        .disabled(busy || !LAAWorkDrafts.canRepeat(pending))
                    Button { acknowledge = true } label: { Text(verbatim: "Linearで結果を確認済み") }
                        .disabled(busy)
                }
            }
            if loading || busy { ProgressView().frame(maxWidth: .infinity) }
            Section {
                ForEach(rows) { task in
                    HStack(alignment: .top, spacing: LAASpacing.x3) {
                        Button { editor = Editor(id: task.id, task: task) } label: {
                            VStack(alignment: .leading, spacing: LAASpacing.x1) {
                                Text(verbatim: task.title).foregroundStyle(LAAColor.text).fontWeight(.medium)
                                HStack(spacing: LAASpacing.x2) {
                                    if task.priority != 0 {
                                        Text(verbatim: LAALinearTask.priorityLabel(task.priority))
                                            .foregroundStyle(task.priority <= 2 ? LAAColor.attention : LAAColor.secondaryText)
                                    }
                                    if let due = task.dueDate {
                                        Label { Text(verbatim: due) } icon: { Image(systemName: "calendar") }
                                            .foregroundStyle(due <= LAALinearTask.today() ? LAAColor.attention : LAAColor.secondaryText)
                                    }
                                }.laaTextStyle(.secondary)
                            }.frame(maxWidth: .infinity, minHeight: LAASpacing.minimumTouchTarget, alignment: .leading)
                        }.buttonStyle(.borderless).disabled(archivedOnly)
                    }
                    .disabled(busy || pending != nil)
                    .listRowBackground(LAAColor.surface)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if archivedOnly {
                            Button { submit(method: "POST", id: task.id, body: nil, version: task.updatedAt, action: "restore") } label: {
                                Label { Text(verbatim: "戻す") } icon: { Image(systemName: "arrow.uturn.backward") }
                            }.tint(LAAColor.link).disabled(busy || pending != nil)
                        } else {
                            Button(role: .destructive) { deleting = task } label: {
                                Label { Text(verbatim: "削除") } icon: { Image(systemName: "trash") }
                            }.disabled(busy || pending != nil)
                        }
                    }
                }
            } header: {
                Text(verbatim: archivedOnly ? "アーカイブ" : priorityOnly ? "期限・優先度の高いタスク" : "社長のタスク")
            } footer: {
                Text(verbatim: archivedOnly ? "アーカイブしたタスクです。スワイプで戻せます。" : "Linear · LAA担当")
            }
            if loaded && rows.isEmpty && !loading && failure == nil {
                ContentUnavailableView {
                    Label { Text(verbatim: archivedOnly ? "アーカイブはありません" : priorityOnly ? "優先タスクはありません" : "タスクはありません") }
                    icon: { Image(systemName: "checkmark.circle") }
                } description: {
                    Text(verbatim: archivedOnly ? "アーカイブしたタスクは、スワイプで戻せます。" : priorityOnly ? "緊急・高優先度、または今日までが期限のタスクを表示します。" : "＋から追加できます。")
                }.listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .tint(LAAColor.link)
        .refreshable { await load() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !archivedOnly {
                    Button { showingArchive = true } label: { Image(systemName: "archivebox") }
                        .accessibilityLabel(Text(verbatim: "アーカイブ"))
                        .accessibilityIdentifier("work.linear.archive")
                        .disabled(busy || pending != nil)
                Button { editor = Editor(id: UUID().uuidString.lowercased(), task: nil) } label: { Image(systemName: "plus") }
                    .accessibilityLabel(Text(verbatim: "タスクを追加"))
                    .accessibilityIdentifier("work.linear.add")
                    .disabled(busy || pending != nil)
                } else {
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel(Text(verbatim: "読み直す"))
                }
            }
        }
        .sheet(isPresented: $showingArchive, onDismiss: { Task { await load() } }) {
            NavigationStack {
                LAALinearTasksView(drafts: drafts, priorityOnly: false, archivedOnly: true)
                    .navigationTitle(Text(verbatim: "アーカイブ"))
                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                        Button { showingArchive = false } label: { Text(verbatim: "閉じる") }
                    } }
            }
        }
        .task(id: bridge.revision) { await load() }
        .sheet(item: $editor) { value in
            LAALinearTaskEditor(id: value.id, task: value.task, busy: busy || pending != nil, failure: failure) { body in
                submit(method: value.task == nil ? "POST" : "PATCH", id: value.id,
                       body: body, version: value.task?.updatedAt)
            }
        }
        .confirmationDialog(Text(verbatim: "このタスクを削除しますか？"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button(role: .destructive) {
                if let task = deleting { submit(method: "POST", id: task.id, body: nil, version: task.updatedAt, action: "archive") }
                deleting = nil
            } label: { Text(verbatim: "削除") }
            Button(role: .cancel) { deleting = nil } label: { Text(verbatim: "キャンセル") }
        } message: { Text(verbatim: "アーカイブに移り、あとで戻せます。") }
        .confirmationDialog(Text(verbatim: "操作の控えを閉じますか？"), isPresented: $acknowledge) {
            Button { if let pending { _ = drafts.finishSubmission(pending.id, restoring: false) }; Task { await load() } }
            label: { Text(verbatim: "結果を確認して閉じる") }
        } message: { Text(verbatim: "Linearで反映結果を確認した場合だけ閉じてください。この操作は変更を取り消しません。") }
    }

    private func submit(method: String, id: String, body: Data?, version: String?, action: String? = nil) {
        guard bridge.status == .paired, !busy, pending == nil else { return }
        let mutation = LAALinearTaskMutation(method: method, id: id, body: body, version: version, action: action)
        guard mutation.isValid, let data = try? JSONEncoder().encode(mutation),
              let item = LAAWorkDrafts.reserve(drafts, key: journalKey, text: "Linearタスクの変更", body: data,
                                             idempotency: LAABridgeIdempotencyKey()) else {
            failure = "入力を端末に保存できません。もう一度お試しください。"; return
        }
        drafts.markSubmissionUnknown(item.id)
        startSend(item)
    }

    private func startSend(_ item: ComposerDraftStore.Submission, retry: Bool = false) {
        guard !busy else { return }
        busy = true
        Task { await send(item, retry: retry) }
    }

    private func send(_ item: ComposerDraftStore.Submission, retry: Bool = false) async {
        defer { busy = false }
        guard item.key == journalKey, LAAWorkDrafts.canRepeat(item),
              let (bytes, key) = LAAWorkDrafts.request(item),
              let mutation = try? JSONDecoder().decode(LAALinearTaskMutation.self, from: bytes), mutation.isValid else { return }
        failure = nil
        let device = bridge.deviceID
        do {
            if let action = mutation.action {
                struct ArchiveResult: Decodable { let id: String; let archived: Bool }
                let result: LAABridgeResponse<ArchiveResult> = try await bridge.request(method: mutation.method, path: mutation.path,
                    idempotencyKey: key, ifMatch: mutation.version)
                guard result.data.id == mutation.id, result.data.archived == (action == "archive") else { throw LAABridgeError.invalidResponse }
            } else {
                let result: LAABridgeResponse<LAALinearTask> = try await bridge.request(method: mutation.method, path: mutation.path,
                    jsonBody: mutation.body, idempotencyKey: key, ifMatch: mutation.version)
                guard result.data.id.lowercased() == mutation.id.lowercased() else { throw LAABridgeError.invalidResponse }
            }
            guard bridge.deviceID == device else { return }
            guard drafts.finishSubmission(item.id, restoring: false) else {
                failure = "反映されましたが、端末の控えを更新できません。再確認してください。"; return
            }
            editor = nil
            await load()
        } catch let error as LAABridgeHTTPError where [400, 403, 404, 412, 422, 428].contains(error.status)
            || (error.status == 409 && ["linear_owner_task_conflict", "linear_owner_task_archived"].contains(error.code ?? "")) {
            guard bridge.deviceID == device else { return }
            let archivedMessage = error.status == 409 && error.code == "linear_owner_task_archived"
                ? "このタスクはアーカイブ済みです。読み直してください。" : nil
            if retry {
                failure = archivedMessage ?? "前の操作の結果は未確認です。Linearで状態を確認してください。"
            } else if !drafts.finishSubmission(item.id, restoring: false) {
                failure = "端末の控えを更新できません。入力を保持しています。"
            } else {
                failure = archivedMessage ?? (error.status == 412 ? "Linearで更新されています。編集画面を閉じて読み直してください。" : "操作が受け付けられませんでした。入力と接続を確認してください。")
            }
        } catch {
            guard bridge.deviceID == device else { return }
            editor = nil
            await reconcile(item, mutation: mutation, device: device)
        }
    }

    private func reconcile(_ item: ComposerDraftStore.Submission, mutation: LAALinearTaskMutation, device: String?) async {
        do {
            let current: LAALinearTask = try await bridge.read("/v1/linear-owner-tasks/\(mutation.id)")
            guard bridge.deviceID == device, mutation.isReflected(in: current),
                  drafts.finishSubmission(item.id, restoring: false) else { throw LAABridgeError.invalidResponse }
            editor = nil
            await load()
        } catch {
            if bridge.deviceID == device { failure = "保存結果を確認できません。接続を確認して、もう一度お試しください。" }
        }
    }

    private func load() async {
        let device = bridge.deviceID
        if loadedDevice != device { items = []; loaded = false; loadedDevice = device; editor = nil }
        guard bridge.status == .paired else { return }
        let epoch = UUID(); loadID = epoch
        loading = true
        defer { if loadID == epoch { loading = false } }
        do {
            let page: LAAWorkPage<LAALinearTask> = try await bridge.read(archivedOnly ? "/v1/linear-owner-tasks?archived=only" : "/v1/linear-owner-tasks")
            guard loadID == epoch, device == bridge.deviceID, !Task.isCancelled else { return }
            guard page.nextCursor == nil else { throw LAABridgeError.invalidResponse }
            items = page.items; loaded = true; failure = nil
            if !busy, let pending, let (bytes, _) = LAAWorkDrafts.request(pending),
               let mutation = try? JSONDecoder().decode(LAALinearTaskMutation.self, from: bytes), mutation.isValid {
                // A restarted app may have missed a successful reply. Read only;
                // never replace its key or replay a write during refresh.
                if let current: LAALinearTask = try? await bridge.read("/v1/linear-owner-tasks/\(mutation.id)"),
                   loadID == epoch, device == bridge.deviceID, mutation.isReflected(in: current) {
                    _ = drafts.finishSubmission(pending.id, restoring: false)
                }
            }
        } catch is CancellationError { return }
        catch {
            guard loadID == epoch, device == bridge.deviceID else { return }
            failure = loaded ? "最新のタスクを取得できません。前回の内容を表示しています。" : "Linearのタスクを取得できません。接続を確認して読み直してください。"
        }
    }
}

private struct LAALinearTaskEditor: View {
    @Environment(\.dismiss) private var dismiss
    let id: String
    let task: LAALinearTask?
    let busy: Bool
    let failure: String?
    let save: (Data) -> Void
    @State private var title: String
    @State private var detail: String
    @State private var priority: Int
    @State private var hasDueDate: Bool
    @State private var dueDate: Date

    init(id: String, task: LAALinearTask?, busy: Bool, failure: String?, save: @escaping (Data) -> Void) {
        self.id = id; self.task = task; self.busy = busy; self.failure = failure; self.save = save
        _title = State(initialValue: task?.title ?? "")
        _detail = State(initialValue: task?.description ?? "")
        _priority = State(initialValue: task?.priority ?? 0)
        _hasDueDate = State(initialValue: task?.dueDate != nil)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        _dueDate = State(initialValue: task?.dueDate.flatMap { formatter.date(from: $0) } ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(text: $title, axis: .vertical) { Text(verbatim: "題名") }
                        .accessibilityIdentifier("work.linear.title")
                    TextField(text: $detail, axis: .vertical) { Text(verbatim: "説明") }.lineLimit(4...10)
                }
                Section {
                    Toggle(isOn: $hasDueDate) { Text(verbatim: "期限") }
                    if hasDueDate { DatePicker(selection: $dueDate, displayedComponents: .date) { Text(verbatim: "期限日") } }
                    Picker(selection: $priority) {
                        ForEach(0...4, id: \.self) { value in Text(verbatim: LAALinearTask.priorityLabel(value)).tag(value) }
                    } label: { Text(verbatim: "優先度") }
                }
                if let failure { Text(verbatim: failure).foregroundStyle(LAAColor.attention) }
            }
            .disabled(busy)
            .navigationTitle(Text(verbatim: task == nil ? "タスクを追加" : "タスクを編集"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Text(verbatim: "閉じる") } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        var body: [String: Any] = ["title": title.trimmingCharacters(in: .whitespacesAndNewlines),
                            "description": detail, "priority": priority, "dueDate": hasDueDate ? LAALinearTask.today(dueDate) as Any : NSNull()]
                        if task == nil { body["id"] = id }
                        if let data = try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys) { save(data) }
                    } label: { Text(verbatim: "保存") }
                    .disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count > 200 || detail.utf16.count > 20000)
                }
            }
        }.interactiveDismissDisabled(busy)
    }
}
#endif
