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
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    private var ordered: [LAAWorkSession] {
        let filtered = sessions.filter {
            LAAWorkDesktopList.matches($0.name + " " + ($0.observed?.model ?? $0.requested?.model ?? ""), query: search)
        }
        let rows = LAAWorkSessionOrder.rows(filtered)
        return rows.pinned + rows.recent
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
                    TextField("", text: $search, prompt: Text(verbatim: "Search sessions"))
                        .textFieldStyle(.roundedBorder)
                        .focused($searchFocused)
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
                        ForEach(Array(ordered.enumerated()), id: \.element.id) { index, session in
                            if index == 0 || ordered[index - 1].isFavorite != session.isFavorite {
                                Text(verbatim: session.isFavorite ? "PINNED" : "RECENT")
                                    .laaTextStyle(.section).fontWeight(.semibold)
                                    .foregroundStyle(LAAColor.secondaryText)
                                    .padding(.horizontal, LAASpacing.x3).padding(.top, LAASpacing.x3).padding(.bottom, LAASpacing.x1)
                            }
                            sessionRow(session)
                        }
                        if ordered.isEmpty && !loading && failure == nil {
                            Text(verbatim: showArchived ? "No archived sessions." : "No sessions yet.")
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
            .onKeyPress(.init("f"), phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                searchFocused = true; return .handled
            }
            .onKeyPress(.init("r"), phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                reloadID += 1; return .handled
            }
            .onKeyPress(.init("n"), phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                showLauncher = true; return .handled
            }
        } detail: {
            if let selected {
                NavigationStack {
                    LAAWorkSessionDetail(id: selected.id, projects: projects, workspaces: [], drafts: drafts)
                        .id(selected.id)
                }
            } else {
                LAAMacEmptyDetail(symbol: "rectangle.stack", title: "Select a session",
                                  message: "Choose a session on the left to read its conversation and continue it here.")
            }
        }
        .accessibilityIdentifier("work.desktop.sessions")
        .sheet(isPresented: $showLauncher, onDismiss: { reloadID += 1 }) {
            LAAWorkSessionLauncher(projects: projects, options: options, drafts: drafts) { created in
                showLauncher = false; selectedID = created.id; reloadID += 1
            }
            .environmentObject(bridge)
        }
        .task(id: "\(bridge.revision)-\(refreshID)-\(reloadID)-\(showArchived)") { await load() }
    }

    private func sessionRow(_ session: LAAWorkSession) -> some View {
        Button {
            selectedID = session.id
        } label: {
            LAAWorkSessionRow(session: session, projectName: projects.first { $0.id == session.projectId }?.name, options: options)
                .padding(.leading, CGFloat(LAAWorkSessionOrder.depth(session, in: ordered)) * 16)
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
            failure = "Could not read sessions."
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
        } catch {
            failure = "Could not save the change."
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
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    private var visible: [LAAWorkProject] {
        projects.filter { LAAWorkDesktopList.matches($0.name, query: search) }
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
                    TextField("", text: $search, prompt: Text(verbatim: "Search projects"))
                        .textFieldStyle(.roundedBorder).focused($searchFocused)
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
                                        Text(verbatim: project.name).laaTextStyle(.body).fontWeight(.semibold)
                                            .foregroundStyle(LAAColor.text).lineLimit(1)
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
                            .accessibilityAddTraits(selectedID == project.id ? .isSelected : [])
                            .accessibilityIdentifier("work.project.\(project.id)")
                        }
                        if visible.isEmpty && !loading && failure == nil {
                            Text(verbatim: "No projects yet.")
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
            .onKeyPress(.init("f"), phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                searchFocused = true; return .handled
            }
            .onKeyPress(.init("r"), phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                reloadID += 1; return .handled
            }
            .onKeyPress(.init("n"), phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                showNew = true; return .handled
            }
        } detail: {
            if let selected {
                NavigationStack {
                    LAAWorkProjectHome(project: selected, drafts: drafts).id(selected.id)
                }
            } else {
                LAAMacEmptyDetail(symbol: "folder", title: "Select a project",
                                  message: "Choose a project on the left to see its instructions, files and sessions.")
            }
        }
        .accessibilityIdentifier("work.desktop.projects")
        .sheet(isPresented: $showNew, onDismiss: { reloadID += 1 }) {
            LAAWorkProjectEditor(project: nil, canEditInstructions: true, drafts: drafts).environmentObject(bridge)
        }
        .task(id: "\(bridge.revision)-\(refreshID)-\(reloadID)") { await load() }
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
            let loaded: [LAAWorkProject] = try await LAAWorkPaging.all(bridge, "/v1/projects")
            guard !Task.isCancelled else { return }
            projects = loaded; failure = nil
            if selectedID == nil || !projects.contains(where: { $0.id == selectedID }) { selectedID = projects.first?.id }
        } catch is CancellationError {
            return
        } catch {
            failure = "Could not read projects."
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
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    private var rows: [(id: String, title: String, subtitle: String)] {
        if kind == .routines {
            return routines.filter { LAAWorkDesktopList.matches($0.name + " " + ($0.schedule ?? ""), query: search) }
                .map { ($0.id, $0.name, $0.schedule ?? "Schedule unknown") }
        }
        var seen = Set<String>()
        return skills.filter { seen.insert($0.name).inserted }
            .filter { LAAWorkDesktopList.matches($0.name + " " + $0.explanation, query: search) }
            .sorted { $0.name < $1.name }
            .map { ($0.id, $0.name, $0.explanation.isEmpty ? "No description" : $0.explanation) }
    }

    var body: some View {
        LAAMacListDetail {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: LAASpacing.x3) {
                    HStack {
                        Text(verbatim: kind == .routines ? "WORK ROUTINES" : "SKILLS")
                            .laaTextStyle(.section).fontWeight(.semibold).foregroundStyle(LAAColor.secondaryText)
                        Spacer()
                        Button { reloadID += 1 } label: { Image(systemName: "arrow.clockwise") }
                            .frame(width: LAASpacing.minimumTouchTarget, height: LAASpacing.minimumTouchTarget)
                            .accessibilityLabel(Text(verbatim: "Reload"))
                            .macTooltip("Reload (⌘R)")
                    }
                    TextField("", text: $search, prompt: Text(verbatim: kind == .routines ? "Search routines" : "Search skills"))
                        .textFieldStyle(.roundedBorder).focused($searchFocused)
                    if let failure { Text(verbatim: failure).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention) }
                    if loading && !loaded { ProgressView().controlSize(.small) }
                }
                .padding(LAASpacing.x3)
                Rectangle().fill(LAAColor.separator).frame(height: 1)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows, id: \.id) { row in
                            Button { selectedID = row.id } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: row.title).laaTextStyle(.body).fontWeight(.semibold)
                                        .foregroundStyle(LAAColor.text).lineLimit(1)
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
                            Text(verbatim: kind == .routines ? "No routines." : "No skills.")
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
            .onKeyPress(.init("f"), phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                searchFocused = true; return .handled
            }
            .onKeyPress(.init("r"), phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                reloadID += 1; return .handled
            }
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
                    Text(verbatim: routine.name).font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
                    Text(verbatim: routine.schedule ?? "Schedule unknown").foregroundStyle(LAAColor.link)
                    VStack(alignment: .leading, spacing: LAASpacing.x2) {
                        detailLine("Destination", routine.destination ?? "Not set")
                        detailLine("State", stateLabel(routine.state))
                        detailLine("Last run", routine.previousRunSummary())
                    }.workCard()
                }
                .padding(LAASpacing.x6).laaReadableWidth()
            }
            .background(LAAColor.background)
        } else if kind == .skills, let skill = skills.first(where: { $0.id == selectedID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: LAASpacing.x4) {
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
                              title: kind == .routines ? "Select a routine" : "Select a skill",
                              message: "Choose an item on the left to read its details here.")
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
            failure = "Could not read the list."
        }
    }
}
#endif
