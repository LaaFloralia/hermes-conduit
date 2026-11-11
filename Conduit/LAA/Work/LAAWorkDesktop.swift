#if LAA_BUILD
import SwiftUI

/// Small, testable list behaviour shared by the Mac Work columns.
enum LAAWorkDesktopList {
    static func next(current: Int?, count: Int, delta: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return delta < 0 ? count - 1 : 0 }
        return min(max(current + delta, 0), count - 1)
    }

    static func matches(_ text: String, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || text.localizedCaseInsensitiveContains(query)
    }
}

/// Work › Sessions on the Mac. The list stays put; the selected session opens
/// in the detail column and keeps its own live observation.
struct LAAWorkDesktopSessionsView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @ObservedObject var drafts: ComposerDraftStore
    let refreshID: Int
    var createID = 0
    var onCreateConsumed: () -> Void = {}
    @State private var sessions: [LAAWorkSession] = []
    @State private var projects: [LAAWorkProject] = []
    @State private var options: LAAWorkSessionOptions?
    @State private var search = ""
    @State private var showArchived = false
    #if targetEnvironment(macCatalyst)
    /// The panes beside the list, saved per window so a relaunch returns to
    /// the same arrangement. The highlighted row is the focused pane's.
    @SceneStorage("laa.work.sessionPanes") private var storedPanes = ""
    @State private var panes = LAAWorkPaneLayout()
    @State private var panesRestored = false
    /// Every session a successful read has listed, active or archived: a pane
    /// keeps what it shows while that session still exists somewhere.
    @State private var knownIDs = Set<String>()
    private var selectedID: String? { panes.focused?.sessionID }
    #else
    @State private var selectedID: String?
    #endif
    @State private var hoveredID: String?
    @State private var failure: String?
    @State private var loading = false
    @State private var hasLoaded = false
    @State private var showLauncher = false
    @State private var reloadID = 0
    @State private var expanded = Set<String>()
    @State private var projectOrder = false
    @State private var showProjects = false
    @State private var editingProject: LAAWorkProject?
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    private var searching: Bool { !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var filtered: [LAAWorkSession] {
        sessions.filter {
            LAAWorkRef.matches(search, ref: $0.ref, text: [$0.name, $0.observed?.model ?? $0.requested?.model ?? ""])
        }
    }

    private var ordered: [LAAWorkSession] {
        let groups = LAAWorkSessionOrder.sections(filtered)
        var rows = groups.active + groups.pinned + groups.recent
        if projectOrder {
            rows = rows.sorted {
                let a = LAAWorkSessionOrder.projectID($0, in: filtered) ?? "~"
                let b = LAAWorkSessionOrder.projectID($1, in: filtered) ?? "~"
                return a < b
            }
        }
        return searching ? rows : LAAWorkSessionOrder.visible(rows, expanded: expanded)
    }

    private var selected: LAAWorkSession? { sessions.first { $0.id == selectedID } }

    /// Opens a session where the list's selection goes: the focused pane on
    /// the Mac, the one detail column otherwise. Nil empties it.
    private func select(_ id: String?) {
        #if targetEnvironment(macCatalyst)
        if let id { panes.open(id) } else { panes.clear() }
        #else
        selectedID = id
        #endif
    }

    var body: some View {
        LAAMacListDetail {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: LAASpacing.x3) {
                    HStack {
                        Text(verbatim: "Sessions").font(.system(size: 13, weight: .semibold)).foregroundStyle(LAAColor.secondaryText)
                        Spacer()
                        Menu {
                            Button(String("新しい順")) { projectOrder = false }
                            Button(String("プロジェクト別")) { projectOrder = true }
                            Button(showArchived ? String("最近のセッションに戻る") : String("アーカイブを表示")) { showArchived.toggle(); reloadID += 1 }
                            Button(String("プロジェクトを管理")) { showProjects = true }
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                        .accessibilityLabel(String("一覧の表示")).accessibilityIdentifier("work.sessions.menu")
                    }
                    LAASearchField(placeholder: "検索", text: $search,
                                   identifier: "work.sessions.desktop.search", focus: $searchFocused)
                        .accessibilityIdentifier("work.sessions.search")
                    if let failure {
                        LAAWorkFailure(text: failure) { Task { await load() } }
                    }
                    if loading && !hasLoaded && sessions.isEmpty { LAALoadingDots() }
                }
                .padding(LAASpacing.x3)
                Rectangle().fill(LAAColor.separator).frame(height: 1)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let ordered = self.ordered
                        let children = LAAWorkSessionOrder.descendants(filtered)
                        ForEach(Array(ordered.enumerated()), id: \.element.id) { index, session in
                            if projectOrder, index == 0 || LAAWorkSessionOrder.projectID(ordered[index - 1], in: filtered) != LAAWorkSessionOrder.projectID(session, in: filtered) {
                                let project = projects.first { $0.id == LAAWorkSessionOrder.projectID(session, in: filtered) }
                                Text(verbatim: project?.name ?? "プロジェクトなし")
                                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(LAAColor.secondaryText)
                                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .contextMenu {
                                        if let project {
                                            Button(String("名前と指示を変更")) { editingProject = project }
                                            Button(String("アーカイブ")) { Task { try? await LAAWorkHTTP.setProjectArchived(project, archived: true, bridge: bridge); reloadID += 1 } }
                                        }
                                    }
                            }
                            sessionRow(session, children: children[session.id] ?? [], in: ordered)
                        }
                        if ordered.isEmpty && !loading && failure == nil {
                            Text(verbatim: showArchived ? LAACopy.macNoArchivedSessions : LAACopy.macNoSessions)
                                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                                .padding(LAASpacing.x4)
                        }

                    }
                }
            }
            .background(LAAColor.background)
            .focusable()
            .focused($listFocused)
            .onAppear { listFocused = true }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.return) { if selectedID == nil { select(ordered.first?.id) }; return .handled }
            .onKeyPress(.escape) { select(nil); return .handled }
            .laaMacSectionCommands(LAAMacSectionCommands(
                newTitle: "新しいセッション",
                canCreate: bridge.status == .paired,
                create: { showLauncher = true },
                canSearch: true,
                focusSearch: { searchFocused = true },
                canReload: true,
                reload: { reloadID += 1 }
            ))
        } detail: {
            #if targetEnvironment(macCatalyst)
            LAAWorkPaneArea(layout: $panes, sessions: sessions, projects: projects, options: options, drafts: drafts,
                            canCreate: bridge.status == .paired, onNewSession: { showLauncher = true })
            #else
            if let selected {
                NavigationStack {
                    LAAWorkSessionDetail(id: selected.id, projects: projects, workspaces: [], drafts: drafts)
                        .id(selected.id)
                }
            } else {
                LAAMacEmptyDetail(symbol: "rectangle.stack", title: LAACopy.macNoSessionTitle)
            }
            #endif
        }
        .accessibilityIdentifier("work.desktop.sessions")
        #if targetEnvironment(macCatalyst)
        .onAppear {
            guard !panesRestored else { return }
            panesRestored = true
            panes = LAAWorkPaneLayout.decoded(storedPanes)
            #if DEBUG
            // `-laa-work-panes S2,S3:v,S5` opens those sessions side by side
            // (`:v` stacks a pane under the previous one), for the window
            // shots without driving the mouse.
            if let preset = LAAWorkPanePreset.launched { panes = preset }
            #endif
        }
        .onChange(of: panes) { _, value in storedPanes = value.encoded }
        #endif
        .sheet(item: $editingProject, onDismiss: { reloadID += 1 }) { project in
            LAAWorkProjectEditor(project: project, canEditInstructions: true, drafts: drafts).environmentObject(bridge)
        }
        .navigationDestination(isPresented: $showProjects) { LAAWorkDesktopProjectsView(drafts: drafts, refreshID: 0) }
        .onChange(of: createID, initial: true) { _, value in
            guard value > 0 else { return }; showLauncher = true; onCreateConsumed()
        }
        .sheet(isPresented: $showLauncher, onDismiss: { reloadID += 1 }) {
            LAAWorkSessionLauncher(projects: projects, options: options, drafts: drafts) { created in
                showLauncher = false; select(created.id); reloadID += 1
            }
            .environmentObject(bridge)
            .laaSheetSize(.form)
        }
        .task(id: "\(bridge.revision)-\(refreshID)-\(reloadID)-\(showArchived)") {
            if !hasLoaded {
                sessions = LAAWorkSessionCache.read([LAAWorkSession].self, store: drafts, device: bridge.deviceID,
                                                   target: showArchived ? "archived" : "list") ?? []
            }
            await load()
        }
    }

    private func sessionRow(_ session: LAAWorkSession, children: [LAAWorkSession], in rows: [LAAWorkSession]) -> some View {
        let open = searching || expanded.contains(session.id)
        return HStack(spacing: 0) {
            sessionButton(session, open: open, children: children, in: rows)
            if !children.isEmpty && !searching {
                LAAWorkChildDisclosure(id: session.id, count: children.count, open: open) {
                    expanded.formSymmetricDifference([session.id])
                }
            }
        }
    }

    private func sessionButton(_ session: LAAWorkSession, open: Bool, children: [LAAWorkSession], in rows: [LAAWorkSession]) -> some View {
        Button {
            select(session.id)
        } label: {
            LAAWorkSessionRow(session: session, projectName: projects.first { $0.id == session.projectId }?.name, options: options,
                              childNeedsDecision: !open && children.contains(where: \.needsDecision),
                              pane: paneBadge(session.id))
                .padding(.leading, CGFloat(LAAWorkSessionOrder.depth(session, in: rows)) * 16)
                .background(rowBackground(session.id), in: RoundedRectangle(cornerRadius: LAARadius.card))
        }
        .buttonStyle(.plain)
        .onHover { hoveredID = $0 ? session.id : (hoveredID == session.id ? nil : hoveredID) }
        #if targetEnvironment(macCatalyst)
        // A row dragged onto a pane opens there; onto a pane's edge, beside it.
        .onDrag { LAAWorkPaneDrag.provider(.session(session.id)) } preview: {
            LAAWorkPaneDragPreview(title: session.name, model: session.observed ?? session.requested)
        }
        #endif
        .contextMenu {
            #if targetEnvironment(macCatalyst)
            if panes.pane(showing: session.id) == nil {
                Button { _ = panes.split(edge: .trailing, sessionID: session.id) } label: {
                    Label { Text(verbatim: LAACopy.paneOpenRight) } icon: { Image(systemName: "rectangle.split.2x1") }
                }
                .disabled(!panes.canSplit)
                Button { _ = panes.split(edge: .bottom, sessionID: session.id) } label: {
                    Label { Text(verbatim: LAACopy.paneOpenBelow) } icon: { Image(systemName: "rectangle.split.1x2") }
                }
                .disabled(!panes.canSplit)
                Divider()
            }
            #endif
            Button { Task { await update(session, favorite: !session.isFavorite) } } label: {
                Label { Text(verbatim: session.isFavorite ? "ピンを外す" : "ピン留め") } icon: { Image(systemName: "pin") }
            }
            Button { Task { await update(session, archived: !session.isArchived) } } label: {
                Label { Text(verbatim: session.isArchived ? "戻す" : "アーカイブ") } icon: { Image(systemName: "archivebox") }
            }
        }
        .accessibilityAddTraits(selectedID == session.id ? .isSelected : [])
        .accessibilityIdentifier("work.session.\(session.id)")
    }

    private func rowBackground(_ id: String) -> Color {
        if selectedID == id { return LAAColor.selectionFill }
        if hoveredID == id { return LAAColor.subtleSurface }
        return .clear
    }

    /// With more than one pane, a row that is on screen carries its pane's
    /// number, the same number the pane's heading shows.
    private func paneBadge(_ id: String) -> LAAWorkPaneBadge.Value? {
        #if targetEnvironment(macCatalyst)
        guard panes.panes.count > 1, let pane = panes.pane(showing: id), let number = panes.number(of: pane.id) else { return nil }
        return .init(number: number, focused: pane.id == panes.focusedID)
        #else
        return nil
        #endif
    }

    private func move(_ delta: Int) {
        let ids = ordered.map(\.id)
        let index = selectedID.flatMap { ids.firstIndex(of: $0) }
        if let next = LAAWorkDesktopList.next(current: index, count: ids.count, delta: delta) { select(ids[next]) }
    }

    @MainActor private func load() async {
        guard bridge.status == .paired else { return }
        loading = true
        defer { loading = false; hasLoaded = true }
        do {
            let query = showArchived ? [URLQueryItem(name: "archived", value: "only")] : []
            async let page: [LAAWorkSession] = LAAWorkPaging.all(bridge, "/v1/sessions", query: query)
            async let projectPage: [LAAWorkProject] = LAAWorkPaging.all(bridge, "/v1/projects")
            let (loaded, loadedProjects) = try await (page, projectPage)
            guard !Task.isCancelled else { return }
            sessions = loaded.filter { $0.isArchived == showArchived }
            LAAWorkSessionCache.save(sessions, store: drafts, device: bridge.deviceID, target: showArchived ? "archived" : "list")
            projects = loadedProjects
            failure = nil
            #if targetEnvironment(macCatalyst)
            knownIDs.formUnion(sessions.map(\.id))
            // A saved pane from another Bridge, or a session that is gone,
            // empties rather than showing a failure. Archived sessions the
            // owner opened stay: they were listed.
            if !showArchived { panes.forget(sessionsNotIn: knownIDs) }
            // As the one detail column did: an area with nothing open shows
            // the first session rather than an empty page.
            if panes.panes.allSatisfy({ $0.sessionID == nil }), let first = sessions.first?.id { panes.open(first) }
            #else
            if selectedID == nil || !sessions.contains(where: { $0.id == selectedID }) { selectedID = sessions.first?.id }
            #endif
        } catch is CancellationError {
            return
        } catch let error as LAABridgeError {
            failure = error.japaneseText
        } catch {
            failure = LAACopy.macSessionsUnreadable
        }
        if options == nil { options = try? await bridge.read("/v1/session-options") }
    }

    @MainActor private func update(_ session: LAAWorkSession, favorite: Bool? = nil, archived: Bool? = nil) async {
        struct Change: Encodable { let favorite: Bool?; let archived: Bool? }
        guard let body = try? JSONEncoder().encode(Change(favorite: favorite, archived: archived)) else { return }
        do {
            let updated: LAAWorkSession = try await LAAWorkHTTP.write(bridge, path: "/v1/sessions/\(session.id)", body: body,
                                                                     key: LAABridgeIdempotencyKey(), method: "PATCH")
            if updated.isArchived != showArchived { sessions.removeAll { $0.id == updated.id } }
            else if let index = sessions.firstIndex(where: { $0.id == updated.id }) { sessions[index] = updated }
            failure = nil
            // Archiving takes the children along.
            if archived != nil { reloadID += 1 }
        } catch let error as LAABridgeHTTPError {
            failure = LAAWorkHTTP.message(error)
        } catch {
            failure = "変更を保存できません。"
        }
    }
}

