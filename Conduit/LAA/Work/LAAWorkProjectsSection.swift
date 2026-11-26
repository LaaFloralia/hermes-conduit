#if LAA_BUILD
import SwiftUI
import UniformTypeIdentifiers

/// Work › Projects, after Claude Projects: a name, shared instructions and
/// reference files, with sessions started inside the project.
struct LAAWorkProjectsSection: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @ObservedObject var drafts: ComposerDraftStore
    let refreshID: Int
    /// The Work hub's search on the phone.
    var query = ""
    @Binding var linkedProject: String?

    init(drafts: ComposerDraftStore, refreshID: Int, query: String = "", linkedProject: Binding<String?> = .constant(nil)) {
        self.drafts = drafts; self.refreshID = refreshID; self.query = query
        _linkedProject = linkedProject
    }

    @State private var projects: [LAAWorkProject] = []
    /// The sessions, only to mark the projects with work running or waiting.
    @State private var sessions: [LAAWorkSession] = []
    @State private var failure: String?
    @State private var loading = false
    /// Set once a read answered, so a periodic re-read does not flash the
    /// empty text over an empty list.
    @State private var hasLoaded = false
    @State private var showNew = false
    @State private var editorID = 0
    @State private var showArchived = false
    @State private var archivePrompt: LAAWorkArchivePrompt?
    @State private var opened: LAAWorkProject?
    @State private var openRow: String?

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x4) {
            LAAWorkPrimaryButton(title: "新しいプロジェクト", systemImage: "plus") { showNew = true }
                .accessibilityIdentifier("work.projects.new")
            if let failure { LAAWorkFailure(text: failure) { Task { await load() } } }
            if loading && projects.isEmpty { LAALoadingDots() }
            if visibleProjects.isEmpty && (hasLoaded || !loading) && failure == nil {
                Text(verbatim: showArchived ? "アーカイブしたプロジェクトはありません。" : "名前・指示・資料をまとめ、その中でセッションを始められます。")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
            if !visibleProjects.isEmpty {
                VStack(spacing: 0) {
                    ForEach(visibleProjects) { project in
                        LAAWorkSwipeRow(id: project.id, openID: $openRow,
                                        leading: .init(title: project.isArchived ? LAACopy.WorkTab.unarchive : LAACopy.WorkTab.archive,
                                                       systemImage: project.isArchived ? "tray.and.arrow.up" : "archivebox",
                                                       tint: LAAColor.attention,
                                                       identifier: "work.project.archive.\(project.id)") { toggleArchive(project) },
                                        onOpen: { opened = project }) {
                            LAAWorkProjectRow(project: project,
                                              activity: project.isArchived ? .idle : LAAWorkProjectActivity.of(project.id, sessions: sessions))
                        }
                        .contextMenu {
                            Button { toggleArchive(project) } label: {
                                Label { Text(verbatim: project.isArchived ? LAACopy.WorkTab.unarchive : LAACopy.WorkTab.archive) } icon: { Image(systemName: "archivebox") }
                            }
                        }
                        .accessibilityIdentifier("work.project.\(project.id)")
                        if project.id != visibleProjects.last?.id { Divider().overlay(LAAColor.separator).padding(.leading, LAASpacing.x4) }
                    }
                }
                .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: LAARadius.card, style: .continuous))
            }
            Button {
                showArchived.toggle()
            } label: {
                Label { Text(verbatim: showArchived ? "プロジェクトへ戻る" : "アーカイブを表示") }
                    icon: { Image(systemName: showArchived ? "arrow.uturn.left" : "archivebox") }
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.link)
                    .frame(minHeight: LAASpacing.minimumTouchTarget)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("work.projects.archiveToggle")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work.projects")
        .laaWorkArchivePrompt($archivePrompt)
        .navigationDestination(item: $opened) { project in
            LAAWorkProjectHome(project: project, drafts: drafts)
                .onAppear { LAAWorkSessionProjects.noteOpened(project.id) }
        }
        .sheet(isPresented: $showNew, onDismiss: { editorID += 1 }) {
            LAAWorkProjectEditor(project: nil, canEditInstructions: true, drafts: drafts).environmentObject(bridge)
        }
        .task(id: "\(bridge.revision)-\(linkedProject ?? "")") {
            guard let id = linkedProject, bridge.status == .paired else { return }
            do {
                let project: LAAWorkProject = try await bridge.read("/v1/projects/\(id)")
                guard !Task.isCancelled, linkedProject == id else { return }
                opened = project
                linkedProject = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, linkedProject == id else { return }
                linkedProject = nil
                failure = (error as? LAABridgeError)?.japaneseText ?? "プロジェクトを開けませんでした。"
            }
        }
        // Re-read like the session list (every five seconds while shown), so
        // a requirement Monet finishes moves the row's count without a pull.
        .task(id: "\(bridge.revision)-\(refreshID)-\(editorID)-\(showArchived)") {
            await load()
            while !Task.isCancelled {
                do { try await Task.sleep(for: LAAWorkProjectHome.interval) } catch { return }
                await load()
            }
        }
    }

    private var visibleProjects: [LAAWorkProject] {
        projects.filter { LAAWorkRef.matches(query, ref: $0.ref, text: [$0.name]) }
    }

    @MainActor private func load() async {
        guard bridge.status == .paired else { return }
        loading = true
        defer { loading = false }
        do {
            let query = showArchived ? [URLQueryItem(name: "archived", value: "only")] : []
            let loaded: [LAAWorkProject] = try await LAAWorkPaging.all(bridge, "/v1/projects", query: query)
            guard !Task.isCancelled else { return }
            projects = loaded; failure = nil; hasLoaded = true
            // The marks are a hint: a failed session read leaves the last ones.
            if !showArchived, let rows: [LAAWorkSession] = try? await LAAWorkPaging.all(bridge, "/v1/sessions") {
                sessions = rows
            }
        } catch is CancellationError {
            return
        } catch let error as LAABridgeError {
            failure = error.japaneseText
        } catch {
            failure = "プロジェクトを読み取れませんでした。"
        }
    }

    /// Archiving asks first; bringing a project back does not.
    private func toggleArchive(_ project: LAAWorkProject) {
        if project.isArchived { Task { await setArchived(project) }; return }
        archivePrompt = .project(project) { Task { await setArchived(project) } }
    }

    @MainActor private func setArchived(_ project: LAAWorkProject) async {
        openRow = nil
        let archiving = !project.isArchived
        do {
            try await LAAWorkHTTP.setProjectArchived(project, archived: archiving, bridge: bridge)
            await load()
        } catch let error as LAABridgeHTTPError {
            let text = LAAWorkHTTP.isVersionConflict(error) ? "別の端末で更新されています。読み直してからもう一度操作してください。" : LAAWorkArchivePrompt.refusal(error)
            if archiving { archivePrompt = .init(title: LAAWorkArchivePrompt.refusedTitle, message: text, archive: nil) } else { failure = text }
            await load()
        } catch {
            if archiving { archivePrompt = .refused(error) } else { failure = "変更を保存できませんでした。" }
        }
    }
}
#endif
