#if LAA_BUILD
import SwiftUI

struct LAAStudioCreateView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let snapshot: LAAStudioSnapshot
    var initialProject: LAAStudioProject? = nil
    var initialPrompt: String = ""
    var draftID: String? = nil
    var initialPrinciple: LAAStudioRequest.Principle? = nil
    @State private var draft = LAAStudioDraft()
    @State private var initialized = false
    @State private var storageBlocked = false
    @State private var done = false
    @State private var revision: UInt64 = 0
    @State private var sending = false
    @State private var canRetry = false
    @State private var error: String?
    @State private var created: LAAStudioRecord?
    @State private var catalog: LAAStudioCatalog?
    @State private var catalogNote: String?
    private var device: String { bridge.deviceID ?? "fixture" }
    private var selection: Binding<String> {
        Binding(get: { draft.projectID ?? "" }, set: { value in
            draft.projectID = value.isEmpty ? nil : value
            draft.expectedRevision = snapshot.projects.first(where: { $0.id == value })?.revision ?? 0
            draft.resetSubmission()
        })
    }
    private var principleSelection: Binding<String> {
        Binding(get: { draft.principle?.id ?? "" }, set: { value in
            let found = snapshot.principles.first(where: { $0.id == value })
            draft.principle = found.map { .init(id: $0.id, version: $0.version, revision: $0.revision) }
            draft.resetSubmission()
        })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x6) {
                Text(verbatim: LAACopy.Studio.newRequest).font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
                if let created {
                    Text(verbatim: "依頼を受け付けました。").foregroundStyle(LAAColor.text)
                    NavigationLink {
                        LAAStudioRequestView(initial: created, initialProject: snapshot.projects.first { $0.id == created.request.projectId })
                    } label: {
                        Text(verbatim: LAACopy.Studio.check)
                    }
                        .laaGlassButton(prominent: true)
                    if let error { Text(verbatim: error).laaTextStyle(.body).foregroundStyle(LAAColor.attention) }
                } else {
                    Text(verbatim: draft.pending ? (draft.workBusy == true ? LAACopy.Studio.workBusy : LAACopy.Studio.uncertain) : LAACopy.Studio.draft)
                        .laaTextStyle(.secondary).foregroundStyle(draft.pending ? LAAColor.attention : LAAColor.secondaryText)
                    LabeledContent(LAACopy.Studio.work) {
                        Picker(LAACopy.Studio.work, selection: selection) {
                            Text(verbatim: LAACopy.Studio.newWork).tag("")
                            ForEach(snapshot.projects) { project in Text(verbatim: project.title).tag(project.id) }
                        }.labelsHidden().frame(minHeight: LAASpacing.minimumTouchTarget)
                            .disabled(draft.pending || sending || storageBlocked).accessibilityIdentifier("laa.studio.project")
                    }
                    if draft.isNew {
                        TextField(LAACopy.Studio.title, text: $draft.title)
                            .studioInputField().disabled(draft.pending || sending || storageBlocked)
                            .accessibilityIdentifier("laa.studio.title")
                    }
                    LabeledContent(LAACopy.Studio.principle) {
                        Picker(LAACopy.Studio.principle, selection: principleSelection) {
                            Text(verbatim: LAACopy.Studio.none).tag("")
                            if let selected = draft.principle, !snapshot.principles.contains(where: { $0.id == selected.id }) {
                                Text(verbatim: "\(selected.id) · v\(selected.version)").tag(selected.id)
                            }
                            ForEach(snapshot.principles) { item in Text(verbatim: "\(item.name) · \(item.status)").tag(item.id) }
                        }.labelsHidden().frame(minHeight: LAASpacing.minimumTouchTarget).disabled(draft.pending || sending || storageBlocked)
                    }
                    LAAWorkComposer(text: $draft.prompt, revision: $revision, placeholder: LAACopy.Studio.prompt,
                                    enabled: !draft.pending && !sending && !storageBlocked,
                                    canSend: draft.prompt.utf16.count <= 10000 && (!draft.isNew || !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                                    onChange: { _ in }, onSubmit: { Task { await submit() } },
                                    submitLabel: LAACopy.Studio.send, accessibilityPrefix: "laa.studio.composer", showsTextSize: false)
                    Text(verbatim: "\(draft.prompt.utf16.count) / 10,000").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    if let catalog {
                        DisclosureGroup("依頼の型と書き方") {
                            VStack(alignment: .leading, spacing: LAASpacing.x2) {
                                ForEach(catalog.capabilities) { capability in
                                    Button { appendTemplate(capability.prompt) } label: {
                                        VStack(alignment: .leading, spacing: LAASpacing.x1) {
                                            Text(verbatim: "＋ \(capability.title)").fontWeight(.semibold)
                                            Text(verbatim: capability.description).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                                        }.frame(maxWidth: .infinity, minHeight: LAASpacing.minimumTouchTarget, alignment: .leading)
                                    }.disabled(draft.pending || sending || storageBlocked)
                                }
                                ForEach(Array(catalog.brief.enumerated()), id: \.offset) { _, item in
                                    Button { appendTemplate(item) } label: {
                                        Text(verbatim: "＋ \(item)").frame(maxWidth: .infinity, minHeight: LAASpacing.minimumTouchTarget, alignment: .leading)
                                    }.disabled(draft.pending || sending || storageBlocked)
                                }
                            }
                        }
                    }
                    if let catalogNote { Text(verbatim: catalogNote).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText) }
                    if draft.pending {
                        Button { Task { await check() } } label: {
                            Text(verbatim: LAACopy.Studio.check).frame(minHeight: LAASpacing.minimumTouchTarget)
                        }.disabled(sending || storageBlocked)
                            .accessibilityIdentifier("laa.studio.check")
                        if canRetry {
                            Button { Task { await submit() } } label: {
                                Text(verbatim: LAACopy.Studio.retry).frame(minHeight: LAASpacing.minimumTouchTarget)
                            }.disabled(sending || storageBlocked)
                                .accessibilityIdentifier("laa.studio.retry")
                        }
                    }
                    if let error { Text(verbatim: error).laaTextStyle(.body).foregroundStyle(LAAColor.attention) }
                    if sending { ProgressView() }
                }
            }.padding(LAASpacing.horizontal).laaPageWidth()
        }
        .background(LAAColor.background.ignoresSafeArea()).navigationTitle(Text(verbatim: LAACopy.Assets.studio))
        .tint(LAAColor.link)
        .navigationBarTitleDisplayMode(.inline)
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
            guard initialized && !done && !storageBlocked else { return }
            if !LAAStudioDraftStore.save(value, deviceID: device, draftID: draftID) { storageBlocked = true; error = LAACopy.Studio.saveFailed }
        }
        .task(id: bridge.revision) {
            catalog = nil; catalogNote = nil
            guard snapshot.supportsV2 else { return }
            let catalogRevision = bridge.revision
            do {
                let result = try await LAAStudioData.catalog(bridge)
                guard bridge.revision == catalogRevision, !Task.isCancelled else { return }
                catalog = result.catalog
                catalogNote = result.stale ? "依頼の型は端末に保存した内容です。" : nil
            } catch is CancellationError { }
            catch {
                guard bridge.revision == catalogRevision, !Task.isCancelled else { return }
                if LAAStudioData.isAuthorizationFailure(error) { catalog = nil }
                catalogNote = "依頼の型を読み込めません。本文はそのまま入力できます。"
            }
        }
    }
    private func appendTemplate(_ text: String) {
        guard !draft.pending, !sending, !storageBlocked else { return }
        let next = draft.prompt.isEmpty ? text : draft.prompt + "\n" + text
        guard next.utf16.count <= 10000 else { error = LAACopy.Studio.tooLong; return }
        draft.prompt = next; revision += 1
    }
    @MainActor private func submit() async {
        guard !sending && !storageBlocked && (!draft.pending || canRetry) else { return }
        sending = true; error = nil
        defer { sending = false }
        do {
            if draft.requestID == nil { draft.requestID = try await LAAStudioData.requestID(bridge) }
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
            done = true
            if !LAAStudioDraftStore.clear(deviceID: device, draftID: draftID) { error = LAACopy.Studio.saveFailed }
            created = record
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
            done = true
            if !LAAStudioDraftStore.clear(deviceID: device, draftID: draftID) { error = LAACopy.Studio.saveFailed }
            created = record
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
