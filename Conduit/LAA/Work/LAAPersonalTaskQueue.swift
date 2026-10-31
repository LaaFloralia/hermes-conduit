#if LAA_BUILD
#if !LAATASK_QUEUE_STANDALONE
import SwiftUI
#else
import Foundation
#endif
import CryptoKit

@MainActor protocol LAAPersonalQueueTransport {
    var deviceID: String? { get }
    func queueOperation(_ key: LAABridgeIdempotencyKey) async throws -> LAAPersonalOperationResponse.Operation?
    func queueTask(_ id: String) async throws -> LAAPersonalTaskResponse
    func queueWrite(_ method: String, path: String, body: Data, key: LAABridgeIdempotencyKey,
                    ifMatch: String?) async throws -> LAAPersonalOperationResponse.Operation
    func queueUpload(_ path: String, file: URL, metadata: LAAPersonalUploadMetadata,
                     key: LAABridgeIdempotencyKey) async throws -> LAAPersonalOperationResponse.Operation
}

#if !LAATASK_QUEUE_STANDALONE
extension LAABridgeSession: LAAPersonalQueueTransport {
    func queueOperation(_ key: LAABridgeIdempotencyKey) async throws -> LAAPersonalOperationResponse.Operation? {
        do {
            let result: LAABridgeResponse<LAAPersonalOperationResponse> = try await request(
                method: "GET", path: "/v1/task-operations/by-key", idempotencyKey: key)
            return result.data.operation
        } catch let failure as LAABridgeHTTPError where failure.status == 404 && failure.code == "operation_not_found" {
            return nil
        }
    }
    func queueTask(_ id: String) async throws -> LAAPersonalTaskResponse {
        try await read("/v1/personal-tasks/\(id)")
    }
    func queueWrite(_ method: String, path: String, body: Data, key: LAABridgeIdempotencyKey,
                    ifMatch: String?) async throws -> LAAPersonalOperationResponse.Operation {
        let result: LAABridgeResponse<LAAPersonalOperationResponse> = try await request(
            method: method, path: path, jsonBody: body, idempotencyKey: key, ifMatch: ifMatch, timeout: 90)
        return result.data.operation
    }
    func queueUpload(_ path: String, file: URL, metadata: LAAPersonalUploadMetadata,
                     key: LAABridgeIdempotencyKey) async throws -> LAAPersonalOperationResponse.Operation {
        try await uploadPersonalTaskFile(path: path, file: file, metadata: metadata, key: key).data.operation
    }
}
#endif

/// Runs only while the task screen is active. Every request is checked against
/// the durable Bridge ledger first; an ambiguous result is never replaced by a
/// fresh key. No background delivery is implied.
@MainActor enum LAAPersonalTaskQueue {
    private static var running = false

    static func dependency(_ item: ComposerDraftStore.Submission, device: String, viewer: String) -> LAAPersonalDependency? {
        guard let (body, key) = LAAWorkDrafts.request(item),
              let value = try? JSONDecoder().decode(LAAPersonalDependency.self, from: body),
              value.valid, value.deviceId == device, value.viewerId == viewer, value.childKey == key.value,
              item.key == LAAWorkDrafts.key(deviceID: device, target: "linear:\(viewer):dependency:\(value.childKey)") else { return nil }
        return value
    }

    static func isDependency(_ item: ComposerDraftStore.Submission, device: String, viewer: String) -> Bool {
        item.key.profile == "laa-bridge" && item.key.sessionID.hasPrefix("\(device):linear:\(viewer):dependency:")
    }

    @discardableResult static func run(drafts: ComposerDraftStore, bridge: any LAAPersonalQueueTransport, viewer: String) async -> Bool {
        guard !running, let device = bridge.deviceID, !drafts.persistenceFailed else { return false }
        running = true; defer { running = false }
        let initialIDs = Set(drafts.submissions.map(\.id))
        let prefix = "\(device):linear:\(viewer):"
        let items = drafts.submissions.filter { $0.key.profile == "laa-bridge" && $0.key.sessionID.hasPrefix(prefix) }
        // Parents first, then their follow-ups, in reservation order.
        for item in items where isCreate(item, device: device, viewer: viewer) {
            guard !Task.isCancelled, bridge.deviceID == device else { return false }
            await create(item, drafts: drafts, bridge: bridge, device: device, viewer: viewer)
        }
        for item in items where !isCreate(item, device: device, viewer: viewer) && !isDependency(item, device: device, viewer: viewer) {
            guard !Task.isCancelled, bridge.deviceID == device else { return false }
            await ordinary(item, drafts: drafts, bridge: bridge, device: device, viewer: viewer)
        }
        for item in items where isDependency(item, device: device, viewer: viewer) {
            guard !Task.isCancelled, bridge.deviceID == device else { return false }
            await follow(item, drafts: drafts, bridge: bridge, device: device, viewer: viewer)
        }
        return !initialIDs.isSubset(of: Set(drafts.submissions.map(\.id)))
    }

