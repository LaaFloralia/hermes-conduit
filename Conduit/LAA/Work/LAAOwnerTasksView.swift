#if LAA_BUILD
import SwiftUI

struct LAAOwnerTasksView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @ObservedObject var drafts: ComposerDraftStore
    let refreshID: Int

    @State private var items: [LAAOwnerTask] = []
    @State private var cache = LAAOwnerTaskCache()
    @State private var currentDevice: String?
    @State private var loaded = false
    @State private var listIsStale = false
    @State private var loading = false
    @State private var loadID = UUID()
    @State private var message: String?
    @State private var newTitle = ""
    @State private var newID = UUID()
    @State private var sending = Set<UUID>()
    @State private var editor: Editor?
    @State private var editorVisible = false
    @State private var deferredEditor: Editor?
    @State private var comparison: Comparison?
    @State private var deferredComparison: Comparison?
    @State private var showingPending = false
    @State private var pendingAction: PendingAction?
    @State private var inspected: [UUID: LAAOwnerTask] = [:]

    private struct Editor: Identifiable {
        let id = UUID()
        let draft: LAAOwnerTaskDraft
        let deviceID: String
    }
    private struct Comparison: Identifiable {
        let id = UUID()
        let value: LAAOwnerTaskConflict
        let deviceID: String
    }
    private struct PendingAction: Identifiable {
        enum Kind { case retry, restoreConflict, discard, move, discardDraft, moveDraft }
        let id = UUID()
        let kind: Kind
        var item: ComposerDraftStore.Submission? = nil
        var entry: LAAOwnerTaskLocalDrafts.Entry? = nil
    }

    private var pending: [ComposerDraftStore.Submission] { LAAOwnerTaskOutbox.entries(in: drafts) }
    private var localEntries: [LAAOwnerTaskLocalDrafts.Entry] { LAAOwnerTaskLocalDrafts.entries(in: drafts) }
    private var ownPending: [ComposerDraftStore.Submission] {
        pending.filter { LAAOwnerTaskOutbox.request($0)?.deviceID == bridge.deviceID && bridge.deviceID != nil }
    }
    private var ownDrafts: [LAAOwnerTaskLocalDrafts.Entry] {
        localEntries.filter { $0.deviceID == bridge.deviceID && bridge.deviceID != nil }
    }
    private var otherCount: Int { pending.count + localEntries.count - ownPending.count - ownDrafts.count }
    private var otherPending: [ComposerDraftStore.Submission] {
        pending.filter { !ownPending.contains($0) }
    }
    private var otherDrafts: [LAAOwnerTaskLocalDrafts.Entry] {
        localEntries.filter { entry in !ownDrafts.contains(where: { $0.key == entry.key }) }
    }
    private var blockedIDs: Set<UUID> {
        Set(ownPending.compactMap { LAAOwnerTaskOutbox.request($0)?.taskID }).union(sending)
    }
    private var draftIDs: Set<UUID> { Set(ownDrafts.compactMap(\.taskID)) }

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            if let message {
                Text(verbatim: message).foregroundStyle(LAAColor.attention)
                    .accessibilityIdentifier("work.ownerTasks.message")
            }
            if bridge.deviceID == nil {
                Text(verbatim: "タスクを保存するには、この端末とMacの接続が必要です。")
                    .foregroundStyle(LAAColor.secondaryText)
            }
            if loading && items.isEmpty { LAALoadingDots() }
            LAAOwnerTaskListContent(tasks: items, newTitle: $newTitle, adding: false,
                                    inputEnabled: bridge.deviceID != nil, showEmpty: loaded,
                                    disabledIDs: blockedIDs, checkboxDisabledIDs: draftIDs,
                                    openTask: open, createTask: create,
                                    toggleTask: toggle)
            Button {
                showingPending = true
            } label: {
                Text(verbatim: "送信待ち・下書き（\(pending.count + localEntries.count)）")
            }
            .accessibilityIdentifier("work.ownerTasks.pending")
        }
        .onChange(of: newTitle) { _, _ in saveInline() }
        .task(id: "\(bridge.revision)-\(refreshID)") { await load() }
        .sheet(item: $editor, onDismiss: {
            editorVisible = false
            presentDeferred()
        }) { entry in
            LAAOwnerTaskEditor(draft: entry.draft, onChange: { draft in
                guard bridge.deviceID == entry.deviceID else { return }
                if !LAAOwnerTaskLocalDrafts.save(draft, in: drafts, deviceID: entry.deviceID) {
                    message = "下書きを端末に保存できません。入力を保持し、もう一度お試しください。"
                }
            }, save: { draft in
                guard bridge.deviceID == entry.deviceID else {
                    message = "接続先が変わりました。下書きは元の端末の保留に残っています。"
                    return
                }
                submit(draft, deviceID: entry.deviceID)
            })
            .onAppear { editorVisible = true }
        }
        .sheet(item: $comparison) { entry in
            NavigationStack {
                LAAOwnerTaskConflictContent(conflict: entry.value, useCurrent: {
                    if LAAOwnerTaskLocalDrafts.remove(entry.value.draft, from: drafts, deviceID: entry.deviceID) {
                        comparison = nil
                    } else { message = "下書きを消去できませんでした。" }
                }, saveMine: { draft in
                    guard bridge.deviceID == entry.deviceID else { return }
                    comparison = nil
                    submit(draft, deviceID: entry.deviceID)
                }, keepDraft: { comparison = nil })
            }
        }
        .sheet(isPresented: $showingPending, onDismiss: presentDeferred) { pendingSheet }

    }

    private var pendingSheet: some View {
        NavigationStack {
            List {
                if let message {
                    Section { Text(verbatim: message).foregroundStyle(LAAColor.attention) }
                }
                Section("On this device") {
                    if ownPending.isEmpty && ownDrafts.isEmpty { Text(verbatim: "送信待ちと下書きはありません。") }
                    ForEach(ownPending) { item in
                        if let request = LAAOwnerTaskOutbox.request(item) {
                            VStack(alignment: .leading, spacing: LAASpacing.x2) {
                                Text(verbatim: request.draft.title)
                                Text(verbatim: sending.contains(request.taskID) ? "送信中" : request.conflict == true
                                     ? "送信できなかった下書きです。以前に保存された可能性を確認してください。"
                                     : "保存されたか確認できていません。")
                                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                                if request.originalDeviceID != nil {
                                    Text(verbatim: "別の接続から移した保留です。元の結果は不明です。")
                                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                                }
                                if let current = inspected[request.taskID] {
                                    Text(verbatim: "現在の題名: \(current.title)")
                                    Text(verbatim: "現在のメモ: \(current.memo)")
                                    Text(verbatim: "現在の期限: \(current.dueDate?.value ?? "なし")")
                                    Text(verbatim: "現在の状態: \(current.status.label)")
                                    if let conflict = LAAOwnerTaskConflict(draft: request.draft, current: current) {
                                        ForEach(conflict.changedFields) { field in
                                            Text(verbatim: "自分の変更（\(field.label)）: \(conflict.draftValue(for: field))")
                                        }
                                    } else {
                                        Text(verbatim: "自分の入力: \(request.draft.title)\n\(request.draft.memo)")
                                    }
                                }
                                HStack {
                                    if request.conflict == true {
                                        Button(String("下書きに戻す")) { pendingAction = PendingAction(kind: .restoreConflict, item: item) }
                                            .disabled(sending.contains(request.taskID))
                                    } else {
                                        Button(String("再試行")) { pendingAction = PendingAction(kind: .retry, item: item) }
                                            .disabled(bridge.status != .paired || sending.contains(request.taskID) || !LAAOwnerTaskOutbox.canRetry(request))
                                    }
                                    Button(LAAOwnerTaskCopy.inspectCurrent) { Task { await inspect(item) } }
                                        .disabled(bridge.status != .paired)
                                    Button(LAAOwnerTaskCopy.discard) { pendingAction = PendingAction(kind: .discard, item: item) }
                                        .disabled(sending.contains(request.taskID))
                                }
                            }
                        }
                    }
                    ForEach(ownDrafts, id: \.key) { entry in
                        if let deviceID = entry.deviceID, let taskID = entry.taskID,
                           case let .saved(draft) = LAAOwnerTaskLocalDrafts.read(drafts, deviceID: deviceID, taskID: taskID) {
                            Button {
                                if taskID == newID { newID = UUID(); newTitle = "" }
                                deferredEditor = Editor(draft: draft, deviceID: deviceID)
                                showingPending = false
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(verbatim: draft.title.isEmpty ? "題名なしの下書き" : draft.title)
                                    Text(verbatim: "端末内の下書き").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                                }
                            }
                        } else { Text(verbatim: "読み取れない下書きがあります。") }
                    }
                }
                if otherCount > 0 {
                    Section(LAAOwnerTaskCopy.otherDevices) {
                        Text(verbatim: "\(otherCount)件あります。内容は表示せず、選んだ記録だけを移すか破棄します。")
                        ForEach(Array(otherPending.enumerated()), id: \.element.id) { index, item in
                            HStack {
                                Text(verbatim: "送信待ち \(index + 1)")
                                Spacer()
                                Button(LAAOwnerTaskCopy.move) { pendingAction = PendingAction(kind: .move, item: item) }
                                    .disabled(bridge.deviceID == nil || LAAOwnerTaskOutbox.request(item).map { sending.contains($0.taskID) } != false)
                                Button(LAAOwnerTaskCopy.discard) { pendingAction = PendingAction(kind: .discard, item: item) }
                                    .disabled(LAAOwnerTaskOutbox.request(item).map { sending.contains($0.taskID) } != false)
                            }
                        }
                        ForEach(Array(otherDrafts.enumerated()), id: \.element.key) { index, entry in
                            HStack {
                                Text(verbatim: "下書き \(index + 1)")
                                Spacer()
                                Button(LAAOwnerTaskCopy.move) { pendingAction = PendingAction(kind: .moveDraft, entry: entry) }
                                    .disabled(bridge.deviceID == nil || entry.deviceID == nil || entry.taskID == nil)
                                Button(LAAOwnerTaskCopy.discard) { pendingAction = PendingAction(kind: .discardDraft, entry: entry) }
                                    .disabled(entry.deviceID == nil || entry.taskID == nil)
                            }
                        }
                    }
                }
            }
            .navigationTitle(LAAOwnerTaskCopy.pending)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { showingPending = false } } }
        }
        .accessibilityIdentifier("work.ownerTasks.pending.sheet")
        .confirmationDialog(LAAOwnerTaskCopy.confirmAction,
                            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
                            titleVisibility: .visible, presenting: pendingAction) { action in
            if action.kind == .retry, let item = action.item {
                Button(LAAOwnerTaskCopy.retryRequest) { Task { await send(item) } }
            } else if action.kind == .restoreConflict, let item = action.item {
                Button(String("下書きに戻す")) {
                    guard let latest = LAAOwnerTaskOutbox.entries(in: drafts).first(where: { $0.id == item.id }),
                          let request = LAAOwnerTaskOutbox.request(latest), request.conflict == true,
                          request.deviceID == bridge.deviceID, !sending.contains(request.taskID),
                          LAAOwnerTaskOutbox.restoreRejected(latest, in: drafts) else {
                        message = "下書きに戻せません。送信待ちを保持しています。"; return
                    }
                    message = "下書きに戻しました。現在のタスクを確認してから保存してください。"
                }
            } else if action.kind == .discard, let item = action.item {
                Button(LAAOwnerTaskCopy.discardRecord, role: .destructive) {
                    if !LAAOwnerTaskOutbox.finish(item, in: drafts) { message = "端末の記録を破棄できませんでした。" }
                }
            } else if action.kind == .move, let item = action.item {
                Button(LAAOwnerTaskCopy.moveToDevice) {
                    guard let deviceID = bridge.deviceID, LAAOwnerTaskOutbox.move(item, to: deviceID, in: drafts) else {
                        message = "移せません。同じタスクの下書きや送信待ちがないか確認してください。"; return
                    }
                }
            } else if action.kind == .moveDraft, let entry = action.entry {
                Button(LAAOwnerTaskCopy.moveDraft) {
                    guard let deviceID = bridge.deviceID, LAAOwnerTaskLocalDrafts.move(entry, to: deviceID, in: drafts) else {
                        message = "移せません。同じタスクの下書きや送信待ちがないか確認してください。"; return
                    }
                }
            } else if action.kind == .discardDraft, let entry = action.entry {
                Button(LAAOwnerTaskCopy.discardLocalDraft, role: .destructive) {
                    guard let deviceID = entry.deviceID, let taskID = entry.taskID,
                          case let .saved(draft) = LAAOwnerTaskLocalDrafts.read(drafts, deviceID: deviceID, taskID: taskID),
                          LAAOwnerTaskLocalDrafts.remove(draft, from: drafts, deviceID: deviceID) else {
                        message = "下書きを破棄できませんでした。"; return
                    }
                }
            }
            Button("キャンセル", role: .cancel) { }
        } message: { action in
            Text(verbatim: action.kind == .retry
                 ? "未反映なら、この再送で初めて保存されます。同じ識別子と内容を使います。"
                 : action.kind == .restoreConflict
                 ? "編集できる下書きに戻します。復元前に保存されていた可能性があるため、保存前に現在のタスクを確認してください。"
                 : action.kind == .move
                 ? "同じ識別子と鍵を引き継ぎ、結果不明のまま移します。自動送信はしません。"
                 : action.kind == .moveDraft
                 ? "この端末の下書きに移します。自動送信はしません。"
                 : action.kind == .discardDraft
                 ? "端末内の下書きだけを破棄します。"
                 : "Macへの操作の取消にはなりません。すでに保存された可能性があります。")
        }
    }

    private func saveInline() {
        guard let deviceID = bridge.deviceID else { return }
        let existing = LAAOwnerTaskLocalDrafts.read(drafts, deviceID: deviceID, taskID: newID)
        if newTitle.isEmpty, existing == .absent { return }
        guard let draft = inlineDraft(deviceID: deviceID) else { return }
        if !LAAOwnerTaskLocalDrafts.save(draft, in: drafts, deviceID: deviceID) {
            message = "下書きを端末に保存できません。入力を保持し、もう一度お試しください。"
        }
    }

    private func inlineDraft(deviceID: String) -> LAAOwnerTaskDraft? {
        guard let draft = LAAOwnerTaskLocalDrafts.updatingInlineTitle(newTitle, store: drafts,
                                                                     deviceID: deviceID, taskID: newID) else {
            message = "下書きを読み取れません。端末の記録を保持しています。"
            return nil
        }
        return draft
    }

    private func presentDeferred() {
        guard !showingPending, !editorVisible else { return }
        if let next = deferredEditor {
            deferredEditor = nil
            if next.deviceID == bridge.deviceID { editor = next }
        } else if let next = deferredComparison {
            deferredComparison = nil
            if next.deviceID == bridge.deviceID { comparison = next }
        }
    }

    private func create() {
        guard let deviceID = bridge.deviceID else { return }
        guard let draft = inlineDraft(deviceID: deviceID) else { return }
        if reserve(draft, deviceID: deviceID) {
            newID = UUID()
            newTitle = ""
        }
    }

    private func toggle(_ task: LAAOwnerTask) {
        guard let deviceID = bridge.deviceID, !blockedIDs.contains(task.id), !draftIDs.contains(task.id) else { return }
        var draft = LAAOwnerTaskDraft(task: task)
        draft.status = task.status == .done ? .todo : .done
        submit(draft, deviceID: deviceID)
    }

    private func open(_ task: LAAOwnerTask) {
        guard let deviceID = bridge.deviceID, !blockedIDs.contains(task.id) else { return }
        if case let .saved(draft) = LAAOwnerTaskLocalDrafts.read(drafts, deviceID: deviceID, taskID: task.id) {
            editor = Editor(draft: draft, deviceID: deviceID)
            return
        }
        Task {
            let observedLoadID = loadID
            do {
                let detail = try await readDetail(task.id)
                guard bridge.deviceID == deviceID else { return }
                guard loadID == observedLoadID else {
                    message = "タスクが更新されました。もう一度開いてください。"
                    return
                }
                rememberDetail(detail, deviceID: deviceID)
                editor = Editor(draft: LAAOwnerTaskDraft(task: detail), deviceID: deviceID)
            } catch {
                guard bridge.deviceID == deviceID else { return }
                if let previous = cache.details.first(where: { $0.id == task.id }) {
                    message = "前回取得した内容で編集します。保存時に更新の競合を確認します。"
                    editor = Editor(draft: LAAOwnerTaskDraft(task: previous), deviceID: deviceID)
                } else { message = "タスクの内容を取得できません。接続を確認してください。" }
            }
        }
    }

    private func submit(_ draft: LAAOwnerTaskDraft, deviceID: String) {
        if reserve(draft, deviceID: deviceID) {
            if draft.base == nil && newID == draft.id { newID = UUID(); newTitle = "" }
            editor = nil
        }
    }

    @discardableResult
    private func reserve(_ draft: LAAOwnerTaskDraft, deviceID: String) -> Bool {
        guard bridge.deviceID == deviceID, !blockedIDs.contains(draft.id) else { return false }
        do {
            try draft.validate()
            if let base = draft.base, LAAOwnerTaskConflict(draft: draft, current: base)?.changedFields.isEmpty == true {
                if case let .saved(previous) = LAAOwnerTaskLocalDrafts.read(drafts, deviceID: deviceID, taskID: draft.id) {
                    guard LAAOwnerTaskLocalDrafts.remove(previous, from: drafts, deviceID: deviceID) else { throw LAABridgeError.keychain }
                }
                return true
            }
            guard LAAOwnerTaskLocalDrafts.save(draft, in: drafts, deviceID: deviceID) else { throw LAABridgeError.keychain }
            let key = LAABridgeIdempotencyKey().value
            let request = try draft.base == nil
                ? LAAOwnerTaskRequest.create(draft, deviceID: deviceID, key: key)
                : LAAOwnerTaskRequest.update(draft, deviceID: deviceID, key: key)
            guard let item = LAAOwnerTaskOutbox.reserve(request, in: drafts) else { throw LAABridgeError.keychain }
            Task { await send(item) }
            return true
        } catch LAAOwnerTaskDraft.ValidationError.missingTitle {
            message = "題名を入力してください。"
        } catch LAAOwnerTaskDraft.ValidationError.invalidTitle {
            message = "題名は改行を含めず500文字以内で入力してください。"
        } catch LAAOwnerTaskDraft.ValidationError.invalidMemo {
            message = "メモは20,000文字以内で入力してください。"
        } catch LAAOwnerTaskDraft.ValidationError.invalidDueDate {
            message = "期限を確認してください。"
        } catch LAAOwnerTaskDraft.ValidationError.invalidLink {
            message = "関連リンクを確認してください。"
        } catch LAAOwnerTaskRequest.Error.bodyTooLarge {
            message = "入力の容量が大きすぎます。メモを短くしてください。"
        } catch {
            message = "下書きを保存できません。入力を保持し、内容と端末の空き容量を確認してください。"
        }
        return false
    }

    private func readDetail(_ id: UUID) async throws -> LAAOwnerTask {
        let response: LAABridgeResponse<LAAOwnerTaskWire> = try await bridge.request(
            method: "GET", path: "/v1/owner-tasks/\(id.uuidString.lowercased())")
        let result = try response.data.task(requiringDetail: true)
        guard result.id == id else { throw LAABridgeError.invalidResponse }
        return result
    }

    private func inspect(_ item: ComposerDraftStore.Submission) async {
        guard let request = LAAOwnerTaskOutbox.request(item), request.deviceID == bridge.deviceID else { return }
        do {
            let current = try await readDetail(request.taskID)
            guard bridge.deviceID == request.deviceID else { return }
            inspected[request.taskID] = current
        } catch { message = "現在のタスクを確認できません。保留は残しています。" }
    }

    private func send(_ item: ComposerDraftStore.Submission) async {
        guard let latest = LAAOwnerTaskOutbox.entries(in: drafts).first(where: { $0.id == item.id }),
              let request = LAAOwnerTaskOutbox.request(latest), request.deviceID == bridge.deviceID, LAAOwnerTaskOutbox.canRetry(request),
              !sending.contains(request.taskID), let key = LAABridgeIdempotencyKey(restoring: request.key) else { return }
        sending.insert(request.taskID)
        defer { sending.remove(request.taskID) }
        do {
            let response: LAABridgeResponse<LAAOwnerTaskWire> = try await bridge.request(
                method: request.method, path: request.path, jsonBody: request.body, idempotencyKey: key, ifMatch: request.ifMatch)
            let task = try response.data.task(requiringDetail: true)
            guard task.id == request.taskID, bridge.deviceID == request.deviceID else { throw LAABridgeError.invalidResponse }
            guard LAAOwnerTaskOutbox.finish(latest, in: drafts) else { throw LAABridgeError.keychain }
            record(task, deviceID: request.deviceID)
            if drafts.persistenceFailed { message = "タスクは保存されましたが、端末の控えを保存できません。" }
            else if !loaded || listIsStale { message = "一覧全体はまだ最新ではありません。接続後に読み直してください。" }
            else { message = nil }
        } catch let error as LAABridgeHTTPError where error.status == 412 && error.code == "owner_task_revision_mismatch" {
            guard bridge.deviceID == request.deviceID else { return }
            if request.originalDeviceID != nil {
                message = "元の接続で反映された可能性があります。送信待ちで現在の内容を確認してください。"
                await inspect(latest)
                return
            }
            guard LAAOwnerTaskOutbox.restoreRejected(latest, in: drafts) else {
                message = "競合した入力を端末に保持しています。送信待ちを確認してください。"; return
            }
            do {
                let current = try await readDetail(request.taskID)
                guard bridge.deviceID == request.deviceID, let conflict = LAAOwnerTaskConflict(draft: request.draft, current: current) else { return }
                record(current, deviceID: request.deviceID)
                let next = Comparison(value: conflict, deviceID: request.deviceID)
                if showingPending || editorVisible {
                    deferredComparison = next
                    showingPending = false
                    editor = nil
                } else { comparison = next }
            } catch { message = "競合した入力は下書きに残っています。接続後にもう一度開いてください。" }
        } catch let error as LAABridgeHTTPError where error.status == 400 {
            if request.originalDeviceID != nil {
                message = "今回の再送は拒否されました。元の結果は不明のため保留を残しています。"; return
            }
            if LAAOwnerTaskOutbox.restoreRejected(latest, in: drafts) {
                message = "入力が受け付けられませんでした。下書きを開いて修正してください。"
            } else { message = "入力を端末に保持しています。送信待ちを確認してください。" }
        } catch let error as LAABridgeHTTPError where error.status == 410 && error.code == "owner_task_operation_compacted" {
            if request.originalDeviceID != nil {
                message = "元の接続の結果は不明です。送信待ちで現在の内容を確認してください。"
                await inspect(latest)
                return
            }
            guard case let .object(details)? = error.details, case let .string(target)? = details["targetId"],
                  UUID(uuidString: target) == request.taskID, bridge.deviceID == request.deviceID else {
                message = "保存先を確認できません。送信待ちを保持しています。"; return
            }
            do {
                let current = try await readDetail(request.taskID)
                guard bridge.deviceID == request.deviceID, LAAOwnerTaskOutbox.finish(latest, in: drafts) else { throw LAABridgeError.keychain }
                record(current, deviceID: request.deviceID)
                if drafts.persistenceFailed { message = "タスクは確認できましたが、端末の控えを保存できません。" }
                else if !loaded || listIsStale { message = "一覧全体はまだ最新ではありません。接続後に読み直してください。" }
                else { message = nil }
            } catch { message = "保存先を確認できません。送信待ちを保持しています。" }
        } catch let error as LAABridgeHTTPError where error.status == 409 {
            if LAAOwnerTaskOutbox.markConflict(latest, in: drafts) {
                message = "送信できなかった下書きを残しました。送信待ちで現在の内容を確認してください。"
            } else {
                message = "送信待ちを保持しています。端末に状態を保存できませんでした。"
            }
        } catch {
            message = "保存されたか確認できません。送信待ちから確認・再送できます。"
        }
    }

    private func record(_ task: LAAOwnerTask, deviceID: String) {
        loadID = UUID()
        loading = false
        if let index = items.firstIndex(where: { $0.id == task.id }) {
            items[index] = task
        } else { items.append(task) }
        cache.items = items
        rememberDetail(task, deviceID: deviceID)
    }

    private func rememberDetail(_ task: LAAOwnerTask, deviceID: String) {
        if let index = cache.details.firstIndex(where: { $0.id == task.id }) {
            cache.details[index] = task
        } else { cache.details.append(task) }
        if !LAAOwnerTaskCacheStore.save(cache, in: drafts, deviceID: deviceID) {
            message = "端末に前回の内容を保存できません。"
        }
    }

    private func load() async {
        let deviceID = bridge.deviceID
        if currentDevice != deviceID {
            currentDevice = deviceID
            cache = deviceID.flatMap { LAAOwnerTaskCacheStore.read(drafts, deviceID: $0) } ?? LAAOwnerTaskCache()
            items = cache.items
            loaded = cache.observedAt != nil
            listIsStale = loaded
            newID = UUID()
            newTitle = ""
            if let deviceID, let entry = ownDrafts.first(where: { entry in
                guard let id = entry.taskID, case let .saved(draft) = LAAOwnerTaskLocalDrafts.read(drafts, deviceID: deviceID, taskID: id) else { return false }
                return draft.base == nil
            }), let id = entry.taskID,
               case let .saved(draft) = LAAOwnerTaskLocalDrafts.read(drafts, deviceID: deviceID, taskID: id) {
                newID = id; newTitle = draft.title
            }
            editor = nil; comparison = nil; deferredEditor = nil; deferredComparison = nil
            inspected = [:]
        }
        let id = UUID(); loadID = id
        guard bridge.status == .paired, let deviceID else {
            loading = false
            if loaded {
                listIsStale = true
                message = "Macに接続できないため、前回の内容を表示しています。"
            }
            return
        }
        loading = true
        defer { if loadID == id { loading = false } }
        do {
            var pages = LAAOwnerTaskPageAccumulator()
            repeat {
                var query = [URLQueryItem(name: "status", value: "all"), URLQueryItem(name: "limit", value: "200")]
                if let cursor = pages.nextCursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
                let path = LAAWorkPresentation.path("/v1/owner-tasks", query: query)
                let page: LAABridgeResponse<LAAOwnerTaskPage> = try await bridge.request(method: "GET", path: path)
                try pages.append(page.data)
            } while pages.nextCursor != nil
            let result = try pages.complete()
            guard loadID == id, bridge.deviceID == deviceID, !Task.isCancelled else { throw LAABridgeError.invalidResponse }
            items = result; loaded = true; listIsStale = false; cache.items = result; cache.observedAt = Date()
            if !LAAOwnerTaskCacheStore.save(cache, in: drafts, deviceID: deviceID) {
                message = "端末に前回の内容を保存できません。"
            } else { message = nil }
        } catch is CancellationError {
            return
        } catch {
            if loadID == id && bridge.deviceID == deviceID {
                listIsStale = true
                message = loaded ? "最新の一覧を取得できません。前回の内容を表示しています。" : "タスクを取得できません。Macとの接続を確認してください。"
            }
        }
    }
}
#endif
