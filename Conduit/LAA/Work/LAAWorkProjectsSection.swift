#if LAA_BUILD
import SwiftUI
import UniformTypeIdentifiers

/// Work › Projects, after Claude Projects: a name, shared instructions and
/// reference files, with sessions started inside the project.
struct LAAWorkProjectsSection: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @ObservedObject var drafts: ComposerDraftStore
    let refreshID: Int

    @State private var projects: [LAAWorkProject] = []
    @State private var failure: String?
    @State private var loading = false
    @State private var showNew = false
    @State private var editorID = 0

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x4) {
            LAAWorkPrimaryButton(title: "新しいプロジェクト", systemImage: "plus") { showNew = true }
                .accessibilityIdentifier("work.projects.new")
            if let failure { LAAWorkFailure(text: failure) { Task { await load() } } }
            if loading && projects.isEmpty { ProgressView().accessibilityLabel(Text(verbatim: "読み込み中")) }
            if projects.isEmpty && !loading && failure == nil {
                Text(verbatim: "名前・指示・資料をまとめ、その中でセッションを始められます。")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
            if !projects.isEmpty {
                VStack(spacing: 0) {
                    ForEach(projects) { project in
                        NavigationLink {
                            LAAWorkProjectHome(project: project, drafts: drafts)
                        } label: {
                            HStack(spacing: LAASpacing.x3) {
                                Image(systemName: "folder").foregroundStyle(LAAColor.link).frame(width: 22)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: project.name).laaTextStyle(.body).fontWeight(.semibold)
                                        .foregroundStyle(LAAColor.text).lineLimit(1)
                                    Text(verbatim: summary(project)).laaTextStyle(.secondary)
                                        .foregroundStyle(LAAColor.secondaryText).lineLimit(1)
                                }
                                Spacer(minLength: LAASpacing.x2)
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(LAAColor.secondaryText)
                            }
                            .padding(.horizontal, LAASpacing.x4)
                            .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("work.project.\(project.id)")
                        if project.id != projects.last?.id { Divider().overlay(LAAColor.separator).padding(.leading, 50) }
                    }
                }
                .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card, style: .continuous))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work.projects")
        .sheet(isPresented: $showNew, onDismiss: { editorID += 1 }) {
            LAAWorkProjectEditor(project: nil, canEditInstructions: true, drafts: drafts).environmentObject(bridge)
        }
        .task(id: "\(bridge.revision)-\(refreshID)-\(editorID)") { await load() }
    }

    private func summary(_ project: LAAWorkProject) -> String {
        let instructions = (project.instructionHash ?? "").isEmpty ? "指示なし" : "指示あり"
        let files = (project.fileCount ?? 0) > 0 ? "資料 \(project.fileCount ?? 0)" : "資料なし"
        return [instructions, files, LAAWorkSessionStyle.relative(project.updatedAt ?? "")].compactMap { $0 }.joined(separator: " · ")
    }

    @MainActor private func load() async {
        guard bridge.status == .paired else { return }
        loading = true
        defer { loading = false }
        do {
            let loaded: [LAAWorkProject] = try await LAAWorkPaging.all(bridge, "/v1/projects")
            guard !Task.isCancelled else { return }
            projects = loaded; failure = nil
        } catch is CancellationError {
            return
        } catch let error as LAABridgeError {
            failure = error.japaneseText
        } catch {
            failure = "プロジェクトを読み取れませんでした。"
        }
    }
}

