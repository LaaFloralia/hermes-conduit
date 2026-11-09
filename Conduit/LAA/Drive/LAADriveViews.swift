#if LAA_BUILD
import SwiftUI
import PDFKit
import QuickLook
import UIKit

extension LAACopy {
    enum Drive {
        static var details: String { AppLocalization.string("File details") }
        static var size: String { AppLocalization.string("Size") }
        static var mime: String { AppLocalization.string("Type") }
        static var modified: String { AppLocalization.string("Modified") }
        static var owner: String { AppLocalization.string("Owner") }
        static var downloadable: String { AppLocalization.string("Downloadable") }
        static var unknown: String { AppLocalization.string("Unavailable") }
        static var yes: String { AppLocalization.string("Yes") }
        static var no: String { AppLocalization.string("No") }
        static var open: String { AppLocalization.string("Open") }
        static var play: String { AppLocalization.string("Play") }
        static var pause: String { AppLocalization.string("Pause") }
        static var seek: String { AppLocalization.string("Playback position") }
        static var retry: String { AppLocalization.string("Retry") }
        static var workspace: String { AppLocalization.string("Open in Google Drive") }
        static var unsupported: String { AppLocalization.string("This file type cannot be previewed here. Open on Mac.") }
        static var notDownloadable: String { AppLocalization.string("This file cannot be downloaded. Open on Mac.") }
        static var downloadUnknown: String { AppLocalization.string("Download permission is unavailable. Open on Mac.") }
        static var rangeUnsupported: String { AppLocalization.string("The server did not support seeking. Playback was stopped.") }
        static var rangeInvalid: String { AppLocalization.string("The requested file range could not be read. Try again.") }
        static var tooLarge: String { AppLocalization.string("This preview is larger than 64 MB. Open on Mac.") }
        static var invalidPreview: String { AppLocalization.string("This file could not be displayed. Open on Mac.") }
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
        if let error = error as? LAADrivePDFExportError {
            switch error {
            case .tooLarge: return AppLocalization.string("The exported PDF exceeds 10 MB. Open in Google Drive.")
            case .versionChanged: return AppLocalization.string("This file changed in Drive. Reopen it to continue.")
            }
        }
        if let error = error as? LAADriveRangeError {
            switch error {
            case .rangeUnsupported: return LAACopy.Drive.rangeUnsupported
            case .unsatisfiable, .invalidRange: return LAACopy.Drive.rangeInvalid
            case .tooLarge: return LAACopy.Drive.tooLarge
            case .versionChanged: return AppLocalization.string("This file changed in Drive. Reopen it to continue.")
            }
        }
        if let error = error as? LAABridgeHTTPError {
            if error.code == "drive_not_configured" { return "Google Driveは未連携です。Mac側のGoogle接続を確認してください。" }
            if error.code == "drive_auth_required" { return "Googleの認証が切れています。Mac側で再連携してください。" }
            if error.code == "drive_access_denied" { return "Google Driveのアクセス権限を確認してください。" }
            if error.code == "drive_not_found" { return "ファイルが削除されたか、アクセスできなくなっています。一覧を更新してください。" }
            if error.code == "drive_conflict" { return "Driveで変更されています。開き直してください。" }
            if error.code == "insufficient_scope" { return LAACopy.Assets.scope }
            if error.code == "version_changed" { return AppLocalization.string("This file changed in Drive. Reopen it to continue.") }
            return bridgeMessage(error.legacyError)
        }
        return bridgeMessage((error as? LAABridgeError) ?? .invalidResponse)
    }

