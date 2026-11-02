#if LAA_BUILD
import SwiftUI

struct LAAStudioPendingAction: Codable {
    let action: String
    let approvalId: String?
    var payload: LAAStudioAction? = nil
    var attemptedAt: Date? = nil
    var keyValue: String? = nil
    var body: Data? = nil

    func retryMaterial() -> (action: LAAStudioAction, key: LAABridgeIdempotencyKey, body: Data)? {
        guard let keyValue, let key = LAABridgeIdempotencyKey(restoring: keyValue), let body,
              let decoded = try? JSONDecoder().decode(LAAStudioAction.self, from: body),
              decoded.action == action, decoded.approvalId == approvalId else { return nil }
        if let payload {
            // Normalize through Codable so a whole-valued number round-trips like the body.
            guard let encoded = try? JSONEncoder().encode(payload),
                  let normalized = try? JSONDecoder().decode(LAAStudioAction.self, from: encoded),
                  normalized == decoded else { return nil }
        }
        return (decoded, key, body)
    }
}
enum LAAStudioActionGuard {
    static func prepare(_ action: LAAStudioAction) throws -> LAAStudioPendingAction {
        let key = LAABridgeIdempotencyKey()
        let body = try JSONEncoder().encode(action)
        return LAAStudioPendingAction(action: action.action, approvalId: action.approvalId, payload: action,
                                      attemptedAt: Date(), keyValue: key.value, body: body)
    }
    static func prepareRetry(_ pending: LAAStudioPendingAction) -> LAAStudioPendingAction? {
        guard pending.retryMaterial() != nil else { return nil }
        guard pending.action == "stop" else { return pending }
        var retry = pending
        retry.keyValue = LAABridgeIdempotencyKey().value
        retry.attemptedAt = Date()
        return retry
    }
    static func resolved(_ pending: LAAStudioPendingAction, record: LAAStudioRecord) -> Bool {
        pending.action == "stop" ? !record.canStop :
            record.status != "approval" || !(record.report?.approvals.contains(where: { $0.id == pending.approvalId }) ?? false)
    }
    static func mayStop(busy: Bool, pending: LAAStudioPendingAction?) -> Bool {
        !busy && pending?.action != "stop"
    }
    static func requiresReentry(code: String?) -> Bool {
        code == "idempotency_outcome_unknown" || code == "idempotency_key_conflict"
    }
    static func rejected(code: String?, action: String) -> Bool {
        ["studio_payload_invalid", "invalid_request", "studio_approval_on_mac", "studio_approval_changed", "studio_approval_expired", "studio_request_finished", "insufficient_scope"].contains(code ?? "") ||
            (action == "stop" && code == "studio_stopping")
    }
    static func mayRetry(_ pending: LAAStudioPendingAction, record: LAAStudioRecord, checks: Int) -> Bool {
        checks >= 3 && !resolved(pending, record: record)
    }
    static func nextChecks(previous: LAAStudioRecord, latest: LAAStudioRecord, count: Int) -> Int {
        previous.status == latest.status && previous.updatedAt == latest.updatedAt && previous.report?.sequence == latest.report?.sequence ? count + 1 : 0
    }
    static func file(device: String, id: String, directory: URL = LAAStudioDraftStore.directory()) -> URL? {
        guard let root = LAAStudioDraftStore.file(deviceID: device, directory: directory), UUID(uuidString: id) != nil else { return nil }
        return root.deletingLastPathComponent().appendingPathComponent("action-\(device)-\(id).json")
    }
    static func load(device: String, id: String, directory: URL = LAAStudioDraftStore.directory()) -> LAAStudioPendingAction? {
        guard let file = file(device: device, id: id, directory: directory), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(LAAStudioPendingAction.self, from: data)
    }
    static func save(_ pending: LAAStudioPendingAction, device: String, id: String, directory: URL = LAAStudioDraftStore.directory()) -> Bool {
        guard let file = file(device: device, id: id, directory: directory) else { return false }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(pending).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { return false }
    }
    static func clear(device: String, id: String, directory: URL = LAAStudioDraftStore.directory()) -> Bool {
        guard let file = file(device: device, id: id, directory: directory) else { return false }
        do { if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }; return true }
        catch { return false }
    }
}

