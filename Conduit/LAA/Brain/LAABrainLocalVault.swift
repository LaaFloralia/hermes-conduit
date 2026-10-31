#if LAA_BUILD
import Combine
import Foundation

/// A selected folder remains in scope while its file presenter is registered.
/// No sync state is inferred from the ability to read this folder.
@MainActor final class LAABrainLocalVault: ObservableObject {
    enum State: Equatable { case disconnected, ready, needsAccess }
    @Published private(set) var state: State = .disconnected
    @Published private(set) var revision = 0
    private var root: URL?
    private var presenter: LAABrainVaultPresenter?
    private var scopeHeld = false
    private let bookmarkURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        bookmarkURL = support.appendingPathComponent("Brain", isDirectory: true).appendingPathComponent("vault.bookmark")
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-laa-brain-local-fixture") {
            do {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("brain-fixture-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: root.appendingPathComponent("Company"), withIntermediateDirectories: true)
                try Data("# 見出し\n\nオフラインの検索本文です。\n\n[[Other|次のメモ]]\n".utf8)
                    .write(to: root.appendingPathComponent("Company/Start.md"))
                try Data("# 別のメモ\n".utf8).write(to: root.appendingPathComponent("Company/Other.md"))
                activate(root, scoped: false)
            } catch { state = .needsAccess }
            return
        }
        #endif
        restoreBookmark()
    }

    var isSelected: Bool { state != .disconnected }
    var isReady: Bool { state == .ready }

    func connect(_ selected: URL) throws {
        guard selected.startAccessingSecurityScopedResource() else { throw LAABrainVaultError.access }
        do {
            let values = try selected.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { throw LAABrainVaultError.notDirectory }
            let bookmark = try selected.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            try FileManager.default.createDirectory(at: bookmarkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bookmark.write(to: bookmarkURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            activate(selected, scoped: true)
        } catch {
            selected.stopAccessingSecurityScopedResource()
            throw error
        }
    }

    func disconnect() throws {
        // Keep the bookmark and current state if removing it fails.
        if FileManager.default.fileExists(atPath: bookmarkURL.path) { try FileManager.default.removeItem(at: bookmarkURL) }
        deactivate()
        state = .disconnected
        revision += 1
    }

    func snapshot() throws -> URL {
        guard state == .ready, let root else { throw LAABrainVaultError.access }
        return root
    }

    private func restoreBookmark() {
        guard FileManager.default.fileExists(atPath: bookmarkURL.path) else { return }
        do {
            let data = try Data(contentsOf: bookmarkURL)
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale, url.startAccessingSecurityScopedResource() else { state = .needsAccess; return }
            do {
                guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                    url.stopAccessingSecurityScopedResource(); state = .needsAccess; return
                }
                activate(url, scoped: true)
            } catch {
                url.stopAccessingSecurityScopedResource(); state = .needsAccess
            }
        } catch { state = .needsAccess }
    }

    private func activate(_ url: URL, scoped: Bool) {
        deactivate()
        root = url
        scopeHeld = scoped
        let observer = LAABrainVaultPresenter(url: url) { [weak self] in
            Task { @MainActor in self?.revision += 1 }
        }
        presenter = observer
        NSFileCoordinator.addFilePresenter(observer)
        state = .ready
        revision += 1
    }

    private func deactivate() {
        if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
        presenter = nil
        if scopeHeld { root?.stopAccessingSecurityScopedResource() }
        root = nil
        scopeHeld = false
    }

    deinit {
        if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
        if scopeHeld { root?.stopAccessingSecurityScopedResource() }
    }
}

private final class LAABrainVaultPresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; return queue
    }()
    private let changed: () -> Void
    init(url: URL, changed: @escaping () -> Void) { presentedItemURL = url; self.changed = changed }
    func presentedItemDidChange() { changed() }
    func presentedSubitemDidAppear(at url: URL) { changed() }
    func presentedSubitemDidChange(at url: URL) { changed() }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { changed() }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil); changed()
    }
}

enum LAABrainVaultError: Error {
    case access, notDirectory, invalidPath, unreadable, invalidText

    var message: String {
        switch self {
        case .access: return "Folder access is unavailable. Choose it again or use the Mac connection."
        case .notDirectory: return "Choose a folder."
        case .invalidPath: return "This item is outside the selected folder or is a symbolic link."
        case .unreadable: return "The folder or note could not be read. Check its availability and try again."
        case .invalidText: return "This note is not valid UTF-8 text."
        }
    }
}

/// All inputs are a user-selected directory or a test fixture, never a guessed vault path.
enum LAABrainVaultIO {
    private static let excludedDirectories: Set<String> = [".obsidian", ".git", ".trash", ".stfolder", ".stversions"]

    static func files(root: URL) throws -> [LAABrainFile] {
        var result: Result<[LAABrainFile], Error> = .failure(LAABrainVaultError.unreadable)
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: root, options: [], error: &coordinationError) { coordinatedRoot in
            result = Result { try enumerate(root: coordinatedRoot) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    private static func enumerate(root: URL) throws -> [LAABrainFile] {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        var enumerationError: Error?
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, error in
            enumerationError = error; return false
        }) else { throw LAABrainVaultError.unreadable }
        let prefix = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var files: [LAABrainFile] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isDirectory == true {
                if excludedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, url.pathExtension.lowercased() == "md",
                  url.standardizedFileURL.path.hasPrefix(prefix) else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(prefix.count))
            let reference = LAABrainReference(path: path, includeInbox: true)
            files.append(LAABrainFile(id: reference.id, path: path,
                title: url.deletingPathExtension().lastPathComponent,
                modifiedAt: values.contentModificationDate.map(formatter.string) ?? "", area: "local", unreadable: nil))
        }
        if let enumerationError { throw enumerationError }
        return files
    }

    static func note(root: URL, path: String) throws -> LAABrainNote {
        let file = try safeURL(root: root, path: path)
        var result: Result<LAABrainNote, Error> = .failure(LAABrainVaultError.unreadable)
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordinationError) { coordinatedURL in
            result = Result {
                _ = try safeURL(root: root, path: path)
                let data = try Data(contentsOf: coordinatedURL)
                guard let text = String(data: data, encoding: .utf8) else { throw LAABrainVaultError.invalidText }
                return LAABrainNote(id: LAABrainReference(path: path, includeInbox: true).id, path: path, text: text)
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    private static func safeURL(root: URL, path: String) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !excludedDirectories.contains(String($0)) }) else {
            throw LAABrainVaultError.invalidPath
        }
        var url = root
        for component in components {
            url.appendPathComponent(String(component))
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw LAABrainVaultError.invalidPath }
        }
        return url
    }
}
#endif