    private static func bridgeMessage(_ error: LAABridgeError) -> String {
        switch error {
        case .invalidAddress: return AppLocalization.string("Check the Mac’s Tailscale HTTPS address.")
        case .networkUnreachable: return AppLocalization.string("Cannot reach the Mac. Check Tailscale and the Mac.")
        case .tlsFailed: return AppLocalization.string("The secure connection could not be verified. Check the address and certificate.")
        case .invalidResponse: return AppLocalization.string("The Mac returned an invalid response.")
        case .keychain: return AppLocalization.string("The connection information could not be saved or read.")
        case .revoked: return AppLocalization.string("This device’s connection was revoked. Pair it again.")
        case .unauthorized: return AppLocalization.string("Authentication failed. Pair the device again.")
        case .forbidden: return AppLocalization.string("This device does not have the required permission.")
        case .conflict: return AppLocalization.string("The operation conflicted. Refresh and try again.")
        case .expired: return AppLocalization.string("The results expired. Reload and try again.")
        case .rateLimited: return AppLocalization.string("Too many requests. Try again later.")
        case .unavailable: return AppLocalization.string("The service on the Mac is unavailable.")
        case .other: return AppLocalization.string("Could not get data from the Mac.")
        }
    }

    static func reason(_ item: LAADriveItem) -> String? {
        if item.isWorkspace && item.exportFormats?.contains("application/pdf") != true { return LAACopy.Drive.workspace }
        guard let downloadable = item.downloadable else { return LAACopy.Drive.downloadUnknown }
        if !downloadable { return LAACopy.Drive.notDownloadable }
        if !(item.isMedia || item.isImage || item.isPDF || item.isWorkspace || item.isDocument) { return LAACopy.Drive.unsupported }
        return nil
    }
}