struct LAAStudioRequestView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @State private var record: LAAStudioRecord
    @State private var pending: LAAStudioPendingAction?
    @State private var unchangedChecks = 0
    @State private var error: String?
    @State private var busy = false
    @State private var retryNeedsReentry = false
    @State private var confirmStop = false
    @State private var project: LAAStudioProject?
    private var device: String { bridge.deviceID ?? "fixture" }
    init(initial: LAAStudioRecord, initialProject: LAAStudioProject? = nil) {
        _record = State(initialValue: initial)
        _project = State(initialValue: initialProject)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x6) {
                Text(verbatim: LAAStudioPresentation.title(for: record, project: project))
                    .font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
                VStack(alignment: .leading, spacing: LAASpacing.x2) {
                    if record.status == "approval" {
                        Label(LAACopy.Studio.needsApproval, systemImage: "exclamationmark.circle.fill")
                            .laaTextStyle(.body).fontWeight(.semibold).foregroundStyle(LAAColor.attention)
                    } else {
                        Text(verbatim: LAAStudioPresentation.status(record.status))
                            .laaTextStyle(.body).fontWeight(.semibold).foregroundStyle(LAAColor.link)
                    }
                    Text(verbatim: LAAWorkPresentation.date(record.updatedAt)).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    if record.status == "unreceived" { Text(verbatim: LAACopy.Studio.unreceived).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention) }
                }
                Text(verbatim: record.request.prompt).laaTextStyle(.body).foregroundStyle(LAAColor.text).textSelection(.enabled)
                if let report = record.report {
                    Text(verbatim: report.text).laaTextStyle(.body).foregroundStyle(LAAColor.text)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if let revision = report.revision { Text(verbatim: "Revision \(revision)").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText) }
                    if record.status == "approval" {
                        ForEach(report.approvals) { approval in
                            LAAStudioApprovalView(approval: approval, disabled: busy || pending != nil) { accepted, content, persist in
                                Task { await perform(.init(action: "answer", id: record.id, approvalId: approval.id,
                                                          accept: accepted, content: content, persist: persist)) }
                            }
                        }
                    }
                }
                if let pending {
                    Text(verbatim: LAACopy.Studio.pendingAction).laaTextStyle(.body).foregroundStyle(LAAColor.attention)
                    if LAAStudioActionGuard.mayRetry(pending, record: record, checks: unchangedChecks) {
                        Text(verbatim: pending.retryMaterial() == nil || retryNeedsReentry ? LAACopy.Studio.reenterAction : LAACopy.Studio.retryAction)
                            .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        Button { Task { await retryPending() } } label: {
                            Text(verbatim: pending.retryMaterial() == nil || retryNeedsReentry ? LAACopy.Studio.reenter : LAACopy.Studio.retry)
                        }.laaGlassButton().disabled(busy).accessibilityIdentifier("laa.studio.action.retry")
                    }
                }
                if let error { Text(verbatim: error).laaTextStyle(.body).foregroundStyle(LAAColor.attention) }
                if busy { ProgressView() }
                if let project, LAAStudioPresentation.hasDeliverables(project) {
                    NavigationLink { LAAStudioWorkView(project: project) } label: {
                        Text(verbatim: LAACopy.Studio.deliverables).frame(minHeight: LAASpacing.minimumTouchTarget)
                    }
                        .accessibilityIdentifier("laa.studio.deliverables")
                }
                if record.canStop {
                    Button(role: .destructive) { confirmStop = true } label: {
                        Text(verbatim: LAACopy.Studio.stop)
                    }.laaGlassButton().tint(LAAColor.end).disabled(!LAAStudioActionGuard.mayStop(busy: busy, pending: pending))
                        .accessibilityIdentifier("laa.studio.stop")
                }
                if record.canRequestAgain {
                    NavigationLink { LAAStudioRerequestView(previous: record) } label: {
                        Text(verbatim: LAACopy.Studio.askAgain).frame(minHeight: LAASpacing.minimumTouchTarget)
                    }
                        .accessibilityIdentifier("laa.studio.again")
                }
            }.padding(LAASpacing.horizontal).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(LAAColor.background.ignoresSafeArea()).navigationTitle(Text(verbatim: LAACopy.Studio.requestDetail))
        .tint(LAAColor.link)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(LAACopy.Studio.stop, isPresented: $confirmStop, titleVisibility: .visible) {
            Button(LAACopy.Studio.stop, role: .destructive) { Task { await perform(.init(action: "stop", id: record.id)) } }
            Button(LAACopy.Studio.cancel, role: .cancel) { }
        }
        .task(id: record.id) {
            pending = LAAStudioActionGuard.load(device: device, id: record.id)
            await refresh()
            if let snapshot = try? await LAAStudioData.snapshot(bridge) {
                project = snapshot.projects.first { $0.id == record.request.projectId }
            }
            while !Task.isCancelled && record.active {
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
                await refresh()
            }
        }
    }
    @MainActor private func refresh() async {
        do {
            let latest = try await LAAStudioData.record(record.id, bridge: bridge)
            let checks = LAAStudioActionGuard.nextChecks(previous: record, latest: latest, count: unchangedChecks)
            record = latest
            if let pending {
                if LAAStudioActionGuard.resolved(pending, record: latest) {
                    if LAAStudioActionGuard.clear(device: device, id: record.id) { self.pending = nil; unchangedChecks = 0 }
                } else { unchangedChecks = checks }
            }
            if pending == nil { error = nil }
        } catch is CancellationError { }
        catch { unchangedChecks = 0; self.error = LAAStudioData.message(error) }
    }
    @MainActor private func retryPending() async {
        guard !busy, let pending, LAAStudioActionGuard.mayRetry(pending, record: record, checks: unchangedChecks) else { return }
        // Recheck immediately before allowing a manual retry; never retry automatically.
        busy = true
        await refresh()
        busy = false
        guard let current = self.pending, LAAStudioActionGuard.mayRetry(current, record: record, checks: unchangedChecks) else { return }
        guard !retryNeedsReentry, let retry = LAAStudioActionGuard.prepareRetry(current), let material = retry.retryMaterial() else {
            if LAAStudioActionGuard.clear(device: device, id: record.id) { self.pending = nil; unchangedChecks = 0; retryNeedsReentry = false }
            else { error = LAACopy.Studio.saveFailed }
            return
        }
        await perform(material.action, retry: retry)
    }
    @MainActor private func perform(_ action: LAAStudioAction, retry: LAAStudioPendingAction? = nil) async {
        // Stop remains available even if an earlier answer has an unknown outcome.
        guard !busy, action.id == record.id,
              pending == nil || retry != nil || (action.action == "stop" && LAAStudioActionGuard.mayStop(busy: busy, pending: pending)) else { return }
        let marker: LAAStudioPendingAction
        do { marker = try retry ?? LAAStudioActionGuard.prepare(action) }
        catch { self.error = LAACopy.Studio.saveFailed; return }
        guard let material = marker.retryMaterial(), material.action.id == record.id else { error = LAACopy.Studio.saveFailed; return }
        guard LAAStudioActionGuard.save(marker, device: device, id: record.id) else { error = LAACopy.Studio.saveFailed; return }
        pending = marker; unchangedChecks = 0; busy = true; error = nil; retryNeedsReentry = false
        defer { busy = false }
        do {
            record = try await LAAStudioData.action(material.action, body: material.body, key: material.key, bridge: bridge)
            if LAAStudioActionGuard.clear(device: device, id: record.id) { pending = nil }
        } catch let failure as LAABridgeHTTPError {
            let rejected = LAAStudioActionGuard.rejected(code: failure.code, action: action.action)
            if rejected && LAAStudioActionGuard.clear(device: device, id: record.id) { pending = nil }
            if LAAStudioActionGuard.requiresReentry(code: failure.code) { retryNeedsReentry = true }
            error = failure.code == "studio_not_connected" ? LAACopy.Studio.actionDisconnected : LAAStudioData.message(failure)
        } catch { self.error = LAAStudioData.message(error) }
    }
}

