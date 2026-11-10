#if LAA_BUILD
import Combine
import Foundation
#if targetEnvironment(macCatalyst)
import Darwin
#endif

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
    private let preferences: UserDefaults
    private let beginScope: (URL) -> Bool
    private let endScope: (URL) -> Void
    private let homeDirectory: URL?
    #if DEBUG && targetEnvironment(macCatalyst)
    private var fixtureRoots: [Location: URL] = [:]
    #endif
    enum Location: String, CaseIterable { case brain = "Brain", hq = "HQ" }
    @Published private(set) var location: Location?
    private var locationBookmark: URL? { location.map { bookmarkURL.deletingLastPathComponent().appendingPathComponent("vault-\($0.rawValue).bookmark") } }

    nonisolated static func userHomeDirectory() -> URL? {
        #if targetEnvironment(macCatalyst)
        guard let entry = getpwuid(getuid()), let path = entry.pointee.pw_dir, path.pointee != 0 else { return nil }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
        #else
        return nil
        #endif
    }

    static func allowedMacRoot(_ url: URL, home: URL) -> Bool {
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        let home = home.standardizedFileURL.resolvingSymlinksInPath().path
        return candidate != home && !home.hasPrefix(candidate == "/" ? "/" : candidate + "/")
    }

    static func legacyLocation(_ url: URL, home: URL) -> Location? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path == home.appendingPathComponent("Brain").standardizedFileURL.resolvingSymlinksInPath().path { return .brain }
        if path == home.appendingPathComponent("hq").standardizedFileURL.resolvingSymlinksInPath().path { return .hq }
        return nil
    }

    func hasBookmark(_ location: Location) -> Bool {
        FileManager.default.fileExists(atPath: bookmarkURL.deletingLastPathComponent().appendingPathComponent("vault-\(location.rawValue).bookmark").path)
    }

    init(bookmarkDirectory: URL? = nil, preferences: UserDefaults = .standard,
         homeDirectory: URL? = LAABrainLocalVault.userHomeDirectory(),
         beginScope: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         endScope: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        bookmarkURL = (bookmarkDirectory ?? support.appendingPathComponent("Brain", isDirectory: true)).appendingPathComponent("vault.bookmark")
        self.preferences = preferences
        self.homeDirectory = homeDirectory
        self.beginScope = beginScope
        self.endScope = endScope
        #if DEBUG
        #if targetEnvironment(macCatalyst)
        if ProcessInfo.processInfo.arguments.contains("-laa-brain-mac-roots-fixture") {
            do {
                let container = FileManager.default.temporaryDirectory.appendingPathComponent("brain-mac-fixture-" + UUID().uuidString)
                for target in Location.allCases {
                    let directory = container.appendingPathComponent(target.rawValue, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try Data("# \(target.rawValue) Only\n".utf8).write(to: directory.appendingPathComponent("\(target.rawValue)Only.md"))
                    fixtureRoots[target] = directory
                }
                location = .brain
                activate(fixtureRoots[.brain]!, scoped: false)
            } catch { state = .needsAccess }
            return
        }
        #endif
        if ProcessInfo.processInfo.arguments.contains("-laa-brain-no-vault-fixture") { return }
        if ProcessInfo.processInfo.arguments.contains("-laa-brain-local-fixture") {
            do {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("brain-fixture-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: root.appendingPathComponent("Company"), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets"), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: root.appendingPathComponent("Company/Empty"), withIntermediateDirectories: true)
                try Data("# 見出し\n\nオフラインの検索本文です。 fixture-search #garden\n\n[[Other#Details|次のメモ]]\n\n![[Assets/fixture.png]]\n\n![[Other]]\n".utf8)
                    .write(to: root.appendingPathComponent("Company/Start.md"))
                try Data("# 別のメモ\n\n## Details\n本文\n".utf8).write(to: root.appendingPathComponent("Company/Other.md"))
                if ProcessInfo.processInfo.arguments.contains("-laa-brain-document-fixture") {
                    let lines = (1...45).map { "段落\($0)：長いノートを読み進めても、リンクから戻った位置を保持します。" }
                    let text = "---\r\ncustom: [keep, exact]\r\nunknown: |\r\n  untouched\r\n---\r\n" + lines.joined(separator: "\n\n") + "\n\n[[Other#Details|次のメモ]]\n\n:::custom unsupported\n\n![[Other]]\n"
                    try Data(text.utf8).write(to: root.appendingPathComponent("Company/Start.md"))
                }
                if ProcessInfo.processInfo.arguments.contains("-laa-brain-daily-existing-fixture") {
                    let daily = root.appendingPathComponent(try LAABrainDailyNote.path(root: root))
                    try FileManager.default.createDirectory(at: daily.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data("EXISTING-DAILY-FIXTURE".utf8).write(to: daily)
                }
                if ProcessInfo.processInfo.arguments.contains("-laa-brain-table-fixture") {
                    try Data("# 表\n\n| 項目 | 値 |\n| --- | --- |\n| あ | 1 |\n\n末尾の段落\n".utf8)
                        .write(to: root.appendingPathComponent("Company/Table.md"))
                    // No trailing newline: a note that ends on its table row
                    // must still take text after it without gaining a newline.
                    try Data("| a | b |\n| --- | --- |\n| 1 | 2 |".utf8)
                        .write(to: root.appendingPathComponent("Company/OnlyTable.md"))
                }
                if ProcessInfo.processInfo.arguments.contains("-laa-brain-conflict-copy-fixture") {
                    try Data("CONFLICT-COPY-FIXTURE".utf8).write(to: root.appendingPathComponent("Company/Start.sync-conflict-20261101-ABC.md"))
                }
                if ProcessInfo.processInfo.arguments.contains("-laa-brain-unsafe-ignore-fixture") {
                    try Data("!/anything\n".utf8).write(to: root.appendingPathComponent(".stignore"))
                }
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
        #if targetEnvironment(macCatalyst)
        guard let homeDirectory, Self.allowedMacRoot(selected, home: homeDirectory), let location, Self.legacyLocation(selected, home: homeDirectory) == location else { throw LAABrainVaultError.invalidPath }
        #endif
        guard beginScope(selected) else { throw LAABrainVaultError.access }
        do {
            let values = try selected.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { throw LAABrainVaultError.notDirectory }
            let bookmark = try selected.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            try FileManager.default.createDirectory(at: bookmarkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bookmark.write(to: locationBookmark ?? bookmarkURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            activate(selected, scoped: true)
        } catch {
            endScope(selected)
            throw error
        }
    }

    func disconnect() throws {
        // Keep the bookmark and current state if removing it fails.
        let selectedBookmark = locationBookmark ?? bookmarkURL
        if FileManager.default.fileExists(atPath: selectedBookmark.path) { try FileManager.default.removeItem(at: selectedBookmark) }
        deactivate()
        state = .disconnected
        revision += 1
    }

    func snapshot() throws -> URL {
        guard state == .ready, let root else { throw LAABrainVaultError.access }
        return root
    }

    #if targetEnvironment(macCatalyst)
    func select(_ target: Location) {
        guard location != target || !isReady else { return }
        deactivate()
        location = target
        state = .disconnected
        revision += 1
        #if DEBUG
        if let fixture = fixtureRoots[target] { activate(fixture, scoped: false); return }
        #endif
        restoreBookmark(at: locationBookmark!)
    }

    func prepareDaily() -> Bool {
        if location != .brain { select(.brain) }
        return location == .brain && isReady
    }

    private func restoreBookmark() {
        // Prefer the last explicitly selected location. Never delete the legacy
        // bookmark: it remains a recovery source if migration is interrupted.
        if let raw = preferences.string(forKey: "laa.brain.mac.location"),
           let target = Location(rawValue: raw), hasBookmark(target) {
            location = target
            restoreBookmark(at: locationBookmark!)
            return
        }
        guard FileManager.default.fileExists(atPath: bookmarkURL.path) else { return }
        do {
            let data = try Data(contentsOf: bookmarkURL)
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard let homeDirectory, !stale, Self.allowedMacRoot(url, home: homeDirectory) else { state = .needsAccess; return }
            if let target = Self.legacyLocation(url, home: homeDirectory) {
                let destination = bookmarkURL.deletingLastPathComponent().appendingPathComponent("vault-\(target.rawValue).bookmark")
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
                location = target
                restoreBookmark(at: destination)
            } else {
                // Keep the old bookmark solely as a recovery source.
                state = .needsAccess
            }
        } catch { state = .needsAccess }
    }
    #else
    private func restoreBookmark() { restoreBookmark(at: bookmarkURL) }
    #endif

    private func restoreBookmark(at bookmarkURL: URL) {
        guard FileManager.default.fileExists(atPath: bookmarkURL.path) else { return }
        do {
            let data = try Data(contentsOf: bookmarkURL)
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            #if targetEnvironment(macCatalyst)
            guard let homeDirectory, let location, Self.allowedMacRoot(url, home: homeDirectory), Self.legacyLocation(url, home: homeDirectory) == location else {
                state = .needsAccess; return
            }
            #endif
            guard !stale, beginScope(url) else { state = .needsAccess; return }
            do {
                guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                    endScope(url); state = .needsAccess; return
                }
                activate(url, scoped: true)
            } catch {
                endScope(url); state = .needsAccess
            }
        } catch { state = .needsAccess }
    }

    private func activate(_ url: URL, scoped: Bool) {
        deactivate()
        // Reading remains available if the provider cannot maintain the rule;
        // the save coordinator independently gates the fallback on it.
        _ = LAABrainSaveCoordinator.ensureFallbackIgnored(root: url)
        root = url
        scopeHeld = scoped
        let observer = LAABrainVaultPresenter(url: url) { [weak self] in
            Task { @MainActor in self?.revision += 1 }
        }
        presenter = observer
        NSFileCoordinator.addFilePresenter(observer)
        state = .ready
        #if targetEnvironment(macCatalyst)
        #if DEBUG
        if fixtureRoots.isEmpty, let location { preferences.set(location.rawValue, forKey: "laa.brain.mac.location") }
        #else
        if let location { preferences.set(location.rawValue, forKey: "laa.brain.mac.location") }
        #endif
        #endif
        revision += 1
    }

    private func deactivate() {
        if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
        presenter = nil
        if scopeHeld, let root { endScope(root) }
        root = nil
        scopeHeld = false
    }

    deinit {
        if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
        if scopeHeld, let root { endScope(root) }
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
        case .access: return AppLocalization.string("フォルダにアクセスできません。もう一度選んでください。")
        case .notDirectory: return AppLocalization.string("フォルダを選んでください。")
        case .invalidPath: return AppLocalization.string("選んだフォルダの外、またはシンボリックリンクは開けません。")
        case .unreadable: return AppLocalization.string("フォルダまたはノートを読めません。保存先を確認してください。")
        case .invalidText: return AppLocalization.string("このノートはUTF-8のテキストではありません。")
        case .tooLarge: return AppLocalization.string("ファイルが大きすぎるため表示できません。")
        case .ambiguous: return AppLocalization.string("同名の添付が複数あります。フルパスを指定してください。")
        }
    }
}

/// All inputs are a user-selected directory or a test fixture, never a guessed vault path.
enum LAABrainVaultIO {
    private static let excludedDirectories: Set<String> = [".obsidian", ".git", ".trash", ".stfolder", ".stversions", ".laa-tmp"]

    struct Listing {
        let files: [LAABrainFile]
        /// Relative paths, including empty directories.
        let folders: [String]
    }

    static func files(root: URL) throws -> [LAABrainFile] { try listing(root: root).files }

    static func listing(root: URL) throws -> Listing {
        var result: Result<Listing, Error> = .failure(LAABrainVaultError.unreadable)
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: root, options: [], error: &coordinationError) { coordinatedRoot in
            result = Result { try enumerate(root: coordinatedRoot) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    private static func enumerate(root: URL) throws -> Listing {
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
        var folders: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            // FileManager does not traverse symbolic links. Calling
            // skipDescendants on one can skip the next real directory instead.
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                if url.lastPathComponent.hasPrefix(".") { enumerator.skipDescendants(); continue }
                if url.standardizedFileURL.path.hasPrefix(prefix) {
                    folders.append(String(url.standardizedFileURL.path.dropFirst(prefix.count)))
                }
                continue
            }
            guard values.isRegularFile == true, !url.lastPathComponent.hasPrefix("."), url.pathExtension.lowercased() == "md",
                  url.standardizedFileURL.path.hasPrefix(prefix) else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(prefix.count))
            let reference = LAABrainReference(path: path, includeInbox: true)
            files.append(LAABrainFile(id: reference.id, path: path,
                title: url.deletingPathExtension().lastPathComponent,
                modifiedAt: values.contentModificationDate.map(formatter.string) ?? "", area: "local", unreadable: nil))
        }
        if let enumerationError { throw enumerationError }
        return Listing(files: files, folders: folders)
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
                    if values.isSymbolicLink == true { continue }
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