struct LAADriveDetailView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    let item: LAADriveItem
    let webViewURL: URL?
    let images: [LAADriveItem]
    @State private var metadata: LAADriveItem?
    @State private var error: String?
    @State private var loading = true
    @State private var saveConfirmation = false
    @State private var saveTask: Task<Void, Never>?
    @State private var saveMessage: String?

    /// The Mac detail column paints the whole column; only the content is
    /// narrowed, so no banded background shows beside it.
    var contentMaxWidth: CGFloat? = nil
    var usesNavigationTitle = true

    init(item: LAADriveItem, webViewURL: URL? = nil, images: [LAADriveItem] = [],
         contentMaxWidth: CGFloat? = nil, usesNavigationTitle: Bool = true) {
        self.item = item
        self.webViewURL = webViewURL
        self.images = images
        self.contentMaxWidth = contentMaxWidth
        self.usesNavigationTitle = usesNavigationTitle
    }

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
                        let explanation = value.isWorkspace && webViewURL == nil
                            ? AppLocalization.string("Google Drive link unavailable.") : reason
                        Button(LAACopy.Drive.open) {}.buttonStyle(.borderedProminent).disabled(true)
                            .tint(LAAColor.filledButton).foregroundStyle(LAAColor.filledButtonText)
                            .accessibilityHint(Text(verbatim: explanation))
                        Text(verbatim: explanation).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    } else {
                        NavigationLink(LAACopy.Drive.open) { LAADrivePreviewView(item: value, images: images) }
                            .buttonStyle(.borderedProminent).tint(LAAColor.filledButton)
                            .foregroundStyle(LAAColor.filledButtonText).accessibilityIdentifier("laa.drive.open")
                    }
                    if let webViewURL {
                        Link("Open in Google Drive", destination: webViewURL)
                            .accessibilityHint("Opens Google Drive or a browser.")
                            .accessibilityIdentifier("laa.drive.open-in-drive")
                        ShareLink("Share Drive link", item: webViewURL)
                    }
                    if LAADrivePresentation.reason(value) == nil {
                        if saveTask == nil {
                            Button("Save offline") { saveConfirmation = true }
                                .accessibilityIdentifier("laa.drive.offline.save")
                        } else {
                            HStack {
                                ProgressView("Saving offline")
                                Button("Cancel") { saveTask?.cancel() }
                            }
                        }
                        if let saveMessage {
                            Text(verbatim: saveMessage).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        }
                    }
                }
            }
            .laaTextStyle(.body)
            .padding(LAASpacing.horizontal)
            .frame(maxWidth: contentMaxWidth ?? .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(LAAColor.background.ignoresSafeArea())
        .navigationTitle(Text(verbatim: usesNavigationTitle ? LAACopy.Drive.details : ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task(id: bridge.revision) { await load() }
        .onDisappear { saveTask?.cancel() }
        // The copy is saved on the device the app runs on: this Mac on the Mac.
        .confirmationDialog(Text(verbatim: LAADeviceCopy.shown(AppLocalization.string("Save a copy on this iPhone?"))),
                            isPresented: $saveConfirmation, titleVisibility: .visible) {
            Button("Save offline") { if let metadata { save(metadata) } }
            Button("Cancel", role: .cancel) { }
        } message: {
            if let metadata, metadata.isWorkspace {
                Text("The document will be saved as a PDF. Its size is known after export (up to 10 MB).")
            } else if let size = metadata?.size {
                let requiredSpace = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                Text("Required file space: \(requiredSpace), plus a small temporary allowance.")
            } else { Text("The file size will be checked before saving.") }
        }
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
    @MainActor private func save(_ value: LAADriveItem) {
        guard saveTask == nil else { return }
        saveMessage = nil
        saveTask = Task {
            do {
                try await LAADriveOfflineOperations.shared.save(value, bridge: bridge)
                saveMessage = AppLocalization.string("Saved offline")
            } catch is CancellationError { saveMessage = AppLocalization.string("Cancelled") }
            catch { saveMessage = LAADriveOfflineOperations.message(error) }
            saveTask = nil
        }
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

struct LAADrivePreviewView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    let item: LAADriveItem
    var images: [LAADriveItem] = []
    @State private var data: Data?
    @State private var error: String?
    @State private var loading = true
    @State private var retry = 0
    @State private var localFile: LAADriveShareFile?
    @State private var showShare = false

    var body: some View {
        Group {
            if item.isMedia {
                LAADrivePlayerView(item: item, bridge: bridge)
            } else if item.isImage, images.count > 1 {
                LAADriveImagePager(items: images, initialID: item.id)
            } else if let data {
                if item.isImage, let image = UIImage(data: data) { LAADriveZoomImage(image: image) }
                else if (item.isPDF || item.isWorkspace), let document = PDFDocument(data: data) { LAADrivePDF(document: document) }
                else if item.isDocument, let localFile { LAADriveQuickLook(url: localFile.url) }
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
        .toolbar {
            if localFile != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showShare = true } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel(Text(verbatim: "共有・ファイルに保存"))
                }
            }
        }
        .sheet(isPresented: $showShare) {
            if let localFile { LAADriveShareSheet(items: [localFile.url], onComplete: { showShare = false }) }
        }
        .onDisappear { releaseLocal() }
        .task(id: "\(retry):\(bridge.revision)") {
            guard !item.isMedia, !(item.isImage && images.count > 1) else { return }
            loading = true; error = nil; data = nil; releaseLocal()
            let revision = bridge.revision
            do {
                if item.isWorkspace {
                    data = try await LAADriveData.exportPDF(item, bridge: bridge, expectedVersion: item.version).data
                } else {
                    data = try await LAADriveContent.preview(item, bridge: bridge)
                }
                try Task.checkCancellation()
                guard revision == bridge.revision else { throw CancellationError() }
                if let data {
                    let prepared = try await LAADriveOfflineOperations.shared.shares.prepare(data: data,
                        name: item.isWorkspace ? item.name + ".pdf" : item.name, mimeType: item.isWorkspace ? "application/pdf" : item.mimeType)
                    guard revision == bridge.revision, !Task.isCancelled else {
                        try? await LAADriveOfflineOperations.shared.shares.release(prepared.id); throw CancellationError()
                    }
                    localFile = prepared
                }
            }
            catch is CancellationError { }
            catch { self.error = LAADrivePresentation.message(error) }
            loading = false
        }
    }
    private func releaseLocal() {
        guard let localFile else { return }
        self.localFile = nil
        Task { try? await LAADriveOfflineOperations.shared.shares.release(localFile.id) }
    }
}

private struct LAADriveQuickLook: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url; controller.reloadData()
    }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(_ url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}

struct LAADrivePDF: UIViewRepresentable {
    let document: PDFDocument
    func makeUIView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; return view }
    func updateUIView(_ view: PDFView, context: Context) { if view.document !== document { view.document = document } }
}

struct LAADriveZoomImage: UIViewRepresentable {
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
