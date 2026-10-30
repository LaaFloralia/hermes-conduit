#if LAA_BUILD
import SwiftUI
import PDFKit
import UIKit

extension LAACopy {
    enum Drive {
        static let details = "File details"
        static let size = "Size"
        static let mime = "Type"
        static let modified = "Modified"
        static let owner = "Owner"
        static let downloadable = "Downloadable"
        static let unknown = "Unavailable"
        static let yes = "Yes"
        static let no = "No"
        static let open = "Open"
        static let play = "Play"
        static let pause = "Pause"
        static let seek = "Playback position"
        static let retry = "Retry"
        static let workspace = "Google documents cannot be exported by this Bridge yet. Open on Mac."
        static let unsupported = "This file type cannot be previewed here. Open on Mac."
        static let notDownloadable = "This file cannot be downloaded. Open on Mac."
        static let downloadUnknown = "Download permission is unavailable. Open on Mac."
        static let rangeUnsupported = "The server did not support seeking. Playback was stopped."
        static let rangeInvalid = "The requested file range could not be read. Try again."
        static let tooLarge = "This preview is larger than 64 MB. Open on Mac."
        static let invalidPreview = "This file could not be displayed. Open on Mac."
    }
}

enum LAADriveThumbnail {
    // Google links get no Bridge credentials. Never forward a token to a URL
    // supplied by metadata, including redirects to another host.
    static func safeURL(_ url: URL?) -> URL? {
        guard let url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), host.hasSuffix(".googleusercontent.com") else { return nil }
        return url
    }
}

enum LAADrivePresentation {
    static func message(_ error: Error) -> String {
        if let error = error as? LAADriveRangeError {
            switch error {
            case .rangeUnsupported: return LAACopy.Drive.rangeUnsupported
            case .unsatisfiable, .invalidRange: return LAACopy.Drive.rangeInvalid
            case .tooLarge: return LAACopy.Drive.tooLarge
            }
        }
        if let error = error as? LAABridgeHTTPError {
            if error.code == "drive_not_configured" { return LAACopy.Assets.configureDrive }
            if error.code == "insufficient_scope" { return LAACopy.Assets.scope }
            return error.legacyError.japaneseText
        }
        return (error as? LAABridgeError)?.japaneseText ?? LAABridgeError.invalidResponse.japaneseText
    }

    static func reason(_ item: LAADriveItem) -> String? {
        if item.isWorkspace { return LAACopy.Drive.workspace }
        guard let downloadable = item.downloadable else { return LAACopy.Drive.downloadUnknown }
        if !downloadable { return LAACopy.Drive.notDownloadable }
        if !(item.isMedia || item.isImage || item.isPDF) { return LAACopy.Drive.unsupported }
        return nil
    }
}

struct LAADriveDetailView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let item: LAADriveItem
    @State private var metadata: LAADriveItem?
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x6) {
                Label { Text(verbatim: item.name).font(LAAType.screenTitle) } icon: {
                    Image(systemName: item.symbol).foregroundStyle(LAAColor.link)
                }.foregroundStyle(LAAColor.text)
                if loading { ProgressView() }
                if let error {
                    Text(verbatim: error).foregroundStyle(LAAColor.attention)
                    Button(LAACopy.Drive.retry) { Task { await load() } }
                }
                if let value = metadata {
                    VStack(spacing: LAASpacing.x4) {
                        row(LAACopy.Drive.size, value.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? LAACopy.Drive.unknown)
                        row(LAACopy.Drive.mime, value.mimeType)
                        row(LAACopy.Drive.modified, formattedDate(value.modifiedAt))
                        row(LAACopy.Drive.owner, value.owners?.compactMap(\.displayName).joined(separator: ", ").nilIfEmpty ?? LAACopy.Drive.unknown)
                        row(LAACopy.Drive.downloadable, value.downloadable.map { $0 ? LAACopy.Drive.yes : LAACopy.Drive.no } ?? LAACopy.Drive.unknown)
                    }
                    .padding(LAASpacing.x4)
                    .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
                    if let reason = LAADrivePresentation.reason(value) {
                        Button(LAACopy.Drive.open) {}.buttonStyle(.borderedProminent).disabled(true)
                            .tint(LAAColor.filledButton).foregroundStyle(LAAColor.filledButtonText)
                            .accessibilityHint(Text(verbatim: reason))
                        Text(verbatim: reason).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    } else {
                        NavigationLink(LAACopy.Drive.open) { LAADrivePreviewView(item: value) }
                            .buttonStyle(.borderedProminent).tint(LAAColor.filledButton)
                            .foregroundStyle(LAAColor.filledButtonText).accessibilityIdentifier("laa.drive.open")
                    }
                }
            }.laaTextStyle(.body).padding(LAASpacing.horizontal).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(LAAColor.background.ignoresSafeArea())
        .navigationTitle(Text(verbatim: LAACopy.Drive.details))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task(id: bridge.revision) { await load() }
        .accessibilityIdentifier("laa.drive.detail")
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: LAASpacing.x4) {
            Text(verbatim: label).foregroundStyle(LAAColor.secondaryText).fixedSize()
            Text(verbatim: value).foregroundStyle(LAAColor.text).multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        }
    }
    private func formattedDate(_ text: String?) -> String {
        guard let text else { return LAACopy.Drive.unknown }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) else { return text }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
    @MainActor private func load() async {
        loading = true; error = nil; metadata = nil
        do { metadata = try await LAADriveData.metadata(item, bridge: bridge) }
        catch is CancellationError { }
        catch { self.error = LAADrivePresentation.message(error) }
        loading = false
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

struct LAADrivePreviewView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let item: LAADriveItem
    @State private var data: Data?
    @State private var error: String?
    @State private var loading = true
    @State private var retry = 0

    var body: some View {
        Group {
            if item.isMedia {
                LAADrivePlayerView(item: item, bridge: bridge)
            } else if let data {
                if item.isImage, let image = UIImage(data: data) { LAADriveZoomImage(image: image) }
                else if item.isPDF, let document = PDFDocument(data: data) { LAADrivePDF(document: document) }
                else { Text(verbatim: LAACopy.Drive.invalidPreview).foregroundStyle(LAAColor.attention) }
            } else if let error {
                VStack(spacing: LAASpacing.x4) {
                    Text(verbatim: error).foregroundStyle(LAAColor.attention)
                    Button(LAACopy.Drive.retry) { retry += 1 }
                }.padding(LAASpacing.horizontal)
            } else if loading { ProgressView() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LAAColor.background.ignoresSafeArea())
        .tint(LAAColor.link)
        .navigationTitle(Text(verbatim: item.name)).navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task(id: retry) {
            guard !item.isMedia else { return }
            loading = true; error = nil
            do { data = try await LAADriveContent.preview(item, bridge: bridge) }
            catch is CancellationError { }
            catch { self.error = LAADrivePresentation.message(error) }
            loading = false
        }
    }
}

private struct LAADrivePDF: UIViewRepresentable {
    let document: PDFDocument
    func makeUIView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; return view }
    func updateUIView(_ view: PDFView, context: Context) { if view.document !== document { view.document = document } }
}

private struct LAADriveZoomImage: UIViewRepresentable {
    let image: UIImage
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView(); scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 5
        scroll.backgroundColor = .clear
        let imageView = UIImageView(image: image); imageView.contentMode = .scaleAspectFit
        imageView.frame = scroll.bounds; imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(imageView); context.coordinator.imageView = imageView
        return scroll
    }
    func updateUIView(_ view: UIScrollView, context: Context) { context.coordinator.imageView?.image = image }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    }
}
#endif
