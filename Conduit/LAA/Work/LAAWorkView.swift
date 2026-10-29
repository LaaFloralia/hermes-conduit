#if LAA_BUILD
import SwiftUI

struct LAAWorkView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
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
            LAAColor.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: LAASpacing.x6) {
                    header
                    segmentPicker
                    if section == 3 {
                        routinePlaceholder
                    } else if bridge.status != .paired {
                        connection
                    } else {
                        content
                    }
                }
                .padding(.horizontal, LAASpacing.horizontal)
                .padding(.top, LAASpacing.x2)
                .padding(.bottom, LAASpacing.x8)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .laaTextStyle(.body).foregroundStyle(LAAColor.text)
            }
            .refreshable { await load() }
        }
        .navigationTitle(Text(verbatim: LAACopy.WorkTab.title))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onRequestSettings) { Image(systemName: "gearshape") }
                    .accessibilityLabel(Text(verbatim: LAACopy.WorkTab.settings))
            }
        }
        .tint(LAAColor.link)
        .sheet(isPresented: $showPairing) { LAAPairingView().environmentObject(bridge) }
        .sheet(isPresented: $showNewSession, onDismiss: { refreshID += 1 }) {
            LAAWorkNewSessionView(projects: projects, workspaces: workspaces, drafts: drafts).environmentObject(bridge)
        }
        .sheet(isPresented: $showNewProject, onDismiss: { refreshID += 1 }) {
            LAAWorkProjectEditor(project: nil, canEditInstructions: projectInstructionsAvailable, drafts: drafts).environmentObject(bridge)
        }
        .task(id: "\(bridge.revision)-\(section)-\(refreshID)") { await load() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: LAASpacing.x4) {
            VStack(alignment: .leading, spacing: LAASpacing.x1) {
                Text(verbatim: "LAA").laaTextStyle(.section).fontWeight(.semibold).foregroundStyle(LAAColor.link)
                Text(verbatim: LAACopy.WorkTab.title).font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
                Text(verbatim: LAACopy.WorkTab.subtitle).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
            Spacer(minLength: LAASpacing.x2)
            if section == 0 || section == 1 {
                Button {
                    if section == 0 { showNewSession = true } else { showNewProject = true }
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(LAAColor.link)
                        .frame(width: LAASpacing.minimumTouchTarget, height: LAASpacing.minimumTouchTarget)
                        .background(LAAColor.surface, in: Circle())
                        .overlay(Circle().stroke(LAAColor.separator))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: section == 0 ? LAACopy.WorkTab.newSession : LAACopy.WorkTab.newProject))
                .accessibilityHint(Text(verbatim: bridge.status != .paired ? "Macへの接続が必要です。" : ""))
                .disabled(bridge.status != .paired || (section == 0 && (!sessionContextReady || isLoading)))
            }
        }
    }

    private var segmentPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LAASpacing.x2) {
                ForEach(LAACopy.WorkTab.segments.indices, id: \.self) { index in
                    Button { section = index } label: {
                        Text(verbatim: LAACopy.WorkTab.segments[index])
                            .laaTextStyle(.secondary).fontWeight(section == index ? .semibold : .regular)
                            .foregroundStyle(section == index ? LAAColor.filledButtonText : LAAColor.secondaryText)
                            .padding(.horizontal, LAASpacing.x3)
                            .padding(.vertical, LAASpacing.x2)
                            .background(section == index ? LAAColor.filledButton : LAAColor.subtleSurface,
                                        in: RoundedRectangle(cornerRadius: LAARadius.selectionChip))
                            .frame(minHeight: LAASpacing.minimumTouchTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(section == index ? .isSelected : [])
                }
            }
        }
        .accessibilityIdentifier("work.segment")
    }

    private var routinePlaceholder: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            Text(verbatim: "準備中").laaTextStyle(.body).fontWeight(.semibold)
            Text(verbatim: "習慣の原本との連携はまだ利用できません。")
                .foregroundStyle(LAAColor.secondaryText)
        }.workCard()
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            if bridge.status == .keychainError {
                Label(LAAWorkPresentation.japanese("接続情報を読み取れません"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(LAAColor.attention)
                Text(verbatim: "端末の接続情報を確認してください。")
                Button(LAACopy.WorkTab.settings, action: onRequestSettings).buttonStyle(.bordered)
            } else {
                Label { Text(verbatim: "未接続") } icon: { Image(systemName: "circle") }
                    .foregroundStyle(LAAColor.secondaryText)
                Text(verbatim: bridge.status == .revoked || bridge.status == .unauthorized
                     ? "この端末の接続が無効です。新しいコードで接続してください。"
                     : "この端末はMacのLAA Bridgeとペアリングされていません。")
                Button(LAACopy.WorkTab.connect) { showPairing = true }
                    .buttonStyle(.borderedProminent).tint(LAAColor.filledButton)
                    .foregroundStyle(LAAColor.filledButtonText)
            }
        }
        .workCard()
    }

    @ViewBuilder private var content: some View {
        if let failure {
            VStack(alignment: .leading, spacing: LAASpacing.x2) {
                Label(LAAWorkPresentation.japanese("取得できませんでした"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(LAAColor.attention)
                Text(verbatim: failure).foregroundStyle(LAAColor.text)
                Text(verbatim: "残っている一覧は前回取得した内容です。")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                Button(LAACopy.WorkTab.retry) { Task { await load() } }
            }.workCard()
        }
        if isLoading { ProgressView().accessibilityLabel(Text(verbatim: "読み込み中")) }
        switch section {
        case 0: sessionList
        case 1: projectList
        case 2: taskList
        default: routinePlaceholder
        }
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LAASpacing.x2) {
                    filter(LAACopy.WorkTab.projectFilter, selection: $projectFilter, values: projects.map { ($0.id, $0.name) })
                    filter(LAACopy.WorkTab.phaseFilter, selection: $phaseFilter, values: phaseOptions)
                }
            }
            let rows = LAAWorkPresentation.filteredSessionRows(sessions, projectID: projectFilter, phase: phaseFilter)
            sectionHeading(LAACopy.WorkTab.sessions.uppercased())
            if rows.isEmpty && !isLoading && failure == nil {
                Text(verbatim: projectFilter.isEmpty && phaseFilter.isEmpty
                     ? "セッションがありません。＋から始められます。" : "条件に合うセッションはありません。")
                    .foregroundStyle(LAAColor.secondaryText).workCard()
            }
            ForEach(rows) { row in
                NavigationLink {
                    LAAWorkSessionDetail(id: row.session.id, projects: projects, workspaces: workspaces, drafts: drafts)
                } label: {
                    VStack(alignment: .leading, spacing: LAASpacing.x1) {
                        HStack {
                            Text(verbatim: row.session.name).laaTextStyle(.body).fontWeight(.semibold).foregroundStyle(LAAColor.text)
                                .accessibilityIdentifier("work.session.\(row.session.id)")
                            Spacer()
                            Text(verbatim: LAAWorkPresentation.phaseSymbol(row.session.phase) + " " + LAAWorkPresentation.phase(row.session.phase))
                                .laaTextStyle(.secondary).foregroundStyle(LAAWorkPresentation.phaseNeedsAttention(row.session.phase) ? LAAColor.attention : LAAColor.link)
                        }
                        if row.session.resumedFrom != nil {
                            Text(verbatim: "後継セッション").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        }
                        if (!projectFilter.isEmpty && row.session.projectId != projectFilter) ||
                            (!phaseFilter.isEmpty && row.session.phase != phaseFilter) {
                            Text(verbatim: "親セッション（階層を表示するため含む）")
                                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        }
                        Text(verbatim: projectName(row.session.projectId) + " · " + workspaceName(row.session.workspaceId))
                            .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        Text(verbatim: "要求: " + (row.session.requested?.display ?? "未確認"))
                            .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        Text(verbatim: "観測: " + (row.session.observed?.display ?? "未確認"))
                            .laaTextStyle(.secondary).foregroundStyle(row.session.modelMismatch ? LAAColor.attention : LAAColor.secondaryText)
                        if row.session.modelMismatch {
                            Label(LAAWorkPresentation.japanese("要求と観測が一致しません"), systemImage: "exclamationmark.triangle.fill")
                                .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                        } else if row.session.runtimeVerified != true {
                            Text(verbatim: "○ 実行時のモデルは未確認").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        }
                        Text(verbatim: "最終活動 " + LAAWorkPresentation.date(row.session.updatedAt))
                            .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    }
                    .padding(.leading, CGFloat(row.depth) * LAASpacing.x3)
                    .workListRow()
                }.buttonStyle(.plain)
            }
            let decisions = LAAWorkPresentation.decisionRows(rows, projectID: projectFilter, phase: phaseFilter)
            if !decisions.isEmpty {
                sectionHeading(LAACopy.WorkTab.needsDecision).padding(.top, LAASpacing.x6)
                ForEach(decisions) { row in
                    NavigationLink {
                        LAAWorkSessionDetail(id: row.session.id, projects: projects, workspaces: workspaces, drafts: drafts)
                    } label: {
                        HStack(spacing: LAASpacing.x3) {
                            VStack(alignment: .leading, spacing: LAASpacing.x1) {
                                Text(verbatim: row.session.name).laaTextStyle(.body).fontWeight(.semibold).foregroundStyle(LAAColor.text)
                                Text(verbatim: "内容を開いて確認できます。回答は後続の機能で対応します。")
                                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                            }
                            Spacer(minLength: LAASpacing.x2)
                            Image(systemName: "chevron.right").foregroundStyle(LAAColor.link)
                        }.workCard()
                    }.buttonStyle(.plain)
                }
            }
        }
        .accessibilityIdentifier("work.sessions")
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            if projects.isEmpty && !isLoading && failure == nil {
                Text(verbatim: "プロジェクトがありません。＋から作成できます。")
                    .foregroundStyle(LAAColor.secondaryText).workCard()
            }
            ForEach(projects) { project in
                NavigationLink {
                    LAAWorkProjectDetail(project: project, drafts: drafts)
                } label: {
                    VStack(alignment: .leading, spacing: LAASpacing.x2) {
                        Text(verbatim: project.name).laaTextStyle(.body).fontWeight(.semibold).foregroundStyle(LAAColor.text)
                        Text(verbatim: "指示版 \(project.instructionVersion.map(String.init) ?? "未確認") · " + (project.instructionHash ?? "ハッシュ未確認"))
                            .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText).lineLimit(2)
                    }.workListRow()
                }.buttonStyle(.plain)
            }
        }.accessibilityIdentifier("work.projects")
    }

    private var taskList: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            Text(verbatim: "Linearが現在のタスクの正本です。ここでは閲覧のみできます。")
                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LAASpacing.x2) {
                    filter(LAACopy.WorkTab.ownerFilter, selection: $taskOwnerFilter, values: unique(tasks.compactMap { $0.owner?.name }).map { ($0, $0) })
                    filter(LAACopy.WorkTab.statusFilter, selection: $taskStatusFilter, values: unique(tasks.compactMap { $0.status?.name }).map { ($0, $0) })
                    filter(LAACopy.WorkTab.projectFilter, selection: $taskProjectFilter, values: unique(tasks.compactMap { $0.project?.name }).map { ($0, $0) })
                }
            }
            if taskSources.contains(where: { $0.source == "linear" && $0.truncated == true }) {
                Label(LAAWorkPresentation.japanese("Linearの取得上限を超えています。一部のみ表示しています。"), systemImage: "exclamationmark.triangle")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
            }
            let visible = tasks.filter {
                (taskOwnerFilter.isEmpty || $0.owner?.name == taskOwnerFilter) &&
                (taskStatusFilter.isEmpty || $0.status?.name == taskStatusFilter) &&
                (taskProjectFilter.isEmpty || $0.project?.name == taskProjectFilter)
            }
            if visible.isEmpty && !isLoading && failure == nil {
                Text(verbatim: "該当するタスクはありません。")
                    .foregroundStyle(LAAColor.secondaryText).workCard()
            }
            ForEach(visible) { item in
                NavigationLink { LAAWorkTaskDetailView(id: item.id) } label: {
                    VStack(alignment: .leading, spacing: LAASpacing.x1) {
                        Text(verbatim: item.title).laaTextStyle(.body).fontWeight(.semibold).foregroundStyle(LAAColor.text)
                        Text(verbatim: "\(item.sourceId) · \(item.status?.name ?? "状態未確認") · 担当 \(item.owner?.name ?? "未設定")")
                            .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        if let executor = item.executor?.name {
                            Text(verbatim: "実行 \(executor)").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        }
                    }.workListRow()
                }.buttonStyle(.plain)
            }
        }.accessibilityIdentifier("work.tasks")
    }

    private func filter(_ title: String, selection: Binding<String>, values: [(String, String)]) -> some View {
        Picker(selection: selection, label: Text(verbatim: title)) {
            Text(verbatim: "\(title): \(LAACopy.WorkTab.all)").tag("")
            ForEach(values.indices, id: \.self) { index in Text(verbatim: values[index].1).tag(values[index].0) }
        }.pickerStyle(.menu).laaTextStyle(.secondary)
    }
    private func sectionHeading(_ title: String) -> some View {
        Text(verbatim: title).laaTextStyle(.section).fontWeight(.semibold).foregroundStyle(LAAColor.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        content.padding(LAASpacing.x4).frame(maxWidth: .infinity, alignment: .leading)
            .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
            .laaTextStyle(.body).foregroundStyle(LAAColor.text)
    }
}
private struct LAAWorkListRow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.vertical, LAASpacing.x4)
            .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
            .overlay(alignment: .bottom) { Divider().overlay(LAAColor.separator) }
            .contentShape(Rectangle())
    }
}
extension View {
    func workCard() -> some View { modifier(LAAWorkCard()) }
    func workListRow() -> some View { modifier(LAAWorkListRow()) }
}
#endif
