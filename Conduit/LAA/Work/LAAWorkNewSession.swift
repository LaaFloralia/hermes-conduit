#if LAA_BUILD
import SwiftUI

struct LAAWorkNewSessionView: View {
    private struct Request: Codable {
        let workspaceId: String
        let requestId: String
        let profile: String
        let prompt: String
        let name: String?
        let projectId: String?
    }
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var drafts: ComposerDraftStore
    let projects: [LAAWorkProject]
    @State private var workspaceItems: [LAAWorkWorkspace]
    @State private var projectID = ""
    @State private var workspaceID = ""
    @State private var workspaceBranchNotices: [String: String] = [:]
    @State private var profile = ""
    @State private var name = ""
    @State private var prompt = ""
    @State private var revision: UInt64 = 0
    @State private var showConfirm = false
    @State private var showWorkspace = false
    @State private var starting = false
    @State private var error: String?
    @State private var created: LAAWorkSession?

    init(projects: [LAAWorkProject], workspaces: [LAAWorkWorkspace], drafts: ComposerDraftStore) {
        self.projects = projects; self.drafts = drafts
        _workspaceItems = State(initialValue: workspaces)
    }
    private var key: ComposerDraftKey? {
        bridge.deviceID.map { LAAWorkDrafts.key(deviceID: $0, target: "new-session") }
    }
    private var pending: ComposerDraftStore.Submission? { key.flatMap { LAAWorkDrafts.pending(drafts, key: $0) } }
    private var canStart: Bool {
        !workspaceID.isEmpty && !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !starting && pending == nil && !drafts.persistenceFailed
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let created {
                        Label(LAAWorkPresentation.japanese("セッションを開始しました"), systemImage: "checkmark.circle").foregroundStyle(LAAColors.teal)
                        Text(verbatim: "要求: " + (created.requested?.display ?? "未確認"))
                        Text(verbatim: "観測: " + (created.observed?.display ?? "未確認"))
                        NavigationLink(LAAWorkPresentation.japanese("セッションを開く")) {
                            LAAWorkSessionDetail(id: created.id, projects: projects, workspaces: workspaceItems, drafts: drafts)
                        }.buttonStyle(.borderedProminent)
                    } else {
                        if let pending { unknownBanner(pending) }
                        if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(LAAColors.plum) }
                        Picker(LAAWorkPresentation.japanese("プロジェクト"), selection: $projectID) {
                            Text(verbatim: "プロジェクトなし").tag("")
                            ForEach(projects) { item in Text(verbatim: item.name).tag(item.id) }
                        }.pickerStyle(.menu).accessibilityIdentifier("work.session.project")
                        Picker(LAAWorkPresentation.japanese("作業場所"), selection: $workspaceID) {
                            Text(verbatim: "選択してください").tag("")
                            ForEach(workspaceItems) { item in
                                Text(verbatim: (item.displayPath ?? item.path) + (item.branch.map { " · " + $0 } ?? "")).tag(item.id)
                            }
                        }.pickerStyle(.menu).accessibilityIdentifier("work.session.workspace")
                        if let notice = workspaceBranchNotices[workspaceID] {
                            Label(notice, systemImage: "exclamationmark.triangle.fill").foregroundStyle(LAAColors.plum)
                        }
                        Button(LAAWorkPresentation.japanese("作業場所を新しく作る")) { showWorkspace = true }.disabled(pending != nil || starting)
                        TextField(LAAWorkPresentation.japanese("プロファイル名（例: deepseek-flash-high）"), text: $profile)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("work.session.profile")
                        TextField(LAAWorkPresentation.japanese("セッション名（任意）"), text: $name).textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("work.session.name")
                        Text(verbatim: "実際のモデルは開始後に確認できます。")
                            .font(.caption).foregroundStyle(LAAColors.muted)
                        LAAWorkComposer(text: $prompt, revision: $revision, placeholder: "依頼内容",
                                        enabled: !starting && pending == nil && !drafts.persistenceFailed,
                                        canSend: !workspaceID.isEmpty && !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                        onChange: saveDraft, onSubmit: { showConfirm = true }, submitLabel: "内容を確認")
                        if drafts.persistenceFailed {
                            Text(verbatim: "下書きを保存できません。開始せず保存状態を確認してください。")
                                .foregroundStyle(LAAColors.plum)
                        }
                    }
                }.padding(16).frame(maxWidth: 720, alignment: .leading)
            }
            .background(LAAColors.paper)
            .navigationTitle(Text(verbatim: "新しいセッション"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(LAAWorkPresentation.japanese("閉じる")) { dismiss() } } }
            .confirmationDialog(LAAWorkPresentation.japanese("この内容で開始しますか？"), isPresented: $showConfirm, titleVisibility: .visible) {
                Button(LAAWorkPresentation.japanese("セッションを開始")) { start() }.disabled(!canStart)
                Button(LAAWorkPresentation.japanese("戻る"), role: .cancel) { }
            } message: {
                let workspace = workspaceItems.first { $0.id == workspaceID }
                Text(verbatim: "プロジェクト: \(projects.first { $0.id == projectID }?.name ?? "なし")\n作業場所: \(workspace?.displayPath ?? workspace?.path ?? "未選択")\nブランチ: \(workspace?.branch ?? "未確認")\nプロファイル: \(profile)")
            }
            .sheet(isPresented: $showWorkspace) {
                LAAWorkWorkspaceCreator(repositories: workspaceItems.filter { $0.kind == "repo" }, projectID: projectID, drafts: drafts) { item, notice in
                    workspaceItems.append(item); workspaceID = item.id
                    workspaceBranchNotices[item.id] = notice; showWorkspace = false
                }.environmentObject(bridge)
            }
            .task(id: bridge.revision) {
                if let key { revision &+= 1; prompt = drafts.draft(for: key).text }
            }
        }.tint(LAAColors.teal)
    }

    private func unknownBanner(_ item: ComposerDraftStore.Submission) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(LAAWorkPresentation.japanese("開始結果は未確認"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(LAAColors.plum)
            Text(verbatim: "同じ依頼とIDで再照合します。新しいセッションを重複して開始しません。")
            Text(verbatim: item.draft.text).font(.caption).lineLimit(4)
            Button(LAAWorkPresentation.japanese("開始済みか確認")) { Task { await reconcile(item) } }.disabled(starting)
            Button(LAAWorkPresentation.japanese("同じ要求を再照合")) { Task { await perform(item) } }.disabled(starting)
        }.workCard()
    }
    private func saveDraft(_ text: String) {
        guard let key else { return }
        if !drafts.save(ComposerDraft(text: text, attachments: []), for: key) {
            error = "下書きを端末に保存できませんでした。"
        }
    }
    private func start() {
        guard canStart, let key else { return }
        let task = Request(workspaceId: workspaceID, requestId: UUID().uuidString.lowercased(),
                           profile: profile.trimmingCharacters(in: .whitespacesAndNewlines), prompt: prompt,
                           name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name,
                           projectId: projectID.isEmpty ? nil : projectID)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let body = try? encoder.encode(task),
              let item = LAAWorkDrafts.reserve(drafts, key: key, text: prompt, body: body,
                                               idempotency: LAABridgeIdempotencyKey()) else {
            error = "開始前に下書きと要求IDを保存できませんでした。"; return
        }
        revision &+= 1; prompt = ""
        Task { await perform(item) }
    }
    @MainActor private func perform(_ item: ComposerDraftStore.Submission) async {
        guard LAAWorkDrafts.canRepeat(item) else { error = LAAWorkDrafts.expiredMessage; return }
        guard let (body, key) = LAAWorkDrafts.request(item) else { error = "開始要求の記録を読み取れません。"; return }
        starting = true
        defer { starting = false }
        do {
            let result: LAAWorkSession = try await LAAWorkHTTP.write(bridge, path: "/v1/sessions", body: body, key: key)
            guard drafts.finishSubmission(item.id, restoring: false) else {
                error = "開始結果を端末に保存できません。再送せず状態を確認してください。"; return
            }
            error = nil; created = result
        } catch let failure as LAABridgeHTTPError {
            if LAAWorkHTTP.outcomeUnknown(failure) { drafts.markSubmissionUnknown(item.id) }
            else if drafts.finishSubmission(item.id, restoring: true), let draftKey = self.key {
                revision &+= 1; prompt = drafts.draft(for: draftKey).text
            }
            error = LAAWorkHTTP.message(failure)
        } catch let failure as LAABridgeError {
            drafts.markSubmissionUnknown(item.id)
            error = failure.japaneseText
        } catch {
            drafts.markSubmissionUnknown(item.id)
            self.error = "開始結果を確認できませんでした。"
        }
    }

    @MainActor private func reconcile(_ item: ComposerDraftStore.Submission) async {
        guard let (body, _) = LAAWorkDrafts.request(item),
              let request = try? JSONDecoder().decode(Request.self, from: body) else {
            error = "開始要求の記録を読み取れません。"; return
        }
        starting = true; defer { starting = false }
        do {
            let path = LAAWorkPresentation.path("/v1/sessions", query: [URLQueryItem(name: "requestId", value: request.requestId)])
            let page: LAAWorkPage<LAAWorkSession> = try await bridge.read(path)
            guard page.items.count == 1, page.items[0].requestId == request.requestId else {
                error = "開始の記録をまだ確認できません。同じIDの記録を保持しています。"; return
            }
            guard drafts.finishSubmission(item.id, restoring: false) else {
                error = "開始結果を端末に保存できません。"; return
            }
            created = page.items[0]; error = nil
        } catch let failure as LAABridgeError { error = failure.japaneseText }
        catch { self.error = "開始結果を確認できませんでした。" }
    }
}

