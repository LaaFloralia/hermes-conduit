#if LAA_BUILD
import Foundation

struct LAABrainFile: Decodable, Hashable, Identifiable {
    let id: String
    let path: String
    let title: String
    let modifiedAt: String
    let area: String
    let unreadable: String?

    var folder: String { path.split(separator: "/").dropLast().joined(separator: "/") }
}

struct LAABrainPage: Decodable {
    let items: [LAABrainFile]
    let nextCursor: String?
}

struct LAABrainNote: Decodable {
    let id: String
    let path: String
    let text: String
}

struct LAABrainSearch: Decodable {
    let results: [LAABrainHit]
}

struct LAABrainHit: Decodable, Identifiable {
    let path: String
    let section: String
    let text: String
    var id: String { path + "\u{0}" + section + "\u{0}" + text }
}

struct LAABrainDevice: Decodable { let scopes: [String] }
struct LAABrainCreated: Decodable { let id: String; let path: String; let suffixApplied: Bool }

struct LAABrainCreateBody: Codable, Equatable {
    let path: String
    let content: String
    var onConflict = "suffix"

    static func make(name: String, content: String) -> LAABrainCreateBody? {
        var title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.lowercased().hasSuffix(".md") { title.removeLast(3) }
        guard !title.isEmpty, !title.hasPrefix("."), title.count <= 200,
              title.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:").union(.controlCharacters)) == nil,
              content.utf8.count <= 48 * 1024 else { return nil }
        return LAABrainCreateBody(path: "Inbox/" + title + ".md", content: content)
    }
}

struct LAABrainReference: Hashable {
    let id: String
    let path: String
    let inbox: Bool

    init(file: LAABrainFile, includeInbox: Bool) {
        id = file.id; path = file.path; inbox = includeInbox
    }

    init(path: String, includeInbox: Bool) {
        let normalized = path.precomposedStringWithCanonicalMapping
        id = "bf_" + Data(normalized.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        self.path = normalized
        inbox = includeInbox
    }
}

enum LAABrainRoute: Hashable {
    case folder(String)
    case note(LAABrainReference)
}

enum LAABrainPaths {
    static func request(_ path: String, items: [URLQueryItem] = [], includeInbox: Bool = false) -> String? {
        var parts = URLComponents()
        parts.path = path
        parts.queryItems = items + (includeInbox ? [URLQueryItem(name: "area", value: "inbox")] : [])
        // URLSearchParams on the Bridge treats a literal + as a space.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.string
    }

    static func folders(in files: [LAABrainFile], parent: String) -> [String] {
        let prefix = parent.isEmpty ? "" : parent + "/"
        let names = files.compactMap { file -> String? in
            guard file.path.hasPrefix(prefix) else { return nil }
            let remaining = String(file.path.dropFirst(prefix.count))
            guard let slash = remaining.firstIndex(of: "/") else { return nil }
            return String(remaining[..<slash])
        }
        return Array(Set(names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func resolve(_ target: String, currentPath: String, files: [LAABrainFile]) -> LAABrainFile? {
        let reference = target.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines).removingPercentEncoding ?? ""
        guard !reference.isEmpty, !reference.hasPrefix("/"), !reference.contains(":") else { return nil }
        let named = reference.lowercased().hasSuffix(".md") ? reference : reference + ".md"
        func normalized(_ raw: String) -> String? {
            var components: [String] = []
            for part in raw.split(separator: "/", omittingEmptySubsequences: false) {
                if part == "." { continue }
                if part == ".." { guard !components.isEmpty else { return nil }; components.removeLast() }
                else if part.isEmpty { return nil }
                else { components.append(String(part)) }
            }
            return components.joined(separator: "/").precomposedStringWithCanonicalMapping
        }
        let directory = currentPath.split(separator: "/").dropLast().joined(separator: "/")
        let relative = normalized(directory.isEmpty ? named : directory + "/" + named)
        let absolute = normalized(named)
        if let exact = files.first(where: { $0.path.precomposedStringWithCanonicalMapping == relative }) { return exact }
        if let exact = files.first(where: { $0.path.precomposedStringWithCanonicalMapping == absolute }) { return exact }
        guard !named.contains("/") else { return nil }
        let matches = files.filter { $0.path.split(separator: "/").last.map(String.init) == named }
        return matches.count == 1 ? matches[0] : nil
    }
}

struct LAABrainDocument {
    enum Part: Equatable { case markdown(String), raw(String), image(String) }
    let frontmatter: String?
    let body: String

    init(_ source: String) {
        // Delimiters and line endings remain in the raw source. Only a closed
        // frontmatter block is separated; an unfinished one stays in the body.
        let lines = source.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
           let end = lines.dropFirst().firstIndex(where: {
               let line = $0.trimmingCharacters(in: .whitespacesAndNewlines)
               return line == "---" || line == "..."
           }) {
            frontmatter = lines[...end].joined(separator: "\n")
            body = lines.dropFirst(end + 1).joined(separator: "\n")
        } else { frontmatter = nil; body = source }
    }

    func parts(currentPath: String, files: [LAABrainFile]) -> [Part] {
        var result: [Part] = []
        var markdown: [String] = []
        var fence: (character: Character, length: Int)?
        func flush() {
            if !markdown.isEmpty { result.append(.markdown(markdown.joined(separator: "\n"))); markdown.removeAll() }
        }
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let active = fence {
                markdown.append(line)
                if trimmed.count >= active.length && trimmed.allSatisfy({ $0 == active.character }) { fence = nil }
                continue
            }
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let count = trimmed.prefix { $0 == marker }.count
                if count >= 3 { fence = (marker, count); markdown.append(line); continue }
            }
            if line.contains("![[") || line.range(of: #"!\[[^\]]*\]\("#, options: .regularExpression) != nil {
                flush(); result.append(.image(line)); continue
            }
            // Syntax specific to other editors is shown verbatim rather than
            // being consumed by the chat Markdown renderer.
            if trimmed.hasPrefix(":::") || trimmed.hasPrefix("%%") || trimmed.hasPrefix("<") ||
                trimmed.range(of: #"^\[[^\]]+\]:"#, options: .regularExpression) != nil {
                flush(); result.append(.raw(line)); continue
            }
            markdown.append(Self.linkWikis(line, currentPath: currentPath, files: files))
        }
        flush()
        return result
    }

    private static func linkWikis(_ line: String, currentPath: String, files: [LAABrainFile]) -> String {
        // Do not rewrite inside inline code. Unknown or ambiguous links stay
        // exactly as written; links are limited to the already allowed list.
        let pieces = line.components(separatedBy: "`")
        return pieces.enumerated().map { index, piece in
            guard index % 2 == 0 else { return piece }
            let pattern = #"(?<!!)\[\[([^\]]+)\]\]"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return piece }
            let matches = regex.matches(in: piece, range: NSRange(piece.startIndex..., in: piece))
            var output = piece
            for match in matches.reversed() {
                guard let whole = Range(match.range(at: 0), in: output), let inner = Range(match.range(at: 1), in: output) else { continue }
                let target = String(output[inner])
                guard let file = LAABrainPaths.resolve(target, currentPath: currentPath, files: files) else { continue }
                let label = target.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) ?? target
                let safeLabel = label.replacingOccurrences(of: "]", with: "\\]")
                output.replaceSubrange(whole, with: "[\(safeLabel)](laabrain://note/\(file.id))")
            }
            return output
        }.joined(separator: "`")
    }
}
#endif