/// Work › Projects on the Mac.
struct LAAWorkDesktopProjectsView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @ObservedObject var drafts: ComposerDraftStore
    let refreshID: Int
    @State private var projects: [LAAWorkProject] = []
    @State private var search = ""
    @State private var selectedID: String?
    @State private var hoveredID: String?
    @State private var failure: String?
    @State private var loading = false
    @State private var showNew = false
    @State private var reloadID = 0
    @State private var showArchived = false
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    private var visible: [LAAWorkProject] {
        projects.filter { LAAWorkRef.matches(search, ref: $0.ref, text: [$0.name]) }
    }
    private var selected: LAAWorkProject? { projects.first { $0.id == selectedID } }

    var body: some View {
        LAAMacListDetail {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: LAASpacing.x3) {
                    HStack {
                        Button { showNew = true } label: {
                            Label {
                                    Text(verbatim: "新しいプロジェクト").foregroundStyle(LAAColor.filledButtonText)
                                } icon: {
                                    Image(systemName: "plus").foregroundStyle(LAAColor.filledButtonText)
                                }
                                .laaTextStyle(.secondary).fontWeight(.semibold)
                                .frame(minHeight: LAASpacing.minimumTouchTarget)
                        }
                        .buttonStyle(.plain)
                        .background(LAAColor.filledButton, in: Capsule())
                        .accessibilityIdentifier("work.projects.new")
                        Spacer(minLength: 0)
                        Button { reloadID += 1 } label: { Image(systemName: "arrow.clockwise") }
                            .frame(width: LAASpacing.minimumTouchTarget, height: LAASpacing.minimumTouchTarget)
                            .accessibilityLabel(Text(verbatim: "プロジェクトを再読込み"))
                            .macTooltip("Reload (⌘R)")
                    }
                    LAASearchField(placeholder: "検索", text: $search,
                                   identifier: "work.projects.desktop.search", focus: $searchFocused)
                    if let failure { Text(verbatim: failure).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention) }
                    if loading && projects.isEmpty { LAALoadingDots() }
                }
                .padding(LAASpacing.x3)
                Rectangle().fill(LAAColor.separator).frame(height: 1)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { project in
                            Button { selectedID = project.id } label: {
                                HStack(spacing: LAASpacing.x3) {
                                    Image(systemName: "folder").foregroundStyle(LAAColor.link).frame(width: 22)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x2) {
                                            LAAWorkRefLabel(ref: project.ref)
                                            Text(verbatim: project.name).laaTextStyle(.body).fontWeight(.semibold)
                                                .foregroundStyle(LAAColor.text).lineLimit(1)
                                        }
                                        Text(verbatim: summary(project)).laaTextStyle(.secondary)
                                            .foregroundStyle(LAAColor.secondaryText).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, LAASpacing.x4)
                                .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
                                .background(rowBackground(project.id), in: RoundedRectangle(cornerRadius: LAARadius.card))
                            }
                            .buttonStyle(.plain)
                            .onHover { hoveredID = $0 ? project.id : (hoveredID == project.id ? nil : hoveredID) }
                            .contextMenu {
                                Button { Task { await setArchived(project) } } label: {
                                    Label { Text(verbatim: project.isArchived ? "戻す" : "アーカイブ") } icon: { Image(systemName: "archivebox") }
                                }
                            }
                            .accessibilityAddTraits(selectedID == project.id ? .isSelected : [])
                            .accessibilityIdentifier("work.project.\(project.id)")
                        }
                        if visible.isEmpty && !loading && failure == nil {
                            Text(verbatim: showArchived ? LAACopy.macNoArchivedProjects : LAACopy.macNoProjects)
                                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                                .padding(LAASpacing.x4)
                        }
                        Button {
                            showArchived.toggle()
                        } label: {
                            Label { Text(verbatim: showArchived ? "プロジェクトへ戻る" : "アーカイブを表示") }
                                icon: { Image(systemName: showArchived ? "arrow.uturn.left" : "archivebox") }
                                .laaTextStyle(.secondary).foregroundStyle(LAAColor.link)
                                .frame(minHeight: LAASpacing.minimumTouchTarget)
                                .padding(.horizontal, LAASpacing.x3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("work.projects.archiveToggle")
                    }
                }
            }
            .background(LAAColor.background)
            .focusable()
            .focused($listFocused)
            .onAppear { listFocused = true }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.escape) { selectedID = nil; return .handled }
            .laaMacSectionCommands(LAAMacSectionCommands(
                newTitle: "新しいプロジェクト",
                canCreate: bridge.status == .paired,
                create: { showNew = true },
                canSearch: true,
                focusSearch: { searchFocused = true },
                canReload: true,
                reload: { reloadID += 1 }
            ))
        } detail: {
            if let selected {
                NavigationStack {
                    LAAWorkProjectHome(project: selected, drafts: drafts).id(selected.id)
                }
            } else {
                LAAMacEmptyDetail(symbol: "folder", title: LAACopy.macNoProjectTitle)
            }
        }
        .accessibilityIdentifier("work.desktop.projects")
        .sheet(isPresented: $showNew, onDismiss: { reloadID += 1 }) {
            LAAWorkProjectEditor(project: nil, canEditInstructions: true, drafts: drafts)
                .environmentObject(bridge)
                .laaSheetSize(.form)
        }
        .task(id: "\(bridge.revision)-\(refreshID)-\(reloadID)-\(showArchived)") { await load() }
    }

    private func summary(_ project: LAAWorkProject) -> String {
        let instructions = (project.instructionHash ?? "").isEmpty ? "指示なし" : "指示あり"
        let files = (project.fileCount ?? 0) > 0 ? "資料 \(project.fileCount ?? 0)" : "資料なし"
        return [instructions, files, LAAWorkSessionStyle.relative(project.updatedAt ?? "")].compactMap { $0 }.joined(separator: " · ")
    }

    private func rowBackground(_ id: String) -> Color {
        if selectedID == id { return LAAColor.selectionFill }
        if hoveredID == id { return LAAColor.subtleSurface }
        return .clear
    }

    private func move(_ delta: Int) {
        let ids = visible.map(\.id)
        let index = selectedID.flatMap { ids.firstIndex(of: $0) }
        if let next = LAAWorkDesktopList.next(current: index, count: ids.count, delta: delta) { selectedID = ids[next] }
    }

    @MainActor private func load() async {
        guard bridge.status == .paired else { return }
        loading = true
        defer { loading = false }
        do {
            let query = showArchived ? [URLQueryItem(name: "archived", value: "only")] : []
            let loaded: [LAAWorkProject] = try await LAAWorkPaging.all(bridge, "/v1/projects", query: query)
            guard !Task.isCancelled else { return }
            projects = loaded; failure = nil
            if selectedID == nil || !projects.contains(where: { $0.id == selectedID }) { selectedID = projects.first?.id }
        } catch is CancellationError {
            return
        } catch {
            failure = LAACopy.macProjectsUnreadable
        }
    }

    @MainActor private func setArchived(_ project: LAAWorkProject) async {
        do {
            try await LAAWorkHTTP.setProjectArchived(project, archived: !project.isArchived, bridge: bridge)
            reloadID += 1
        } catch let error as LAABridgeHTTPError {
            failure = LAAWorkHTTP.message(error)
        } catch {
            failure = "変更を保存できません。"
        }
    }
}