struct LAAWorkWorkspaceCreator: View {
    private struct Request: Codable { let repoId: String; let worktreeName: String; let branch: String; let projectId: String? }
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.dismiss) private var dismiss
    let repositories: [LAAWorkWorkspace]
    let projectID: String
    @ObservedObject var drafts: ComposerDraftStore
    let onSuccess: (LAAWorkWorkspace, String?) -> Void
    @State private var repoID = ""
    @State private var worktreeName = ""
    @State private var branch = ""
    @State private var busy = false
    @State private var error: String?
    private var key: ComposerDraftKey? { bridge.deviceID.map { LAAWorkDrafts.key(deviceID: $0, target: "new-worktree") } }
    private var pending: ComposerDraftStore.Submission? { key.flatMap { LAAWorkDrafts.pending(drafts, key: $0) } }

    static func branchNotice(requested: String?, actual: String?) -> String? {
        guard let requested else { return "指定したブランチ名を確認できません。" }
        guard let actual else { return "作成されたブランチ名を確認できません。" }
        guard requested != actual else { return nil }
        return "指定したブランチ「\(requested)」は「\(actual)」として作成されました。"
    }

    var body: some View {
        NavigationStack {
            Form {
                if let pending {
                    Section(LAAWorkPresentation.japanese("作成結果は未確認")) {
                        Text(verbatim: "同じ要求を再照合します。別の作業場所は作りません。")
                        Button(LAAWorkPresentation.japanese("同じ要求を再照合")) { Task { await perform(pending) } }.disabled(busy)
                    }
                }
                if let error { Text(verbatim: error).foregroundStyle(LAAColors.plum) }
                Picker(LAAWorkPresentation.japanese("元のリポジトリ"), selection: $repoID) {
                    Text(verbatim: "選択してください").tag("")
                    ForEach(repositories) { item in Text(verbatim: item.displayPath ?? item.path).tag(item.id) }
                }.accessibilityIdentifier("work.workspace.repo")
                TextField(LAAWorkPresentation.japanese("作業場所の名前"), text: $worktreeName).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("work.workspace.name")
                TextField(LAAWorkPresentation.japanese("ブランチ名"), text: $branch).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("work.workspace.branch")
                Button(LAAWorkPresentation.japanese("作成")) { start() }
                    .disabled(repoID.isEmpty || worktreeName.isEmpty || branch.isEmpty || busy || pending != nil || drafts.persistenceFailed)
                    .accessibilityIdentifier("work.workspace.create")
            }
            .navigationTitle(Text(verbatim: "新しい作業場所"))
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(LAAWorkPresentation.japanese("閉じる")) { dismiss() } } }
        }
    }
    private func start() {
        guard let key else { return }
        let request = Request(repoId: repoID, worktreeName: worktreeName, branch: branch,
                              projectId: projectID.isEmpty ? nil : projectID)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let body = try? encoder.encode(request),
              let item = LAAWorkDrafts.reserve(drafts, key: key, text: "作業場所: \(worktreeName) · \(branch)", body: body,
                                               idempotency: LAABridgeIdempotencyKey()) else {
            error = "作成要求を保存できませんでした。"; return
        }
        Task { await perform(item) }
    }
    @MainActor private func perform(_ item: ComposerDraftStore.Submission) async {
        guard LAAWorkDrafts.canRepeat(item) else { error = LAAWorkDrafts.expiredMessage; return }
        guard let (body, key) = LAAWorkDrafts.request(item) else { error = "作成要求の記録を読み取れません。"; return }
        busy = true; defer { busy = false }
        do {
            let result: LAAWorkWorkspace = try await LAAWorkHTTP.write(bridge, path: "/v1/workspaces", body: body, key: key)
            guard drafts.finishSubmission(item.id, restoring: false) else { error = "作成結果を保存できません。"; return }
            let requested = (try? JSONDecoder().decode(Request.self, from: body))?.branch
            onSuccess(result, Self.branchNotice(requested: requested, actual: result.branch))
        } catch let failure as LAABridgeHTTPError {
            if LAAWorkHTTP.outcomeUnknown(failure) { drafts.markSubmissionUnknown(item.id) }
            else { _ = drafts.finishSubmission(item.id, restoring: false) }
            error = LAAWorkHTTP.message(failure)
        } catch let failure as LAABridgeError {
            drafts.markSubmissionUnknown(item.id); error = failure.japaneseText
        } catch { drafts.markSubmissionUnknown(item.id); self.error = "作成結果を確認できませんでした。" }
    }
}
#endif
