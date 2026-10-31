#if LAA_BUILD
import SwiftUI

extension LAACopy.WorkTab {
    static let newTask = "New Task"
    static let editTask = "Edit Task"
    static let myTasks = "My Tasks"
    static let inProgress = "In Progress"
    static let backlog = "Backlog"
    static let searchTasks = "Search Tasks"
    static let loadMore = "Load More"
    static let views = "Views"
    static let cycles = "Cycles"
    static let checkStatus = "Check Status"
    static let retrySameRequest = "Retry Same Request"
}

struct LAAPersonalTaskList: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @ObservedObject var drafts: ComposerDraftStore
    let refreshID: Int
    @State private var view = "mine"
    @State private var search = ""
    @State private var submittedSearch = ""
    @State private var project = ""
    @State private var cycle = ""
    @State private var customView = ""
    @State private var projects: [LAAPersonalChoice] = []
    @State private var cycles: [LAAPersonalChoice] = []
    @State private var views: [LAAPersonalChoice] = []
    @State private var collectionsIncomplete = false
    @State private var projectCursor: String?
    @State private var cycleCursor: String?
    @State private var viewCursor: String?
    @State private var projectsDone = false
    @State private var cyclesDone = false
    @State private var viewsDone = false
    @State private var collectionViewer: String?
    @State private var items: [LAAPersonalTask] = []
    @State private var cursor: String?
    @State private var seenCursors = Set<String>()
    @State private var viewerId: String?
    @State private var observedAt: String?
    @State private var error: String?
    @State private var loading = false
    @State private var generation = UUID()
    @State private var loadedFilter: String?
    @State private var showCreate = false
    @State private var editing: LAAPersonalTask?
    @State private var revision = 0
    @State private var inboxRevision = 0
    @State private var inboxSummary = "未確認"
    @State private var inboxObservedAt: String?

    private var filterID: String { [view, submittedSearch, project, cycle, customView, String(refreshID), String(revision)].joined(separator: "\u{1f}") }
    private var filterSelection: String { [view, submittedSearch, project, cycle, customView].joined(separator: "\u{1f}") }

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            HStack {
                Text(verbatim: "TASKS").laaTextStyle(.section).fontWeight(.semibold).foregroundStyle(LAAColor.secondaryText)
                Spacer()
                Button(LAACopy.WorkTab.newTask) { showCreate = true }
                    .buttonStyle(.borderedProminent).disabled(viewerId == nil)
                    .accessibilityIdentifier("work.tasks.create")
            }
            HStack {
                if let viewerId {
                    NavigationLink(destination: LAAPersonalInboxView(drafts: drafts, viewerId: viewerId, onExit: { inboxRevision += 1 })) {
                        VStack(alignment: .leading, spacing: LAASpacing.x1) {
                            Text(verbatim: "Inbox · \(inboxSummary)")
                            if let inboxObservedAt {
                                Text(verbatim: "取得: \(LAAWorkPresentation.date(inboxObservedAt))")
                                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                            }
                        }
                    }.accessibilityIdentifier("work.tasks.inbox")
                }
                Spacer()
                NavigationLink {
                    if let viewerId { LAAPersonalPendingView(drafts: drafts, viewerId: viewerId) }
                    else { LAAPersonalPendingOfflineView(drafts: drafts) }
                } label: { Text(verbatim: "Pending") }
                    .accessibilityIdentifier("work.tasks.pending")
            }
            TextField(LAACopy.WorkTab.searchTasks, text: $search)
                .submitLabel(.search).textInputAutocapitalization(.never)
                .onSubmit { customView = ""; submittedSearch = search.trimmingCharacters(in: .whitespacesAndNewlines) }
                .textFieldStyle(.roundedBorder)
            if !submittedSearch.isEmpty {
                HStack {
                    Text(verbatim: "Search: \(submittedSearch)").laaTextStyle(.secondary)
                    Button(LAACopy.WorkTab.close) { search = ""; submittedSearch = "" }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    Picker(LAACopy.WorkTab.task, selection: Binding(get: { view }, set: { view = $0; customView = "" })) {
                        Text(LAACopy.WorkTab.myTasks).tag("mine")
                        Text(LAACopy.WorkTab.all).tag("all")
                        Text(LAACopy.WorkTab.inProgress).tag("active")
                        Text(LAACopy.WorkTab.backlog).tag("backlog")
                    }
                    Picker(LAACopy.WorkTab.projectFilter, selection: Binding(get: { project }, set: { project = $0; customView = "" })) {
                        Text(LAACopy.WorkTab.all).tag("")
                        ForEach(projects) { Text(verbatim: $0.displayName).tag($0.id) }
                    }
                    Picker(LAACopy.WorkTab.cycles, selection: Binding(get: { cycle }, set: { cycle = $0; customView = "" })) {
                        Text(LAACopy.WorkTab.all).tag("")
                        ForEach(cycles) { Text(verbatim: $0.displayName).tag($0.id) }
                    }
                    Menu(LAACopy.WorkTab.views) {
                        Button(LAACopy.WorkTab.all) { customView = "" }
                        ForEach(views.filter { $0.modelName == "Issue" }) { choice in
                            Button(choice.displayName) {
                                search = ""; submittedSearch = ""; project = ""; cycle = ""; view = "all"
                                customView = choice.id
                            }
                        }
                    }
                }.pickerStyle(.menu)
            }
            if !customView.isEmpty, let selected = views.first(where: { $0.id == customView }) {
                Text(verbatim: "View: \(selected.displayName)").laaTextStyle(.secondary)
            }
            if collectionsIncomplete {
                Text(verbatim: "一部のProject・Cycle・Viewは読み込めていません。")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                Button(LAACopy.WorkTab.loadMore) { Task { await loadCollections() } }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(LAAColor.attention)
                if !items.isEmpty { Text(verbatim: "前回取得した結果です。更新できていません。") }
                Button(LAACopy.WorkTab.retry) { Task { await load(reset: true) } }
            }
            if let observedAt {
                Text(verbatim: "更新: \(LAAWorkPresentation.date(observedAt)) · ページ間で内容が変わる場合があります。")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
            if loading { ProgressView() }
            if items.isEmpty && !loading && error == nil {
                Text(verbatim: "該当するタスクはありません。").foregroundStyle(LAAColor.secondaryText).workCard()
            }
            ForEach(items) { item in
                LAAPersonalTaskRow(task: item, edit: { editing = item }) {
                    LAAWorkTaskDetailView(id: item.id, drafts: drafts)
                }
            }
            if cursor != nil {
                Button(LAACopy.WorkTab.loadMore) { Task { await load(reset: false) } }.disabled(loading)
            }
        }
        .accessibilityIdentifier("work.tasks")
        .sheet(isPresented: $showCreate, onDismiss: { revision += 1 }) {
            if let viewerId { LAAPersonalTaskEditor(task: nil, viewerId: viewerId, drafts: drafts).environmentObject(bridge) }
        }
        .sheet(item: $editing, onDismiss: { revision += 1 }) { item in
            if let viewerId { LAAPersonalTaskEditor(task: item, viewerId: viewerId, drafts: drafts).environmentObject(bridge) }
        }
        .task(id: filterID) { await load(reset: true) }
        .task(id: bridge.revision) {
            projects = []; cycles = []; views = []; projectCursor = nil; cycleCursor = nil; viewCursor = nil
            projectsDone = false; cyclesDone = false; viewsDone = false; collectionViewer = nil
            await loadCollections()
        }
        .task(id: "\(bridge.revision)-\(viewerId ?? "")-\(refreshID)-\(inboxRevision)") { await loadInboxSummary() }
    }

    @MainActor private func load(reset: Bool) async {
        if !reset && (loading || cursor == nil) { return }
        let thisGeneration = reset ? UUID() : generation
        let selection = filterSelection
        if reset {
            generation = thisGeneration; cursor = nil; seenCursors = []
            if loadedFilter != selection { items = []; observedAt = nil }
        }
        loading = true; error = nil
        defer { if generation == thisGeneration { loading = false } }
        var query = [URLQueryItem(name: "view", value: customView.isEmpty ? view : "all")]
        if !submittedSearch.isEmpty { query.append(URLQueryItem(name: "search", value: submittedSearch)) }
        if !project.isEmpty { query.append(URLQueryItem(name: "project", value: project)) }
        if !cycle.isEmpty { query.append(URLQueryItem(name: "cycle", value: cycle)) }
        if !customView.isEmpty { query.append(URLQueryItem(name: "customView", value: customView)) }
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        do {
            let page: LAAPersonalPage<LAAPersonalTask> = try await bridge.read(LAAWorkPresentation.path("/v1/personal-tasks", query: query))
            guard !Task.isCancelled, generation == thisGeneration else { return }
            if !reset, let viewerId, page.viewerId != viewerId { throw LAABridgeError.invalidResponse }
            if let next = page.nextCursor, !seenCursors.insert(next).inserted { throw LAABridgeError.invalidResponse }
            if reset { items = [] }
            var existing = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { existing.insert($0.id).inserted })
            loadedFilter = selection
            cursor = page.nextCursor; viewerId = page.viewerId; observedAt = page.observedAt
            if await LAAPersonalTaskQueue.run(drafts: drafts, bridge: bridge, viewer: page.viewerId), !Task.isCancelled {
                revision += 1
            }
        } catch is CancellationError {
        } catch let failure as LAABridgeError {
            if generation == thisGeneration && !Task.isCancelled { error = failure.japaneseText }
        } catch {
            if generation == thisGeneration && !Task.isCancelled { self.error = "タスクを読み取れませんでした。" }
        }
    }

    @MainActor private func loadCollections() async {
        do {
            if !projectsDone {
                let page = try await collectionPage("/v1/task-projects", cursor: projectCursor)
                try checkViewer(page.viewerId)
                projects = appendChoices(projects, page.items); projectsDone = page.nextCursor == nil; projectCursor = page.nextCursor
            }
            if !cyclesDone {
                let page = try await collectionPage("/v1/task-cycles", cursor: cycleCursor)
                try checkViewer(page.viewerId)
                cycles = appendChoices(cycles, page.items); cyclesDone = page.nextCursor == nil; cycleCursor = page.nextCursor
            }
            if !viewsDone {
                let page = try await collectionPage("/v1/task-views", cursor: viewCursor)
                try checkViewer(page.viewerId)
                views = appendChoices(views, page.items); viewsDone = page.nextCursor == nil; viewCursor = page.nextCursor
            }
            collectionsIncomplete = !projectsDone || !cyclesDone || !viewsDone
        } catch { collectionsIncomplete = true }
    }
    @MainActor private func loadInboxSummary() async {
        inboxSummary = "未確認"
        inboxObservedAt = nil
        guard let viewerId else { return }
        do {
            let page: LAAPersonalPage<LAAPersonalNotification> = try await bridge.read("/v1/task-inbox?limit=50")
            guard !Task.isCancelled else { return }
            var snapshot = LAAPersonalInboxSnapshot(viewerId: viewerId)
            try snapshot.merge(page, reset: true)
            inboxSummary = snapshot.summary
            inboxObservedAt = snapshot.observedAt
        } catch { if !Task.isCancelled { inboxSummary = "未確認"; inboxObservedAt = nil } }
    }
    @MainActor private func collectionPage(_ path: String, cursor: String?) async throws -> LAAPersonalPage<LAAPersonalChoice> {
        var query = [URLQueryItem(name: "limit", value: "100")]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let page: LAAPersonalPage<LAAPersonalChoice> = try await bridge.read(LAAWorkPresentation.path(path, query: query))
        if cursor != nil && cursor == page.nextCursor { throw LAABridgeError.invalidResponse }
        return page
    }
    private func appendChoices(_ old: [LAAPersonalChoice], _ new: [LAAPersonalChoice]) -> [LAAPersonalChoice] {
        let ids = Set(old.map(\.id))
        return old + new.filter { !ids.contains($0.id) }
    }
    @MainActor private func checkViewer(_ id: String) throws {
        guard collectionViewer == nil || collectionViewer == id else { throw LAABridgeError.conflict }
        collectionViewer = id
    }
}

private struct LAAPersonalTaskRow<Destination: View>: View {
    let task: LAAPersonalTask
    let edit: () -> Void
    @ViewBuilder let destination: () -> Destination
    @State private var showActions = false
    var body: some View {
        HStack {
            NavigationLink(destination: destination) {
                VStack(alignment: .leading, spacing: LAASpacing.x1) {
                    Text(verbatim: task.title).laaTextStyle(.body).fontWeight(.semibold).foregroundStyle(LAAColor.text)
                    Text(verbatim: "\(task.sourceId) · \(task.status?.name ?? "状態未確認") · 担当 \(task.owner?.name ?? "未設定")")
                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                }.workListRow()
            }.buttonStyle(.plain)
            if showActions { Button(LAACopy.WorkTab.edit, action: edit).buttonStyle(.bordered) }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 25).onEnded { value in
            if let action = LAAPersonalTaskSwipe.action(width: value.translation.width, height: value.translation.height) {
                showActions = action
            }
        })
        .accessibilityAction(named: Text(LAACopy.WorkTab.edit), edit)
        .contextMenu { Button(LAACopy.WorkTab.edit, action: edit) }
    }
}
#endif