/// Work › Routines and Skills on the Mac.
struct LAAWorkDesktopCatalogView: View {
    enum Kind { case routines, skills }
    let kind: Kind
    @EnvironmentObject private var bridge: LAABridgeSession
    @StateObject private var cache: ComposerDraftStore
    @State private var cacheDevice: String?

    @MainActor init(kind: Kind) {
        self.kind = kind
        let name = kind == .routines ? "routines" : "skills"
        _cache = StateObject(wrappedValue: LAAWorkDrafts.makeStore(fileURL: LAAWorkDrafts.fileURL.deletingLastPathComponent().appendingPathComponent("catalog-" + name + "-cache-v1.json")))
    }
    @State private var routines: [LAAWorkRoutine] = []
    @State private var skills: [LAAWorkSkill] = []
    @State private var search = ""
    @State private var selectedID: String?
    @State private var hoveredID: String?
    @State private var loading = false
    @State private var loaded = false
    @State private var failure: String?
    @State private var reloadID = 0
    /// As on the phone: a partial or old read is said, not shown as complete.
    @State private var skipped = 0
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    private struct CatalogRow: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let group: String
        let ref: String?
        var service = false
        var status: LAAWorkStatus? = nil
    }

    private var rows: [CatalogRow] {
        if kind == .routines {
            let scheduled = routines.filter { $0.triggerKind == nil || $0.triggerKind == "scheduled" }
                .filter { LAAWorkRef.matches(search, ref: $0.ref, text: [$0.name, $0.destination ?? "", $0.schedule ?? ""]) }
            // The phone's day order: grouped by part of the day, by the clock
            // inside each part, with the last result's mark on every row.
            var band = ""
            var result: [CatalogRow] = []
            for entry in LAAWorkRoutineTree.entries(scheduled) {
                switch entry {
                case .band(let value): band = value.title
                case .routine(let routine, let clock):
                    result.append(CatalogRow(id: routine.id, title: [clock, routine.name].compactMap { $0 }.joined(separator: "  "),
                                             subtitle: [routine.destination, "次回 " + LAAWorkRoutineTime.next(routine.nextRunAt)].compactMap { $0 }.joined(separator: " · "),
                                             group: band, ref: routine.ref, status: LAAWorkStatus.routine(routine)))
                }
            }
            // Always-on and manual services have no schedule to place them by;
            // the phone lists them under their own note, so the Mac does too.
            let services = self.services
            if !services.isEmpty {
                let title = "常駐・手動・時刻未確認（\(services.count)）"
                result += services.map { routine in
                    CatalogRow(id: routine.id, title: routine.name,
                               subtitle: "次回 \(LAAWorkRoutineTime.next(routine.nextRunAt))",
                               group: title, ref: routine.ref, service: true, status: LAAWorkStatus.routine(routine))
                }
            }
            return result
        }
        var seen = Set<String>()
        return skills.filter { seen.insert($0.name).inserted }
            .filter { LAAWorkRef.matches(search, ref: $0.ref, text: [$0.name, $0.explanation]) }
            .sorted { $0.name < $1.name }
            .map { CatalogRow(id: $0.id, title: $0.name,
                              subtitle: $0.explanation.isEmpty ? "説明はありません" : $0.explanation, group: "", ref: $0.ref) }
    }

    private var services: [LAAWorkRoutine] {
        routines.filter { $0.triggerKind != nil && $0.triggerKind != "scheduled" }
            .filter { LAAWorkRef.matches(search, ref: $0.ref, text: [$0.name, $0.destination ?? "", $0.schedule ?? ""]) }
    }

    var body: some View {
        LAAMacListDetail {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: LAASpacing.x3) {
                    HStack {
                        Text(verbatim: kind == .routines ? "Routines" : "スキル")
                            .laaTextStyle(.section).fontWeight(.semibold).foregroundStyle(LAAColor.secondaryText)
                        Spacer()
                        Menu { Button(String("再読込")) { reloadID += 1 } } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                            .accessibilityLabel(String("一覧の表示"))
                    }
                    LAASearchField(placeholder: kind == .routines ? "検索" : "検索", text: $search,
                                   identifier: "work.\(kind == .routines ? "routines" : "skills").desktop.search",
                                   focus: $searchFocused)
                    if let failure { Text(verbatim: failure).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention) }
                    if kind == .routines, skipped > 0 {
                        Text(verbatim: "一部（\(skipped)件）を読み取れませんでした。表示は前回の内容です。")
                            .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                            .accessibilityIdentifier("work.routines.partial")
                    }
                    if loading && !loaded { LAALoadingDots() }
                }
                .padding(LAASpacing.x3)
                Rectangle().fill(LAAColor.separator).frame(height: 1)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            if !row.group.isEmpty, rows.first(where: { $0.group == row.group })?.id == row.id {
                                Text(verbatim: row.group).laaTextStyle(.section).fontWeight(.semibold)
                                    .foregroundStyle(LAAColor.secondaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, LAASpacing.x4)
                                    .padding(.top, LAASpacing.x3)
                                    .accessibilityIdentifier(row.service ? "work.routines.services" : "work.desktop.routines.group")
                            }
                            Button { selectedID = row.id } label: {
                                HStack(alignment: .top, spacing: LAASpacing.x3) {
                                    if let status = row.status { LAAWorkStatusMark(status: status) }
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x2) {
                                            LAAWorkRefLabel(ref: row.ref)
                                            Text(verbatim: row.title).laaTextStyle(.body).fontWeight(.medium)
                                                .foregroundStyle(LAAColor.text).lineLimit(1)
                                        }
                                        Text(verbatim: row.subtitle).laaTextStyle(.secondary)
                                            .foregroundStyle(LAAColor.secondaryText).lineLimit(2)
                                    }
                                }
                                .padding(.vertical, LAASpacing.x2)
                                .padding(.horizontal, LAASpacing.x4)
                                .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
                                .background(rowBackground(row.id), in: RoundedRectangle(cornerRadius: LAARadius.card))
                            }
                            .buttonStyle(.plain)
                            .onHover { hoveredID = $0 ? row.id : (hoveredID == row.id ? nil : hoveredID) }
                            .accessibilityAddTraits(selectedID == row.id ? .isSelected : [])
                        }
                        if loaded && rows.isEmpty && failure == nil {
                            Text(verbatim: kind == .routines ? LAACopy.macNoRoutines : LAACopy.macNoSkills)
                                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                                .padding(LAASpacing.x4)
                        }
                    }
                }
            }
            .background(LAAColor.background)
            .focusable()
            .focused($listFocused)
            .onAppear { listFocused = true }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.escape) { selectedID = nil; return .handled }
            .laaMacSectionCommands(LAAMacSectionCommands(
                newTitle: kind == .routines ? "新しい定期実行" : "新しいスキル",
                canCreate: false,
                canSearch: true,
                focusSearch: { searchFocused = true },
                canReload: true,
                reload: { reloadID += 1 }
            ))
        } detail: {
            detail
        }
        .accessibilityIdentifier(kind == .routines ? "work.desktop.routines" : "work.desktop.skills")
        .task(id: "\(bridge.revision)-\(kind == .routines)-\(reloadID)") { await load() }
    }

    @ViewBuilder private var detail: some View {
        if kind == .routines, let routine = routines.first(where: { $0.id == selectedID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: LAASpacing.x4) {
                    LAAWorkRefLabel(ref: routine.ref)
                    Text(verbatim: routine.name).font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
                    Text(verbatim: routine.schedule ?? LAACopy.macScheduleUnknown).foregroundStyle(LAAColor.link)
                    VStack(alignment: .leading, spacing: LAASpacing.x2) {
                        detailLine("次回", LAAWorkRoutineTime.next(routine.nextRunAt))
                        detailLine("担当", routine.destination ?? "未設定")
                        detailLine("状態", stateLabel(routine.state))
                        detailLine("前回", routine.previousRunSummary())
                        if routine.runId != nil || routine.reasonCode != nil {
                            DisclosureGroup("実行の記録") {
                                detailLine("予定", LAAWorkRoutine.recordedTime(routine.expectedRunAt ?? routine.scheduledAt))
                                detailLine("開始", LAAWorkRoutine.recordedTime(routine.startedAt))
                                detailLine("終了", LAAWorkRoutine.recordedTime(routine.finishedAt))
                                detailLine("チャット受付", LAAWorkRoutine.recordedTime(routine.notificationAcceptedAt))
                                detailLine("送信", LAAWorkRoutine.recordedTime(routine.notificationSentAt))
                                detailLine("端末受信", LAAWorkRoutine.recordedTime(routine.notificationReceivedAt))
                            }
                        }
                    }.workCard()
                }
                .padding(LAASpacing.x6).laaReadableWidth()
            }
            .background(LAAColor.background)
        } else if kind == .skills, let skill = skills.first(where: { $0.id == selectedID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: LAASpacing.x4) {
                    LAAWorkRefLabel(ref: skill.ref)
                    Text(verbatim: skill.name).font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
                    Text(verbatim: skill.group).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    Text(verbatim: skill.explanation.isEmpty ? "説明はありません" : skill.explanation).workCard()
                    if let body = skill.detail, !body.isEmpty, body != skill.explanation {
                        Text(verbatim: body).workCard()
                    }
                }
                .padding(LAASpacing.x6).laaReadableWidth()
            }
            .background(LAAColor.background)
        } else {
            LAAMacEmptyDetail(symbol: kind == .routines ? "clock" : "sparkles",
                              title: kind == .routines ? LAACopy.macNoRoutineTitle : LAACopy.macNoSkillTitle)
        }
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(verbatim: label).foregroundStyle(LAAColor.secondaryText)
            Spacer(minLength: LAASpacing.x3)
            Text(verbatim: value).multilineTextAlignment(.trailing)
        }
    }

    private func stateLabel(_ value: String?) -> String {
        switch value {
        case "running": "実行中"
        case "paused": "一時停止"
        case "error": "要確認"
        case "scheduled": "実行待ち"
        default: "未確認"
        }
    }

    private func rowBackground(_ id: String) -> Color {
        if selectedID == id { return LAAColor.selectionFill }
        if hoveredID == id { return LAAColor.subtleSurface }
        return .clear
    }

    private func move(_ delta: Int) {
        let ids = rows.map(\.id)
        let index = selectedID.flatMap { ids.firstIndex(of: $0) }
        if let next = LAAWorkDesktopList.next(current: index, count: ids.count, delta: delta) { selectedID = ids[next] }
    }

    @MainActor private func load() async {
        if cacheDevice != bridge.deviceID {
            cacheDevice = bridge.deviceID
            routines = LAAWorkSessionCache.read([LAAWorkRoutine].self, store: cache, device: cacheDevice, target: "routines") ?? []
            skills = LAAWorkSessionCache.read([LAAWorkSkill].self, store: cache, device: cacheDevice, target: "skills") ?? []
            loaded = kind == .routines ? !routines.isEmpty : !skills.isEmpty
        }
        guard bridge.status == .paired else { return }
        loading = true
        defer { loading = false }
        do {
            if kind == .routines {
                let page: LAAWorkPage<LAAWorkRoutine> = try await bridge.read("/v1/routines")
                guard !Task.isCancelled else { return }
                routines = page.items
                LAAWorkSessionCache.save(routines, store: cache, device: cacheDevice, target: "routines")
                skipped = max(0, page.skipped ?? 0)
            } else {
                let page: LAAWorkPage<LAAWorkSkill> = try await bridge.read("/v1/skills")
                guard !Task.isCancelled else { return }
                skills = page.items
                LAAWorkSessionCache.save(skills, store: cache, device: cacheDevice, target: "skills")
            }
            loaded = true; failure = nil
            if selectedID == nil || !rows.contains(where: { $0.id == selectedID }) { selectedID = rows.first?.id }
        } catch is CancellationError {
            return
        } catch {
            failure = LAACopy.macListUnreadable
        }
    }
}
#endif
