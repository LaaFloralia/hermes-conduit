#if LAA_BUILD
import SwiftUI

struct LAAStudioCreateView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let snapshot: LAAStudioSnapshot
    var initialProject: LAAStudioProject? = nil
    var initialPrompt: String = ""
    var draftID: String? = nil
    var initialPrinciple: LAAStudioRequest.Principle? = nil
    var inline = false
    var onSubmitted: () -> Void = {}
    @State private var draft = LAAStudioDraft()
    @State private var initialized = false
    @State private var storageBlocked = false
    @State private var done = false
    @State private var revision: UInt64 = 0
    @State private var sending = false
    @State private var canRetry = false
    @State private var error: String?
    private var device: String { bridge.deviceID ?? "fixture" }
    private var selection: Binding<String> {
        Binding(get: { draft.projectID ?? "" }, set: { value in
            draft.projectID = value.isEmpty ? nil : value
            draft.expectedRevision = snapshot.projects.first(where: { $0.id == value })?.revision ?? 0
            draft.resetSubmission()
        })
    }
    @Environment(\.dismiss) private var dismiss
    @State private var referencePicker = false
    @State private var upload = false
    @State private var selectUploadedReference = false
    @FocusState private var promptFocused: Bool
    var body: some View {
        Group { if inline { composer } else { form } }
        .tint(LAAColor.link)
        .sheet(isPresented: $referencePicker) {
            LAAStudioReferencePicker { reference in
                if draft.references == nil { draft.references = [] }
                if draft.references?.contains(reference) != true { draft.references?.append(reference) }
            }.environmentObject(bridge)
        }
        .sheet(isPresented: $upload, onDismiss: {
            if selectUploadedReference { selectUploadedReference = false; referencePicker = true }
        }) {
            LAADriveUpload(folderId: nil) { selectUploadedReference = true }.environmentObject(bridge)
        }
        .onAppear {
            guard !initialized else { return }
            let saved: LAAStudioDraft?
            switch LAAStudioDraftStore.loadResult(deviceID: device, draftID: draftID) {
            case .missing: saved = nil
            case .loaded(let value): saved = value
            case .unreadable:
                storageBlocked = true
                error = "保存済みの下書きを読み取れません。内容を保持するため送信を止めています。"
                initialized = true
                return
            }
            draft = saved ?? LAAStudioDraft()
            canRetry = draft.pending && draft.workBusy == true
            if saved == nil {
                if let initialProject {
                    draft.projectID = initialProject.id; draft.expectedRevision = initialProject.revision; draft.prompt = initialPrompt
                }
                draft.principle = initialPrinciple
                if (initialProject != nil || initialPrinciple != nil) && !LAAStudioDraftStore.save(draft, deviceID: device, draftID: draftID) {
                    storageBlocked = true; error = LAACopy.Studio.saveFailed
                }
            }
            initialized = true
        }
        .onChange(of: draft) { _, value in
            guard initialized && !storageBlocked else { return }
            if done { done = false; return }
            if !LAAStudioDraftStore.save(value, deviceID: device, draftID: draftID) { storageBlocked = true; error = LAACopy.Studio.saveFailed }
        }
    }
    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x6) {
                TextField(String("何を作りますか"), text: $draft.prompt, axis: .vertical)
                    .font(.title3).lineLimit(6...14).focused($promptFocused)
                    .disabled(draft.pending || sending || storageBlocked)
                    .accessibilityIdentifier("laa.studio.composer.field")
                HStack(spacing: LAASpacing.x2) {
                    ForEach(["画像", "動画", "資料", "その他"], id: \.self) { kind in
                        Button { draft.kind = draft.kind == kind ? nil : kind } label: {
                            Text(verbatim: kind).studioFilterChip(selected: draft.kind == kind)
                        }.buttonStyle(.plain).disabled(draft.pending || sending || storageBlocked)
                            .accessibilityIdentifier("laa.studio.kind.\(kind)")
                    }
                }
                Menu {
                    Button(String("写真から選ぶ"), systemImage: "photo") { upload = true }
                    Button(String("Driveから選ぶ"), systemImage: "folder") { referencePicker = true }
                } label: { Label(String("参考を添付"), systemImage: "paperclip").frame(minHeight: 44) }
                    .disabled(draft.pending || sending || storageBlocked)
                if let references = draft.references, !references.isEmpty {
                    ForEach(references, id: \.self) { reference in
                        HStack {
                            Text(verbatim: reference.components(separatedBy: "\n").first ?? "参考").lineLimit(1)
                            Spacer()
                            Button { draft.references?.removeAll { $0 == reference } } label: { Image(systemName: "xmark") .frame(width: 44, height: 44) }.accessibilityLabel(String("参考を外す"))
                                .disabled(draft.pending || sending || storageBlocked)
                        }.laaTextStyle(.secondary)
                    }
                }
                LabeledContent(String("作品")) {
                    Picker(String("作品"), selection: selection) {
                        Text(verbatim: "新規").tag("")
                        ForEach(snapshot.projects) { project in Text(verbatim: project.title).tag(project.id) }
                    }.labelsHidden().frame(minHeight: 44).disabled(draft.pending || sending || storageBlocked)
                        .accessibilityIdentifier("laa.studio.project")
                }
                if draft.prompt.utf16.count > 9000 {
                    Text(verbatim: "\(draft.prompt.utf16.count) / 10,000").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                }
                if draft.pending {
                    Text(verbatim: draft.workBusy == true ? LAACopy.Studio.workBusy : LAACopy.Studio.uncertain)
                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                    Button(String("状態を確認")) { Task { await check() } }.frame(minHeight: 44).disabled(sending || storageBlocked)
                        .accessibilityIdentifier("laa.studio.check")
                    if canRetry {
                        Button(String("再試行")) { Task { await submit() } }.frame(minHeight: 44).disabled(sending || storageBlocked)
                            .accessibilityIdentifier("laa.studio.retry")
                    }
                } else {
                    Button(sending ? String("送信中") : String("依頼する")) { promptFocused = false; Task { await submit() } }
                        .laaGlassButton(prominent: true)
                        .disabled(sending || storageBlocked || draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.prompt.utf16.count > 10000)
                        .accessibilityIdentifier("laa.studio.composer.send")
                }
                if let error { Text(verbatim: error).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention) }
            }.padding(LAASpacing.horizontal).laaPageWidth()
        }
        .background(LAAColor.background.ignoresSafeArea()).navigationTitle(String("制作を依頼"))
        .tint(LAAColor.link).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } } }
    }

    private var editingBlocked: Bool { draft.pending || sending || storageBlocked }
    private var canSend: Bool {
        !editingBlocked && !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.prompt.utf16.count <= 10000
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            TextField(initialProject == nil ? String("何を作りますか") : String("直してほしい点"),
                      text: $draft.prompt, axis: .vertical)
                .font(.body).lineLimit(2...8).focused($promptFocused).disabled(editingBlocked)
                .accessibilityIdentifier("laa.studio.composer.field")
            if let references = draft.references {
                ForEach(references, id: \.self) { reference in
                    HStack {
                        Text(verbatim: reference.components(separatedBy: "\n").first ?? "参考").lineLimit(1)
                        Spacer()
                        Button { draft.references?.removeAll { $0 == reference } } label: {
                            Image(systemName: "xmark").frame(width: 44, height: 44)
                        }.accessibilityLabel(Text(verbatim: "参考を外す")).disabled(editingBlocked)
                    }.laaTextStyle(.secondary)
                }
            }
            HStack(spacing: LAASpacing.x1) {
                Menu {
                    Button(String("写真から選ぶ"), systemImage: "photo") { upload = true }
                    Button(String("Driveから選ぶ"), systemImage: "folder") { referencePicker = true }
                } label: { Image(systemName: "plus").frame(width: 36, height: 44) }
                .accessibilityLabel(Text(verbatim: "参考を添付")).disabled(editingBlocked)
                ForEach(["画像", "動画", "資料"], id: \.self) { kind in
                    Button { draft.kind = draft.kind == kind ? nil : kind } label: {
                        Text(verbatim: kind).studioFilterChip(selected: draft.kind == kind)
                    }.buttonStyle(.plain).disabled(editingBlocked)
                        .accessibilityIdentifier("laa.studio.kind.\(kind)")
                        .accessibilityAddTraits(draft.kind == kind ? .isSelected : [])
                }
                Spacer(minLength: 0)
                Button { promptFocused = false; Task { await submit() } } label: {
                    Image(systemName: "arrow.up").font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(canSend ? .white : LAAColor.secondaryText)
                        .frame(width: 36, height: 36)
                        .laaComposerGlass(in: Circle(), fill: canSend ? LAAColor.link : nil)
                        .frame(minWidth: 44, minHeight: 44)
                }.buttonStyle(.plain).disabled(!canSend)
                    .accessibilityLabel(Text(verbatim: initialProject == nil ? "依頼する" : "直しを頼む"))
                    .accessibilityIdentifier("laa.studio.composer.send")
            }
            if draft.pending && !sending {
                HStack {
                    Button(String("状態を確認")) { Task { await check() } }.frame(minHeight: 44)
                        .accessibilityIdentifier("laa.studio.check")
                    if canRetry {
                        Button(String("再試行")) { Task { await submit() } }.frame(minHeight: 44)
                            .accessibilityIdentifier("laa.studio.retry")
                    }
                }.disabled(storageBlocked)
            }
            if let error { Text(verbatim: error).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention) }
        }.padding(LAASpacing.x4)
            .frame(maxWidth: .infinity, minHeight: 112)
            .laaComposerGlass(in: RoundedRectangle(cornerRadius: 22))
    }

    private func finish(_ record: LAAStudioRecord) {
        done = true
        if LAAStudioDraftStore.clear(deviceID: device, draftID: draftID) {
            draft = LAAStudioDraft()
            if let initialProject {
                draft.projectID = initialProject.id
                draft.expectedRevision = snapshot.projects.first(where: { $0.id == initialProject.id })?.revision ?? initialProject.revision
            }
            draft.principle = initialPrinciple
            canRetry = false
        } else {
            storageBlocked = true
            error = LAACopy.Studio.saveFailed
        }
        NotificationCenter.default.post(name: .laaStudioChanged, object: record)
        if inline { onSubmitted() } else { dismiss() }
    }

    @MainActor private func submit() async {
        guard !sending && !storageBlocked && (!draft.pending || canRetry) else { return }
        sending = true; error = nil
        defer { sending = false }
        do {
            if draft.requestID == nil { draft.requestID = try await LAAStudioData.requestID(bridge) }
            if draft.isNew && draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.title = String(draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
            }
            let rotateKey = draft.pending && draft.workBusy != true
            guard let submission = try draft.submission(rotateKey: rotateKey) else { error = LAACopy.Studio.invalid; return }
            let previousDraft = draft
            let previousCanRetry = canRetry
            draft.pending = true
            draft.workBusy = nil
            canRetry = false
            guard LAAStudioDraftStore.save(draft, deviceID: device, draftID: draftID) else {
                draft = previousDraft; canRetry = previousCanRetry; error = LAACopy.Studio.saveFailed; return
            }
            let record = try await LAAStudioData.submit(submission.request, body: submission.body, key: submission.key, bridge: bridge)
            finish(record)
        } catch let failure as LAABridgeHTTPError {
            if failure.status == 409 && failure.code == "studio_work_busy" && failure.retryable == true {
                draft.workBusy = true; canRetry = true
                if !LAAStudioDraftStore.save(draft, deviceID: device, draftID: draftID) { error = LAACopy.Studio.saveFailed }
            } else {
                let refused = ["studio_revision_changed", "studio_principle_changed", "invalid_request", "studio_payload_invalid", "insufficient_scope"].contains(failure.code ?? "")
                if refused { draft.resetSubmission(); _ = LAAStudioDraftStore.save(draft, deviceID: device, draftID: draftID) }
                error = LAAStudioData.message(failure)
            }
        } catch { self.error = LAAStudioData.message(error) }
    }
    @MainActor private func check() async {
        guard let id = draft.requestID, !sending, !storageBlocked else { return }
        sending = true; error = nil
        defer { sending = false }
        do {
            let record = try await LAAStudioData.record(id, bridge: bridge)
            finish(record)
        } catch let failure as LAABridgeHTTPError {
            canRetry = draft.workBusy == true || failure.code == "studio_request_missing"
            error = LAAStudioData.message(failure)
        } catch { self.error = LAAStudioData.message(error) }
    }
}

private struct LAAStudioInputField: ViewModifier {
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain)
            .padding(.horizontal, LAASpacing.x3)
            .frame(minHeight: LAASpacing.minimumTouchTarget)
            .background(LAAColor.subtleSurface, in: RoundedRectangle(cornerRadius: LAARadius.card))
            .overlay(RoundedRectangle(cornerRadius: LAARadius.card).stroke(LAAColor.separator))
    }
}

extension View {
    func studioInputField() -> some View { modifier(LAAStudioInputField()) }

    func studioFilterChip(selected: Bool) -> some View {
        fontWeight(selected ? .semibold : .regular)
            .foregroundStyle(selected ? LAAColor.link : LAAColor.secondaryText)
            .frame(minHeight: LAASpacing.minimumTouchTarget)
            .padding(.horizontal, LAASpacing.x4)
            .laaGlass(in: Capsule(), selected: selected)
    }
}
#endif
