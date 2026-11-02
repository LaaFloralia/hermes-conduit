#if LAA_BUILD
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private struct LAADrivePickedMedia: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in try copy(received.file) }
        FileRepresentation(importedContentType: .movie) { received in try copy(received.file) }
    }
    private static func copy(_ source: URL) throws -> Self {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DriveUpload-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: destination)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
        return Self(url: destination)
    }
}

struct LAADriveUpload: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.dismiss) private var dismiss
    let folderId: String?
    let completed: () -> Void
    @State private var file: URL?
    @State private var ownsFile = false
    @State private var picker = false
    @State private var photo: PhotosPickerItem?
    @State private var busy = false
    @State private var fraction = 0.0
    @State private var message: String?
    @State private var uncertain = false
    @State private var confirm = false

    var body: some View {
        NavigationStack {
            Form {
                PhotosPicker(selection: $photo, matching: .any(of: [.images, .videos])) { Text(verbatim: "写真・動画から選択") }.disabled(busy)
                Button { picker = true } label: { Text(verbatim: "ファイルから選択") }.disabled(busy)
                if let file {
                    Text(verbatim: file.lastPathComponent)
                    Text(verbatim: folderId == nil ? "保存先：マイドライブ" : "保存先：開いているフォルダ")
                    Button { confirm = true } label: { Text(verbatim: "アップロード") }.disabled(busy || uncertain)
                }
                if busy { ProgressView(value: fraction) }
                if let message { Text(verbatim: message).foregroundStyle(LAAColor.attention) }
            }
            .navigationTitle(Text(verbatim: "Driveに追加"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Text(verbatim: "閉じる") }.disabled(busy) } }
            .fileImporter(isPresented: $picker, allowedContentTypes: [.item]) { result in
                if case .success(let url) = result { cleanup(); file = url; ownsFile = false; uncertain = false }
            }
            .task(id: photo) {
                guard let photo else { return }
                busy = true; defer { busy = false }
                do {
                    guard let media = try await photo.loadTransferable(type: LAADrivePickedMedia.self) else { return }
                    cleanup(); file = media.url; ownsFile = true; uncertain = false
                } catch { message = "写真・動画を読み込めませんでした。" }
            }
            .confirmationDialog(Text(verbatim: "Google Driveにアップロードしますか？"), isPresented: $confirm, titleVisibility: .visible) {
                Button { Task { await upload() } } label: { Text(verbatim: "アップロード") }
            }
        }.interactiveDismissDisabled(busy).onDisappear { cleanup() }
    }
    private func cleanup() {
        if ownsFile, let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    }
    private func upload() async {
        guard let file else { return }
        let access = file.startAccessingSecurityScopedResource()
        defer { if access { file.stopAccessingSecurityScopedResource() } }
        busy = true; fraction = 0; message = nil
        defer { busy = false }
        do {
            let revision = bridge.revision
            let size = (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard size > 0 else { message = "空のファイルは追加できません。"; return }
            let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            var info: [String: Any] = ["name": file.lastPathComponent, "mimeType": type, "size": size]
            if let folderId { info["folderId"] = folderId }
            struct Upload: Decodable { let id: String; let chunkSize: Int }
            let opened: LAABridgeResponse<Upload> = try await bridge.request(method: "POST", path: "/v1/drive/uploads", jsonBody: JSONSerialization.data(withJSONObject: info), idempotencyKey: LAABridgeIdempotencyKey())
            guard opened.data.chunkSize > 0, opened.data.chunkSize <= 4 * 1024 * 1024,
                  UUID(uuidString: opened.data.id) != nil else { throw LAABridgeError.invalidResponse }
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            struct Chunk: Decodable { let completed: Bool; let offset: Int }
            var offset = 0
            while offset < size {
                try Task.checkCancellation()
                guard revision == bridge.revision else { throw LAABridgeError.unauthorized }
                guard let bytes = try handle.read(upToCount: min(opened.data.chunkSize, size - offset)), !bytes.isEmpty else { throw LAABridgeError.invalidResponse }
                let response: LAABridgeResponse<Chunk> = try await bridge.request(method: "PUT", path: "/v1/drive/uploads/\(opened.data.id)/chunks/\(offset)", jsonBody: bytes, idempotencyKey: LAABridgeIdempotencyKey(), timeout: 120)
                guard response.data.offset == offset + bytes.count, response.data.completed == (response.data.offset == size) else { throw LAABridgeError.invalidResponse }
                offset = response.data.offset; fraction = Double(offset) / Double(size)
            }
            completed(); dismiss()
        } catch {
            uncertain = true
            message = "追加結果を確認できません。Driveを更新してから再操作してください。権限不足の場合はMac側のGoogle接続を確認してください。"
        }
    }
}
#endif