/// One project: start a session, the instructions, the files and its sessions.
struct LAAWorkProjectHome: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @ObservedObject var drafts: ComposerDraftStore
    @State private var project: LAAWorkProject
    @State private var sessions: [LAAWorkSession] = []
    @State private var options: LAAWorkSessionOptions?
    @State private var showEditor = false
    @State private var showLauncher = false
    @State private var showImporter = false
    @State private var opened: LAAWorkSession?
    @State private var uploading = false
    @State private var error: String?

    init(project: LAAWorkProject, drafts: ComposerDraftStore) {
        _project = State(initialValue: project); self.drafts = drafts
    }

    private static let maxFileBytes = 5 * 1024 * 1024

    var body: some View {
        ZStack {
            LAAColor.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: LAASpacing.x6) {
                    Text(verbatim: project.name).font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
                        .accessibilityAddTraits(.isHeader)
                    if let error { LAAWorkFailure(text: error) { Task { await load() } } }
                    LAAWorkPrimaryButton(title: "このプロジェクトで開始", systemImage: "plus") { showLauncher = true }
                        .accessibilityIdentifier("work.project.newSession")
                    instructionsCard
                    filesCard
                    sessionList
                }
                .padding(.horizontal, LAASpacing.horizontal).padding(.vertical, LAASpacing.x4)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .laaTextStyle(.body).foregroundStyle(LAAColor.text)
            }
            .refreshable { await load() }
        }
        .navigationTitle(Text(verbatim: ""))
        .navigationBarTitleDisplayMode(.inline)
        .tint(LAAColor.link)
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(item: $opened) { session in
            LAAWorkSessionDetail(id: session.id, projects: [project], workspaces: [], drafts: drafts)
        }
        .sheet(isPresented: $showEditor, onDismiss: { Task { await load() } }) {
            LAAWorkProjectEditor(project: project, canEditInstructions: project.hasInstructionBody && project.instructionError == nil,
                                 drafts: drafts)
                .environmentObject(bridge)
        }
        .sheet(isPresented: $showLauncher) {
            LAAWorkSessionLauncher(projects: [project], options: options, drafts: drafts, projectID: project.id) { created in
                showLauncher = false
                Task { await load(); opened = created }
            }
            .environmentObject(bridge)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            Task { await upload(result) }
        }
        .task { await load() }
    }

    private func heading(_ title: String, action: (String, String, () -> Void)? = nil) -> some View {
        HStack {
            Text(verbatim: title).laaTextStyle(.section).fontWeight(.semibold).foregroundStyle(LAAColor.secondaryText)
            Spacer()
            if let action {
                Button(action: action.2) {
                    Label { Text(verbatim: action.0) } icon: { Image(systemName: action.1) }
                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.link)
                        .frame(minHeight: LAASpacing.minimumTouchTarget)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var instructionsCard: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            heading("指示", action: ("編集", "pencil", { showEditor = true }))
            let text = project.instructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Button { showEditor = true } label: {
                Text(verbatim: text.isEmpty ? "このプロジェクトの全セッションに渡す指示を書けます。" : text)
                    .laaTextStyle(.body)
                    .foregroundStyle(text.isEmpty ? LAAColor.secondaryText : LAAColor.text)
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(LAASpacing.x4)
                    .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("work.project.instructions")
        }
    }

    private var filesCard: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            heading("資料", action: uploading ? nil : ("追加", "plus", { showImporter = true }))
            let files = project.files ?? []
            if uploading { ProgressView().accessibilityLabel(Text(verbatim: "資料を送信中")) }
            if files.isEmpty && !uploading {
                Text(verbatim: "PDF・画像・メモなどを追加すると、セッションが必要な時に読みます。")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            } else if !files.isEmpty {
                VStack(spacing: 0) {
                    ForEach(files) { file in
                        HStack(spacing: LAASpacing.x3) {
                            Image(systemName: icon(file)).foregroundStyle(LAAColor.link).frame(width: 22)
                            Text(verbatim: file.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: LAASpacing.x2)
                            Text(verbatim: file.size.map(size) ?? "").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        }
                        .padding(.horizontal, LAASpacing.x4)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .background(LAAColor.surface)
                        .contextMenu {
                            Button(role: .destructive) { Task { await remove(file) } } label: {
                                Label { Text(verbatim: "削除") } icon: { Image(systemName: "trash") }
                            }
                        }
                        if file.id != files.last?.id { Divider().overlay(LAAColor.separator).padding(.leading, 50) }
                    }
                }
                .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: LAARadius.card, style: .continuous))
                Text(verbatim: "長押しで削除できます。").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work.project.files")
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            heading("セッション")
            let rows = LAAWorkSessionOrder.rows(sessions)
            let all = rows.pinned + rows.recent
            if all.isEmpty {
                Text(verbatim: "まだありません。").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            } else {
                VStack(spacing: 0) {
                    ForEach(all) { session in
                        Button { opened = session } label: {
                            LAAWorkSessionRow(session: session, projectName: nil, options: options)
                        }
                        .buttonStyle(.plain)
                        if session.id != all.last?.id { Divider().overlay(LAAColor.separator).padding(.leading, 30) }
                    }
                }
                .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card, style: .continuous))
            }
        }
    }

    private func icon(_ file: LAAWorkProjectFile) -> String {
        let type = file.mimeType ?? UTType(filenameExtension: (file.name as NSString).pathExtension)?.preferredMIMEType ?? ""
        if type.hasPrefix("image/") { return "photo" }
        if type == "application/pdf" { return "doc.richtext" }
        if type.hasPrefix("text/") { return "doc.text" }
        return "doc"
    }

    private func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    @MainActor private func load() async {
        do {
            async let detail: LAAWorkProject = bridge.read("/v1/projects/\(project.id)")
            async let page: [LAAWorkSession] = LAAWorkPaging.all(bridge, "/v1/sessions",
                                                                 query: [URLQueryItem(name: "projectId", value: project.id)])
            let (fetched, loaded) = try await (detail, page)
            project = fetched
            sessions = loaded.filter { $0.worktree != true && !$0.isArchived }
            error = nil
        } catch is CancellationError {
        } catch let failure as LAABridgeError {
            error = failure.japaneseText
        } catch {
            self.error = "プロジェクトを読み取れませんでした。"
        }
        if options == nil { options = try? await bridge.read("/v1/session-options") }
    }

    @MainActor private func upload(_ result: Result<[URL], Error>) async {
        guard case .success(let urls) = result else { error = "ファイルを開けませんでした。"; return }
        struct Upload: Encodable { let name: String; let contentBase64: String; let mimeType: String? }
        uploading = true
        defer { uploading = false }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { error = "\(url.lastPathComponent) を読めませんでした。"; continue }
            guard data.count <= Self.maxFileBytes else { error = "\(url.lastPathComponent) は5 MBを超えています。"; continue }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            guard let body = try? JSONEncoder().encode(Upload(name: url.lastPathComponent, contentBase64: data.base64EncodedString(),
                                                              mimeType: mime)) else { continue }
            do {
                let updated: LAAWorkProject = try await LAAWorkHTTP.write(bridge, path: "/v1/projects/\(project.id)/files",
                                                                         body: body, key: LAABridgeIdempotencyKey())
                project = updated; error = nil
            } catch let failure as LAABridgeHTTPError {
                error = failure.status == 404 || failure.status == 405 ? "MacのBridgeを更新すると資料を追加できます。"
                    : failure.code == "file_limit_reached" ? "資料は20件までです。" : LAAWorkHTTP.message(failure)
                return
            } catch {
                self.error = "資料を送れませんでした。"; return
            }
        }
    }

    @MainActor private func remove(_ file: LAAWorkProjectFile) async {
        do {
            let updated: LAAWorkProject = try await LAAWorkHTTP.write(bridge, path: "/v1/projects/\(project.id)/files/\(file.id)",
                                                                     body: Data("{}".utf8), key: LAABridgeIdempotencyKey(), method: "DELETE")
            project = updated; error = nil
        } catch let failure as LAABridgeHTTPError {
            error = LAAWorkHTTP.message(failure)
        } catch {
            self.error = "資料を削除できませんでした。"
        }
    }
}
#endif
