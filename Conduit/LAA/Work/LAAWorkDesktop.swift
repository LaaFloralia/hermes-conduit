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
    @State private var engineDown = false
    @State private var loading = false
    @State private var hasLoaded = false
    @State private var showLauncher = false
    @State private var reloadID = 0
    @State private var expanded = Set<String>()
    @State private var projectOrder = false
    @State private var editingProject: LAAWorkProject?
    @State private var archivePrompt: LAAWorkArchivePrompt?
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
                        Text(verbatim: "Sessions").laaTextStyle(.section).foregroundStyle(LAAColor.secondaryText)
                        Spacer()
                        Menu {
                            Button { projectOrder = false } label: { Text(verbatim: "Recent First") }
                            Button { projectOrder = true } label: { Text(verbatim: "By Project") }
                            Button { showArchived.toggle(); reloadID += 1 } label: {
                                Text(verbatim: showArchived ? "Recent" : "Archived")
                            }
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                        .accessibilityLabel(String("List View")).accessibilityIdentifier("work.sessions.menu")
                    }
                    LAASearchField(placeholder: "Search", text: $search,
                                   identifier: "work.sessions.desktop.search", focus: $searchFocused)
                        .accessibilityIdentifier("work.sessions.search")
                    // Only running Sessions are 実行中; the rest wait (BUS-508).
                    if !showArchived && hasLoaded { LAAWorkSessionTallyLine(tally: LAAWorkSessionTally(sessions: sessions)) }
                    if let failure {
                        LAAWorkFailure(text: failure) { Task { await load() } }
                    }
                    if engineDown && failure == nil { LAAWorkEngineDownLine() }
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
                                Text(verbatim: project?.name ?? "No Project")
                                    .laaTextStyle(.section).foregroundStyle(LAAColor.secondaryText)
                                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .contextMenu {
                                        if let project {
                                            Button(String("Edit")) { editingProject = project }
                                            Button(String("Archive")) {
                                                archivePrompt = .project(project) {
                                                    Task {
                                                        do { try await LAAWorkHTTP.setProjectArchived(project, archived: true, bridge: bridge) }
                                                        catch { archivePrompt = .refused(error) }
                                                        reloadID += 1
                                                    }
                                                }
                                            }
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
                newTitle: "New Session",
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
                    LAAWorkSessionDetail(id: selected.id, projects: projects, workspaces: [], drafts: drafts, seed: selected)
                        .id(selected.id)
                }
            } else {
                LAAMacEmptyDetail(symbol: "rectangle.stack", title: LAACopy.macNoSessionTitle)
            }
            #endif
        }
        .accessibilityIdentifier("work.desktop.sessions")
        .laaWorkArchivePrompt($archivePrompt)
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
            // The phone's list re-reads every five seconds. Without the same
            // here a row kept its old state, model and time for as long as
            // the window stayed open.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await load()
            }
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
                Label { Text(verbatim: session.isFavorite ? LAACopy.WorkTab.unpin : LAACopy.WorkTab.pin) } icon: { Image(systemName: "pin") }
            }
            Button {
                if session.isArchived { Task { await update(session, archived: false) } }
                else { archivePrompt = .session(session) { Task { await update(session, archived: true) } } }
            } label: {
                Label { Text(verbatim: session.isArchived ? LAACopy.WorkTab.unarchive : LAACopy.WorkTab.archive) } icon: { Image(systemName: "archivebox") }
            }
            LAAWorkProjectMoveMenu(session: session, projects: projects) { project in
                Task { await move(session, to: project) }
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
            async let page: (items: [LAAWorkSession], engineDown: Bool) = LAAWorkPaging.pages(bridge, "/v1/sessions", query: query)
            async let projectPage: [LAAWorkProject] = LAAWorkPaging.all(bridge, "/v1/projects")
            let (read, loadedProjects) = try await (page, projectPage)
            guard !Task.isCancelled else { return }
            let loaded = read.items
            engineDown = read.engineDown
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

    /// Moves the Session (and its children, on the Bridge) to another project.
    @MainActor private func move(_ session: LAAWorkSession, to project: LAAWorkProject) async {
        do {
            let updated = try await LAAWorkSessionProjects.move(session, to: project, bridge: bridge)
            if let index = sessions.firstIndex(where: { $0.id == updated.id }) { sessions[index] = updated }
            failure = nil
            reloadID += 1
        } catch {
            failure = LAAWorkSessionProjects.failure(error)
        }
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
            // A refused archive changes nothing; say why in full.
            if archived == true { archivePrompt = .refused(error); return }
            failure = LAAWorkHTTP.message(error)
        } catch {
            if archived == true { archivePrompt = .refused(error); return }
            failure = "変更を保存できません。"
        }
    }
}

