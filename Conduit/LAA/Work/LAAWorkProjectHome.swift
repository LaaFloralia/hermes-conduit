#if LAA_BUILD
import SwiftUI
import UniformTypeIdentifiers

/// One project, opened, on the phone and in the Mac's detail column. It reads
/// the project's detail and its sessions, re-reads the detail every five
/// seconds while it is shown (the session lists' interval) with the last
/// answer's tag, so an unchanged project is a 304, and reads the session rows
/// again only when the detail changed. Archived sessions are read only when
/// the owner opens them. The last reading stays on the device for when the
/// Mac is out of reach.
struct LAAWorkProjectHome: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.laaDesktop) private var laaDesktop
    @ObservedObject var drafts: ComposerDraftStore
    @State private var project: LAAWorkProject
    @State private var detail: LAAWorkProjectSnapshot?
    @State private var phase: LAAWorkProjectPhase = .loading
    @State private var sessions: [LAAWorkSession] = []
    @State private var sessionsCursor: String?
    @State private var archivedSessions: [LAAWorkSession]?
    @State private var archivedCursor: String?
    @State private var showArchived = false
    @State private var readingMore = false
    /// The HTTP tag of the last detail whose sessions were also read.
    @State private var detailTag: String?
    @State private var options: LAAWorkSessionOptions?
    @State private var showEditor = false
    @State private var showLauncher = false
    @State private var showImporter = false
    @State private var showAddRequirement = false
    @State private var openedID: String?
    @State private var uploading = false
    @State private var busyRequirement: String?
    @State private var actionError: String?

    init(project: LAAWorkProject, drafts: ComposerDraftStore) {
        _project = State(initialValue: project); self.drafts = drafts
    }

    static let interval: Duration = .seconds(5)
    private static let maxFileBytes = 5 * 1024 * 1024
    private var cacheTarget: String { "project:\(project.id)" }

    var body: some View {
        ZStack {
            LAAColor.background.ignoresSafeArea()
            ScrollView {
                LAAWorkProjectPage(project: project, detail: detail, sessions: sessions,
                                   archivedSessions: archivedSessions, options: options, phase: phase,
                                   actionError: actionError, busyRequirement: busyRequirement,
                                   uploading: uploading, showArchived: showArchived,
                                   moreSessions: sessionsCursor != nil, moreArchived: archivedCursor != nil,
                                   readingMore: readingMore, canChange: project.etag != nil && !project.isArchived, actions: actions)
                    .padding(.horizontal, LAASpacing.horizontal).padding(.vertical, LAASpacing.x4)
                    .frame(maxWidth: laaDesktop ? LAADesktopMetrics.documentWidth : 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: laaDesktop ? .center : .leading)
            }
            .refreshable { await load(force: true) }
        }
        .navigationTitle(Text(verbatim: ""))
        .navigationBarTitleDisplayMode(.inline)
        .tint(LAAColor.link)
        .toolbar(.hidden, for: .tabBar)
        .accessibilityIdentifier("laa.work.project.detail")
        .navigationDestination(item: $openedID) { id in
            LAAWorkSessionDetail(id: id, projects: [project], workspaces: [], drafts: drafts)
        }
        .sheet(isPresented: $showEditor, onDismiss: { Task { await load() } }) {
            LAAWorkProjectEditor(project: project, canEditInstructions: project.hasInstructionBody && project.instructionError == nil,
                                 drafts: drafts)
                .environmentObject(bridge)
                .laaSheetSize(.form)
        }
        .sheet(isPresented: $showLauncher) {
            LAAWorkSessionLauncher(projects: [project], options: options, drafts: drafts, projectID: project.id) { created in
                showLauncher = false
                Task { await load(); openedID = created.id }
            }
            .environmentObject(bridge)
        }
        .sheet(isPresented: $showAddRequirement) {
            LAAWorkRequirementAddSheet { addition, key in try await add(addition, key: key) }
                .laaSheetSize(.form)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            Task { await upload(result) }
        }
        .task(id: bridge.revision) {
            restoreCache()
            await load()
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.interval) } catch { return }
                await load()
            }
        }
    }

    private var actions: LAAWorkProjectActions {
        LAAWorkProjectActions(
            openSession: { openedID = $0 },
            setStatus: { requirement, status in Task { await setStatus(status, of: requirement) } },
            withdraw: { requirement in Task { await withdraw(requirement) } },
            addRequirement: { actionError = nil; showAddRequirement = true },
            startSession: { showLauncher = true },
            editInstructions: { showEditor = true },
            addFile: { showImporter = true },
            removeFile: { file in Task { await remove(file) } },
            retry: { Task { await load(force: true) } },
            toggleArchived: {
                showArchived.toggle()
                if showArchived { Task { await loadArchived() } }
            },
            readMore: { archived in Task { await readMore(archived: archived) } })
    }

    // MARK: Reading

    private func restoreCache() {
        guard detail == nil,
              let kept = LAAWorkSessionCache.read(LAAWorkProjectSnapshot.self, store: drafts, device: bridge.deviceID,
                                                  target: cacheTarget) else { return }
        detail = kept
    }

    /// `force` drops the tag: pull to refresh and retry read everything again.
    @MainActor private func load(force: Bool = false) async {
        guard bridge.status == .paired else { return }
        do {
            switch try await LAAWorkProjectDetailAPI.read(bridge, id: project.id, tag: force ? nil : detailTag) {
            case .unchanged:
                break
            case .changed(let fetched, let tag):
                guard !Task.isCancelled else { return }
                apply(fetched)
                // As many rows as already shown, so a re-read doesn't fold the owner's "read more".
                let shown = max(LAAWorkProjectSessionsAPI.firstScreen, sessions.count)
                let page = try await LAAWorkProjectSessionsAPI.read(bridge, project: project.id, archived: false, atLeast: shown)
                guard !Task.isCancelled else { return }
                sessions = page.rows; sessionsCursor = page.cursor
                // Kept only once the rows match it, so a failed row read is retried.
                detailTag = tag
                if showArchived { await loadArchived() }
            }
            phase = .ready
        } catch is CancellationError {
            return
        } catch LAABridgeError.networkUnreachable {
            phase = .offline(detail?.savedAt)
        } catch let failure as LAABridgeError {
            phase = .failed(failure.japaneseText)
        } catch let failure as LAABridgeHTTPError {
            phase = .failed(LAAWorkHTTP.message(failure))
        } catch {
            phase = .failed(LAACopy.WorkProject.readFailed)
        }
        if options == nil { options = try? await LAAWorkOptionsStore.read(bridge) }
    }

    /// The archived rows, read when the owner opens them and again when the
    /// detail changes while they're open. Never part of the five-second read.
    @MainActor private func loadArchived() async {
        let shown = max(LAAWorkProjectSessionsAPI.pageSize, archivedSessions?.count ?? 0)
        guard let page = try? await LAAWorkProjectSessionsAPI.read(bridge, project: project.id, archived: true,
                                                                   atLeast: shown) else { return }
        archivedSessions = page.rows; archivedCursor = page.cursor
    }

    @MainActor private func readMore(archived: Bool) async {
        guard !readingMore, let cursor = archived ? archivedCursor : sessionsCursor else { return }
        readingMore = true
        defer { readingMore = false }
        do {
            let page = try await LAAWorkProjectSessionsAPI.read(bridge, project: project.id, archived: archived, from: cursor,
                                                                atLeast: LAAWorkProjectSessionsAPI.pageSize)
            if archived {
                archivedSessions = (archivedSessions ?? []) + page.rows.filter { row in archivedSessions?.contains { $0.id == row.id } != true }
                archivedCursor = page.cursor
            } else {
                sessions += page.rows.filter { row in !sessions.contains { $0.id == row.id } }
                sessionsCursor = page.cursor
            }
            actionError = nil
        } catch {
            actionError = LAACopy.WorkProject.readFailed
        }
    }

    /// Takes a detail the Bridge returned, from a read or a change. A change's
    /// answer without sessions keeps the ones already shown.
    @MainActor private func apply(_ fetched: LAAWorkProject) {
        project = fetched
        let next = LAAWorkProjectSnapshot(fetched)
        let merged = fetched.sessions == nil && fetched.requirements != nil && detail?.sessions != nil
            ? LAAWorkProjectSnapshot(progressNote: next.progressNote, requirements: next.requirements,
                                     sessions: detail?.sessions, sessionCounts: detail?.sessionCounts, savedAt: next.savedAt)
            : next
        // Written only when what it shows changed, not on every read.
        if detail?.sameContent(as: merged) != true {
            LAAWorkSessionCache.save(merged, store: drafts, device: bridge.deviceID, target: cacheTarget)
        }
        detail = merged
    }

    // MARK: Requirement changes

    @MainActor private func setStatus(_ status: LAAWorkRequirementStatus, of requirement: LAAWorkRequirement) async {
        busyRequirement = requirement.id
        defer { busyRequirement = nil }
        do {
            apply(try await LAAWorkRequirementAPI.setStatus(status, of: requirement, in: project, bridge: bridge))
            actionError = nil
        } catch {
            actionError = LAAWorkRequirementAPI.message(error)
            await load()
        }
    }

    @MainActor private func withdraw(_ requirement: LAAWorkRequirement) async {
        busyRequirement = requirement.id
        defer { busyRequirement = nil }
        do {
            apply(try await LAAWorkRequirementAPI.withdraw(requirement, in: project, bridge: bridge))
            actionError = nil
        } catch {
            actionError = LAAWorkRequirementAPI.message(error)
            await load()
        }
    }

    /// Throws for the sheet to show; a refused version re-reads first so the
    /// owner's next try carries the current one.
    @MainActor private func add(_ addition: LAAWorkRequirementAPI.Addition, key: LAABridgeIdempotencyKey) async throws {
        do {
            apply(try await LAAWorkRequirementAPI.add(addition, to: project, key: key, bridge: bridge))
            actionError = nil
        } catch let failure as LAABridgeHTTPError where LAAWorkHTTP.isVersionConflict(failure) {
            await load()
            throw failure
        }
    }

    // MARK: Files

    @MainActor private func upload(_ result: Result<[URL], Error>) async {
        guard case .success(let urls) = result else { actionError = "ファイルを開けませんでした。"; return }
        struct Upload: Encodable { let name: String; let contentBase64: String; let mimeType: String? }
        uploading = true
        defer { uploading = false }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { actionError = "\(url.lastPathComponent) を読めませんでした。"; continue }
            guard data.count <= Self.maxFileBytes else { actionError = "\(url.lastPathComponent) は5 MBを超えています。"; continue }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            guard let body = try? JSONEncoder().encode(Upload(name: url.lastPathComponent, contentBase64: data.base64EncodedString(),
                                                              mimeType: mime)) else { continue }
            do {
                let updated: LAAWorkProject = try await LAAWorkHTTP.write(bridge, path: "/v1/projects/\(project.id)/files",
                                                                         body: body, key: LAABridgeIdempotencyKey())
                project = updated; actionError = nil
            } catch let failure as LAABridgeHTTPError {
                actionError = failure.status == 404 || failure.status == 405 ? "MacのLAAアプリを最新にすると資料を追加できます。"
                    : failure.code == "file_limit_reached" ? "資料は20件までです。" : LAAWorkHTTP.message(failure)
                return
            } catch {
                actionError = "資料を送れませんでした。"; return
            }
        }
    }

    @MainActor private func remove(_ file: LAAWorkProjectFile) async {
        do {
            let updated: LAAWorkProject = try await LAAWorkHTTP.write(bridge, path: "/v1/projects/\(project.id)/files/\(file.id)",
                                                                     body: Data("{}".utf8), key: LAABridgeIdempotencyKey(), method: "DELETE")
            project = updated; actionError = nil
        } catch let failure as LAABridgeHTTPError {
            actionError = LAAWorkHTTP.message(failure)
        } catch {
            actionError = "資料を削除できませんでした。"
        }
    }
}

