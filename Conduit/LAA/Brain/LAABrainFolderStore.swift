#if LAA_BUILD
import Darwin
import Foundation

/// Creates only new items in the selected vault; never follows a symlink or
/// replaces an existing name. The caller keeps the security scope open.
enum LAABrainFolderStore {
    enum Kind { case note, folder }
    enum Failure: Error { case invalidName, invalidFolder, invalidText, tooLarge, exists, uncertain, coordination, unavailable }

    static func itemName(_ input: String, kind: Kind) throws -> String {
        var name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains("\\"),
              !name.contains(":"), name.rangeOfCharacter(from: .controlCharacters) == nil,
              !name.contains(".sync-conflict-") else { throw Failure.invalidName }
        if case .note = kind, !name.lowercased().hasSuffix(".md") { name += ".md" }
        guard name.utf8.count <= 240 else { throw Failure.invalidName }
        return name
    }

    /// A failure after creation can be ambiguous. Do not delete the item:
    /// another writer may already have modified it.
    static func create(root: URL, parent: String, name input: String, kind: Kind, body: Data = Data(),
                       journal: LAABrainSaveJournal = LAABrainSaveJournal(), forceFallback: Bool = false,
                       fixtureBeforeRename: (() throws -> Void)? = nil) throws -> String {
        let name = try itemName(input, kind: kind)
        let parts = parent.isEmpty ? [] : parent.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("\\") && !$0.contains(":") &&
            $0.rangeOfCharacter(from: .controlCharacters) == nil }) else { throw Failure.invalidFolder }
        guard body.count <= 32 * 1024 * 1024 else { throw Failure.tooLarge }
        guard String(data: body, encoding: .utf8) != nil else { throw Failure.invalidText }
        let relative = (parts + [name]).joined(separator: "/")
        let directory = parts.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
        // Check before coordinating the parent, to avoid nested coordination.
        let fallbackAllowed: Bool
        switch kind {
        case .note: fallbackAllowed = LAABrainSaveCoordinator.ensureFallbackIgnored(root: root)
        case .folder: fallbackAllowed = false
        }
        var result: Result<String, Error> = .failure(Failure.coordination)
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: directory, options: .forMerging, error: &coordinationError) { coordinated in
            result = Result {
                guard coordinated.standardizedFileURL == directory.standardizedFileURL else { throw Failure.invalidFolder }
                var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard fd >= 0 else { throw Failure.invalidFolder }
                defer { close(fd) }
                for part in parts {
                    let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                    guard next >= 0 else { throw Failure.invalidFolder }
                    close(fd); fd = next
                }
                switch kind {
                case .folder:
                    try verifyParent(root: root, parts: parts, expected: fd)
                    guard mkdirat(fd, name, 0o755) == 0 else {
                        if errno == EEXIST { throw Failure.exists }
                        throw Failure.invalidFolder
                    }
                case .note:
                    var existing = stat()
                    if fstatat(fd, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 { throw Failure.exists }
                    guard errno == ENOENT else { throw Failure.invalidFolder }
                    // Record the complete draft before making any vault file visible.
                    do { _ = try journal.record(vault: LAABrainSaveJournal.vaultID(root), path: relative, kind: .draft, bytes: body) }
                    catch { throw Failure.unavailable }
                    let privateDirectory = journal.directory.appendingPathComponent("staging", isDirectory: true)
                    let privateFD = open(privateDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                    guard privateFD >= 0 else { throw Failure.unavailable }
                    defer { close(privateFD) }
                    let privateName = UUID().uuidString + ".recovery"
                    try writeStage(directory: privateFD, name: privateName, body: body)
                    defer { _ = unlinkat(privateFD, privateName, 0) }
                    #if DEBUG
                    try fixtureBeforeRename?()
                    #endif
                    try verifyParent(root: root, parts: parts, expected: fd)
                    let code: Int32
                    if forceFallback { code = EXDEV }
                    else { code = renameatx_np(privateFD, privateName, fd, name, UInt32(RENAME_EXCL)) == 0 ? 0 : errno }
                    if code == EEXIST { throw Failure.exists }
                    if code == 0 {
                        guard fsync(privateFD) == 0 else { throw Failure.uncertain }
                    } else {
                        guard [EXDEV, ENOTSUP, EINVAL, EPERM, EACCES, ENOSYS].contains(code),
                              fallbackAllowed, LAABrainSaveCoordinator.isFallbackIgnored(root: root) else { throw Failure.unavailable }
                        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                        guard rootFD >= 0 else { throw Failure.invalidFolder }
                        defer { close(rootFD) }
                        if mkdirat(rootFD, ".laa-tmp", 0o700) != 0 && errno != EEXIST { throw Failure.unavailable }
                        let tempFD = openat(rootFD, ".laa-tmp", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                        guard tempFD >= 0 else { throw Failure.unavailable }
                        defer { close(tempFD) }
                        let tempName = UUID().uuidString + ".tmp"
                        try writeStage(directory: tempFD, name: tempName, body: body)
                        defer { _ = unlinkat(tempFD, tempName, 0) }
                        guard LAABrainSaveCoordinator.isFallbackIgnored(root: root) else { throw Failure.unavailable }
                        try verifyParent(root: root, parts: parts, expected: fd)
                        if renameatx_np(tempFD, tempName, fd, name, UInt32(RENAME_EXCL)) != 0 {
                            if errno == EEXIST { throw Failure.exists }
                            throw Failure.unavailable
                        }
                        guard fsync(tempFD) == 0 else { throw Failure.uncertain }
                    }
                }
                guard fsync(fd) == 0 else { throw Failure.uncertain }
                return relative
            }
        }
        if coordinationError != nil {
            if case .success = result { throw Failure.uncertain }
            throw Failure.coordination
        }
        return try result.get()
    }

    private static func verifyParent(root: URL, parts: [String], expected: Int32) throws {
        var original = stat()
        guard fstat(expected, &original) == 0 else { throw Failure.invalidFolder }
        var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.invalidFolder }
        defer { close(fd) }
        for part in parts {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw Failure.invalidFolder }
            close(fd); fd = next
        }
        var current = stat()
        guard fstat(fd, &current) == 0, current.st_dev == original.st_dev, current.st_ino == original.st_ino else {
            throw Failure.invalidFolder
        }
    }

    private static func writeStage(directory: Int32, name: String, body: Data) throws {
        let fd = openat(directory, name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: body)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            _ = unlinkat(directory, name, 0)
            throw Failure.unavailable
        }
    }
}
#endif
