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
                try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets"), withIntermediateDirectories: true)
                try Data("# 見出し\n\nオフラインの検索本文です。 fixture-search #garden\n\n[[Other#Details|次のメモ]]\n\n![[Assets/fixture.png]]\n\n![[Other]]\n".utf8)
                    .write(to: root.appendingPathComponent("Company/Start.md"))
                try Data("# 別のメモ\n\n## Details\n本文\n".utf8).write(to: root.appendingPathComponent("Company/Other.md"))
                guard let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO7+X2sAAAAASUVORK5CYII=") else { throw LAABrainVaultError.unreadable }
                try image.write(to: root.appendingPathComponent("Assets/fixture.png"))
                if ProcessInfo.processInfo.arguments.contains("-laa-brain-save-fixture") &&
                    ProcessInfo.processInfo.arguments.contains("-laa-brain-history-fixture") {
                    let journal = LAABrainSaveJournal()
                    let vault = LAABrainSaveJournal.vaultID(root)
                    _ = try journal.record(vault: vault, path: "Company/Deleted.md", kind: .original, bytes: Data("DELETED-FIXTURE".utf8))
                    _ = try journal.record(vault: vault, path: "Company/Renamed.md", kind: .displaced, bytes: Data([0xff, 0xfe, 0x80]))
                    let pending = try journal.makePending(vault: vault, path: "Company/Deleted.md", base: Data(), draft: Data())
                    try Data("INTERRUPTED-FIXTURE".utf8).write(to: journal.stageURL(pending), options: .atomic)
                    try Data("RENAMED-CURRENT".utf8).write(to: root.appendingPathComponent("Company/Renamed-current.md"))
                }
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
    case access, notDirectory, invalidPath, unreadable, invalidText, tooLarge, ambiguous

    var message: String {
        switch self {
        case .access: return "Folder access is unavailable. Choose it again or use the Mac connection."
        case .notDirectory: return "Choose a folder."
        case .invalidPath: return "This item is outside the selected folder or is a symbolic link."
        case .unreadable: return "The folder or note could not be read. Check its availability and try again."
        case .invalidText: return "This note is not valid UTF-8 text."
        case .tooLarge: return "This file is too large to preview."
        case .ambiguous: return "More than one attachment has this name. Use its full path."
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
                let maxBytes = 32 * 1024 * 1024
                if let size = try coordinatedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxBytes {
                    throw LAABrainVaultError.tooLarge
                }
                let data = try Data(contentsOf: coordinatedURL, options: .mappedIfSafe)
                guard data.count <= maxBytes else { throw LAABrainVaultError.tooLarge }
                guard let text = String(data: data, encoding: .utf8) else { throw LAABrainVaultError.invalidText }
                return LAABrainNote(id: LAABrainReference(path: path, includeInbox: true).id, path: path, text: text)
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    static func attachment(root: URL, currentPath: String, target: String) throws -> (path: String, data: Data) {
        let raw = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let requested = raw.removingPercentEncoding ?? raw
        guard !requested.isEmpty, !requested.hasPrefix("/"), !requested.contains(":"),
              !requested.contains("\\"), requested.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw LAABrainVaultError.invalidPath
        }
        let parent = currentPath.split(separator: "/").dropLast().map(String.init)
        func normalize(_ base: [String], _ path: String) -> String? {
            var parts = base
            for part in path.split(separator: "/", omittingEmptySubsequences: false) {
                if part == "." { continue }
                if part == ".." { guard !parts.isEmpty else { return nil }; parts.removeLast() }
                else if part.isEmpty { return nil }
                else { parts.append(String(part)) }
            }
            return parts.joined(separator: "/")
        }
        guard let relative = normalize(parent, requested) else { throw LAABrainVaultError.invalidPath }
        let rooted = normalize([], requested)
        let candidates = [relative, rooted].compactMap { $0 }
        var selected: String?
        for path in candidates {
            if let url = try? safeURL(root: root, path: path),
               (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                selected = path; break
            }
        }
        if selected == nil && !requested.contains("/") {
            let matches = try findAttachments(root: root, filename: requested)
            if matches.count > 1 { throw LAABrainVaultError.ambiguous }
            selected = matches.first
        }
        guard let path = selected else { throw LAABrainVaultError.unreadable }
        let url = try safeURL(root: root, path: path)
        var result: Result<Data, Error> = .failure(LAABrainVaultError.unreadable)
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result {
                _ = try safeURL(root: root, path: path)
                let maxBytes = 32 * 1024 * 1024
                if let size = try coordinatedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxBytes {
                    throw LAABrainVaultError.tooLarge
                }
                let data = try Data(contentsOf: coordinatedURL, options: .mappedIfSafe)
                guard data.count <= maxBytes else { throw LAABrainVaultError.tooLarge }
                return data
            }
        }
        if let coordinationError { throw coordinationError }
        return (path, try result.get())
    }

    private static func findAttachments(root: URL, filename: String) throws -> [String] {
        var result: Result<[String], Error> = .failure(LAABrainVaultError.unreadable)
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: root, options: [], error: &coordinationError) { coordinatedRoot in
            result = Result {
                let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
                var enumerationError: Error?
                guard let enumerator = FileManager.default.enumerator(at: coordinatedRoot, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, error in
                    enumerationError = error; return false
                }) else { throw LAABrainVaultError.unreadable }
                let prefix = coordinatedRoot.standardizedFileURL.path.hasSuffix("/") ? coordinatedRoot.standardizedFileURL.path : coordinatedRoot.standardizedFileURL.path + "/"
                var matches: [String] = []
                for case let item as URL in enumerator {
                    let values = try item.resourceValues(forKeys: keys)
                    if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                    if values.isDirectory == true {
                        if excludedDirectories.contains(item.lastPathComponent) { enumerator.skipDescendants() }
                    } else if values.isRegularFile == true, item.lastPathComponent.precomposedStringWithCanonicalMapping == filename.precomposedStringWithCanonicalMapping,
                              item.standardizedFileURL.path.hasPrefix(prefix) {
                        matches.append(String(item.standardizedFileURL.path.dropFirst(prefix.count)))
                    }
                }
                if let enumerationError { throw enumerationError }
                return matches
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
