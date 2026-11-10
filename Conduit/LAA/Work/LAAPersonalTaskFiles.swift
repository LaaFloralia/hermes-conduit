#if LAA_BUILD
import SwiftUI
import QuickLook

private struct LAAPersonalFileList: Decodable {
    struct Item: Decodable, Identifiable { let id: String; let name: String }
    let items: [Item]
    let viewerId: String
}
private struct LAAPersonalFileContent: Decodable {
    let viewerId: String
    let name: String
    let content: Data
    let size: Int
}

/// Preview files are protected at rest and removed on dismissal or on the
/// next preview after an interrupted app session.
@MainActor private enum LAAPersonalPreview {
    private static var prepared = false
    static func save(_ content: LAAPersonalFileContent) throws -> URL {
        guard content.size == content.content.count, (0...(20 * 1024 * 1024)).contains(content.size) else {
            throw LAABridgeError.invalidResponse
        }
        let manager = FileManager.default
        let root = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LinearPreviews", isDirectory: true)
        if !prepared {
            try? manager.removeItem(at: root)
            prepared = true
        }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true,
                                    attributes: [.protectionKey: FileProtectionType.complete])
        let clean: [Character] = String(content.name.prefix(160)).map { character in
            character == "/" || character == "\\" || character == ":"
                || character.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) ? "_" : character
        }
        let name = String(clean)
        let url = folder.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "file" : name)
        do { try content.content.write(to: url, options: [.atomic, .completeFileProtection]) }
        catch { try? manager.removeItem(at: folder); throw error }
        return url
    }
    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

struct LAAPersonalFileButton: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let title: String
    let path: String
    let viewerId: String
    @State private var preview: URL?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading) {
            Button(title) { Task { await open() } }.disabled(loading)
            if loading { LAAWorkSkeleton() }
            if let error { Text(verbatim: error).foregroundStyle(LAAColor.attention).laaTextStyle(.secondary) }
        }
        .quickLookPreview($preview)
        .onChange(of: preview) { old, new in if new == nil, let old { LAAPersonalPreview.remove(old) } }
    }

    @MainActor private func open() async {
        loading = true; error = nil; defer { loading = false }
        do {
            let response: LAABridgeResponse<LAAPersonalFileContent> = try await bridge.request(method: "GET", path: path, timeout: 90)
            guard response.data.viewerId == viewerId else { throw LAABridgeError.conflict }
            preview = try LAAPersonalPreview.save(response.data)
        } catch let failure as LAABridgeHTTPError {
            error = failure.code == "file_too_large" ? "20 MiBを超えるファイルはLinearで開いてください。" : LAAWorkHTTP.message(failure)
        } catch is CancellationError {
        } catch let failure as LAABridgeError { error = failure.japaneseText }
        catch { self.error = "ファイルを開けませんでした。" }
    }
}

struct LAAPersonalMarkdownFiles: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let taskPath: String
    let viewerId: String
    let commentId: String?
    @State private var files: [LAAPersonalFileList.Item] = []
    @State private var error: String?
    private var query: [URLQueryItem] { commentId.map { [URLQueryItem(name: "comment", value: $0)] } ?? [] }
    private var listPath: String { LAAWorkPresentation.path(taskPath + "/files", query: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x1) {
            if let error { Text(verbatim: error).foregroundStyle(LAAColor.attention).laaTextStyle(.secondary) }
            ForEach(files) { file in
                LAAPersonalFileButton(title: file.name,
                    path: LAAWorkPresentation.path(taskPath + "/files/" + file.id + "/content", query: query), viewerId: viewerId)
            }
        }
        .task(id: "\(bridge.revision)-\(listPath)-\(viewerId)") {
            do {
                let result: LAAPersonalFileList = try await bridge.read(listPath)
                guard result.viewerId == viewerId else { throw LAABridgeError.conflict }
                files = result.items; error = nil
            } catch is CancellationError {
            } catch { self.error = "本文内ファイルを確認できませんでした。" }
        }
    }
}
#endif
