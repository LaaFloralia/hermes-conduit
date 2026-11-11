#if LAA_BUILD
import SwiftUI

/// Work's task list (owner, 2026-11-11: 「タスクがめちゃくちゃ見にくい」).
/// Sections by genre (or due date, assignee, priority) that fold, a circle
/// that completes a task in one tap, quick filters as glass chips, and rows
/// that show only what is set. The sections are worked out once per change
/// of their inputs (`LAATaskBoard`), not on every redraw, and a refresh that
/// brings the same tasks changes nothing on screen.
struct LAALinearTasksView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.laaDesktop) private var laaDesktop
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var taskRoute = LAALinearTaskRoute.shared
    @ObservedObject var drafts: ComposerDraftStore
    /// The Work hub's search on the phone; the Mac column keeps its own field.
    var query = ""
    var createID = 0
    var onCreateConsumed: () -> Void = {}
    /// The list's pulldown can show the archive in place of the open tasks;
    /// it is not kept, so the tab always opens on the open tasks.
    @State private var archivedOnly = false
    @State private var items: [LAALinearTask] = []
    @State private var board = LAATaskBoard()
    @State private var quick: LAATaskQuickFilter = .all
    @State private var loading = false
    @State private var busy = false
    @State private var failure: String?
    /// A short note that clears itself (a running task's refused circle).
    @State private var notice: String?
    @State private var loaded = false
    @State private var loadID = UUID()
    @State private var loadedDevice: String?
    @State private var loadedArchive = false
    @State private var editor: Editor?
    @State private var detail: LAALinearTask?
    @State private var deleting: LAALinearTask?
    @State private var completing: LAALinearTask?
    @State private var acknowledge = false
    @State private var desktopSelection: DesktopSelection?
    @State private var desktopSearch = ""
    @State private var reloadID = 0
    /// The row whose circle was just ticked. It completes after a moment, so
    /// a second tap takes it back, as in Things.
    @State private var checkedID: String?
    @State private var hold: Task<Void, Never>?
    @AppStorage(LAALinearTaskFilter.storageKey) private var filterRaw = LAALinearTaskFilter.related.rawValue
    @AppStorage(LAATaskGrouping.storageKey) private var groupingRaw = LAATaskGrouping.genre.rawValue
    @AppStorage(LAATaskFolding.storageKey) private var foldedRaw = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    private struct Editor: Identifiable {
        var id: String
        var task: LAALinearTask?
    }
    private enum DesktopSelection: Equatable {
        case task(String)
    }
    /// How long a ticked circle waits before the completion is sent.
    static let completionHold: Duration = .milliseconds(1400)

    private var journalKey: ComposerDraftKey {
        LAAWorkDrafts.key(deviceID: bridge.deviceID ?? "unpaired", target: "linear-owner-operation")
    }
    private var pending: ComposerDraftStore.Submission? { LAAWorkDrafts.pending(drafts, key: journalKey) }
    private var activeQuery: String { laaDesktop ? desktopSearch : query }
    private var searching: Bool { !activeQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var filter: LAALinearTaskFilter { LAALinearTaskFilter(rawValue: filterRaw) ?? .related }
    private var grouping: LAATaskGrouping { LAATaskGrouping(rawValue: groupingRaw) ?? .genre }
    private var groupingBinding: Binding<LAATaskGrouping> {
        Binding(get: { grouping }, set: { value in
            if reduceMotion { groupingRaw = value.rawValue }
            else { withAnimation(.snappy(duration: 0.25)) { groupingRaw = value.rawValue } }
        })
    }
    private var folded: Set<String> { LAATaskFolding.decode(foldedRaw) }
    private var locked: Bool { busy || pending != nil }

    private var boardInputs: LAATaskBoard.Inputs {
        LAATaskBoard.Inputs(items: items, archived: archivedOnly, filter: filter, quick: archivedOnly ? .all : quick,
                            query: activeQuery, grouping: grouping, day: LAADateText.string(Date(), .dateFile))
    }

    /// The rows in screen order, without the folded sections: what ↑↓ walk.
    private var visibleIDs: [String] {
        let closed = folded
        return board.sections.filter { !closed.contains($0.id) }.flatMap { $0.rows.map(\.id) }
    }

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
        if quick != .all { return "「\(quick.title)」に当てはまるタスクはありません。" }
        return searching ? "短い番号（T12）か題名の一部で探せます。" : "＋から追加できます。"
    }

    private var emptyTitle: String {
        archivedOnly ? "アーカイブはありません" : searching || quick != .all ? "一致するタスクはありません" : "タスクはありません"
    }

    var body: some View {
        Group {
            if laaDesktop { desktopBody } else { phoneBody }
        }
        .tint(LAAColor.link)
        .refreshable { await load() }
        .onChange(of: boardInputs, initial: true) { _, inputs in
            board = LAATaskBoard(inputs)
            if laaDesktop, !archivedOnly, desktopSelection == nil, let first = visibleIDs.first {
                desktopSelection = .task(first)
            }
        }
        .onChange(of: createID, initial: true) { _, value in
            guard value > 0, !busy, pending == nil else { return }
            // A new task belongs to the open list, so creating leaves the archive.
            archivedOnly = false
            editor = Editor(id: UUID().uuidString.lowercased(), task: nil)
            onCreateConsumed()
        }
        .task(id: "\(bridge.revision)-\(reloadID)-\(scenePhase == .active)-\(archivedOnly)") {
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
        .task(id: notice) {
            guard notice != nil else { return }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            notice = nil
        }
        .sensoryFeedback(.success, trigger: checkedID) { _, new in new != nil }
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
        .onDisappear { commitHeldCompletion() }
    }

    // MARK: Shared pieces

    private var controls: some View {
        LAATaskControls(grouping: groupingBinding, quick: $quick, counts: board.counts, showsQuick: !archivedOnly,
                        allFolded: !board.sections.isEmpty && board.sections.allSatisfy { folded.contains($0.id) },
                        foldAll: { fold in setFolded(fold ? Set(board.sections.map(\.id)) : []) }) {
            filterMenu
        }
    }

    /// The list's one pulldown, labelled with the range the rows below are in.
    /// Every choice changes this list in place: the three ranges (kept on the
    /// device) and the archive (not kept).
    private var filterMenu: some View {
        LAAWorkListPicker(title: archivedOnly ? LAACopy.WorkTab.archived : filter.title,
                          identifier: "work.tasks.filter") {
            ForEach(LAALinearTaskFilter.allCases) { option in
                LAAWorkPickerItem(title: option.title, selected: !archivedOnly && option == filter,
                                  identifier: "work.tasks.filter.\(option.rawValue)") {
                    filterRaw = option.rawValue
                    archivedOnly = false
                }
            }
            Divider()
            LAAWorkPickerItem(title: LAACopy.WorkTab.archived, selected: archivedOnly,
                              identifier: "work.linear.archive") {
                archivedOnly = true
                if laaDesktop { desktopSelection = nil }
            }
        }
    }

    private func header(_ section: LAATaskSection) -> some View {
        LAATaskSectionHeader(section: section, folded: folded.contains(section.id)) { toggleFold(section.id) }
    }

    private func toggleFold(_ id: String) {
        var value = folded
        if value.contains(id) { value.remove(id) } else { value.insert(id) }
        setFolded(value, keeping: board.sections.map(\.id))
    }

    /// Other groupings' folds are kept; only this grouping's are replaced.
    private func setFolded(_ value: Set<String>, keeping current: [String]? = nil) {
        let mine = Set(current ?? board.sections.map(\.id))
        let others = folded.subtracting(mine)
        let next = LAATaskFolding.encode(others.union(value))
        if reduceMotion { foldedRaw = next } else { withAnimation(.snappy(duration: 0.25)) { foldedRaw = next } }
    }

    private func rowView(_ row: LAATaskRowModel, selected: Bool = false) -> some View {
        LAATaskRow(row: row, showsGenre: grouping != .genre, checked: checkedID == row.id, selected: selected,
                   desktop: laaDesktop, toggle: { toggleCheck(row) }, open: { open(row) })
            .equatable()
    }

    private func open(_ row: LAATaskRowModel) {
        if laaDesktop { desktopSelection = .task(row.id); listFocused = true }
        else if !row.task.isArchived { detail = row.task }
    }

    @ViewBuilder private var messages: some View {
        if let failure {
            HStack(alignment: .top, spacing: LAASpacing.x2) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LAAColor.attention)
                Text(verbatim: failure).laaTextStyle(.secondary).foregroundStyle(LAAColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: LAASpacing.x2)
                Button { reloadID += 1 } label: {
                    Text(verbatim: LAACopy.WorkTab.retry).laaTextStyle(.secondary).foregroundStyle(LAAColor.link)
                }.buttonStyle(.borderless).frame(minHeight: 44)
            }
            .accessibilityIdentifier("work.tasks.failure")
        }
        if let notice {
            Label { Text(verbatim: notice) } icon: { Image(systemName: "info.circle") }
                .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                .accessibilityIdentifier("work.tasks.notice")
        }
    }

    @ViewBuilder private var pendingNotice: some View {
        if let pending, !busy {
            VStack(alignment: .leading, spacing: LAASpacing.x2) {
                Text(verbatim: "保存結果を確認できませんでした。").foregroundStyle(LAAColor.attention)
                HStack(spacing: LAASpacing.x4) {
                    Button { startSend(pending, retry: true) } label: { Text(verbatim: "保存結果を確認") }
                        .disabled(busy || !LAAWorkDrafts.canRepeat(pending))
                    Button { acknowledge = true } label: { Text(verbatim: "Linearで結果を確認済み") }
                        .disabled(busy)
                }
                .buttonStyle(.borderless)
            }
            .laaTextStyle(.secondary)
        }
    }

    // MARK: Phone

    private var phoneBody: some View {
        List {
            Section {
                controls
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: LAASpacing.x1, trailing: 4))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if failure != nil || notice != nil || (pending != nil && !busy) {
                Section {
                    messages
                    pendingNotice
                }
                .listRowBackground(LAAColor.surface)
            }
            if loading && !loaded { LAALoadingDots().listRowBackground(Color.clear) }
            ForEach(board.sections) { section in
                Section {
                    if !folded.contains(section.id) {
                        ForEach(section.rows) { row in phoneRow(row) }
                    }
                } header: {
                    header(section)
                }
            }
            if loaded && board.sections.isEmpty && !loading && failure == nil {
                ContentUnavailableView {
                    Label { Text(verbatim: emptyTitle) } icon: { Image(systemName: "checkmark.circle") }
                } description: {
                    Text(verbatim: archivedDescription)
                }.listRowBackground(Color.clear)
            }
            Section {} footer: {
                Text(verbatim: archivedFooter).frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .listStyle(.insetGrouped).textCase(nil)
        .listSectionSpacing(.compact)
        // The controls sit right under the hub's search, not a section gap below.
        .contentMargins(.top, LAASpacing.x1, for: .scrollContent)
        .environment(\.defaultMinListRowHeight, 44)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("work.tasks.list")
    }

    private func phoneRow(_ row: LAATaskRowModel) -> some View {
        let task = row.task
        return rowView(row)
            .listRowInsets(EdgeInsets(top: 0, leading: LAASpacing.x4, bottom: 0, trailing: LAASpacing.x4))
            .listRowBackground(LAAColor.surface)
            // The separator starts under the number, not under the circle.
            .alignmentGuide(.listRowSeparatorLeading) { dimensions in dimensions[.leading] + 34 }
            .contextMenu {
                if archivedOnly {
                    Button {
                        submit(method: "POST", id: task.id, body: nil, version: task.updatedAt, action: "restore")
                    } label: { Label { Text(verbatim: "戻す") } icon: { Image(systemName: "arrow.uturn.backward") } }
                        .disabled(locked)
                } else {
                    Button { detail = task } label: { Label { Text(verbatim: "詳細・コメント") } icon: { Image(systemName: "doc.text") } }
                    Button { editor = Editor(id: task.id, task: task) } label: {
                        Label { Text(verbatim: "編集") } icon: { Image(systemName: "pencil") }
                    }.disabled(locked)
                    if task.isOpen {
                        Button { completing = task } label: {
                            Label { Text(verbatim: "完了") } icon: { Image(systemName: "checkmark.circle") }
                        }.disabled(locked || task.completionBlockedReason != nil)
                    }
                    Divider()
                    Button(role: .destructive) { deleting = task } label: {
                        Label { Text(verbatim: "削除") } icon: { Image(systemName: "trash") }
                    }.disabled(locked)
                }
            }
            .disabled(locked && checkedID != row.id)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if archivedOnly {
                    Button { submit(method: "POST", id: task.id, body: nil, version: task.updatedAt, action: "restore") } label: {
                        Label { Text(verbatim: "戻す") } icon: { Image(systemName: "arrow.uturn.backward") }
                    }.tint(LAAColor.link).disabled(locked)
                } else {
                    // First on the trailing edge, so a swipe ends on 完了.
                    Button {
                        guard task.completionBlockedReason == nil else { return }
                        completing = task
                    } label: {
                        Label { Text(verbatim: "完了") } icon: { Image(systemName: "checkmark") }
                    }.tint(LAAColor.link)
                        .disabled(locked || task.completionBlockedReason != nil)
                    Button(role: .destructive) { deleting = task } label: {
                        Label { Text(verbatim: "削除") } icon: { Image(systemName: "trash") }
                    }.disabled(locked)
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if !archivedOnly {
                    Button { editor = Editor(id: task.id, task: task) } label: {
                        Label { Text(verbatim: "編集") } icon: { Image(systemName: "pencil") }
                    }.tint(LAAColor.decorativeTan).disabled(locked)
                }
            }
    }

    // MARK: Mac

    private var selectedTask: LAALinearTask? {
        guard case let .task(id) = desktopSelection else { return nil }
        return items.first { $0.id == id }
    }

    private var desktopBody: some View {
        LAAMacListDetail(listWidth: 460) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: LAASpacing.x2) {
                    controls
                    LAASearchField(placeholder: "番号・題名で検索", text: $desktopSearch,
                                   identifier: "work.tasks.desktop.search", focus: $searchFocused)
                    messages
                    pendingNotice
                    if loading && !loaded { LAALoadingDots() }
                }
                .padding(.horizontal, LAASpacing.x4)
                .padding(.top, LAASpacing.x2)
                .padding(.bottom, LAASpacing.x3)
                Rectangle().fill(LAAColor.separator).frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(board.sections) { section in
                                Section {
                                    if !folded.contains(section.id) {
                                        ForEach(section.rows) { row in desktopRow(row).id(row.id) }
                                    }
                                } header: {
                                    header(section)
                                        .padding(.horizontal, LAASpacing.x3)
                                        .padding(.top, LAASpacing.x2)
                                        .background(LAAColor.background)
                                }
                            }
                            if loaded && board.sections.isEmpty && !loading && failure == nil {
                                VStack(alignment: .leading, spacing: LAASpacing.x1) {
                                    Text(verbatim: emptyTitle).fontWeight(.semibold)
                                    Text(verbatim: archivedDescription).laaTextStyle(.secondary)
                                        .foregroundStyle(LAAColor.secondaryText)
                                }
                                .padding(LAASpacing.x4)
                            }
                        }
                        .padding(.horizontal, LAASpacing.x2)
                        .padding(.bottom, LAASpacing.x6)
                    }
                    .onChange(of: desktopSelection) { _, value in
                        guard case let .task(id)? = value else { return }
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { proxy.scrollTo(id) }
                    }
                }
            }
            .background(LAAColor.background)
            .accessibilityIdentifier("work.desktop.tasks.list")
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onAppear { listFocused = true }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.escape) { desktopSelection = nil; return .handled }
            // No key completes a task: the list takes focus with the first row
            // selected, so a stray space would tick it. Completion is a click.
            .onKeyPress(.return) {
                if desktopSelection == nil, let first = visibleIDs.first { desktopSelection = .task(first) }
                return .handled
            }
            // ⌘N, ⌘F and ⌘R come from the menu bar, which reads the commands
            // this column publishes.
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

    private func desktopRow(_ row: LAATaskRowModel) -> some View {
        let task = row.task
        return rowView(row, selected: selectedTask?.id == row.id)
            .contextMenu {
                Button { desktopSelection = .task(task.id) } label: { Text(verbatim: "開く") }
                if task.isArchived {
                    Button {
                        submit(method: "POST", id: task.id, body: nil, version: task.updatedAt, action: "restore")
                    } label: { Text(verbatim: "戻す") }
                } else {
                    Button { editor = Editor(id: task.id, task: task) } label: { Text(verbatim: "編集") }
                    Button { completing = task } label: { Text(verbatim: "完了") }
                        .disabled(locked || !task.isOpen || task.completionBlockedReason != nil)
                    Divider()
                    Button(role: .destructive) { deleting = task } label: { Text(verbatim: "アーカイブ") }
                }
            }
            .disabled(locked && checkedID != row.id)
            .help(Text(verbatim: task.title))
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
        } else {
            LAAMacEmptyDetail(symbol: "checklist", title: "タスクを選んでください。",
                              message: "左の一覧からタスクを選ぶと、ここに詳細とコメントを表示します。")
        }
    }

    private func move(_ delta: Int) {
        let ids = visibleIDs
        let current = selectedTask.flatMap { ids.firstIndex(of: $0.id) }
        if let next = LAAWorkDesktopList.next(current: current, count: ids.count, delta: delta) {
            desktopSelection = .task(ids[next])
        }
    }

    // MARK: Completion from the circle

    /// One tap ticks the circle; the completion leaves after a moment, and a
    /// second tap in that moment takes it back. A task whose session would be
    /// archived still asks first, and a running one says why it cannot.
    private func toggleCheck(_ row: LAATaskRowModel) {
        if checkedID == row.id, hold != nil {
            hold?.cancel(); hold = nil; checkedID = nil
            return
        }
        guard bridge.status == .paired, !locked, checkedID == nil, !row.task.isArchived else { return }
        if let reason = row.task.completionBlockedReason { notice = reason; return }
        if row.completionAsks { completing = row.task; return }
        checkedID = row.id
        let task = row.task
        hold = Task { @MainActor in
            do { try await Task.sleep(for: Self.completionHold) } catch { return }
            hold = nil
            complete(task)
        }
    }

    /// Leaving the list does not lose a ticked circle: it is sent at once.
    private func commitHeldCompletion() {
        guard let hold, let id = checkedID, let task = items.first(where: { $0.id == id }) else { return }
        hold.cancel(); self.hold = nil
        complete(task)
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
        guard bridge.status == .paired, !busy, pending == nil else { if checkedID == task.id { checkedID = nil }; return }
        if let reason = task.completionBlockedReason { notice = reason; if checkedID == task.id { checkedID = nil }; return }
        busy = true
        Task {
            defer { busy = false; if checkedID == task.id { checkedID = nil } }
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
        if loadedDevice != device || loadedArchive != archivedOnly {
            // The pulldown switched between the open tasks and the archive:
            // each has its own snapshot, so one never shows as the other.
            if loadedDevice != device { editor = nil }
            items = []; loaded = false; loadedDevice = device; loadedArchive = archivedOnly
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
            guard loadID == epoch, device == bridge.deviceID, loadedArchive == archivedOnly, !Task.isCancelled else { return }
            guard page.nextCursor == nil else { throw LAABridgeError.invalidResponse }
            // The same tasks again (the 15-second refresh, a pull) change
            // nothing: no new sections, no redraw, no snapshot write.
            let changed = page.items != items
            if changed { items = page.items }
            if !loaded { loaded = true }
            if failure != nil { failure = nil }
            if changed, let device {
                let snapshot = LAALinearTaskCache.OwnerSnapshot(items: page.items)
                let scope = archivedOnly ? "archive" : "owner"
                // Encoding and the file write stay off the main thread.
                Task.detached(priority: .utility) { LAALinearTaskCache.save(snapshot, device: device, scope: scope) }
            }
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

/// A task's number at the head of its row: the short number the owner says
/// (`T12`), or Linear's own identifier from a Bridge that sends none, so every
/// row carries a unique number. Muted, monospaced, in a column of its own.
struct LAATaskNumberLabel: View {
    let task: LAALinearTask
    @ScaledMetric(relativeTo: .footnote) private var width: CGFloat = 34

    static func number(_ task: LAALinearTask) -> String? {
        LAAWorkRef.display(task.ref) ?? LAAWorkRef.display(task.identifier)
    }

    var body: some View {
        if let value = Self.number(task) {
            Text(verbatim: value)
                .laaTextStyle(.secondary).fontWeight(.medium).monospacedDigit()
                .foregroundStyle(LAAColor.secondaryText)
                .lineLimit(1).fixedSize()
                .frame(minWidth: width, alignment: .leading)
                .accessibilityIdentifier("work.ref.\(value)")
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