/// Work › Projects on the Mac.
struct LAAWorkDesktopProjectsView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @ObservedObject var drafts: ComposerDraftStore
    let refreshID: Int
    @Binding var linkedProject: String?

    init(drafts: ComposerDraftStore, refreshID: Int, linkedProject: Binding<String?> = .constant(nil)) {
        self.drafts = drafts; self.refreshID = refreshID
        _linkedProject = linkedProject
    }

    @State private var projects: [LAAWorkProject] = []
    /// Only for the rows' marks of work running or waiting for the owner.
    @State private var sessions: [LAAWorkSession] = []
    @State private var hasLoaded = false
    @State private var search = ""
    @State private var selectedID: String?
    @State private var hoveredID: String?
    @State private var failure: String?
    @State private var loading = false
    @State private var showNew = false
    @State private var reloadID = 0
    @State private var showArchived = false
    @State private var archivePrompt: LAAWorkArchivePrompt?
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
                                    Text(verbatim: "New Project").foregroundStyle(LAAColor.filledButtonText)
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
                            .accessibilityLabel(Text(verbatim: "Reload Project"))
                            .macTooltip("Reload (⌘R)")
                    }
                    LAASearchField(placeholder: "Search", text: $search,
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
                                LAAWorkProjectRow(project: project,
                                                  activity: project.isArchived ? .idle : LAAWorkProjectActivity.of(project.id, sessions: sessions))
                                    .background(rowBackground(project.id), in: RoundedRectangle(cornerRadius: LAARadius.card))
                            }
                            .buttonStyle(.plain)
                            .onHover { hoveredID = $0 ? project.id : (hoveredID == project.id ? nil : hoveredID) }
                            .contextMenu {
                                Button {
                                    if project.isArchived { Task { await setArchived(project) } }
                                    else { archivePrompt = .project(project) { Task { await setArchived(project) } } }
                                } label: {
                                    Label { Text(verbatim: project.isArchived ? LAACopy.WorkTab.unarchive : LAACopy.WorkTab.archive) } icon: { Image(systemName: "archivebox") }
                                }
                            }
                            .accessibilityAddTraits(selectedID == project.id ? .isSelected : [])
                            .accessibilityIdentifier("work.project.\(project.id)")
                        }
                        if visible.isEmpty && (hasLoaded || !loading) && failure == nil {
                            Text(verbatim: showArchived ? LAACopy.macNoArchivedProjects : LAACopy.macNoProjects)
                                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                                .padding(LAASpacing.x4)
                        }
                        Button {
                            showArchived.toggle()
                        } label: {
                            Label { Text(verbatim: showArchived ? "Back" : "Archived") }
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
                newTitle: "New Project",
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
                        .onAppear { LAAWorkSessionProjects.noteOpened(selected.id) }
                }
            } else {
                LAAMacEmptyDetail(symbol: "folder", title: LAACopy.macNoProjectTitle)
            }
        }
        .accessibilityIdentifier("work.desktop.projects")
        .laaWorkArchivePrompt($archivePrompt)
        .sheet(isPresented: $showNew, onDismiss: { reloadID += 1 }) {
            LAAWorkProjectEditor(project: nil, canEditInstructions: true, drafts: drafts)
                .environmentObject(bridge)
                .laaSheetSize(.form)
        }
        .task(id: "\(bridge.revision)-\(linkedProject ?? "")") {
            guard let id = linkedProject, bridge.status == .paired else { return }
            do {
                let project: LAAWorkProject = try await bridge.read("/v1/projects/\(id)")
                guard !Task.isCancelled, linkedProject == id else { return }
                showArchived = project.isArchived
                search = ""
                if !projects.contains(where: { $0.id == id }) { projects.insert(project, at: 0) }
                selectedID = id
                linkedProject = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, linkedProject == id else { return }
                linkedProject = nil
                failure = (error as? LAABridgeError)?.japaneseText ?? "プロジェクトを開けませんでした。"
            }
        }
        // The phone's interval: the Mac list had no re-read of its own
        // (PROJECT-RULES: both lists are checked).
        .task(id: "\(bridge.revision)-\(refreshID)-\(reloadID)-\(showArchived)") {
            await load()
            while !Task.isCancelled {
                do { try await Task.sleep(for: LAAWorkProjectHome.interval) } catch { return }
                await load()
            }
        }
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
            let archived = showArchived
            let query = archived ? [URLQueryItem(name: "archived", value: "only")] : []
            let loaded: [LAAWorkProject] = try await LAAWorkPaging.all(bridge, "/v1/projects", query: query)
            guard !Task.isCancelled, showArchived == archived else { return }
            projects = loaded; failure = nil; hasLoaded = true
            if !showArchived, let rows: [LAAWorkSession] = try? await LAAWorkPaging.all(bridge, "/v1/sessions") {
                sessions = rows
            }
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
            if !project.isArchived { archivePrompt = .refused(error); return }
            failure = LAAWorkHTTP.message(error)
        } catch {
            if !project.isArchived { archivePrompt = .refused(error); return }
            failure = "変更を保存できません。"
        }
    }
}
#endif
