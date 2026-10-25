import Foundation

/// A workspace file prepared for Save to Files: in a folder of its own,
/// which the preview that asked for it removes when it closes.
struct WorkspaceDownload: Equatable {
    let directory: URL
    let file: URL
}

/// Where workspace files are prepared for Save to Files. First use sweeps
/// what a previous run left (a preview open when the app was killed never
/// reaches its cleanup); launch reaches it off the main thread.
enum WorkspaceDownloads {
    static let root: URL = {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Hermes-Conduit-Downloads", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        return root
    }()

    /// Writes `data` to `<root>/<uuid>/<name>`.
    static func stage(_ data: Data, name: String) throws -> WorkspaceDownload {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent(MediaPreviewPresenter.sanitizedFilename(name))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return WorkspaceDownload(directory: directory, file: file)
        } catch {
            remove(WorkspaceDownload(directory: directory, file: file))
            throw error
        }
    }

    static func remove(_ download: WorkspaceDownload?) {
        guard let download else { return }
        try? FileManager.default.removeItem(at: download.directory)
    }
}
