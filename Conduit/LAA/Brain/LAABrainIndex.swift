#if LAA_BUILD
import CryptoKit
import Foundation

/// Rebuilt from the selected folder. Body text stays in process memory; neither
/// the index nor search queries are sent to the Mac or another service.
struct LAABrainIndex {
    struct Entry {
        let file: LAABrainFile
        let text: String
        let tags: Set<String>
        let wikiTargets: [String]
    }
    let entries: [Entry]
    let unreadableCount: Int

    init(files: [LAABrainFile], read: (String) throws -> String) {
        var entries: [Entry] = []
        var unreadable = 0
        for file in files {
            if Task.isCancelled { break }
            do {
                let text = try read(file.path)
                let visible = Self.withoutCode(text)
                let targets = Self.matches(#"!?\[\[([^\]]+)\]\]"#, in: visible)
                    + Self.matches(#"(?<!!)\[[^\]]+\]\(([^)]+)\)"#, in: visible)
                entries.append(Entry(file: file, text: text, tags: Self.tags(in: visible), wikiTargets: targets))
            } catch { unreadable += 1 }
        }
        self.entries = entries
        unreadableCount = unreadable
    }

    var tags: [String] {
        Array(Set(entries.flatMap(\.tags))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func files(tag: String) -> [LAABrainFile] {
        entries.filter { $0.tags.contains(tag) }.map(\.file)
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func search(_ query: String) -> [LAABrainHit] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        return entries.compactMap { entry in
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
            if let range = entry.text.range(of: term, options: options, locale: Locale(identifier: "ja_JP")) {
                let start = entry.text.index(range.lowerBound, offsetBy: -40, limitedBy: entry.text.startIndex) ?? entry.text.startIndex
                let end = entry.text.index(range.upperBound, offsetBy: 80, limitedBy: entry.text.endIndex) ?? entry.text.endIndex
                return LAABrainHit(path: entry.file.path, section: "", text: String(entry.text[start..<end]))
            }
            return entry.file.path.range(of: term, options: options, locale: Locale(identifier: "ja_JP")) != nil
                ? LAABrainHit(path: entry.file.path, section: "", text: "") : nil
        }
    }

    func outgoing(from path: String, files: [LAABrainFile]) -> [LAABrainFile] {
        guard let entry = entries.first(where: { $0.file.path == path }) else { return [] }
        let resolved = entry.wikiTargets.compactMap { LAABrainPaths.resolve($0, currentPath: path, files: files) }
        return uniqueSorted(resolved.filter { $0.path != path })
    }

    func backlinks(to path: String, files: [LAABrainFile]) -> [LAABrainFile] {
        uniqueSorted(entries.compactMap { entry in
            guard entry.file.path != path,
                  entry.wikiTargets.contains(where: { LAABrainPaths.resolve($0, currentPath: entry.file.path, files: files)?.path == path })
            else { return nil }
            return entry.file
        })
    }

    private func uniqueSorted(_ files: [LAABrainFile]) -> [LAABrainFile] {
        var seen = Set<String>()
        return files.filter { seen.insert($0.path).inserted }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func withoutCode(_ source: String) -> String {
        var fence: (Character, Int)?
        return source.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let active = fence {
                if trimmed.count >= active.1 && trimmed.allSatisfy({ $0 == active.0 }) { fence = nil }
                return ""
            }
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let length = trimmed.prefix { $0 == marker }.count
                if length >= 3 { fence = (marker, length); return "" }
            }
            return line.components(separatedBy: "`").enumerated().map { $0.offset % 2 == 0 ? $0.element : "" }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    private static func tags(in source: String) -> Set<String> {
        var tags = Set(matches(#"(?<![\p{L}\p{N}_/])#([\p{L}\p{N}_][\p{L}\p{N}_/-]*)"#, in: source))
        let document = LAABrainDocument(source)
        guard let frontmatter = document.frontmatter else { return tags }
        var inList = false
        for line in frontmatter.components(separatedBy: "\n").dropFirst().dropLast() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("tags:") {
                let value = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                inList = value.isEmpty
                if !value.isEmpty {
                    let cleaned = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    for item in cleaned.split(separator: ",") { addTag(String(item), to: &tags) }
                }
            } else if inList && trimmed.hasPrefix("- ") {
                addTag(String(trimmed.dropFirst(2)), to: &tags)
            } else if !trimmed.isEmpty { inList = false }
        }
        return tags
    }

    private static func addTag(_ value: String, to tags: inout Set<String>) {
        let tag = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'#")))
        guard !tag.isEmpty, tag.range(of: #"^[\p{L}\p{N}_][\p{L}\p{N}_/-]*$"#, options: .regularExpression) != nil else { return }
        tags.insert(tag.precomposedStringWithCanonicalMapping)
    }

    private static func matches(_ pattern: String, in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            guard let range = Range($0.range(at: 1), in: source) else { return nil }
            return String(source[range]).precomposedStringWithCanonicalMapping
        }
    }
}

/// Pins contain paths only and are kept in the app's protected container.
enum LAABrainPins {
    private static func url(root: URL?, directory override: URL?) throws -> URL {
        let identifier = root?.absoluteString ?? "bridge"
        let digest = SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = override ?? support.appendingPathComponent("Brain/Pins", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(digest + ".json")
    }

    static func load(root: URL?, directory: URL? = nil) throws -> Set<String> {
        let file = try url(root: root, directory: directory)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: file)))
    }

    static func save(_ pins: Set<String>, root: URL?, directory: URL? = nil) throws {
        let data = try JSONEncoder().encode(pins.sorted())
        try data.write(to: url(root: root, directory: directory), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
#endif
