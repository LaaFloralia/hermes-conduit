#if LAA_BUILD
import SwiftUI

struct LAAWorkView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let onRequestSettings: () -> Void

    @StateObject private var drafts = ComposerDraftStore(capacity: .max, fileURL: LAAWorkDrafts.fileURL)
    @State private var section = 0
    @State private var projects: [LAAWorkProject] = []
    @State private var workspaces: [LAAWorkWorkspace] = []
    @State private var sessions: [LAAWorkSession] = []
    @State private var tasks: [LAAWorkTask] = []
    @State private var taskSources: [LAAWorkSource] = []
    @State private var projectInstructionsAvailable = false
    @State private var projectFilter = ""
    @State private var phaseFilter = ""
    @State private var taskOwnerFilter = ""
    @State private var taskStatusFilter = ""
    @State private var taskProjectFilter = ""
    @State private var failure: String?
    @State private var isLoading = false
    @State private var sessionContextReady = false
    @State private var showPairing = false
    @State private var showNewSession = false
    @State private var showNewProject = false
    @State private var refreshID = 0
    @State private var loadID = UUID()

    var body: some View {
        ZStack {
            LAAColors.paper.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: LAASpacing.x4) {
                    Text(verbatim: "仕事").font(LAAFont.largeHeading).foregroundStyle(LAAColors.ink)
                    segmentPicker
                    if bridge.status != .paired {
                        connection
                    } else {
                        content
                    }
                }
                .padding(.horizontal, LAASpacing.x4)
                .padding(.top, LAASpacing.x2)
                .padding(.bottom, LAASpacing.x8)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .refreshable { await load() }
        }
        .navigationTitle(Text(verbatim: "仕事"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if bridge.status == .paired && section == 0 {
                    Button { showNewSession = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel(Text(verbatim: "新しいセッション"))
                        .disabled(!sessionContextReady || isLoading)
                }
                if bridge.status == .paired && section == 1 {
                    Button { showNewProject = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel(Text(verbatim: "新しいプロジェクト"))
                }
                Button(action: onRequestSettings) { Image(systemName: "gearshape") }
                    .accessibilityLabel(Text(verbatim: "設定"))
            }
        }
        .tint(LAAColors.teal)
        .sheet(isPresented: $showPairing) { LAAPairingView().environmentObject(bridge) }
        .sheet(isPresented: $showNewSession, onDismiss: { refreshID += 1 }) {
            LAAWorkNewSessionView(projects: projects, workspaces: workspaces, drafts: drafts).environmentObject(bridge)
        }
        .sheet(isPresented: $showNewProject, onDismiss: { refreshID += 1 }) {
            LAAWorkProjectEditor(project: nil, canEditInstructions: projectInstructionsAvailable, drafts: drafts).environmentObject(bridge)
        }
        .task(id: "\(bridge.revision)-\(section)-\(refreshID)") { await load() }
    }

    @ViewBuilder private var segmentPicker: some View {
        let picker = Picker(selection: $section, label: Text(verbatim: "仕事の種類")) {
            Text(verbatim: "セッション").tag(0)
            Text(verbatim: "プロジェクト").tag(1)
            Text(verbatim: "タスク").tag(2)
            Text(verbatim: "ルーティン").tag(3)
        }
        .accessibilityIdentifier("work.segment")
        if dynamicTypeSize.isAccessibilitySize { picker.pickerStyle(.menu) }
        else { picker.pickerStyle(.segmented) }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if bridge.status == .keychainError {
                Label("接続情報を読み取れません", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(LAAColors.plum)
                Text(verbatim: "端末の接続情報を確認してください。")
                Button("設定を確認", action: onRequestSettings).buttonStyle(.bordered)
            } else {
                Label { Text(verbatim: "未接続") } icon: { Image(systemName: "circle") }
                    .foregroundStyle(LAAColors.muted)
                Text(verbatim: bridge.status == .revoked || bridge.status == .unauthorized
                     ? "この端末の接続が無効です。新しいコードで接続してください。"
                     : "この端末はMacのLAA Bridgeとペアリングされていません。")
                Button("Macに接続する") { showPairing = true }.buttonStyle(.borderedProminent)
            }
        }
        .workCard()
    }

    @ViewBuilder private var content: some View {
        if let failure {
            VStack(alignment: .leading, spacing: 8) {
                Label("取得できませんでした", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(LAAColors.plum)
                Text(verbatim: failure).foregroundStyle(LAAColors.ink)
                Text(verbatim: "残っている一覧は前回取得した内容です。")
                    .font(.caption).foregroundStyle(LAAColors.muted)
                Button("もう一度読み込む") { Task { await load() } }
            }.workCard()
        }
        if isLoading { ProgressView().accessibilityLabel(Text(verbatim: "読み込み中")) }
        switch section {
        case 0: sessionList
        case 1: projectList
        case 2: taskList
        default:
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "準備中").font(.headline)
                Text(verbatim: "習慣の原本との連携はまだ利用できません。")
                    .foregroundStyle(LAAColors.muted)
            }.workCard()
        }
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                filter("プロジェクト", selection: $projectFilter, values: projects.map { ($0.id, $0.name) })
                filter("状態", selection: $phaseFilter, values: phaseOptions)
                Spacer(minLength: 0)
            }
            let rows = LAAWorkPresentation.filteredSessionRows(sessions, projectID: projectFilter, phase: phaseFilter)
            if rows.isEmpty && !isLoading && failure == nil {
                Text(verbatim: projectFilter.isEmpty && phaseFilter.isEmpty
                     ? "セッションがありません。＋から始められます。" : "条件に合うセッションはありません。")
                    .foregroundStyle(LAAColors.muted).workCard()
            }
            ForEach(rows) { row in
                NavigationLink {
                    LAAWorkSessionDetail(id: row.session.id, projects: projects, workspaces: workspaces, drafts: drafts)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(verbatim: row.session.name).font(.headline).foregroundStyle(LAAColors.ink)
                                .accessibilityIdentifier("work.session.\(row.session.id)")
                            Spacer()
                            Text(verbatim: LAAWorkPresentation.phaseSymbol(row.session.phase) + " " + LAAWorkPresentation.phase(row.session.phase))
                                .font(.caption).foregroundStyle(LAAWorkPresentation.phaseNeedsAttention(row.session.phase) ? LAAColors.plum : LAAColors.teal)
                        }
                        if row.session.resumedFrom != nil {
                            Text(verbatim: "後継セッション").font(.caption).foregroundStyle(LAAColors.muted)
                        }
                        if (!projectFilter.isEmpty && row.session.projectId != projectFilter) ||
                            (!phaseFilter.isEmpty && row.session.phase != phaseFilter) {
                            Text(verbatim: "親セッション（階層を表示するため含む）")
                                .font(.caption).foregroundStyle(LAAColors.muted)
                        }
                        Text(verbatim: projectName(row.session.projectId) + " · " + workspaceName(row.session.workspaceId))
                            .font(.subheadline).foregroundStyle(LAAColors.muted)
                        Text(verbatim: "要求: " + (row.session.requested?.display ?? "未確認"))
                            .font(.caption).foregroundStyle(LAAColors.muted)
                        Text(verbatim: "観測: " + (row.session.observed?.display ?? "未確認"))
                            .font(.caption).foregroundStyle(row.session.modelMismatch ? LAAColors.plum : LAAColors.muted)
                        if row.session.modelMismatch {
                            Label("要求と観測が一致しません", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(LAAColors.plum)
                        } else if row.session.runtimeVerified != true {
                            Text(verbatim: "○ 実行時のモデルは未確認").font(.caption).foregroundStyle(LAAColors.muted)
                        }
                        Text(verbatim: "最終活動 " + LAAWorkPresentation.date(row.session.updatedAt))
                            .font(.caption).foregroundStyle(LAAColors.muted)
                    }
                    .padding(.leading, CGFloat(row.depth) * 12)
                    .workCard()
                }.buttonStyle(.plain)
            }
        }
        .accessibilityIdentifier("work.sessions")
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 12) {
            if projects.isEmpty && !isLoading && failure == nil {
                Text(verbatim: "プロジェクトがありません。＋から作成できます。")
                    .foregroundStyle(LAAColors.muted).workCard()
            }
            ForEach(projects) { project in
                NavigationLink {
                    LAAWorkProjectDetail(project: project, drafts: drafts)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: project.name).font(.headline).foregroundStyle(LAAColors.ink)
                        Text(verbatim: "指示版 \(project.instructionVersion.map(String.init) ?? "未確認") · " + (project.instructionHash ?? "ハッシュ未確認"))
                            .font(.caption).foregroundStyle(LAAColors.muted).lineLimit(2)
                    }.workCard()
                }.buttonStyle(.plain)
            }
        }.accessibilityIdentifier("work.projects")
    }

    private var taskList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Linearが現在のタスクの正本です。ここでは閲覧のみできます。")
                .font(.footnote).foregroundStyle(LAAColors.muted)
            HStack {
                filter("担当", selection: $taskOwnerFilter, values: unique(tasks.compactMap { $0.owner?.name }).map { ($0, $0) })
                filter("状態", selection: $taskStatusFilter, values: unique(tasks.compactMap { $0.status?.name }).map { ($0, $0) })
                filter("プロジェクト", selection: $taskProjectFilter, values: unique(tasks.compactMap { $0.project?.name }).map { ($0, $0) })
            }
            if taskSources.contains(where: { $0.source == "linear" && $0.truncated == true }) {
                Label("Linearの取得上限を超えています。一部のみ表示しています。", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(LAAColors.plum)
            }
            let visible = tasks.filter {
                (taskOwnerFilter.isEmpty || $0.owner?.name == taskOwnerFilter) &&
                (taskStatusFilter.isEmpty || $0.status?.name == taskStatusFilter) &&
                (taskProjectFilter.isEmpty || $0.project?.name == taskProjectFilter)
            }
            if visible.isEmpty && !isLoading && failure == nil {
                Text(verbatim: "該当するタスクはありません。")
                    .foregroundStyle(LAAColors.muted).workCard()
            }
            ForEach(visible) { item in
                NavigationLink { LAAWorkTaskDetailView(id: item.id) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: item.title).font(.headline).foregroundStyle(LAAColors.ink)
                        Text(verbatim: "\(item.sourceId) · \(item.status?.name ?? "状態未確認") · 担当 \(item.owner?.name ?? "未設定")")
                            .font(.caption).foregroundStyle(LAAColors.muted)
                        if let executor = item.executor?.name {
                            Text(verbatim: "実行 \(executor)").font(.caption).foregroundStyle(LAAColors.muted)
                        }
                    }.workCard()
                }.buttonStyle(.plain)
            }
        }.accessibilityIdentifier("work.tasks")
    }

    private func filter(_ title: String, selection: Binding<String>, values: [(String, String)]) -> some View {
        Picker(selection: selection, label: Text(verbatim: title)) {
            Text(verbatim: "\(title): すべて").tag("")
            ForEach(values.indices, id: \.self) { index in Text(verbatim: values[index].1).tag(values[index].0) }
        }.pickerStyle(.menu).font(.caption)
    }
    private func unique(_ values: [String]) -> [String] { Array(Set(values)).sorted() }
    private var phaseOptions: [(String, String)] {
        let known = ["created", "running", "awaiting_decision", "awaiting_review", "stopped", "stop_unconfirmed", "closed", "error"]
        let extra = unique(sessions.map(\.phase)).filter { !known.contains($0) }
        return (known + extra).map { ($0, LAAWorkPresentation.phase($0)) }
    }
    private func projectName(_ id: String?) -> String {
        guard let id else { return "プロジェクトなし" }
        return projects.first(where: { $0.id == id })?.name ?? "プロジェクト未確認"
    }
    private func workspaceName(_ id: String) -> String {
        guard let item = workspaces.first(where: { $0.id == id }) else { return "作業場所未確認" }
        return (item.displayPath ?? item.path) + (item.branch.map { " · " + $0 } ?? "")
    }

    @MainActor private func load() async {
        let id = UUID()
        loadID = id
        let selected = section
        guard bridge.status == .paired, selected != 3 else { isLoading = false; failure = nil; return }
        isLoading = true
        failure = nil
        defer { if loadID == id { isLoading = false } }
        do {
            if selected == 0 || selected == 1 {
                sessionContextReady = false
                let projectPage: [LAAWorkProject] = try await loadItems("/v1/projects")
                let workspacePage: [LAAWorkWorkspace] = try await loadItems("/v1/workspaces")
                guard !Task.isCancelled, loadID == id else { return }
                projects = projectPage
                workspaces = workspacePage
                sessionContextReady = true
                if let first = projectPage.first {
                    let detail: LAAWorkProject? = try? await bridge.read("/v1/projects/\(first.id)")
                    guard !Task.isCancelled, loadID == id else { return }
                    projectInstructionsAvailable = detail?.hasInstructionBody == true && detail?.instructionError == nil
                } else { projectInstructionsAvailable = false }
                if selected == 0 {
                    let page: [LAAWorkSession] = try await loadItems("/v1/sessions")
                    if !Task.isCancelled && loadID == id { sessions = page }
                }
            } else {
                var cursor: String?
                var seen = Set<String>()
                var all: [LAAWorkTask] = []
                var sources: [LAAWorkSource] = []
                repeat {
                    var query = [URLQueryItem(name: "source", value: "linear")]
                    if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
                    let page: LAAWorkPage<LAAWorkTask> = try await bridge.read(LAAWorkPresentation.path("/v1/tasks", query: query))
                    guard page.sources?.contains(where: { $0.source == "linear" && $0.state == "available" }) == true else {
                        throw LAABridgeError.unavailable
                    }
                    all.append(contentsOf: page.items.filter { $0.source == "linear" })
                    sources = page.sources ?? sources
                    cursor = page.nextCursor
                    if let cursor, !seen.insert(cursor).inserted { throw LAABridgeError.invalidResponse }
                } while cursor != nil && seen.count < 50
                guard cursor == nil else { throw LAABridgeError.invalidResponse }
                if !Task.isCancelled && loadID == id { tasks = all; taskSources = sources }
            }
        } catch is CancellationError {
            return
        } catch let error as LAABridgeError {
            if !Task.isCancelled && loadID == id { failure = error.japaneseText }
        } catch {
            if !Task.isCancelled && loadID == id { failure = "Macからの応答を読み取れませんでした。" }
        }
    }

    @MainActor private func loadItems<T: Decodable>(_ path: String) async throws -> [T] {
        var all: [T] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            let query = cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []
            let page: LAAWorkPage<T> = try await bridge.read(LAAWorkPresentation.path(path, query: query))
            all.append(contentsOf: page.items)
            cursor = page.nextCursor
            if let cursor, !seen.insert(cursor).inserted { throw LAABridgeError.invalidResponse }
        } while cursor != nil && seen.count < 50
        guard cursor == nil else { throw LAABridgeError.invalidResponse }
        return all
    }
}

private struct LAAWorkCard: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(LAAColors.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}
extension View { func workCard() -> some View { modifier(LAAWorkCard()) } }
#endif
