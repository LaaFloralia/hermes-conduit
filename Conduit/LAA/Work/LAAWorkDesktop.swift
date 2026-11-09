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
    @State private var sessions: [LAAWorkSession] = []
    @State private var projects: [LAAWorkProject] = []
    @State private var options: LAAWorkSessionOptions?
    @State private var search = ""
    @State private var showArchived = false
    @State private var selectedID: String?
    @State private var hoveredID: String?
    @State private var failure: String?
    @State private var loading = false
    @State private var showLauncher = false
    @State private var reloadID = 0
    @State private var expanded = Set<String>()
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    private var searching: Bool { !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var filtered: [LAAWorkSession] {
        sessions.filter {
            LAAWorkRef.matches(search, ref: $0.ref, text: [$0.name, $0.observed?.model ?? $0.requested?.model ?? ""])
        }
    }

    private var ordered: [LAAWorkSession] {
        let rows = LAAWorkSessionOrder.rows(filtered)
        return searching ? rows.pinned + rows.recent : LAAWorkSessionOrder.visible(rows.pinned + rows.recent, expanded: expanded)
    }

    private var selected: LAAWorkSession? { sessions.first { $0.id == selectedID } }

    var body: some View {
        LAAMacListDetail {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: LAASpacing.x3) {
                    HStack(spacing: LAASpacing.x2) {
                        Button { showLauncher = true } label: {
                            Label {
                                    Text(verbatim: "New session").foregroundStyle(LAAColor.filledButtonText)
                                } icon: {
                                    Image(systemName: "plus").foregroundStyle(LAAColor.filledButtonText)
                                }
                                .laaTextStyle(.secondary).fontWeight(.semibold)
                                .frame(minHeight: LAASpacing.minimumTouchTarget)
                        }
                        .buttonStyle(.plain)
                        .background(LAAColor.filledButton, in: Capsule())
                        .accessibilityIdentifier("work.sessions.new")
                        .macTooltip("Start a new session")
                        Spacer(minLength: 0)
                        Button { reloadID += 1 } label: { Image(systemName: "arrow.clockwise") }
                            .frame(width: LAASpacing.minimumTouchTarget, height: LAASpacing.minimumTouchTarget)
                            .accessibilityLabel(Text(verbatim: "Reload sessions"))
                            .macTooltip("Reload (⌘R)")
                    }
                    LAASearchField(placeholder: "Search sessions", text: $search,
                                   identifier: "work.sessions.desktop.search", focus: $searchFocused)
                        .accessibilityIdentifier("work.sessions.search")
                    if let failure {
                        Text(verbatim: failure).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                    }
                    if loading && sessions.isEmpty { ProgressView().controlSize(.small) }
                }
                .padding(LAASpacing.x3)
                Rectangle().fill(LAAColor.separator).frame(height: 1)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let ordered = self.ordered
                        let children = LAAWorkSessionOrder.descendants(filtered)
                        ForEach(Array(ordered.enumerated()), id: \.element.id) { index, session in
                            if index == 0 || ordered[index - 1].isFavorite != session.isFavorite {
                                Text(verbatim: session.isFavorite ? "PINNED" : "RECENT")
                                    .laaTextStyle(.section).fontWeight(.semibold)
                                    .foregroundStyle(LAAColor.secondaryText)
                                    .padding(.horizontal, LAASpacing.x3).padding(.top, LAASpacing.x3).padding(.bottom, LAASpacing.x1)
                            }
                            sessionRow(session, children: children[session.id] ?? [], in: ordered)
                        }
                        if ordered.isEmpty && !loading && failure == nil {
                            Text(verbatim: showArchived ? LAACopy.macNoArchivedSessions : LAACopy.macNoSessions)
                                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                                .padding(LAASpacing.x4)
                        }
                        Button {
                            showArchived.toggle(); reloadID += 1
                        } label: {
                            Label { Text(verbatim: showArchived ? "Back to recent" : "Show archive") }
                                icon: { Image(systemName: showArchived ? "arrow.uturn.left" : "archivebox") }
                                .laaTextStyle(.secondary).foregroundStyle(LAAColor.link)
                                .frame(minHeight: LAASpacing.minimumTouchTarget)
                                .padding(.horizontal, LAASpacing.x3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("work.sessions.archiveToggle")
                    }
                }
            }
            .background(LAAColor.background)
            .focusable()
            .focused($listFocused)
            .onAppear { listFocused = true }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.return) { if selectedID == nil { selectedID = ordered.first?.id }; return .handled }
            .onKeyPress(.escape) { selectedID = nil; return .handled }
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
            if let selected {
                NavigationStack {
                    LAAWorkSessionDetail(id: selected.id, projects: projects, workspaces: [], drafts: drafts)
                        .id(selected.id)
                }
            } else {
                LAAMacEmptyDetail(symbol: "rectangle.stack", title: LAACopy.macNoSessionTitle)
            }
        }
        .accessibilityIdentifier("work.desktop.sessions")
        .sheet(isPresented: $showLauncher, onDismiss: { reloadID += 1 }) {
            LAAWorkSessionLauncher(projects: projects, options: options, drafts: drafts) { created in
                showLauncher = false; selectedID = created.id; reloadID += 1
            }
            .environmentObject(bridge)
            .laaSheetSize(.form)
        }
        .task(id: "\(bridge.revision)-\(refreshID)-\(reloadID)-\(showArchived)") { await load() }
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
            selectedID = session.id
        } label: {
            LAAWorkSessionRow(session: session, projectName: projects.first { $0.id == session.projectId }?.name, options: options,
                              childNeedsDecision: !open && children.contains(where: \.needsDecision))
                .padding(.leading, CGFloat(LAAWorkSessionOrder.depth(session, in: rows)) * 16)
                .background(rowBackground(session.id), in: RoundedRectangle(cornerRadius: LAARadius.card))
        }
        .buttonStyle(.plain)
        .onHover { hoveredID = $0 ? session.id : (hoveredID == session.id ? nil : hoveredID) }
        .contextMenu {
            Button { Task { await update(session, favorite: !session.isFavorite) } } label: {
                Label { Text(verbatim: session.isFavorite ? "Unpin" : "Pin") } icon: { Image(systemName: "pin") }
            }
            Button { Task { await update(session, archived: !session.isArchived) } } label: {
                Label { Text(verbatim: session.isArchived ? "Restore" : "Archive") } icon: { Image(systemName: "archivebox") }
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

    private func move(_ delta: Int) {
        let ids = ordered.map(\.id)
        let index = selectedID.flatMap { ids.firstIndex(of: $0) }
        if let next = LAAWorkDesktopList.next(current: index, count: ids.count, delta: delta) { selectedID = ids[next] }
    }

    @MainActor private func load() async {
        guard bridge.status == .paired else { return }
        loading = true
        defer { loading = false }
        do {
            let query = showArchived ? [URLQueryItem(name: "archived", value: "only")] : []
            async let page: [LAAWorkSession] = LAAWorkPaging.all(bridge, "/v1/sessions", query: query)
            async let projectPage: [LAAWorkProject] = LAAWorkPaging.all(bridge, "/v1/projects")
            let (loaded, loadedProjects) = try await (page, projectPage)
            guard !Task.isCancelled else { return }
            sessions = loaded.filter { $0.isArchived == showArchived }
            projects = loadedProjects
            failure = nil
            if selectedID == nil || !sessions.contains(where: { $0.id == selectedID }) { selectedID = sessions.first?.id }
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
                                    Text(verbatim: "New project").foregroundStyle(LAAColor.filledButtonText)
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
                            .accessibilityLabel(Text(verbatim: "Reload projects"))
                            .macTooltip("Reload (⌘R)")
                    }
                    LAASearchField(placeholder: "Search projects", text: $search,
                                   identifier: "work.projects.desktop.search", focus: $searchFocused)
                    if let failure { Text(verbatim: failure).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention) }
                    if loading && projects.isEmpty { ProgressView().controlSize(.small) }
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
                                    Label { Text(verbatim: project.isArchived ? "Restore" : "Archive") } icon: { Image(systemName: "archivebox") }
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
                            Label { Text(verbatim: showArchived ? "Back to projects" : "Show archive") }
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
        let instructions = (project.instructionHash ?? "").isEmpty ? "No instructions" : "Instructions"
        let files = (project.fileCount ?? 0) > 0 ? "\(project.fileCount ?? 0) files" : "No files"
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
    @State private var fetchedAt: Date?
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    private struct CatalogRow: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let group: String
        let ref: String?
        var service = false
    }

    private var rows: [CatalogRow] {
        if kind == .routines {
            let scheduled = routines.filter { $0.triggerKind == nil || $0.triggerKind == "scheduled" }
                .filter { LAAWorkRef.matches(search, ref: $0.ref, text: [$0.name, $0.destination ?? "", $0.schedule ?? ""]) }
            var result = LAAWorkRoutineGrouping.groups(scheduled).flatMap { group in
                group.routines.map { routine in
                    CatalogRow(id: routine.id, title: routine.name,
                               subtitle: "Next \(LAAWorkRoutineTime.next(routine.nextRunAt)) · \(routine.schedule ?? "Schedule unknown")",
                               group: group.destination, ref: routine.ref)
                }
            }
            // Always-on and manual services have no schedule to place them by;
            // the phone lists them under their own note, so the Mac does too.
            let services = self.services
            if !services.isEmpty {
                let title = "常駐・手動・時刻未確認（\(services.count)）"
                result += services.map { routine in
                    CatalogRow(id: routine.id, title: routine.name,
                               subtitle: "Next \(LAAWorkRoutineTime.next(routine.nextRunAt)) · \(routine.schedule ?? "Schedule unknown")",
                               group: title, ref: routine.ref, service: true)
                }
            }
            return result
        }
        var seen = Set<String>()
        return skills.filter { seen.insert($0.name).inserted }
            .filter { LAAWorkRef.matches(search, ref: $0.ref, text: [$0.name, $0.explanation]) }
            .sorted { $0.name < $1.name }
            .map { CatalogRow(id: $0.id, title: $0.name,
                              subtitle: $0.explanation.isEmpty ? "No description" : $0.explanation, group: "", ref: $0.ref) }
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
                        Text(verbatim: kind == .routines ? "ROUTINES" : "SKILLS")
                            .laaTextStyle(.section).fontWeight(.semibold).foregroundStyle(LAAColor.secondaryText)
                        Spacer()
                        Button { reloadID += 1 } label: { Image(systemName: "arrow.clockwise") }
                            .frame(width: LAASpacing.minimumTouchTarget, height: LAASpacing.minimumTouchTarget)
                            .accessibilityLabel(Text(verbatim: "Reload"))
                            .macTooltip("Reload (⌘R)")
                    }
                    LAASearchField(placeholder: kind == .routines ? "Search routines" : "Search skills", text: $search,
                                   identifier: "work.\(kind == .routines ? "routines" : "skills").desktop.search",
                                   focus: $searchFocused)
                    if let failure { Text(verbatim: failure).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention) }
                    if kind == .routines, skipped > 0 {
                        Text(verbatim: "一部（\(skipped)件）を読み取れませんでした。表示は前回の内容です。")
                            .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                            .accessibilityIdentifier("work.routines.partial")
                    }
                    if kind == .routines, LAAWorkFreshness.isStale(fetchedAt) {
                        Text(verbatim: "最終取得 \(clock(fetchedAt))。最新ではない可能性があります。")
                            .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                            .accessibilityIdentifier("work.routines.fetchedAt")
                    }
                    if loading && !loaded { ProgressView().controlSize(.small) }
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
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x2) {
                                        LAAWorkRefLabel(ref: row.ref)
                                        Text(verbatim: row.title).laaTextStyle(.body).fontWeight(.semibold)
                                            .foregroundStyle(LAAColor.text).lineLimit(1)
                                    }
                                    Text(verbatim: row.subtitle).laaTextStyle(.secondary)
                                        .foregroundStyle(LAAColor.secondaryText).lineLimit(2)
                                }
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
                newTitle: kind == .routines ? "New Routine" : "New Skill",
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
                        detailLine("Next run", LAAWorkRoutineTime.next(routine.nextRunAt))
                        detailLine("Destination", routine.destination ?? "Not set")
                        detailLine("State", stateLabel(routine.state))
                        detailLine("Last run", routine.previousRunSummary())
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
                    Text(verbatim: skill.explanation.isEmpty ? "No description" : skill.explanation).workCard()
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
        case "running": "Running"
        case "paused": "Paused"
        case "error": "Needs attention"
        case "scheduled": "Scheduled"
        default: "Unknown"
        }
    }

    private func clock(_ date: Date?) -> String {
        guard let date else { return "時刻不明" }
        let parts = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
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
        guard bridge.status == .paired else { return }
        loading = true
        defer { loading = false }
        do {
            if kind == .routines {
                let page: LAAWorkPage<LAAWorkRoutine> = try await bridge.read("/v1/routines")
                guard !Task.isCancelled else { return }
                routines = page.items
                skipped = max(0, page.skipped ?? 0)
                fetchedAt = LAAWorkFreshness.date(page.fetchedAt)
            } else {
                let page: LAAWorkPage<LAAWorkSkill> = try await bridge.read("/v1/skills")
                guard !Task.isCancelled else { return }
                skills = page.items
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
