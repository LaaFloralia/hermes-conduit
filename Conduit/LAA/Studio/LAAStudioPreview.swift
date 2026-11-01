#if LAA_BUILD
import SwiftUI
import PDFKit
import QuickLook
import ImageIO

@MainActor
private final class LAAStudioPreviewLoader: ObservableObject {
    @Published var file: URL?
    @Published var image: UIImage?
    @Published var loading = false
    @Published var error: String?
    private var directory: URL?
    private var generation = UUID()
    private let limit: Int64 = 128 * 1024 * 1024

    func load(path: String?, bridge: LAABridgeSession) async {
        cleanup()
        let generation = self.generation
        guard let path = LAAStudioMedia.bridgePath(path), let ext = path.split(separator: ".").last.map(String.init),
              let mime = Self.mime[ext] else { error = LAACopy.Studio.unsupported; return }
        loading = true; error = nil
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LAAStudio-\(UUID().uuidString)", isDirectory: true)
        let destination = dir.appendingPathComponent("preview.\(ext)")
        directory = dir
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                     attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                                                  attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
                throw LAABridgeError.invalidResponse
            }
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            var offset: Int64 = 0
            var total: Int64?
            repeat {
                try Task.checkCancellation()
                let timeout: TimeInterval? = path.hasPrefix("/v1/studio/media/catalog/") ? 150 : nil
                let part = try await bridge.driveRange(path: path, offset: offset, length: LAADriveContent.chunkSize, timeout: timeout)
                try Task.checkCancellation()
                guard generation == self.generation, part.total > 0, part.total <= limit,
                      total == nil || total == part.total, part.mimeType?.lowercased() == mime,
                      !part.data.isEmpty, Int64(part.data.count) <= part.total - offset else { throw LAABridgeError.invalidResponse }
                total = part.total
                try handle.write(contentsOf: part.data)
                offset += Int64(part.data.count)
            } while offset < (total ?? 0)
            try handle.synchronize()
            try Task.checkCancellation()
            guard generation == self.generation else { throw CancellationError() }
            if ["jpg", "png", "webp"].contains(ext) {
                let options = [kCGImageSourceShouldCache: false] as CFDictionary
                guard let source = CGImageSourceCreateWithURL(destination as CFURL, options),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 2400,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { throw LAABridgeError.invalidResponse }
                image = UIImage(cgImage: thumbnail)
            } else if ext == "pdf" && PDFDocument(url: destination) == nil {
                throw LAABridgeError.invalidResponse
            }
            file = destination
        } catch is CancellationError {
            if generation == self.generation { cleanup() }
        } catch {
            if generation == self.generation {
                cleanup()
                self.error = "プレビューを開けません。Driveの納品を確認してください。"
            }
        }
        if generation == self.generation { loading = false }
    }
    func cleanup() {
        generation = UUID()
        file = nil; image = nil; loading = false
        if let directory { try? FileManager.default.removeItem(at: directory); self.directory = nil }
    }
    private static let mime = ["jpg": "image/jpeg", "png": "image/png", "webp": "image/webp",
                               "pdf": "application/pdf", "usdz": "model/vnd.usdz+zip"]
}

struct LAAStudioFilePreview: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @StateObject private var loader = LAAStudioPreviewLoader()
    @State private var attempt = 0
    let path: String?
    var driveURL: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            if loader.loading {
                if LAAStudioMedia.bridgePath(path)?.hasPrefix("/v1/studio/media/catalog/") == true {
                    ProgressView {
                        Text(verbatim: "資料を読み込んでいます。Driveからの取得に時間がかかる場合があります。")
                    }.accessibilityIdentifier("laa.studio.document.loading")
                } else {
                    ProgressView().accessibilityLabel(Text(verbatim: LAACopy.loading))
                }
            }
            if let image = loader.image { Image(uiImage: image).resizable().scaledToFit() }
            else if let file = loader.file, file.pathExtension == "pdf" {
                LAAStudioPDFView(url: file).frame(minHeight: 520)
            } else if let file = loader.file, file.pathExtension == "usdz" {
                LAAStudioQuickLook(url: file).frame(minHeight: 520)
            }
            if let error = loader.error {
                Text(verbatim: error).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                if LAAStudioMedia.bridgePath(path) != nil {
                    Button { attempt += 1 } label: { Text(verbatim: LAACopy.Studio.retry).frame(minHeight: LAASpacing.minimumTouchTarget) }
                }
                if let url = LAAStudioMedia.driveURL(driveURL) {
                    Link(destination: url) { Label("Driveで開く", systemImage: "arrow.up.right.square").frame(minHeight: LAASpacing.minimumTouchTarget) }
                }
            }
        }.task(id: "\(path ?? "")-\(attempt)") { await loader.load(path: path, bridge: bridge) }
            .onDisappear { loader.cleanup() }
    }
}

private struct LAAStudioPDFView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.document = PDFDocument(url: url); return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}

private struct LAAStudioQuickLook: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let view = QLPreviewController(); view.dataSource = context.coordinator; return view
    }
    func updateUIViewController(_ view: QLPreviewController, context: Context) {
        if context.coordinator.url != url { context.coordinator.url = url; view.reloadData() }
    }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
#endif
