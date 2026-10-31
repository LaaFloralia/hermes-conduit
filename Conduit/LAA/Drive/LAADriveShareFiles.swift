#if LAA_BUILD
import Foundation
import UniformTypeIdentifiers

struct LAADriveShareFile {
    let id: UUID
    let url: URL
}

enum LAADriveShareError: Error { case invalidSource, insufficientSpace }

/// Copies explicitly selected, already-authorized content for a system share
/// sheet. Keep one instance per root and retain the lease until the activity
/// completes or is dismissed.
actor LAADriveShareFiles {
    typealias CapacityReader = @Sendable (URL) -> Int64?
    private let root: URL
    private let capacity: CapacityReader
    private let fileManager = FileManager.default
    private var active: [UUID: URL] = [:]

    init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("LAADriveShares", isDirectory: true),
         capacity: @escaping CapacityReader = { url in
            try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
         }) {
        self.root = root
        self.capacity = capacity
    }

    func prepare(file source: URL, name: String, mimeType: String) throws -> LAADriveShareFile {
        guard source.isFileURL else { throw LAADriveShareError.invalidSource }
        let attributes = try fileManager.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value >= 0 else {
            throw LAADriveShareError.invalidSource
        }
        return try prepare(name: name, mimeType: mimeType, size: size.int64Value) { destination in
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            guard fileManager.createFile(atPath: destination.path, contents: nil, attributes: protectionAttributes) else {
                throw LAADriveShareError.invalidSource
            }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var copied: Int64 = 0
            while true {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
                let (next, overflow) = copied.addingReportingOverflow(Int64(chunk.count))
                guard !overflow, next <= size.int64Value else { throw LAADriveShareError.invalidSource }
                try output.write(contentsOf: chunk)
                copied = next
            }
            guard copied == size.int64Value else { throw LAADriveShareError.invalidSource }
            try output.synchronize()
        }
    }

    func prepare(data: Data, name: String, mimeType: String) throws -> LAADriveShareFile {
        try prepare(name: name, mimeType: mimeType, size: Int64(data.count)) { destination in
            try data.write(to: destination, options: .atomic)
        }
    }

    private func prepare(name: String, mimeType: String, size: Int64,
                         write: (URL) throws -> Void) throws -> LAADriveShareFile {
        try Task.checkCancellation()
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: protectionAttributes)
        let (required, overflow) = size.addingReportingOverflow(1_048_576)
        guard !overflow, capacity(root).map({ $0 >= required }) ?? true else { throw LAADriveShareError.insufficientSpace }
        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: protectionAttributes)
        let destination = directory.appendingPathComponent(filename(name, mimeType: mimeType), isDirectory: false)
        do {
            try write(destination)
            try Task.checkCancellation()
            if let protectionAttributes { try fileManager.setAttributes(protectionAttributes, ofItemAtPath: destination.path) }
            active[id] = destination
            return .init(id: id, url: destination)
        } catch {
            try? fileManager.removeItem(at: destination)
            try? removeEmptyDirectory(directory)
            throw error
        }
    }

    func release(_ id: UUID) throws {
        guard let file = active[id] else { return }
        if fileManager.fileExists(atPath: file.path) {
            let attributes = try fileManager.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw LAADriveShareError.invalidSource }
            try fileManager.removeItem(at: file)
        }
        try removeEmptyDirectory(file.deletingLastPathComponent())
        active.removeValue(forKey: id)
    }

    /// Recover abandoned copies from an earlier app process. Never touch an
    /// active lease or a directory with an unexpected name or contents.
    func discardAbandoned(now: Date = Date(), minimumAge: TimeInterval = 24 * 60 * 60) throws {
        guard fileManager.fileExists(atPath: root.path) else { return }
        let directories = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for directory in directories {
            guard let id = UUID(uuidString: directory.lastPathComponent), id.uuidString == directory.lastPathComponent,
                  active[id] == nil else { continue }
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, now.timeIntervalSince(modified) >= max(0, minimumAge) else { continue }
            let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard contents.count == 1 else { continue }
            let child = try contents[0].resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard child.isRegularFile == true, child.isSymbolicLink != true else { continue }
            try fileManager.removeItem(at: contents[0])
            try removeEmptyDirectory(directory)
        }
    }

    private func removeEmptyDirectory(_ directory: URL) throws {
        guard try fileManager.contentsOfDirectory(atPath: directory.path).isEmpty else { return }
        try fileManager.removeItem(at: directory)
    }

    private func filename(_ input: String, mimeType: String) -> String {
        let lastComponent = (input as NSString).lastPathComponent
        let sanitized = String(lastComponent.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != "\\" && $0 != ":"
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        var base = ""
        for character in sanitized where (base + String(character)).utf8.count <= 180 { base.append(character) }
        if base.isEmpty || base == "." || base == ".." { base = "File" }
        if let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension?.lowercased(),
           (1...16).contains(ext.utf8.count), ext.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) }),
           !base.lowercased().hasSuffix("." + ext) { base += "." + ext }
        return base
    }

    private var protectionAttributes: [FileAttributeKey: Any]? {
        #if os(iOS)
        return [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        return nil
        #endif
    }
}
#endif
