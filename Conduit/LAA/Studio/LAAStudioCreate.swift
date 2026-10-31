#if LAA_BUILD
import SwiftUI

struct LAAStudioCreateView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let snapshot: LAAStudioSnapshot
    var initialProject: LAAStudioProject? = nil
    var initialPrompt: String = ""
    @State private var draft = LAAStudioDraft()
    @State private var initialized = false
    @State private var done = false
    @State private var revision: UInt64 = 0
    @State private var sending = false
    @State private var canRetry = false
    @State private var error: String?
    @State private var created: LAAStudioRecord?
    private var device: String { bridge.deviceID ?? "fixture" }
    private var selection: Binding<String> {
        Binding(get: { draft.projectID ?? "" }, set: { value in
            draft.projectID = value.isEmpty ? nil : value
            draft.expectedRevision = snapshot.projects.first(where: { $0.id == value })?.revision ?? 0
            draft.requestID = nil
        })
    }
    private var principleSelection: Binding<String> {
        Binding(get: { draft.principle?.id ?? "" }, set: { value in
            let found = snapshot.principles.first(where: { $0.id == value })
            draft.principle = found.map { .init(id: $0.id, version: $0.version, revision: $0.revision) }
            draft.requestID = nil
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
                        Text(verbatim: LAACopy.Studio.check).frame(minHeight: LAASpacing.minimumTouchTarget)
                    }
                        .buttonStyle(.borderedProminent).tint(LAAColor.filledButton)
                    if let error { Text(verbatim: error).laaTextStyle(.body).foregroundStyle(LAAColor.attention) }
                } else {
                    Text(verbatim: draft.pending ? LAACopy.Studio.uncertain : LAACopy.Studio.draft)
                        .laaTextStyle(.secondary).foregroundStyle(draft.pending ? LAAColor.attention : LAAColor.secondaryText)
                    LabeledContent(LAACopy.Studio.work) {
                        Picker(LAACopy.Studio.work, selection: selection) {
                            Text(verbatim: LAACopy.Studio.newWork).tag("")
                            ForEach(snapshot.projects) { project in Text(verbatim: project.title).tag(project.id) }
                        }.labelsHidden().frame(minHeight: LAASpacing.minimumTouchTarget)
                            .disabled(draft.pending || sending).accessibilityIdentifier("laa.studio.project")
                    }
                    if draft.isNew {
                        TextField(LAACopy.Studio.title, text: $draft.title)
                            .studioInputField().disabled(draft.pending || sending)
                            .accessibilityIdentifier("laa.studio.title")
                    }
                    LabeledContent(LAACopy.Studio.principle) {
                        Picker(LAACopy.Studio.principle, selection: principleSelection) {
                            Text(verbatim: LAACopy.Studio.none).tag("")
                            ForEach(snapshot.principles) { item in Text(verbatim: "\(item.name) · \(item.status)").tag(item.id) }
                        }.labelsHidden().frame(minHeight: LAASpacing.minimumTouchTarget).disabled(draft.pending || sending)
                    }
                    LAAWorkComposer(text: $draft.prompt, revision: $revision, placeholder: LAACopy.Studio.prompt,
                                    enabled: !draft.pending && !sending,
                                    canSend: draft.prompt.utf16.count <= 10000 && (!draft.isNew || !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                                    onChange: { _ in }, onSubmit: { Task { await submit() } },
                                    submitLabel: LAACopy.Studio.send, accessibilityPrefix: "laa.studio.composer", showsTextSize: false)
                    Text(verbatim: "\(draft.prompt.utf16.count) / 10,000").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    if draft.pending {
                        Button { Task { await check() } } label: {
                            Text(verbatim: LAACopy.Studio.check).frame(minHeight: LAASpacing.minimumTouchTarget)
                        }.disabled(sending)
                            .accessibilityIdentifier("laa.studio.check")
                        if canRetry {
                            Button { Task { await submit() } } label: {
                                Text(verbatim: LAACopy.Studio.retry).frame(minHeight: LAASpacing.minimumTouchTarget)
                            }.disabled(sending)
                                .accessibilityIdentifier("laa.studio.retry")
                        }
                    }
                    if let error { Text(verbatim: error).laaTextStyle(.body).foregroundStyle(LAAColor.attention) }
                    if sending { ProgressView() }
                }
            }.padding(LAASpacing.horizontal).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(LAAColor.background.ignoresSafeArea()).navigationTitle(Text(verbatim: LAACopy.Assets.studio))
        .tint(LAAColor.link)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !initialized else { return }
            draft = LAAStudioDraftStore.load(deviceID: device) ?? LAAStudioDraft()
            if draft.prompt.isEmpty && !draft.pending, let initialProject {
                draft.projectID = initialProject.id; draft.expectedRevision = initialProject.revision; draft.prompt = initialPrompt
            }
            initialized = true
        }
        .onChange(of: draft) { _, value in
            guard initialized && !done else { return }
            if !LAAStudioDraftStore.save(value, deviceID: device) { error = LAACopy.Studio.saveFailed }
        }
    }
    @MainActor private func submit() async {
        guard !sending else { return }
        sending = true; error = nil
        defer { sending = false }
        do {
            if draft.requestID == nil { draft.requestID = try await LAAStudioData.requestID(bridge) }
            guard let request = draft.request() else { error = LAACopy.Studio.invalid; return }
            draft.pending = true
            guard LAAStudioDraftStore.save(draft, deviceID: device) else { draft.pending = false; error = LAACopy.Studio.saveFailed; return }
            let record = try await LAAStudioData.submit(request, bridge: bridge)
            done = true
            if !LAAStudioDraftStore.clear(deviceID: device) { error = LAACopy.Studio.saveFailed }
            created = record
        } catch let failure as LAABridgeHTTPError {
            let refused = ["studio_revision_changed", "studio_principle_changed", "studio_work_busy", "invalid_request", "studio_payload_invalid", "insufficient_scope"].contains(failure.code ?? "")
            if refused { draft.pending = false; draft.requestID = nil; _ = LAAStudioDraftStore.save(draft, deviceID: device) }
            error = LAAStudioData.message(failure)
        } catch { self.error = LAAStudioData.message(error) }
    }
    @MainActor private func check() async {
        guard let id = draft.requestID, !sending else { return }
        sending = true; error = nil
        defer { sending = false }
        do {
            let record = try await LAAStudioData.record(id, bridge: bridge)
            done = true
            if !LAAStudioDraftStore.clear(deviceID: device) { error = LAACopy.Studio.saveFailed }
            created = record
        } catch let failure as LAABridgeHTTPError {
            canRetry = failure.code == "studio_request_missing"
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
}
#endif