extension LAAWorkProjectSnapshot {
    init(progressNote: String?, requirements: [LAAWorkRequirement]?, sessions: [LAAWorkProjectSession]?,
         sessionCounts: LAAWorkSessionCounts? = nil, savedAt: Date) {
        self.progressNote = progressNote; self.requirements = requirements; self.sessions = sessions
        self.sessionCounts = sessionCounts; self.savedAt = savedAt
    }

    func sameContent(as other: Self) -> Bool {
        progressNote == other.progressNote && requirements == other.requirements && sessions == other.sessions
            && sessionCounts == other.sessionCounts
    }
}

/// The owner adds a requirement in their own words, with an optional note.
/// The request keeps one idempotency key until it is answered, so a retry
/// after a lost answer cannot add it twice.
struct LAAWorkRequirementAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    let submit: (LAAWorkRequirementAPI.Addition, LAABridgeIdempotencyKey) async throws -> Void
    @State private var title = ""
    @State private var details = ""
    @State private var key = LAABridgeIdempotencyKey()
    @State private var sent: LAAWorkRequirementAPI.Addition?
    @State private var busy = false
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    private var addition: LAAWorkRequirementAPI.Addition {
        let note = details.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(title: title.trimmingCharacters(in: .whitespacesAndNewlines), details: note.isEmpty ? nil : note)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Text(verbatim: error).foregroundStyle(LAAColor.attention)
                        .accessibilityIdentifier("laa.work.project.add.error")
                }
                Section {
                    TextField(LAACopy.WorkProject.requirementTitlePrompt, text: $title, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($titleFocused)
                        .accessibilityIdentifier("laa.work.project.add.title")
                } header: { Text(verbatim: LAACopy.WorkProject.requirementTitle) }
                Section {
                    TextEditor(text: $details).frame(minHeight: 120)
                        .scrollContentBackground(.hidden).background(LAAColor.surface)
                        .accessibilityIdentifier("laa.work.project.add.details")
                } header: { Text(verbatim: LAACopy.WorkProject.requirementDetails) }
                  footer: { Text(verbatim: LAACopy.WorkProject.addFooter) }
            }
            .scrollContentBackground(.hidden)
            .background(LAAColor.background)
            .laaTextStyle(.body)
            .foregroundStyle(LAAColor.text)
            .tint(LAAColor.link)
            .disabled(busy)
            .navigationTitle(Text(verbatim: LAACopy.WorkProject.addRequirement))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Text(verbatim: LAACopy.WorkTab.cancel) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await save() } } label: { Text(verbatim: LAACopy.WorkTab.save).fontWeight(.semibold) }
                        .disabled(addition.title.isEmpty || busy)
                        .accessibilityIdentifier("laa.work.project.add.save")
                }
            }
            .onAppear { titleFocused = true }
        }
    }

    @MainActor private func save() async {
        let body = addition
        guard !body.title.isEmpty else { return }
        // A changed text is a new request: it must not reuse the earlier key.
        if let sent, sent != body { key = LAABridgeIdempotencyKey() }
        sent = body
        busy = true
        defer { busy = false }
        do {
            try await submit(body, key)
            dismiss()
        } catch let failure as LAABridgeHTTPError {
            // Refused before anything was written: the next try is a new request.
            if !LAAWorkHTTP.outcomeUnknown(failure) { key = LAABridgeIdempotencyKey(); sent = nil }
            error = LAAWorkRequirementAPI.message(failure)
        } catch {
            self.error = LAAWorkRequirementAPI.message(error)
        }
    }
}
#endif
