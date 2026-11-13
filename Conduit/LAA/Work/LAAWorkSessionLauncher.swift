#if LAA_BUILD
import SwiftUI

/// A saved model setting the owner reuses ("Opus High ⚡︎").
struct LAAWorkModelFavorite: Codable, Hashable, Identifiable {
    let profile: String
    let fast: Bool
    var id: String { "\(profile)|\(fast)" }
}

enum LAAWorkModelPreferences {
    static let favoritesKey = "laa.work.modelFavorites"
    static let lastKey = "laa.work.lastModel"

    static func decode(_ raw: String) -> [LAAWorkModelFavorite] {
        (try? JSONDecoder().decode([LAAWorkModelFavorite].self, from: Data(raw.utf8))) ?? []
    }
    static func encode(_ items: [LAAWorkModelFavorite]) -> String {
        (try? JSONEncoder().encode(items)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}

/// New session: the request, an optional project and the model. Always runs in
/// /Users/laa (no worktree choice) and, unless switched off, without permission prompts.
struct LAAWorkSessionLauncher: View {
    private struct Request: Codable {
        let requestId: String
        let profile: String
        let prompt: String
        let projectId: String?
        let mode: String
        let fast: Bool
    }
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.dismiss) private var dismiss
    let projects: [LAAWorkProject]
    @ObservedObject var drafts: ComposerDraftStore
    let onCreated: (LAAWorkSession) -> Void

    @State private var options: LAAWorkSessionOptions?
    @State private var projectID: String
    @State private var profile = ""
    @State private var fast = false
    @State private var bypass = true
    @State private var prompt = ""
    @State private var revision: UInt64 = 0
    @State private var starting = false
    @State private var error: String?
    @AppStorage(LAAWorkModelPreferences.favoritesKey) private var favoritesRaw = "[]"
    @AppStorage(LAAWorkModelPreferences.lastKey) private var lastRaw = ""

    init(projects: [LAAWorkProject], options: LAAWorkSessionOptions?, drafts: ComposerDraftStore,
         projectID: String = "", onCreated: @escaping (LAAWorkSession) -> Void) {
        self.projects = projects; self.drafts = drafts; self.onCreated = onCreated
        _options = State(initialValue: options)
        _projectID = State(initialValue: projectID)
    }

    private var favorites: [LAAWorkModelFavorite] { LAAWorkModelPreferences.decode(favoritesRaw) }
    private var selected: LAAWorkSessionOptions.Profile? { options?.profiles.first { $0.id == profile } }
    private var current: LAAWorkModelFavorite { LAAWorkModelFavorite(profile: profile, fast: fast && selected?.fast == true) }
    private var key: ComposerDraftKey? { bridge.deviceID.map { LAAWorkDrafts.key(deviceID: $0, target: "launch-session") } }
    private var pending: ComposerDraftStore.Submission? { key.flatMap { LAAWorkDrafts.pending(drafts, key: $0) } }
    private var canStart: Bool {
        selected != nil && !starting && pending == nil && !drafts.persistenceFailed
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LAASpacing.x4) {
                    if let pending { unknown(pending) }
                    if let error {
                        Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                            .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                    }
                    projectPicker
                    modelBar
                    if !favorites.isEmpty { favoriteChips }
                    LAAWorkComposer(text: $prompt, revision: $revision, placeholder: "依頼内容",
                                    enabled: !starting && pending == nil && !drafts.persistenceFailed,
                                    canSend: selected != nil,
                                    onChange: saveDraft, onSubmit: start, submitLabel: "開始",
                                    accessibilityPrefix: "work.launch.composer")
                    Text(verbatim: "/Users/laa で開始 · " + (bypass ? "確認なしで実行" : "操作ごとに確認"))
                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                }
                .padding(.horizontal, LAASpacing.horizontal).padding(.vertical, LAASpacing.x4)
                .laaPageWidth()
            }
            .background(LAAColor.background)
            .laaTextStyle(.body).foregroundStyle(LAAColor.text)
            .navigationTitle(Text(verbatim: "新しいセッション"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Text(verbatim: LAACopy.close) }
                }
            }
        }
        .onChange(of: projectID) { _, _ in applyProjectDefault() }
        .tint(LAAColor.link)
        .laaSheetSize(.form)
        .task(id: bridge.revision) {
            if let key { revision &+= 1; prompt = drafts.draft(for: key).text }
            if options == nil { options = try? await bridge.read("/v1/session-options") }
            applyInitialModel()
        }
    }

    private var projectPicker: some View {
        Menu {
            Button { projectID = "" } label: { Text(verbatim: "プロジェクトなし") }
            ForEach(projects) { item in
                Button { projectID = item.id } label: { Text(verbatim: item.name) }
            }
        } label: {
            HStack(spacing: LAASpacing.x2) {
                Image(systemName: "folder")
                Text(verbatim: projects.first { $0.id == projectID }?.name ?? "プロジェクトなし").lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11))
            }
            .laaTextStyle(.secondary).foregroundStyle(LAAColor.text)
            .padding(.horizontal, LAASpacing.x3).frame(minHeight: 36)
            .background(LAAColor.subtleSurface, in: Capsule())
        }
        .accessibilityIdentifier("work.launch.project")
    }

    /// The control layer of the sheet: the model and the effort, each its
    /// own capsule and menu (LAAModelEffortPickers), then Fast and the
    /// favourite star, all 36pt Liquid Glass (HIG: glass for controls, not
    /// content).
    private var modelBar: some View {
        HStack(spacing: LAASpacing.x2) {
            let models = LAAWorkModelSelection.models(options)
            let chosen = LAAWorkModelSelection.model(of: profile, in: options)
            LAAModelEffortPickers(
                model: selected?.model, provider: selected?.provider, effort: selected?.effort,
                name: chosen?.label ?? (options == nil ? "読み込み中" : "モデルを選択"),
                identifier: "work.launch"
            ) {
                if options == nil { LAAMenuReason(text: "モデルを読み込み中です。") }
                ForEach(LAAWorkModelSelection.providers(models), id: \.name) { group in
                    Section(group.name) {
                        ForEach(group.models) { item in
                            Toggle(isOn: Binding(get: { item.id == chosen?.id }, set: { on in if on { chooseModel(item) } })) {
                                LAAModelMenu.Name(label: item.label, model: item.model)
                            }
                            .accessibilityIdentifier("work.launch.model.\(item.model)")
                        }
                    }
                }
                Section {
                    Toggle(isOn: $bypass) { Text(verbatim: "確認なしで実行") }
                        .accessibilityIdentifier("work.launch.bypass")
                }
            } effortMenu: {
                if let chosen {
                    if chosen.profiles.count < 2 { LAAMenuReason(text: "このモデルで選べる推論はこれだけです。") }
                    Section {
                        ForEach(chosen.profiles) { item in
                            // XHigh and Max carry the deep-effort mark here
                            // too, as in a running session's menu.
                            LAAEffortMenu.Row(effort: item.effort, selected: item.id == profile,
                                              identifier: "work.launch.effort.\(item.effort)") { choose(item.id) }
                        }
                    }
                } else {
                    LAAMenuReason(text: options == nil ? "モデルを読み込み中です。" : "先にモデルを選んでください。")
                }
            }

            Button { fast.toggle(); remember() } label: {
                Image(systemName: fast && selected?.fast == true ? "bolt.fill" : "bolt")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(fast && selected?.fast == true ? LAAColor.link : LAAColor.secondaryText)
                    .frame(width: 36, height: 36)
                    .conduitGlassControl(cornerRadius: 18)
            }
            .buttonStyle(.plain)
            .disabled(selected?.fast != true)
            .opacity(selected?.fast == true ? 1 : 0.4)
            .accessibilityLabel(Text(verbatim: "Fastモード"))
            .accessibilityValue(Text(verbatim: fast ? "オン" : "オフ"))
            .accessibilityIdentifier("work.launch.fast")

            let saved = favorites.contains(current)
            Button { toggleFavorite() } label: {
                Image(systemName: saved ? "star.fill" : "star")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(saved ? LAAColor.decorativeTan : LAAColor.secondaryText)
                    .frame(width: 36, height: 36)
                    .conduitGlassControl(cornerRadius: 18)
            }
            .buttonStyle(.plain)
            .disabled(selected == nil)
            .accessibilityLabel(Text(verbatim: saved ? "お気に入りから外す" : "お気に入りに登録"))
            .accessibilityIdentifier("work.launch.favorite")
        }
    }

    private var favoriteChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LAASpacing.x2) {
                ForEach(favorites) { item in
                    let profileItem = options?.profiles.first { $0.id == item.profile }
                    Button {
                        profile = item.profile; fast = item.fast; remember()
                    } label: {
                        Text(verbatim: profileItem.map { LAAWorkSessionStyle.profileLabel($0, fast: item.fast) } ?? item.profile)
                            .laaTextStyle(.secondary).fontWeight(item == current ? .semibold : .regular)
                            .foregroundStyle(item == current ? LAAColor.filledButtonText : LAAColor.text)
                            .padding(.horizontal, LAASpacing.x3).frame(minHeight: 32)
                            .background(item == current ? LAAColor.filledButton : LAAColor.subtleSurface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(profileItem == nil)
                    .contextMenu {
                        Button(role: .destructive) { removeFavorite(item) } label: {
                            Label { Text(verbatim: "お気に入りから外す") } icon: { Image(systemName: "star.slash") }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("work.launch.favorites")
    }

    private func applyInitialModel() {
        guard profile.isEmpty, let options else { return }
        if applyProjectDefault() {
            bypass = options.defaultMode != "default"
            return
        }
        let last = LAAWorkModelPreferences.decode("[\(lastRaw)]").first
        if let last, options.profiles.contains(where: { $0.id == last.profile }) {
            profile = last.profile; fast = last.fast
        } else {
            profile = options.defaultProfile ?? options.profiles.first?.id ?? ""
        }
        bypass = options.defaultMode != "default"
    }

    @discardableResult private func applyProjectDefault() -> Bool {
        guard pending == nil, let id = projects.first(where: { $0.id == projectID })?.defaultProfile else { return false }
        guard options?.profiles.contains(where: { $0.id == id }) == true else {
            profile = ""; fast = false
            error = "プロジェクトの既定モデルは現在選べません。別のモデルを選んでください。"
            return true
        }
        profile = id; fast = false
        return true
    }

    /// Another model keeps the effort when it has it, else High, else the
    /// nearest (LAAEffort.carried).
    private func chooseModel(_ model: LAAWorkModelSelection.Model) {
        guard let next = LAAWorkModelSelection.profile(switchingTo: model, from: selected) else { return }
        choose(next.id)
    }

    private func choose(_ id: String) {
        profile = id
        if options?.profiles.first(where: { $0.id == id })?.fast != true { fast = false }
        remember()
    }

    private func remember() {
        let text = LAAWorkModelPreferences.encode([current])
        lastRaw = String(text.dropFirst().dropLast())
    }

    private func toggleFavorite() {
        var items = favorites
        if let index = items.firstIndex(of: current) { items.remove(at: index) } else { items.append(current) }
        favoritesRaw = LAAWorkModelPreferences.encode(items)
    }

    private func removeFavorite(_ item: LAAWorkModelFavorite) {
        favoritesRaw = LAAWorkModelPreferences.encode(favorites.filter { $0 != item })
    }

    private func unknown(_ item: ComposerDraftStore.Submission) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            Label { Text(verbatim: "開始結果を確認できていません") } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                .foregroundStyle(LAAColor.attention)
            Text(verbatim: "同じ依頼として照合します。重複して開始しません。").laaTextStyle(.secondary)
            Text(verbatim: item.draft.text).laaTextStyle(.secondary).lineLimit(3)
            Button { Task { await reconcile(item) } } label: { Text(verbatim: "結果を確認") }.disabled(starting)
        }
        .workCard()
    }

    private func saveDraft(_ text: String) {
        guard let key else { return }
        if !drafts.save(ComposerDraft(text: text, attachments: []), for: key) { error = "下書きを端末に保存できませんでした。" }
    }

    private func start() {
        guard canStart, let key, let selected else { return }
        let request = Request(requestId: UUID().uuidString.lowercased(), profile: selected.id, prompt: prompt,
                              projectId: projectID.isEmpty ? nil : projectID,
                              mode: bypass ? "bypass" : "default", fast: fast && selected.fast)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let body = try? encoder.encode(request),
              let item = LAAWorkDrafts.reserve(drafts, key: key, text: prompt, body: body, idempotency: LAABridgeIdempotencyKey()) else {
            error = "開始前に依頼を端末へ保存できませんでした。"; return
        }
        remember()
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
                error = "開始結果を端末に保存できません。"; return
            }
            error = nil
            onCreated(result)
        } catch let failure as LAABridgeHTTPError {
            if LAAWorkHTTP.outcomeUnknown(failure) { drafts.markSubmissionUnknown(item.id) }
            else if drafts.finishSubmission(item.id, restoring: true), let draftKey = self.key {
                revision &+= 1; prompt = drafts.draft(for: draftKey).text
            }
            error = LAAWorkHTTP.message(failure)
        } catch let failure as LAABridgeError {
            drafts.markSubmissionUnknown(item.id); error = failure.japaneseText
        } catch {
            drafts.markSubmissionUnknown(item.id); self.error = "開始結果を確認できませんでした。"
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
                // Not on the Mac yet: send the same request and key again; the Bridge deduplicates.
                await perform(item); return
            }
            guard drafts.finishSubmission(item.id, restoring: false) else { error = "開始結果を端末に保存できません。"; return }
            error = nil
            onCreated(page.items[0])
        } catch let failure as LAABridgeError { error = failure.japaneseText }
        catch { self.error = "開始結果を確認できませんでした。" }
    }
}
#endif