    private static func isCreate(_ item: ComposerDraftStore.Submission, device: String, viewer: String) -> Bool {
        let prefix = "\(device):linear:\(viewer):"
        let id = item.key.sessionID
        guard id == prefix + "new" || id.hasPrefix(prefix + "new-subtask:"),
              let data = item.draft.text.data(using: .utf8),
              let value = try? JSONDecoder().decode(LAAPersonalTaskDraft.self, from: data),
              value.viewerId == viewer, value.base == nil else { return false }
        return true
    }

    private static func create(_ item: ComposerDraftStore.Submission, drafts: ComposerDraftStore,
                               bridge: any LAAPersonalQueueTransport, device: String, viewer: String) async {
        guard let (body, key) = LAAWorkDrafts.request(item),
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              object["expectedViewerId"] as? String == viewer else { return }
        do {
            if let operation = try await bridge.queueOperation(key) {
                if operation.kind == "create", operation.status == "succeeded",
                   let target = UUID(uuidString: operation.targetId),
                   operation.resultId.flatMap(UUID.init(uuidString:)) == target {
                    _ = drafts.finishSubmission(item.id, restoring: false)
                }
                return
            }
            guard LAAWorkDrafts.canRepeat(item), !Task.isCancelled, bridge.deviceID == device,
                  drafts.submissions.contains(where: { $0.id == item.id }) else { return }
            let operation = try await bridge.queueWrite("POST", path: "/v1/personal-tasks", body: body, key: key, ifMatch: nil)
            guard operation.kind == "create", operation.status == "succeeded",
                  let target = UUID(uuidString: operation.targetId),
                  operation.resultId.flatMap(UUID.init(uuidString:)) == target else { throw LAABridgeError.invalidResponse }
            _ = drafts.finishSubmission(item.id, restoring: false)
        } catch { drafts.markSubmissionUnknown(item.id) }
    }