private struct LAAStudioApprovalView: View {
    let approval: LAAStudioApproval
    let disabled: Bool
    let answer: (Bool, [String: LAAStudioScalar], Bool) -> Void
    @State private var raw: [String: String] = [:]
    @State private var persist = false
    @State private var invalid = false
    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            Text(verbatim: approval.message).laaTextStyle(.body).foregroundStyle(LAAColor.text)
            if !approval.supported {
                Text(verbatim: LAACopy.Studio.approvalOnMac).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
            } else {
                ForEach(approval.fields) { field in
                    VStack(alignment: .leading, spacing: LAASpacing.x1) {
                        Text(verbatim: field.title + (field.required ? " *" : "")).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        if let options = field.options, !options.isEmpty {
                            Picker(field.title, selection: binding(field.name)) {
                                Text(verbatim: field.required ? LAACopy.Studio.choose : LAACopy.Studio.none).tag("")
                                ForEach(options, id: \.self) { Text(verbatim: $0).tag($0) }
                            }.frame(minHeight: LAASpacing.minimumTouchTarget)
                        } else if field.type == "boolean" {
                            Picker(field.title, selection: binding(field.name)) {
                                Text(verbatim: field.required ? LAACopy.Studio.choose : LAACopy.Studio.none).tag("")
                                Text(verbatim: LAACopy.Studio.yes).tag("true")
                                Text(verbatim: LAACopy.Studio.no).tag("false")
                            }.frame(minHeight: LAASpacing.minimumTouchTarget)
                        } else {
                            TextField(field.title, text: binding(field.name)).studioInputField()
                                .keyboardType(field.type == "number" || field.type == "integer" ? .decimalPad : .default)
                        }
                    }
                }
                if approval.allowSession { Toggle(LAACopy.Studio.persist, isOn: $persist) }
                if invalid { Text(verbatim: LAACopy.Studio.invalid).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention) }
                HStack(spacing: LAASpacing.x4) {
                    Button {
                        guard let content = LAAStudioAnswers.content(fields: approval.fields, raw: raw) else { invalid = true; return }
                        invalid = false; answer(true, content, persist)
                    } label: {
                        Text(verbatim: LAACopy.Studio.allow)
                    }.laaGlassButton(prominent: true).foregroundStyle(LAAColor.filledButtonText)
                        .accessibilityIdentifier("laa.studio.approval.allow")
                    Button { answer(false, [:], false) } label: {
                        Text(verbatim: LAACopy.Studio.deny)
                    }.laaGlassButton().tint(LAAColor.secondaryText)
                        .accessibilityIdentifier("laa.studio.approval.deny")
                }.disabled(disabled)
            }
        }.padding(LAASpacing.x4).background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
    }
    private func binding(_ name: String) -> Binding<String> {
        Binding(get: { raw[name] ?? "" }, set: { raw[name] = $0 })
    }
}

private struct LAAStudioRerequestView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let previous: LAAStudioRecord
    @State private var snapshot: LAAStudioSnapshot?
    @State private var error: String?
    var body: some View {
        Group {
            if let snapshot, let project = snapshot.projects.first(where: { $0.id == previous.request.projectId }) {
                LAAStudioCreateView(snapshot: snapshot, initialProject: project, initialPrompt: previous.request.prompt, draftID: previous.id)
            } else if let error {
                Text(verbatim: error).foregroundStyle(LAAColor.attention).padding(LAASpacing.horizontal)
            } else { ProgressView() }
        }.task {
            do {
                let current = try await LAAStudioData.snapshot(bridge)
                guard current.projects.contains(where: { $0.id == previous.request.projectId }) else {
                    error = "最新の作品が見つかりません。Studioを確認してください。"; return
                }
                snapshot = current
            } catch { self.error = LAAStudioData.message(error) }
        }
    }
}
#endif
