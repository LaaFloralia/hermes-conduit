#if LAA_BUILD
import SwiftUI

struct LAAWorkProjectChanges: Codable {
    let name: String
    let instructions: String?
    let clearInstructionRef: Bool
    let defaultProfile: String?
    let changesDefaultProfile: Bool
    enum CodingKeys: String, CodingKey { case name, instructions, instructionRef, defaultProfile }
    init(name: String, instructions: String?, clearInstructionRef: Bool = false,
         defaultProfile: String? = nil, changesDefaultProfile: Bool = false) {
        self.name = name; self.instructions = instructions; self.clearInstructionRef = clearInstructionRef
        self.defaultProfile = defaultProfile; self.changesDefaultProfile = changesDefaultProfile
    }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        defaultProfile = try box.decodeIfPresent(String.self, forKey: .defaultProfile)
        changesDefaultProfile = box.contains(.defaultProfile)
        name = try box.decode(String.self, forKey: .name)
        instructions = try box.decodeIfPresent(String.self, forKey: .instructions)
        if box.contains(.instructionRef) { clearInstructionRef = try box.decodeNil(forKey: .instructionRef) }
        else { clearInstructionRef = false }
    }
    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(name, forKey: .name)
        try box.encodeIfPresent(instructions, forKey: .instructions)
        if clearInstructionRef { try box.encodeNil(forKey: .instructionRef) }
        if changesDefaultProfile {
            if let defaultProfile { try box.encode(defaultProfile, forKey: .defaultProfile) }
            else { try box.encodeNil(forKey: .defaultProfile) }
        }
    }
}

struct LAAWorkProjectEditor: View {
    private typealias ChangeSet = LAAWorkProjectChanges
    private struct Draft: Codable { let body: ChangeSet; let baseETag: String? }
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var drafts: ComposerDraftStore
    let canEditInstructions: Bool
    private let clearLegacyRefInitially: Bool
    @State private var options: LAAWorkSessionOptions?
    @State private var defaultProfile: String
    @State private var current: LAAWorkProject?
    @State private var name: String
    @State private var instructions: String
    @State private var clearLegacyRef: Bool
    @State private var draftETag: String?
    @State private var remote: LAAWorkProject?
    @State private var confirmedConflict = false
    @State private var busy = false
    @State private var error: String?

    init(project: LAAWorkProject?, canEditInstructions: Bool, drafts: ComposerDraftStore,
         clearLegacyRefInitially: Bool = false) {
        self.canEditInstructions = canEditInstructions; self.drafts = drafts
        self.clearLegacyRefInitially = clearLegacyRefInitially
        _defaultProfile = State(initialValue: project?.defaultProfile ?? "")
        _current = State(initialValue: project)
        _name = State(initialValue: project?.name ?? "")
        _instructions = State(initialValue: project?.instructions ?? "")
        _clearLegacyRef = State(initialValue: project?.instructionRef != nil && clearLegacyRefInitially)
        _draftETag = State(initialValue: project?.etag)
    }
    private var key: ComposerDraftKey? {
        bridge.deviceID.map { LAAWorkDrafts.key(deviceID: $0, target: "project:\(current?.id ?? "new")") }
    }
    private var pending: ComposerDraftStore.Submission? { key.flatMap { LAAWorkDrafts.pending(drafts, key: $0) } }