    private struct Ordinary {
        let method: String; let path: String; let kind: String; let ifMatch: String?
        let upload: LAAPersonalUploadMetadata?
    }
    private struct ItemDraft: Decodable { let first: String; let second: String; let relationType: String }
    private static func taskPath(_ id: String) -> String? {
        guard id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,200}$"#, options: .regularExpression) != nil,
              let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return "/v1/personal-tasks/" + escaped
    }
    private static func ordinaryRequest(_ item: ComposerDraftStore.Submission, body: Data,
                                        device: String, viewer: String) -> Ordinary? {
        let prefix = "\(device):linear:\(viewer):"
        guard item.key.sessionID.hasPrefix(prefix) else { return nil }
        let target = String(item.key.sessionID.dropFirst(prefix.count))
        if target.hasPrefix("upload:"), let path = taskPath(String(target.dropFirst("upload:".count))),
           let metadata = try? JSONDecoder().decode(LAAPersonalUploadMetadata.self, from: body), metadata.viewerId == viewer {
            return Ordinary(method: "POST", path: path + "/files", kind: "file", ifMatch: nil, upload: metadata)
        }
        guard let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              payload["expectedViewerId"] as? String == viewer else { return nil }
        if target.hasPrefix("comment:"), let last = target.lastIndex(of: ":") {
            let start = target.index(target.startIndex, offsetBy: "comment:".count)
            guard last > start, let path = taskPath(String(target[start..<last])),
                  payload["body"] as? String == item.draft.text else { return nil }
            let suffix = String(target[target.index(after: last)...])
            guard (payload["parentId"] as? String ?? "root") == suffix else { return nil }
            return Ordinary(method: "POST", path: path + "/comments", kind: "comment", ifMatch: nil, upload: nil)
        }
        for (head, section, kind) in [("relation:", "relations", "relation"), ("attachment:", "attachments", "attachment")] {
            guard target.hasPrefix(head) else { continue }
            guard let path = taskPath(String(target.dropFirst(head.count))),
                  let data = item.draft.text.data(using: .utf8), let draft = try? JSONDecoder().decode(ItemDraft.self, from: data) else { return nil }
            if kind == "relation" {
                guard payload["relatedIssueId"] as? String == draft.first.trimmingCharacters(in: .whitespacesAndNewlines),
                      payload["type"] as? String == draft.relationType else { return nil }
            } else {
                guard payload["title"] as? String == draft.first,
                      payload["url"] as? String == draft.second.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            }
            return Ordinary(method: "POST", path: path + "/" + section, kind: kind, ifMatch: nil, upload: nil)
        }
        guard let path = taskPath(target), let data = item.draft.text.data(using: .utf8),
              let draft = try? JSONDecoder().decode(LAAPersonalTaskDraft.self, from: data), draft.viewerId == viewer,
              draft.base?.id == target else { return nil }
        return Ordinary(method: "PATCH", path: path, kind: "update", ifMatch: item.screenshotID, upload: nil)
    }
    private static func ordinary(_ item: ComposerDraftStore.Submission, drafts: ComposerDraftStore,
                                 bridge: any LAAPersonalQueueTransport, device: String, viewer: String) async {
        guard let (body, key) = LAAWorkDrafts.request(item),
              let request = ordinaryRequest(item, body: body, device: device, viewer: viewer) else { return }
        do {
            if let operation = try await bridge.queueOperation(key) {
                if operation.kind == request.kind && (operation.status == "succeeded" ||
                    (operation.status == "resolved" && operation.resolution == "applied")) {
                    _ = drafts.finishSubmission(item.id, restoring: false)
                }
                return
            }
            guard LAAWorkDrafts.canRepeat(item), !Task.isCancelled, bridge.deviceID == device,
                  drafts.submissions.contains(where: { $0.id == item.id }) else { return }
            let result: LAAPersonalOperationResponse.Operation
            if let metadata = request.upload {
                guard item.draft.attachments.count == 1, let file = URL(string: item.draft.attachments[0].uri), file.isFileURL,
                      (1...(20 * 1024 * 1024)).contains(metadata.size) else { return }
                let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, values.fileSize == metadata.size else { return }
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                guard data.count == metadata.size,
                      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == metadata.sha256,
                      !Task.isCancelled, bridge.deviceID == device else { return }
                result = try await bridge.queueUpload(request.path, file: file, metadata: metadata, key: key)
            } else {
                result = try await bridge.queueWrite(request.method, path: request.path, body: body, key: key, ifMatch: request.ifMatch)
            }
            guard result.status == "succeeded", result.kind == request.kind else { throw LAABridgeError.invalidResponse }
            _ = drafts.finishSubmission(item.id, restoring: false)
        } catch { drafts.markSubmissionUnknown(item.id) }
    }

    private static func follow(_ item: ComposerDraftStore.Submission, drafts: ComposerDraftStore,
                               bridge: any LAAPersonalQueueTransport, device: String, viewer: String) async {
        guard let value = dependency(item, device: device, viewer: viewer),
              let childKey = LAABridgeIdempotencyKey(restoring: value.childKey),
              let parentKey = LAABridgeIdempotencyKey(restoring: value.parentKey) else { return }
        do {
            if let operation = try await bridge.queueOperation(childKey) {
                if operation.kind == expectedKind(value.kind) &&
                    (operation.status == "succeeded" || (operation.status == "resolved" && operation.resolution == "applied")) {
                    _ = drafts.finishSubmission(item.id, restoring: false)
                }
                return
            }
            guard LAAWorkDrafts.canRepeat(item), let parent = try await bridge.queueOperation(parentKey),
                  let target = value.parentTarget(parent, device: device, viewer: viewer), !Task.isCancelled else { return }
            let verified = try await bridge.queueTask(target)
            guard let request = value.request(parent: parent, verified: verified, device: device, viewer: viewer),
                  !Task.isCancelled, bridge.deviceID == device,
                  drafts.submissions.contains(where: { $0.id == item.id }) else { return }
            let result = try await bridge.queueWrite("POST", path: request.path, body: request.body, key: childKey, ifMatch: nil)
            guard result.status == "succeeded", result.kind == expectedKind(value.kind) else { throw LAABridgeError.invalidResponse }
            _ = drafts.finishSubmission(item.id, restoring: false)
        } catch { drafts.markSubmissionUnknown(item.id) }
    }
    private static func expectedKind(_ kind: LAAPersonalDependency.Kind) -> String {
        switch kind {
        case .comment: return "comment"
        case .subtask: return "create"
        case .relation: return "relation"
        case .link: return "attachment"
        }
    }
}

