#if LAA_BUILD
import SwiftUI

struct LAALinearTasksView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.laaDesktop) private var laaDesktop
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var taskRoute = LAALinearTaskRoute.shared
    @ObservedObject var drafts: ComposerDraftStore
    /// The Work hub's search on the phone; the Mac column keeps its own field.
    var query = ""
    var archivedOnly = false
    var createID = 0
    var onCreateConsumed: () -> Void = {}
    @State private var showingArchive = false
    @State private var items: [LAALinearTask] = []
    @State private var loading = false
    @State private var busy = false
    @State private var failure: String?
    @State private var loaded = false
    @State private var loadID = UUID()
    @State private var loadedDevice: String?
    @State private var editor: Editor?
    @State private var detail: LAALinearTask?
    @State private var deleting: LAALinearTask?
    @State private var completing: LAALinearTask?
    @State private var acknowledge = false
    @State private var desktopSelection: DesktopSelection?
    @State private var desktopSearch = ""
    @State private var hoveredID: String?
    @State private var reloadID = 0
    @AppStorage(LAALinearTaskFilter.storageKey) private var filterRaw = LAALinearTaskFilter.related.rawValue
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    private struct Editor: Identifiable {
        var id: String
        var task: LAALinearTask?
    }
    private enum DesktopSelection: Equatable {
        case inbox
        case browse
        case task(String)
    }
    private var journalKey: ComposerDraftKey {
        LAAWorkDrafts.key(deviceID: bridge.deviceID ?? "unpaired", target: "linear-owner-operation")
    }
    private var pending: ComposerDraftStore.Submission? { LAAWorkDrafts.pending(drafts, key: journalKey) }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var filter: LAALinearTaskFilter { LAALinearTaskFilter(rawValue: filterRaw) ?? .related }

    /// How a task comes back from the archive: the phone swipes the row, the
    /// Mac uses the row's menu, so the hint names the one that is there.
    private var archivedFooter: String {
        guard archivedOnly else { return "Linear · LAA担当" }
        return laaDesktop ? "アーカイブしたタスクです。" : "アーカイブしたタスクです。スワイプで戻せます。"
    }

    private var archivedDescription: String {
        if archivedOnly {
            return laaDesktop ? "行を右クリックすると戻せます。" : "アーカイブしたタスクは、スワイプで戻せます。"
        }
        return searching ? "短い番号（T12）か題名の一部で探せます。" : "＋から追加できます。"
    }

    private var rows: [LAALinearTask] {
        items.filter { archivedOnly ? $0.isArchived : $0.isOpen }
            .filter { archivedOnly || filter.matches($0) }
            .filter { archivedOnly || LAAWorkRef.matches(query, ref: $0.ref,
                                                         text: [$0.title, $0.description ?? "", $0.identifier]) }
            .sorted {
                let a = $0.priority == 0 ? 5 : $0.priority
                let b = $1.priority == 0 ? 5 : $1.priority
                if a != b { return a < b }
                if $0.dueDate != $1.dueDate { return ($0.dueDate ?? "9999") < ($1.dueDate ?? "9999") }
                return $0.updatedAt > $1.updatedAt
            }
    }

    var body: some View {
        Group {
            if laaDesktop && !archivedOnly { desktopBody } else { phoneBody }
        }
        .tint(LAAColor.link)
        .refreshable { await load() }
        .onChange(of: createID, initial: true) { _, value in
            guard value > 0, !archivedOnly, !busy, pending == nil else { return }
            editor = Editor(id: UUID().uuidString.lowercased(), task: nil)
            onCreateConsumed()
        }
        .navigationDestination(isPresented: Binding(get: { !laaDesktop && desktopSelection == .inbox }, set: { if !$0 { desktopSelection = nil } })) {
            LAAPersonalInboxEntry(drafts: drafts)
        }
        .navigationDestination(isPresented: Binding(get: { !laaDesktop && desktopSelection == .browse }, set: { if !$0 { desktopSelection = nil } })) {
            ScrollView { LAAPersonalTaskList(drafts: drafts, refreshID: 0).padding(20) }.navigationTitle(String("すべての課題"))
        }
        .sheet(isPresented: $showingArchive, onDismiss: { Task { await load() } }) {
            NavigationStack {
                LAALinearTasksView(drafts: drafts, archivedOnly: true)
                    .navigationTitle(Text(verbatim: "アーカイブ"))
                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                        Button { showingArchive = false } label: { Text(verbatim: LAACopy.close) }
                    } }
            }
            .environmentObject(bridge)
        }
        .task(id: "\(bridge.revision)-\(reloadID)-\(scenePhase == .active)") {
            await load()
            // Only a task a staff member is still working on changes quickly;
            // leave the list quiet otherwise. The task ends with the view, so
            // another Work section or the background stops the loop.
            guard !archivedOnly, scenePhase == .active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard !Task.isCancelled, items.contains(where: { $0.isOpen && $0.isAgentActive }) else { continue }
                await load(quiet: true)
            }
        }
        .sheet(item: $taskRoute.target) { target in
            NavigationStack {
                LAAPersonalTaskDetailView(id: target.id, drafts: drafts)
                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                        Button { taskRoute.target = nil } label: { Text(verbatim: LAACopy.close) }
                    } }
            }
            .environmentObject(bridge)
        }
        .sheet(item: $detail) { task in
            NavigationStack {
                LAAPersonalTaskDetailView(id: task.identifier.isEmpty ? task.id : "linear:\(task.identifier)", drafts: drafts,
                                          ref: task.ref, ownerTask: task, onCompleted: { id in
                    items.removeAll { $0.id == id }
                    detail = nil
                    Task { await load(quiet: true) }
                })
                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                        Button { detail = nil } label: { Text(verbatim: LAACopy.close) }
                    } }
            }
            .environmentObject(bridge)
        }
        .sheet(item: $editor) { value in
            LAALinearTaskEditor(id: value.id, task: value.task, busy: busy || pending != nil, failure: $failure) { body in
                submit(method: value.task == nil ? "POST" : "PATCH", id: value.id,
                       body: body, version: value.task?.updatedAt)
            }
            .environmentObject(bridge)
        }
        .confirmationDialog(Text(verbatim: "このタスクを削除しますか？"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button(role: .destructive) {
                if let task = deleting { submit(method: "POST", id: task.id, body: nil, version: task.updatedAt, action: "archive") }
                deleting = nil
            } label: { Text(verbatim: "削除") }
            Button(role: .cancel) { deleting = nil } label: { Text(verbatim: LAACopy.cancel) }
        } message: { Text(verbatim: "アーカイブに移り、あとで戻せます。") }
        .confirmationDialog(Text(verbatim: "完了にしますか？"), isPresented: Binding(get: { completing != nil },
            set: { if !$0 { completing = nil } }), titleVisibility: .visible) {
            Button {
                if let task = completing { complete(task) }
                completing = nil
            } label: { Text(verbatim: "完了") }
            Button(role: .cancel) { completing = nil } label: { Text(verbatim: LAACopy.cancel) }
        } message: {
            Text(verbatim: completing.map(LAATaskRunCopy.completionMessage(for:)) ?? "")
        }
        .confirmationDialog(Text(verbatim: "操作の控えを閉じますか？"), isPresented: $acknowledge) {
            Button { if let pending { _ = drafts.finishSubmission(pending.id, restoring: false) }; Task { await load() } }
            label: { Text(verbatim: "結果を確認して閉じる") }
        } message: { Text(verbatim: "Linearで反映結果を確認した場合だけ閉じてください。この操作は変更を取り消しません。") }
    }

    private var phoneBody: some View {
        List {
            if let failure {
                Section {
                    LAAWorkFailure(text: "タスクを取得できません") { Task { await load() } }
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
            if loading && !loaded { LAALoadingDots().listRowBackground(Color.clear) }
            Section {
                ForEach(rows) { task in
                    VStack(alignment: .leading, spacing: LAASpacing.x1) {
                        Button { editor = Editor(id: task.id, task: task) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x2) {
                                Text(verbatim: task.title).font(.system(size: 17)).foregroundStyle(LAAColor.text)
                                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                                LAAWorkRefLabel(ref: task.ref)
                            }.frame(maxWidth: .infinity, minHeight: LAASpacing.minimumTouchTarget, alignment: .leading)
                        }.buttonStyle(.borderless).disabled(archivedOnly)
                        taskMeta(task)
                    }
                    .contextMenu {
                        if archivedOnly {
                            // The Mac list has no swipe, so the row's menu is
                            // where a task comes back from the archive.
                            Button {
                                submit(method: "POST", id: task.id, body: nil, version: task.updatedAt, action: "restore")
                            } label: { Text(verbatim: "戻す") }
                                .disabled(busy || pending != nil)
                        } else {
                            Button { detail = task } label: { Text(verbatim: "詳細・コメント") }
                            if task.isOpen { Button { completing = task } label: { Text(verbatim: "完了") }
                                .disabled(busy || pending != nil || task.completionBlockedReason != nil) }
                        }
                    }
                    .disabled(busy || pending != nil)
                    .listRowBackground(LAAColor.surface)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if archivedOnly {
                            Button { submit(method: "POST", id: task.id, body: nil, version: task.updatedAt, action: "restore") } label: {
                                Label { Text(verbatim: "戻す") } icon: { Image(systemName: "arrow.uturn.backward") }
                            }.tint(LAAColor.link).disabled(busy || pending != nil)
                        } else {
                            // First on the trailing edge, so a swipe ends on 完了.
                            Button {
                                guard task.completionBlockedReason == nil else { return }
                                completing = task
                            } label: {
                                Label { Text(verbatim: "完了") } icon: { Image(systemName: "checkmark") }
                            }.tint(LAAColor.link)
                                .disabled(busy || pending != nil || task.completionBlockedReason != nil)
                            Button(role: .destructive) { deleting = task } label: {
                                Label { Text(verbatim: "削除") } icon: { Image(systemName: "trash") }
                            }.disabled(busy || pending != nil)
                        }
                    }
                }
            } header: {
                if archivedOnly {
                    Text(verbatim: "アーカイブ")
                } else {
                    filterMenu
                }
            } footer: {
                Text(verbatim: archivedFooter)
            }
            if loaded && rows.isEmpty && !loading && failure == nil {
                ContentUnavailableView {
                    Label { Text(verbatim: archivedOnly ? "アーカイブはありません" : searching ? "一致するタスクはありません" : "タスクはありません") }
                    icon: { Image(systemName: "checkmark.circle") }
                } description: {
                    Text(verbatim: archivedDescription)
                }.listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped).textCase(nil)
        .scrollContentBackground(.hidden)
    }

    /// The list's filter: a menu on its own heading, so the current range is
    /// what the rows below are called. The choice stays on the device.
    private var filterMenu: some View {
        Menu {
            Button(String("受信箱")) { desktopSelection = .inbox }
            Button(String("すべての課題")) { desktopSelection = .browse }
            Button(String("アーカイブを表示")) { showingArchive = true }.accessibilityIdentifier("work.linear.archive")
            Divider()
            ForEach(LAALinearTaskFilter.allCases) { option in
                Button { filterRaw = option.rawValue } label: {
                    if option == filter {
                        Label { Text(verbatim: option.title) } icon: { Image(systemName: "checkmark") }
                    } else {
                        Text(verbatim: option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: LAASpacing.x1) {
                Text(verbatim: "Tasks").font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: "ellipsis").frame(width: 44, height: 44)
            }
            .foregroundStyle(LAAColor.text)
        }
        .accessibilityLabel(Text(verbatim: "絞り込み、\(filter.title)"))
        .accessibilityIdentifier("work.tasks.filter")
    }

    /// 担当 · status · priority · due, one quiet line under the title. The
    /// status is the Bridge's own wording; only a task with a session links to
    /// it, and a missing run (an older Bridge) reads as 担当 社長 with no badge.
    private func taskMeta(_ task: LAALinearTask) -> some View {
        HStack(spacing: LAASpacing.x2) {
            Text(verbatim: task.assigneeDisplay).lineLimit(1)
                .foregroundStyle(LAAColor.secondaryText)
            if let status = task.runStatus { statusLabel(status, task: task) }
            if task.priority != 0 {
                Text(verbatim: LAALinearTask.priorityLabel(task.priority)).lineLimit(1)
                    .foregroundStyle(task.priority <= 2 ? LAAColor.attention : LAAColor.secondaryText)
            }
            if let due = task.dueDate {
                Label { Text(verbatim: due) } icon: { Image(systemName: "calendar") }.lineLimit(1)
                    .foregroundStyle(due <= LAALinearTask.today() ? LAAColor.attention : LAAColor.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .laaTextStyle(.secondary)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func statusLabel(_ status: LAATaskRunStatus, task: LAALinearTask) -> some View {
        let label = Text(verbatim: status.label).lineLimit(1)
            .fontWeight(status.tone == .quiet ? .regular : .semibold)
            .foregroundStyle(status.color)
            .padding(.horizontal, status.tone == .quiet ? 0 : LAASpacing.x2)
            .padding(.vertical, status.tone == .quiet ? 0 : 1)
            .background(status.tone == .quiet ? Color.clear : status.color.opacity(0.12), in: Capsule())
        if let session = status.sessionID {
            // The same handler the deep link uses. A Link would send the URL
            // through the system and back, which the hub has already missed.
            Button {
                guard let url = URL(string: "laa://work/sessions/\(session)") else { return }
                LAAWorkLinkRequest.shared.open(url)
            } label: { label }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isLink)
                .accessibilityLabel(Text(verbatim: "状態 \(status.label)。会話を開く"))
                .accessibilityIdentifier("work.task.status.\(task.id)")
        } else {
            label.accessibilityIdentifier("work.task.status.\(task.id)")
        }
    }

    private var desktopRows: [LAALinearTask] {
        rows.filter { LAAWorkRef.matches(desktopSearch, ref: $0.ref, text: [$0.title, $0.description ?? "", $0.identifier]) }
    }
    private var selectedTask: LAALinearTask? {
        guard case let .task(id) = desktopSelection else { return nil }
        return items.first { $0.id == id }
    }

    private var desktopBody: some View {
        LAAMacListDetail {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: LAASpacing.x3) {
                    filterMenu
                    LAASearchField(placeholder: "検索", text: $desktopSearch,
                                   identifier: "work.tasks.desktop.search", focus: $searchFocused)
                    if let failure {
                        Text(verbatim: failure).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                        Button { reloadID += 1 } label: { Text(verbatim: "読み直す").foregroundStyle(LAAColor.link) }.buttonStyle(.plain)
                    }
                    if let pending, !busy {
                        Text(verbatim: "保存結果を確認できませんでした。")
                            .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                        Button { startSend(pending, retry: true) } label: { Text(verbatim: "保存結果を確認") }
                            .disabled(busy || !LAAWorkDrafts.canRepeat(pending))
                    }
                    if loading && !loaded { LAALoadingDots() }
                }
                .padding(LAASpacing.x3)
                Rectangle().fill(LAAColor.separator).frame(height: 1)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(desktopRows) { task in desktopTaskRow(task) }
                        if loaded && desktopRows.isEmpty && !loading && failure == nil {
                            Text(verbatim: desktopSearch.isEmpty ? "タスクはありません。" : "一致するタスクはありません。")
                                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                                .padding(LAASpacing.x4)
                        }
                    }
                }
            }
            .background(LAAColor.background)
            .accessibilityIdentifier("work.desktop.tasks.list")
            .focusable()
            .focused($listFocused)
            .onAppear { listFocused = true }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.escape) { desktopSelection = nil; return .handled }
            .onKeyPress(.return) {
                if desktopSelection == nil, let first = desktopRows.first { desktopSelection = .task(first.id) }
                return .handled
            }
            // ⌘N, ⌘F and ⌘R come from the menu bar, which reads the commands
            // this column publishes: one implementation per key, as in the
            // window's other sections.
            .laaMacSectionCommands(LAAMacSectionCommands(
                newTitle: "新しいタスク",
                canCreate: !(busy || pending != nil),
                create: { editor = Editor(id: UUID().uuidString.lowercased(), task: nil) },
                canSearch: true,
                focusSearch: { searchFocused = true },
                canReload: true,
                reload: { reloadID += 1 }
            ))
        } detail: {
            desktopDetail
        }
        .accessibilityIdentifier("work.desktop.tasks")
    }

    private func desktopNavRow(_ title: String, icon: String, selection: DesktopSelection, identifier: String) -> some View {
        Button { desktopSelection = selection } label: {
            Label { Text(verbatim: title) } icon: { Image(systemName: icon) }
                .laaTextStyle(.body)
                .foregroundStyle(LAAColor.text)
                .padding(.horizontal, LAASpacing.x4)
                .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
                .background(desktopSelection == selection ? LAAColor.selectionFill : .clear,
                            in: RoundedRectangle(cornerRadius: LAARadius.card))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func desktopTaskRow(_ task: LAALinearTask) -> some View {
        HStack(alignment: .center, spacing: LAASpacing.x2) {
            Button { desktopSelection = .task(task.id) } label: {
                VStack(alignment: .leading, spacing: LAASpacing.x1) {
                    HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x2) {
                        Text(verbatim: task.title).font(.system(size: 17))
                            .foregroundStyle(LAAColor.text).lineLimit(2)
                            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        LAAWorkRefLabel(ref: task.ref)
                    }
                    HStack(spacing: LAASpacing.x2) {
                        Text(verbatim: task.assigneeDisplay)
                            .foregroundStyle(LAAColor.secondaryText)
                        if task.priority != 0 {
                            Text(verbatim: LAALinearTask.priorityLabel(task.priority))
                                .foregroundStyle(task.priority <= 2 ? LAAColor.attention : LAAColor.secondaryText)
                        }
                        if let due = task.dueDate {
                            Label { Text(verbatim: due) } icon: { Image(systemName: "calendar") }
                                .foregroundStyle(due <= LAALinearTask.today() ? LAAColor.attention : LAAColor.secondaryText)
                        }
                    }.laaTextStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selectedTask?.id == task.id ? .isSelected : [])
            .accessibilityIdentifier("work.task.\(task.id)")
            // Outside the row's select button, so a click opens the session
            // rather than selecting the row.
            if let status = task.runStatus { statusLabel(status, task: task) }
        }
        .padding(.horizontal, LAASpacing.x4)
        .background(rowBackground(task.id), in: RoundedRectangle(cornerRadius: LAARadius.card))
        .onHover { hoveredID = $0 ? task.id : (hoveredID == task.id ? nil : hoveredID) }
        .contextMenu {
            Button { desktopSelection = .task(task.id) } label: { Text(verbatim: "開く") }
            Button { editor = Editor(id: task.id, task: task) } label: { Text(verbatim: "編集") }
            Button { completing = task } label: { Text(verbatim: "完了") }
                .disabled(busy || pending != nil || !task.isOpen || task.completionBlockedReason != nil)
            Button(role: .destructive) { deleting = task } label: { Text(verbatim: "アーカイブ") }
        }
        .disabled(busy || pending != nil)
    }

    @ViewBuilder private var desktopDetail: some View {
        if let selectedTask {
            NavigationStack {
                LAAPersonalTaskDetailView(id: selectedTask.identifier.isEmpty ? selectedTask.id : "linear:\(selectedTask.identifier)", drafts: drafts,
                                          ref: selectedTask.ref, ownerTask: selectedTask, onCompleted: { id in
                    items.removeAll { $0.id == id }
                    Task { await load(quiet: true) }
                })
                    .id(selectedTask.id)
            }
        } else if desktopSelection == .inbox {
            NavigationStack { LAAPersonalInboxEntry(drafts: drafts) }
        } else if desktopSelection == .browse {
            NavigationStack {
                ScrollView {
                    LAAPersonalTaskList(drafts: drafts, refreshID: 0)
                        .padding(LAASpacing.horizontal)
                }
                .background(LAAColor.background)
                .navigationTitle(Text(verbatim: "課題を探す"))
            }
        } else {
            LAAMacEmptyDetail(symbol: "checklist", title: "タスクを選んでください。",
                              message: "左の一覧からタスクを選ぶと、ここに詳細とコメントを表示します。")
        }
    }

    private func rowBackground(_ id: String) -> Color {
        if selectedTask?.id == id { return LAAColor.selectionFill }
        if hoveredID == id { return LAAColor.subtleSurface }
        return .clear
    }

    private func move(_ delta: Int) {
        let ids = desktopRows.map(\.id)
        let current = selectedTask.flatMap { ids.firstIndex(of: $0.id) }
        if let next = LAAWorkDesktopList.next(current: current, count: ids.count, delta: delta) {
            desktopSelection = .task(ids[next])
        }
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
        if mutation.action == "complete" {
            switch await LAALinearTaskCompletion.send(item, bridge: bridge, drafts: drafts, device: device) {
            case .completed:
                items.removeAll { $0.id.lowercased() == mutation.id.lowercased() }
                detail = nil
                await load(quiet: true)
            case .failed(let message):
                failure = message
                await load(quiet: true)
            case .unknown:
                failure = "保存結果を確認できません。接続を確認して、もう一度お試しください。"
            }
            return
        }
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
            let scopeMessage = mutation.action == nil
                ? LAALinearTaskCreate.refusalMessage(status: error.status, code: error.code, body: mutation.body) : nil
            if retry {
                failure = scopeMessage ?? archivedMessage ?? "前の操作の結果は未確認です。Linearで状態を確認してください。"
            } else if !drafts.finishSubmission(item.id, restoring: false) {
                failure = "端末の控えを更新できません。入力を保持しています。"
            } else {
                failure = scopeMessage ?? archivedMessage ?? (error.status == 412 ? "Linearで更新されています。編集画面を閉じて読み直してください。" : "操作が受け付けられませんでした。入力と接続を確認してください。")
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

    /// Completing from a row or the detail: one confirmation, then the same
    /// protected request path as every other task write.
    private func complete(_ task: LAALinearTask) {
        guard bridge.status == .paired, !busy, pending == nil else { return }
        if let reason = task.completionBlockedReason { failure = reason; return }
        busy = true
        Task {
            defer { busy = false }
            switch await LAALinearTaskCompletion.complete(task, bridge: bridge, drafts: drafts, key: journalKey) {
            case .completed:
                items.removeAll { $0.id == task.id }
                detail = nil
                await load(quiet: true)
            case .failed(let message):
                failure = message
                await load(quiet: true)
            case .unknown:
                failure = "保存結果を確認できません。接続を確認して、もう一度お試しください。"
            }
        }
    }

    private func load(quiet: Bool = false) async {
        let device = bridge.deviceID
        if loadedDevice != device {
            items = []; loaded = false; loadedDevice = device; editor = nil
            if let device, let snapshot: LAALinearTaskCache.OwnerSnapshot = LAALinearTaskCache.read(device: device, scope: archivedOnly ? "archive" : "owner") {
                items = snapshot.items; loaded = true
            }
        }
        guard bridge.status == .paired else { return }
        let epoch = UUID(); loadID = epoch
        if !quiet { loading = true }
        defer { if !quiet, loadID == epoch { loading = false } }
        do {
            let page: LAAWorkPage<LAALinearTask> = try await bridge.read(archivedOnly ? "/v1/linear-owner-tasks?archived=only" : "/v1/linear-owner-tasks")
            guard loadID == epoch, device == bridge.deviceID, !Task.isCancelled else { return }
            guard page.nextCursor == nil else { throw LAABridgeError.invalidResponse }
            items = page.items; loaded = true; failure = nil
            if laaDesktop, !archivedOnly, desktopSelection == nil, let first = desktopRows.first { desktopSelection = .task(first.id) }
            if let device { LAALinearTaskCache.save(LAALinearTaskCache.OwnerSnapshot(items: items), device: device, scope: archivedOnly ? "archive" : "owner") }
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
            guard loadID == epoch, device == bridge.deviceID, !quiet else { return }
            failure = loaded ? "最新のタスクを取得できません。前回の内容を表示しています。" : "Linearのタスクを取得できません。接続を確認して読み直してください。"
        }
    }
}

struct LAALinearTaskEditor: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.dismiss) private var dismiss
    let id: String
    let task: LAALinearTask?
    let busy: Bool
    /// Live, so a refusal from the Bridge reaches the open form.
    @Binding var failure: String?
    let save: (Data) -> Void
    @State private var title: String
    @State private var detail: String
    @State private var priority: Int
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    /// "" is 社長; anything else is a `LAAStaff` raw value.
    @State private var assignee: String
    @State private var profile: String
    @State private var options: LAAWorkSessionOptions?
    @State private var optionsFailed = false
    @State private var localFailure: String?

    init(id: String, task: LAALinearTask?, busy: Bool, failure: Binding<String?>, save: @escaping (Data) -> Void) {
        self.id = id; self.task = task; self.busy = busy; self._failure = failure; self.save = save
        _title = State(initialValue: task?.title ?? "")
        _detail = State(initialValue: task?.description ?? "")
        _priority = State(initialValue: task?.priority ?? 0)
        _hasDueDate = State(initialValue: task?.dueDate != nil)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        _dueDate = State(initialValue: task?.dueDate.flatMap { formatter.date(from: $0) } ?? Date())
        // A new task goes to Monet until the owner chooses someone else, as
        // the create form promises.
        _assignee = State(initialValue: task == nil ? LAAStaff.monet.rawValue : "")
        _profile = State(initialValue: "")
    }

    #if DEBUG
    /// Snapshots show the create form with its model rows already resolved.
    init(id: String, task: LAALinearTask?, busy: Bool, failure: Binding<String?>, options: LAAWorkSessionOptions?,
         save: @escaping (Data) -> Void) {
        self.init(id: id, task: task, busy: busy, failure: failure, save: save)
        _options = State(initialValue: options)
        _profile = State(initialValue: options?.defaultProfile ?? options?.profiles.first?.id ?? "")
    }
    #endif

    private var staff: String? { assignee.isEmpty ? nil : assignee }
    private var selectedProfile: LAAWorkSessionOptions.Profile? { options?.profiles.first { $0.id == profile } }
    private var titleText: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        guard !busy, !titleText.isEmpty, titleText.utf16.count <= 200, detail.utf16.count <= 20000 else { return false }
        guard task == nil, staff != nil else { return true }
        // A staff task is refused without one of the Bridge's profiles.
        return selectedProfile != nil
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
                    if let task {
                        LabeledContent { Text(verbatim: task.assigneeDisplay) } label: { Text(verbatim: "担当") }
                        if let model = task.run?.profileLabel ?? task.run?.profile {
                            LabeledContent { Text(verbatim: model) } label: { Text(verbatim: "モデル") }
                        }
                        Text(verbatim: "担当とモデルは作成後に変えません。")
                            .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    } else {
                        Picker(selection: $assignee) {
                            Text(verbatim: "社長").tag("")
                            ForEach(LAATaskStaff.assignable, id: \.rawValue) { item in
                                Text(verbatim: item.name).tag(item.rawValue)
                            }
                        } label: { Text(verbatim: "担当") }
                        .accessibilityIdentifier("work.linear.assignee")
                        if staff != nil { modelPicker }
                        if let footer = LAALinearTaskCreate.footer(staff: staff) {
                            Text(verbatim: footer)
                                .laaTextStyle(.secondary)
                                .foregroundStyle(LAAColor.secondaryText)
                                .accessibilityIdentifier("work.linear.createFooter")
                        }
                    }
                }
                Section {
                    Toggle(isOn: $hasDueDate) { Text(verbatim: "期限") }
                    if hasDueDate { DatePicker(selection: $dueDate, displayedComponents: .date) { Text(verbatim: "期限日") } }
                    Picker(selection: $priority) {
                        ForEach(0...4, id: \.self) { value in Text(verbatim: LAALinearTask.priorityLabel(value)).tag(value) }
                    } label: { Text(verbatim: "優先度") }
                }
                if let message = localFailure ?? failure { Text(verbatim: message).foregroundStyle(LAAColor.attention) }
            }
            .disabled(busy)
            .navigationTitle(Text(verbatim: task == nil ? "タスクを追加" : "タスクを編集"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Text(verbatim: LAACopy.close) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { commit() } label: { Text(verbatim: LAACopy.save) }
                        .disabled(!canSave)
                        .accessibilityIdentifier("work.linear.save")
                }
            }
        }
        .interactiveDismissDisabled(busy)
        .task(id: bridge.revision) { await loadOptions() }
    }

    @ViewBuilder private var modelPicker: some View {
        if let options, !options.profiles.isEmpty {
            Picker(selection: $profile) {
                ForEach(options.profiles) { item in
                    Text(verbatim: LAAWorkSessionStyle.profileLabel(item)).tag(item.id)
                }
            } label: { Text(verbatim: "モデル・推論") }
            .accessibilityIdentifier("work.linear.model")
        } else if optionsFailed {
            Button { Task { await loadOptions(force: true) } } label: { Text(verbatim: "モデルを取得できません。読み直す") }
        } else {
            Text(verbatim: "モデルを読み込み中").foregroundStyle(LAAColor.secondaryText)
        }
    }

    private func loadOptions(force: Bool = false) async {
        guard force || options == nil else { return }
        optionsFailed = false
        if let loaded: LAAWorkSessionOptions = try? await bridge.read("/v1/session-options") {
            options = loaded
            if profile.isEmpty || !loaded.profiles.contains(where: { $0.id == profile }) {
                profile = loaded.defaultProfile.flatMap { id in loaded.profiles.contains { $0.id == id } ? id : nil }
                    ?? loaded.profiles.first?.id ?? ""
            }
        } else {
            optionsFailed = true
        }
    }

    private func commit() {
        localFailure = nil
        if task == nil {
            guard let data = LAALinearTaskCreate.body(id: id, title: titleText, description: detail,
                priority: priority, dueDate: hasDueDate ? LAALinearTask.today(dueDate) : nil,
                staff: staff, profile: staff == nil ? nil : profile) else {
                localFailure = "モデルを選んでください。"
                return
            }
            save(data)
        } else {
            let body: [String: Any] = ["title": titleText, "description": detail, "priority": priority,
                "dueDate": hasDueDate ? LAALinearTask.today(dueDate) as Any : NSNull()]
            if let data = try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys) { save(data) }
        }
    }
}
#endif
