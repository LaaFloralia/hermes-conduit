#if LAA_BUILD
import SwiftUI
import UniformTypeIdentifiers
import CryptoKit

struct LAAPersonalTaskUpload: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var drafts: ComposerDraftStore
    let taskId: String
    let viewerId: String
    @State private var selecting = false
    @State private var busy = false
    @State private var prepared: LAAPersonalUploadMetadata?
    @State private var operation: LAAPersonalOperationResponse.Operation?
    @State private var error: String?

    private var key: ComposerDraftKey? {
        bridge.deviceID.map { LAAWorkDrafts.key(deviceID: $0, target: "linear:\(viewerId):upload:\(taskId)") }
    }
    private var pending: ComposerDraftStore.Submission? { key.flatMap { LAAWorkDrafts.pending(drafts, key: $0) } }
    private var path: String {
        "/v1/personal-tasks/" + (taskId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "") + "/files"
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error { Text(verbatim: error).foregroundStyle(LAAColor.attention) }
                if let pending {
                    Section() {
                        if pending.personalOrigin != nil {
                            Text(verbatim: "移した下書きは送信待ちで元の要求を照合してください。")
                        } else {
                            Text(verbatim: "送信結果を確認するまで、別のファイルを送信しません。")
                            if let operation { Text(verbatim: "\(operation.status) · \(operation.targetId)").textSelection(.enabled) }
                            Button(LAACopy.WorkTab.checkStatus) { Task { await check(pending) } }
                            if LAAWorkDrafts.canRepeat(pending) {
                                Button(LAACopy.WorkTab.retrySameRequest) { Task { await perform(pending, firstAttempt: false) } }
                            }
                        }
                    } header: { Text(verbatim: "送信待ち") }
                }
                Section() {
                    if let prepared { Text(verbatim: prepared.filename); Text(verbatim: "\(prepared.size) bytes").laaTextStyle(.secondary) }
                    else { Text(verbatim: "ファイルを選んでください（最大20 MiB）。") }
                    Button() { selecting = true } label: { Text(verbatim: "ファイルを選択") }.disabled(pending != nil)
                    Button() { submit() } label: { Text(verbatim: "Upload") }.disabled(prepared == nil || pending != nil || drafts.persistenceFailed)
                } header: { Text(verbatim: "File") }
            }
            .disabled(busy)
            .navigationTitle(Text(verbatim: "Upload File"))
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(LAACopy.WorkTab.close) { dismiss() } } }
            .fileImporter(isPresented: $selecting, allowedContentTypes: [.item]) { result in
                switch result {
                case .success(let url): stage(url)
                case .failure: error = "ファイルを選択できませんでした。"
                }
            }
            .task(id: bridge.revision) { restore() }
        }
    }

    private func restore() {
        guard let key else { prepared = nil; return }
        let draft = pending?.draft ?? drafts.draft(for: key)
        guard let bytes = draft.text.data(using: .utf8), let saved = try? JSONDecoder().decode(LAAPersonalUploadMetadata.self, from: bytes),
              saved.viewerId == viewerId, draft.attachments.count == 1 else { prepared = nil; return }
        prepared = saved
    }

    @MainActor private func stage(_ source: URL) {
        guard let key, pending == nil else { return }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var folder: URL?
        defer { if let folder { try? FileManager.default.removeItem(at: folder) } }
        do {
            let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, (1...(20 * 1024 * 1024)).contains(size) else {
                error = "1バイト以上、20 MiB以下のファイルを選んでください。"; return
            }
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            var bytes = Data()
            while bytes.count <= size {
                guard let chunk = try handle.read(upToCount: min(256 * 1024, size + 1 - bytes.count)), !chunk.isEmpty else { break }
                bytes.append(chunk)
            }
            guard bytes.count == size else { error = "ファイルが変更されました。選び直してください。"; return }
            let filename = String(source.lastPathComponent.prefix(100))
            guard !filename.isEmpty, !filename.contains("\\"), !filename.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                error = "このファイル名は使用できません。"; return
            }
            let suggestedType = UTType(filenameExtension: source.pathExtension)?.preferredMIMEType ?? ""
            let pattern = #"^[a-zA-Z0-9!#$&^_.+-]+/[a-zA-Z0-9!#$&^_.+-]+$"#
            let type = suggestedType.range(of: pattern, options: .regularExpression) != nil ? suggestedType : "application/octet-stream"
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let metadata = LAAPersonalUploadMetadata(viewerId: viewerId, filename: filename, contentType: type, size: size, sha256: digest)
            let encoded = try JSONEncoder().encode(metadata)
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("laa-linear-\(UUID().uuidString)", isDirectory: true)
            folder = temp
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.complete])
            let staged = temp.appendingPathComponent("upload")
            try bytes.write(to: staged, options: [.atomic, .completeFileProtection])
            let attachment = Attachment(id: UUID().uuidString, name: filename, uri: staged.absoluteString, mimeType: type, kind: .document)
            guard drafts.save(ComposerDraft(text: String(decoding: encoded, as: UTF8.self), attachments: [attachment]), for: key) else {
                error = "ファイルを端末に保存できませんでした。"; return
            }
            prepared = metadata; error = nil
        } catch { self.error = "ファイルを端末に保存できませんでした。" }
    }

    private func submit() {
        guard let key, let prepared, pending == nil, let body = try? JSONEncoder().encode(prepared) else { return }
        let draft = drafts.draft(for: key)
        guard draft.attachments.count == 1,
              LAAWorkDrafts.reserve(drafts, key: key, text: draft.text, body: body, idempotency: LAABridgeIdempotencyKey(),
                                    attachments: draft.attachments) != nil,
              let item = LAAWorkDrafts.pending(drafts, key: key) else {
            error = "送信前の記録を保存できませんでした。"; return
        }
        Task { await perform(item, firstAttempt: true) }
    }

    @MainActor private func perform(_ item: ComposerDraftStore.Submission, firstAttempt: Bool) async {
        guard LAAWorkDrafts.canRepeat(item), let (body, requestKey) = LAAWorkDrafts.request(item),
              let metadata = try? JSONDecoder().decode(LAAPersonalUploadMetadata.self, from: body), metadata.viewerId == viewerId,
              item.draft.attachments.count == 1, let file = URL(string: item.draft.attachments[0].uri), file.isFileURL else {
            error = "ファイルまたは送信記録を確認できません。"; return
        }
        busy = true; defer { busy = false }
        do {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, values.fileSize == metadata.size,
                  (1...(20 * 1024 * 1024)).contains(metadata.size) else {
                error = "保存したファイルが変更されたため送信できません。"; return
            }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            guard data.count == metadata.size, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == metadata.sha256 else {
                error = "保存したファイルが変更されたため送信できません。"; return
            }
            let response = try await bridge.uploadPersonalTaskFile(path: path, file: file, metadata: metadata, key: requestKey)
            guard response.data.operation.status == "succeeded" else { throw LAABridgeError.invalidResponse }
            if drafts.finishSubmission(item.id, restoring: false) { dismiss() }
            else { error = "送信結果を端末に保存できませんでした。" }
        } catch let failure as LAABridgeHTTPError {
            drafts.markSubmissionUnknown(item.id)
            if firstAttempt && ["payload_invalid", "expected_viewer_required", "linear_viewer_changed", "file_too_large"].contains(failure.code ?? "") {
                if drafts.finishSubmission(item.id, restoring: true) { restore() }
            }
            error = LAAWorkHTTP.message(failure)
        } catch let failure as LAABridgeError {
            drafts.markSubmissionUnknown(item.id); error = failure.japaneseText
        } catch { drafts.markSubmissionUnknown(item.id); self.error = "送信結果を確認できませんでした。" }
    }

    @MainActor private func check(_ item: ComposerDraftStore.Submission) async {
        guard let (_, requestKey) = LAAWorkDrafts.request(item) else { error = "送信記録を読み取れません。"; return }
        busy = true; defer { busy = false }
        do {
            let result: LAABridgeResponse<LAAPersonalOperationResponse> = try await bridge.request(
                method: "GET", path: "/v1/task-operations/by-key", idempotencyKey: requestKey)
            operation = result.data.operation
            switch result.data.operation.status {
            case "succeeded":
                if drafts.finishSubmission(item.id, restoring: false) { dismiss() }
            case "rejected":
                if drafts.finishSubmission(item.id, restoring: true) { restore(); error = "課題への添付前に失敗しました。もう一度送れます。" }
            case "resolved":
                guard ["applied", "not_applied"].contains(result.data.operation.resolution ?? "") else { throw LAABridgeError.invalidResponse }
                let restoring = result.data.operation.resolution == "not_applied"
                if drafts.finishSubmission(item.id, restoring: restoring) { if restoring { restore() } else { dismiss() } }
            default: error = "結果は未確認です。課題の添付を確認してから照合してください。"
            }
        } catch let failure as LAABridgeHTTPError {
            error = failure.code == "operation_not_found" ? LAAWorkHTTP.operationNotFound(canRepeat: LAAWorkDrafts.canRepeat(item)) : LAAWorkHTTP.message(failure)
        } catch { self.error = "送信状況を読み取れませんでした。" }
    }
}
#endif