    var body: some View {
        NavigationStack {
            Form {
                if let error { Text(verbatim: error).foregroundStyle(LAAColor.attention) }
                if let remote, let pending {
                    Section(LAAWorkPresentation.japanese("現在の版とあなたの変更")) {
                        Text(verbatim: "現在の版 \(remote.version.map(String.init) ?? "未確認")")
                        Text(verbatim: "現在の名前: \(remote.name)")
                        Text(verbatim: "現在の既定モデル: " + profileLabel(remote.defaultProfile))
                        Text(verbatim: "現在の指示:").laaTextStyle(.body).fontWeight(.semibold)
                        Text(verbatim: remote.instructionError != nil ? "（読み取れません）" : (remote.instructions ?? "（なし）")).textSelection(.enabled)
                        Text(verbatim: "あなたの変更:").laaTextStyle(.body).fontWeight(.semibold)
                        if let mine = draftBody(pending) {
                            Text(verbatim: "名前: " + mine.name).textSelection(.enabled)
                            if mine.changesDefaultProfile { Text(verbatim: "既定モデル: " + profileLabel(mine.defaultProfile)) }
                            Text(verbatim: mine.instructions ?? "（指示は変更しない）").textSelection(.enabled)
                            if mine.clearInstructionRef { Text(verbatim: "旧形式の参照を消去") }
                        }
                        if !confirmedConflict {
                            Text(verbatim: "前の保存結果は未確認です。結果を確定するまで選択できません。")
                                .foregroundStyle(LAAColor.attention)
                            Button(LAACopy.WorkTab.retryRequest) { Task { await perform(pending) } }.disabled(busy)
                        }
                        Button(LAACopy.WorkTab.useCurrent) { chooseRemote(remote, pending: pending) }
                            .disabled(!confirmedConflict)
                        Button(LAACopy.WorkTab.saveMine) { chooseMine(remote, pending: pending) }
                            .disabled(!confirmedConflict || (canEditInstructions && (!remote.hasInstructionBody || remote.instructionError != nil)))
                    }
                } else if let pending {
                    Section(LAAWorkPresentation.japanese("保存結果は未確認")) {
                        Text(verbatim: "保存先の状態を確認し、同じ要求を再照合できます。")
                        if !confirmedConflict {
                            Button(LAACopy.WorkTab.retryRequest) { Task { await perform(pending) } }.disabled(busy)
                        }
                        if current != nil {
                            Button(LAACopy.WorkTab.compare) { Task { await loadConflict() } }.disabled(busy)
                        }
                    }
                }
                Section(LAAWorkPresentation.japanese("名前")) { TextField(LAACopy.WorkTab.projectName, text: $name).disabled(pending != nil) }
                defaultModelSection
                Section(LAAWorkPresentation.japanese("共通指示")) {
                    if current?.instructionRef != nil {
                        Text(verbatim: "旧形式の参照・未適用").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        Button(clearLegacyRef ? LAACopy.WorkTab.undoClearLegacy : LAACopy.WorkTab.clearLegacy) {
                            clearLegacyRef.toggle()
                        }.disabled(pending != nil || !canEditInstructions)
                        if clearLegacyRef { Text(verbatim: "保存時に旧参照を消去します。").laaTextStyle(.secondary) }
                    }
                    if canEditInstructions {
                        TextEditor(text: $instructions).frame(minHeight: 180).disabled(pending != nil)
                            .scrollContentBackground(.hidden).background(LAAColor.surface)
                            .accessibilityIdentifier("work.project.instructions")
                    } else {
                        Text(verbatim: "MacのLAAアプリが指示本文を返すまで編集できません。")
                            .foregroundStyle(LAAColor.secondaryText)
                    }
                }
                Button(LAACopy.WorkTab.save) { save() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy || pending != nil || drafts.persistenceFailed)
            }
            .scrollContentBackground(.hidden)
            .background(LAAColor.background)
            .listRowBackground(LAAColor.surface)
            .laaTextStyle(.body)
            .foregroundStyle(LAAColor.text)
            .tint(LAAColor.link)
            .onChange(of: name) { _, _ in saveDraft() }
            .onChange(of: instructions) { _, _ in saveDraft() }
            .onChange(of: defaultProfile) { _, _ in saveDraft() }
            .onChange(of: clearLegacyRef) { _, _ in saveDraft() }
            .task {
                restoreDraft()
                options = try? await LAAWorkOptionsStore.read(bridge)
                if clearLegacyRefInitially && current?.instructionRef != nil && pending == nil {
                    clearLegacyRef = true
                    saveDraft()
                }
                if let pending, LAAWorkConflictJournal.contains(pending.id) {
                    confirmedConflict = true
                    await loadConflict()
                }
            }
            .navigationTitle(Text(verbatim: current == nil ? LAACopy.WorkTab.newProject : LAACopy.WorkTab.editProject))
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(LAACopy.WorkTab.close) { dismiss() } } }
        }
    }
    private func profileLabel(_ id: String?) -> String {
        guard let id else { return "共通の既定値" }
        return options?.profiles.first { $0.id == id }?.label ?? id
    }
    private var defaultModelSection: some View {
        Section(LAAWorkPresentation.japanese("新しい会話の既定モデル")) {
            let choices = options?.switchingOptions
            let selected = choices?.profiles.first { $0.id == defaultProfile }
            let model = LAAWorkModelSelection.model(of: defaultProfile, in: choices)
            LAAModelEffortPickers(model: selected?.model, provider: selected?.provider, effort: selected?.effort,
                                 name: model?.label ?? (defaultProfile.isEmpty ? "共通の既定値" : "現在は選べないモデル"),
                                 identifier: "work.project.default") {
                Button { defaultProfile = "" } label: { Text(verbatim: "共通の既定値") }
                ForEach(LAAWorkModelSelection.providers(LAAWorkModelSelection.models(choices)), id: \.name) { group in
                    Section(group.name) {
                        ForEach(group.models) { choice in
                            Button {
                                if let next = LAAWorkModelSelection.profile(switchingTo: choice, from: selected) { defaultProfile = next.id }
                            } label: { LAAModelMenu.Name(label: choice.label, model: choice.model) }
                        }
                    }
                }
            } effortMenu: {
                ForEach(model?.efforts ?? [], id: \.self) { effort in
                    LAAEffortMenu.Row(effort: effort, selected: effort == selected?.effort) {
                        if let next = LAAWorkModelSelection.profile(effort: effort, of: defaultProfile, in: choices) { defaultProfile = next.id }
                    }
                }
            }
            .disabled(pending != nil || options == nil || (current != nil && current?.hasDefaultProfile != true))
            if current != nil && current?.hasDefaultProfile != true {
                Text(verbatim: "MacのLAAアプリの更新後に変更できます。").laaTextStyle(.secondary)
            }
        }
    }
    private func draftBody(_ item: ComposerDraftStore.Submission) -> ChangeSet? {
        guard let (bytes, _) = LAAWorkDrafts.request(item) else { return nil }
        return try? JSONDecoder().decode(ChangeSet.self, from: bytes)
    }
    private func saveDraft() {
        guard let key, pending == nil else { return }
        let edited = canEditInstructions && (current == nil || instructions != (current?.instructions ?? ""))
        let body = ChangeSet(name: name, instructions: edited ? instructions : nil,
                        clearInstructionRef: canEditInstructions && clearLegacyRef && current?.instructionRef != nil,
                        defaultProfile: defaultProfile.isEmpty ? nil : defaultProfile,
                        changesDefaultProfile: (current == nil || current?.hasDefaultProfile == true)
                            && defaultProfile != (current?.defaultProfile ?? ""))
        let snapshot = Draft(body: body, baseETag: draftETag)
        guard let bytes = try? JSONEncoder().encode(snapshot), let text = String(data: bytes, encoding: .utf8),
              drafts.save(ComposerDraft(text: text, attachments: []), for: key) else {
            error = "下書きを端末に保存できませんでした。"; return
        }
    }
    private func restoreDraft() {
        guard let key, pending == nil, drafts.hasDraft(for: key),
              let bytes = drafts.draft(for: key).text.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(Draft.self, from: bytes) else { return }
        draftETag = snapshot.baseETag
        name = snapshot.body.name
        if snapshot.body.changesDefaultProfile { defaultProfile = snapshot.body.defaultProfile ?? "" }
        instructions = snapshot.body.instructions ?? current?.instructions ?? ""
        clearLegacyRef = canEditInstructions && snapshot.body.clearInstructionRef && current?.instructionRef != nil
    }
    private func save() {
        guard let key else { return }
        guard current == nil || draftETag != nil else { error = "プロジェクトの版を取得してから保存してください。"; return }
        let edited = canEditInstructions && (current == nil || instructions != (current?.instructions ?? ""))
        let body = ChangeSet(name: name, instructions: edited ? instructions : nil,
                        clearInstructionRef: canEditInstructions && clearLegacyRef && current?.instructionRef != nil,
                        defaultProfile: defaultProfile.isEmpty ? nil : defaultProfile,
                        changesDefaultProfile: (current == nil || current?.hasDefaultProfile == true)
                            && defaultProfile != (current?.defaultProfile ?? ""))
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let bytes = try? encoder.encode(body), let draft = try? encoder.encode(Draft(body: body, baseETag: draftETag)),
              let item = LAAWorkDrafts.reserve(drafts, key: key, text: String(decoding: draft, as: UTF8.self), body: bytes,
                                               idempotency: LAABridgeIdempotencyKey(), expectedVersion: draftETag) else {
            error = "変更を安全に記録できませんでした。"; return
        }
        Task { await perform(item) }
    }
    @MainActor private func perform(_ item: ComposerDraftStore.Submission) async {
        guard LAAWorkDrafts.canRepeat(item) else { error = LAAWorkDrafts.expiredMessage; return }
        guard let (body, key) = LAAWorkDrafts.request(item) else { error = "保存要求を読み取れません。"; return }
        busy = true; defer { busy = false }
        do {
            let saved: LAAWorkProject = try await LAAWorkHTTP.projectWrite(bridge: bridge, id: current?.id,
                                                                          body: body, key: key, etag: item.screenshotID)
            guard drafts.finishSubmission(item.id, restoring: false) else { error = "保存結果を端末に記録できません。"; return }
            current = saved
            dismiss()
        } catch let failure as LAABridgeHTTPError {
            if current != nil && LAAWorkHTTP.isVersionConflict(failure) {
                drafts.markSubmissionUnknown(item.id)
                if LAAWorkConflictJournal.mark(item.id) {
                    confirmedConflict = true
                    await loadConflict()
                } else { error = "競合の記録を保存できません。変更は保留しています。" }
            } else if LAAWorkHTTP.outcomeUnknown(failure) {
                drafts.markSubmissionUnknown(item.id); error = LAAWorkHTTP.message(failure)
            } else {
                if drafts.finishSubmission(item.id, restoring: true) { restoreDraft() }
                error = LAAWorkHTTP.message(failure)
            }
        } catch let failure as LAABridgeError {
            drafts.markSubmissionUnknown(item.id); error = failure.japaneseText
        } catch { drafts.markSubmissionUnknown(item.id); self.error = "保存結果を確認できませんでした。" }
    }
    @MainActor private func loadConflict() async {
        guard let current else { return }
        do { remote = try await bridge.read("/v1/projects/\(current.id)"); error = nil }
        catch let failure as LAABridgeError { error = failure.japaneseText }
        catch { self.error = "現在の版を読み取れませんでした。" }
    }
    private func chooseRemote(_ remote: LAAWorkProject, pending: ComposerDraftStore.Submission) {
        guard confirmedConflict else { return }
        guard drafts.finishSubmission(pending.id, restoring: false) else { error = "選択を保存できませんでした。"; return }
        LAAWorkConflictJournal.clear(pending.id)
        current = remote; draftETag = remote.etag; name = remote.name; instructions = remote.instructions ?? ""
        defaultProfile = remote.defaultProfile ?? ""
        clearLegacyRef = false
        confirmedConflict = false; self.remote = nil
    }
    private func chooseMine(_ remote: LAAWorkProject, pending: ComposerDraftStore.Submission) {
        guard confirmedConflict else { return }
        guard let (payload, _) = LAAWorkDrafts.request(pending), let body = try? JSONDecoder().decode(ChangeSet.self, from: payload) else {
            error = "保存前の変更を読み取れませんでした。"; return
        }
        guard drafts.finishSubmission(pending.id, restoring: true) else { error = "選択を保存できませんでした。"; return }
        LAAWorkConflictJournal.clear(pending.id)
        current = remote; draftETag = remote.etag; name = body.name; instructions = body.instructions ?? remote.instructions ?? ""
        defaultProfile = body.changesDefaultProfile ? (body.defaultProfile ?? "") : (remote.defaultProfile ?? "")
        clearLegacyRef = body.clearInstructionRef && remote.instructionRef != nil
        confirmedConflict = false; self.remote = nil
        save()
    }
}
#endif