#if !LAATASK_QUEUE_STANDALONE
struct LAAPersonalDependencyEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var drafts: ComposerDraftStore
    @State private var value: LAAPersonalDependency
    @State private var ready = false
    @State private var error: String?

    init(drafts: ComposerDraftStore, viewer: String, device: String, parentKey: String, team: String) {
        self.drafts = drafts
        _value = State(initialValue: LAAPersonalDependency(viewerId: viewer, deviceId: device, parentKey: parentKey,
                                                          childKey: UUID().uuidString.lowercased(), teamId: team))
    }
    private var stagingKey: ComposerDraftKey {
        LAAWorkDrafts.key(deviceID: value.deviceId, target: "linear:\(value.viewerId):dependency-compose:\(value.parentKey)")
    }
    private var queueKey: ComposerDraftKey {
        LAAWorkDrafts.key(deviceID: value.deviceId, target: "linear:\(value.viewerId):dependency:\(value.childKey)")
    }
    var body: some View {
        NavigationStack {
            Form {
                if let error { Text(verbatim: error).foregroundStyle(LAAColor.attention) }
                Text(verbatim: "元のタスクの作成と本人を確認してから、接続中に送ります。")
                    .laaTextStyle(.secondary)
                Picker("Follow-up", selection: $value.kind) {
                    ForEach(LAAPersonalDependency.Kind.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                }
                if value.kind == .comment {
                    TextEditor(text: $value.first).frame(minHeight: 180)
                } else {
                    TextField(value.kind == .relation ? "Related Task ID" : "Title", text: $value.first, axis: .vertical)
                }
                if value.kind == .relation {
                    Picker("Relation", selection: $value.relationType) {
                        Text("Related").tag("related"); Text("Blocks").tag("blocks")
                        Text("Duplicate").tag("duplicate"); Text("Similar").tag("similar")
                    }
                } else if value.kind == .link {
                    TextField("HTTPS URL", text: $value.second).keyboardType(.URL).textInputAutocapitalization(.never)
                }
                Button("Queue Follow-up") { reserve() }.disabled(!ready || !value.valid || drafts.persistenceFailed)
            }
            .navigationTitle("Follow-up")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(LAACopy.WorkTab.close) { dismiss() } } }
            .task { restore() }
            .onChange(of: value.kind) { _, _ in save() }
            .onChange(of: value.first) { _, _ in save() }
            .onChange(of: value.second) { _, _ in save() }
            .onChange(of: value.relationType) { _, _ in save() }
        }
    }
    private func restore() {
        let text = drafts.draft(for: stagingKey).text
        if let data = text.data(using: .utf8), let saved = try? JSONDecoder().decode(LAAPersonalDependency.self, from: data),
           saved.deviceId == value.deviceId, saved.viewerId == value.viewerId, saved.parentKey == value.parentKey,
           saved.teamId == value.teamId { value = saved }
        ready = true
    }
    private func save() {
        guard ready, let data = try? JSONEncoder().encode(value) else { return }
        if !drafts.save(ComposerDraft(text: String(decoding: data, as: UTF8.self), attachments: []), for: stagingKey) {
            error = "下書きを端末に保存できませんでした。"
        }
    }
    private func reserve() {
        save()
        guard !drafts.persistenceFailed, value.valid, let data = try? JSONEncoder().encode(value),
              let key = LAABridgeIdempotencyKey(restoring: value.childKey) else { return }
        if let existing = LAAWorkDrafts.pending(drafts, key: queueKey) {
            guard let existingBody = LAAWorkDrafts.request(existing)?.0,
                  (try? JSONDecoder().decode(LAAPersonalDependency.self, from: existingBody)) == value else {
                error = "この要求は既に保存されています。"; return
            }
        } else if LAAWorkDrafts.reserve(drafts, key: queueKey, text: String(decoding: data, as: UTF8.self),
                                         body: data, idempotency: key) == nil {
            error = "送信待ちを端末に保存できませんでした。"; return
        }
        guard drafts.save(ComposerDraft(text: "", attachments: []), for: stagingKey) else {
            error = "送信待ちは保存済みですが、入力欄を消去できませんでした。"; return
        }
        dismiss()
    }
}
#endif
#endif
