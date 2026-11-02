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
    var conflictOriginalPath: String? {
        guard let marker = path.range(of: ".sync-conflict-", options: .backwards),
              let dot = path.lastIndex(of: "."), dot > marker.upperBound else { return nil }
        return String(path[..<marker.lowerBound]) + String(path[dot...])
    }
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
    let anchor: String?

    init(file: LAABrainFile, includeInbox: Bool, anchor: String? = nil) {
        id = file.id; path = file.path; inbox = includeInbox; self.anchor = anchor
    }

    init(path: String, includeInbox: Bool, anchor: String? = nil) {
        let normalized = path.precomposedStringWithCanonicalMapping
        id = "bf_" + Data(normalized.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        self.path = normalized
        inbox = includeInbox
        self.anchor = anchor
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
        parts.queryItems = items + [URLQueryItem(name: "audience", value: "owner")]
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
        let targetPath = target.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let reference = targetPath
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines).removingPercentEncoding ?? ""
        if reference.isEmpty, targetPath.contains("#") { return files.first { $0.path == currentPath } }
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
    enum Part: Equatable {
        case markdown(String), raw(String), image(String), highlight(String)
        case heading(source: String, title: String)
        case footnote(id: String, text: String)
    }
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

    var properties: [(name: String, value: String)] {
        guard let frontmatter else { return [] }
        var result: [(String, String)] = []
        for line in frontmatter.components(separatedBy: "\n").dropFirst().dropLast() {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !value.isEmpty { result.append((name, value)) }
        }
        return result
    }

    static func anchorID(path: String, title: String) -> String {
        path.precomposedStringWithCanonicalMapping + "\u{0}" + normalizedHeading(title)
    }

    private static func normalizedHeading(_ title: String) -> String {
        ["==", "**", "__", "~~", "`"].reduce(title) { $0.replacingOccurrences(of: $1, with: "") }
            .trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
    }

    static func footnoteID(path: String, id: String) -> String {
        path.precomposedStringWithCanonicalMapping + "\u{0}footnote:" + id.lowercased()
    }

    func section(_ title: String) -> String? {
        let lines = body.components(separatedBy: "\n")
        var start: Int?
        var level = 0
        var fence: (Character, Int)?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let active = fence {
                if trimmed.count >= active.1 && trimmed.allSatisfy({ $0 == active.0 }) { fence = nil }
                continue
            }
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let length = trimmed.prefix { $0 == marker }.count
                if length >= 3 { fence = (marker, length); continue }
            }
            guard let heading = Self.capture(#"^#{1,6}\s+(.+?)\s*#*\s*$"#, in: trimmed) else { continue }
            let count = trimmed.prefix { $0 == "#" }.count
            if let start, count <= level { return lines[start..<index].joined(separator: "\n") }
            if start == nil && Self.normalizedHeading(heading) == Self.normalizedHeading(title) {
                start = index; level = count
            }
        }
        return start.map { lines[$0...].joined(separator: "\n") }
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
            if let heading = Self.capture(#"^#{1,6}\s+(.+?)\s*#*\s*$"#, in: trimmed) {
                flush(); result.append(.heading(source: Self.linkWikis(line, currentPath: currentPath, files: files), title: heading)); continue
            }
            if let pair = Self.captures(#"^\[\^([^\]]+)\]:\s*(.*)$"#, in: trimmed), pair.count == 2 {
                flush(); result.append(.footnote(id: pair[0], text: Self.linkWikis(pair[1], currentPath: currentPath, files: files))); continue
            }
            if let regex = try? NSRegularExpression(pattern: #"!\[\[[^\]]+\]\]|!\[[^\]]*\]\([^)]+\)"#) {
                let pieces = Self.inlineSegments(line)
                let hasEmbed = pieces.contains { piece in
                    !piece.code && regex.firstMatch(in: piece.text, range: NSRange(piece.text.startIndex..., in: piece.text)) != nil
                }
                if hasEmbed {
                    var pending = ""
                    for piece in pieces {
                        if piece.code { pending += piece.text; continue }
                        var position = piece.text.startIndex
                        let embeds = regex.matches(in: piece.text, range: NSRange(piece.text.startIndex..., in: piece.text))
                        for embed in embeds {
                            guard let range = Range(embed.range, in: piece.text) else { continue }
                            pending += String(piece.text[position..<range.lowerBound])
                            if !pending.isEmpty { markdown.append(Self.linkWikis(pending, currentPath: currentPath, files: files)) }
                            flush(); result.append(.image(String(piece.text[range]))); pending = ""; position = range.upperBound
                        }
                        pending += String(piece.text[position...])
                    }
                    if !pending.isEmpty { markdown.append(Self.linkWikis(pending, currentPath: currentPath, files: files)) }
                    continue
                }
            }
            // Syntax specific to other editors is shown verbatim rather than
            // being consumed by the chat Markdown renderer.
            if trimmed.hasPrefix(":::") || trimmed.hasPrefix("%%") || trimmed.hasPrefix("<") ||
                trimmed.range(of: #"^\[[^\]]+\]:"#, options: .regularExpression) != nil {
                flush(); result.append(.raw(line)); continue
            }
            let linked = Self.linkWikis(line, currentPath: currentPath, files: files)
            if linked.range(of: #"==[^=\n]+=="#, options: .regularExpression) != nil, !linked.contains("`"),
               !trimmed.contains("|") {
                flush(); result.append(.highlight(linked)); continue
            }
            markdown.append(linked)
        }
        flush()
        return result
    }

    private static func linkWikis(_ line: String, currentPath: String, files: [LAABrainFile]) -> String {
        // Do not rewrite inside inline code. Unknown or ambiguous links stay
        // exactly as written; links are limited to the already allowed list.
        return inlineSegments(line).map { segment in
            let piece = segment.text
            guard !segment.code else { return piece }
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
                let targetPath = target.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)[0]
                let pieces = targetPath.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                var url = URLComponents(); url.scheme = "laabrain"; url.host = "note"; url.path = "/" + file.id
                if pieces.count > 1 { url.fragment = String(pieces[1]) }
                guard let destination = url.string else { continue }
                output.replaceSubrange(whole, with: "[\(safeLabel)](\(destination))")
            }
            let footnotes = #"(?<!!)\[\^([^\]]+)\]"#
            if let regex = try? NSRegularExpression(pattern: footnotes) {
                let matches = regex.matches(in: output, range: NSRange(output.startIndex..., in: output))
                for match in matches.reversed() {
                    guard let whole = Range(match.range(at: 0), in: output), let inner = Range(match.range(at: 1), in: output) else { continue }
                    let id = String(output[inner])
                    var url = URLComponents(); url.scheme = "laabrain"; url.host = "footnote"
                    url.path = "/" + LAABrainReference(path: currentPath, includeInbox: true).id
                    url.queryItems = [URLQueryItem(name: "id", value: id)]
                    if let destination = url.string { output.replaceSubrange(whole, with: "[\(id)](\(destination))") }
                }
            }
            return output
        }.joined()
    }

    private static func inlineSegments(_ source: String) -> [(code: Bool, text: String)] {
        var parts: [(Bool, String)] = []
        var start = source.startIndex
        var position = start
        var activeLength: Int?
        while position < source.endIndex {
            if source[position] == "\\" {
                position = source.index(after: position)
                if position < source.endIndex { position = source.index(after: position) }
                continue
            }
            guard source[position] == "`" else { position = source.index(after: position); continue }
            var end = position
            while end < source.endIndex, source[end] == "`" { end = source.index(after: end) }
            let length = source.distance(from: position, to: end)
            if activeLength == nil {
                if start < position { parts.append((false, String(source[start..<position]))) }
                start = position; activeLength = length
            } else if activeLength == length {
                parts.append((true, String(source[start..<end])))
                start = end; activeLength = nil
            }
            position = end
        }
        if start < source.endIndex { parts.append((activeLength != nil, String(source[start...]))) }
        return parts
    }

    private static func capture(_ pattern: String, in source: String) -> String? {
        captures(pattern, in: source)?.first
    }

    private static func captures(_ pattern: String, in source: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: source).map { String(source[$0]) }
        }
    }
}

struct LAABrainEmbedSpec: Equatable {
    let target: String
    let source: String
    let hasSurroundingText: Bool

    static func parse(_ line: String) -> LAABrainEmbedSpec? {
        for pattern in [#"!\[\[([^\]]+)\]\]"#, #"!\[[^\]]*\]\(([^)]+)\)"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let whole = Range(match.range(at: 0), in: line), let value = Range(match.range(at: 1), in: line) else { continue }
            let target = line[value].split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let remainder = String(line[..<whole.lowerBound]) + String(line[whole.upperBound...])
            return LAABrainEmbedSpec(target: target, source: line,
                                     hasSurroundingText: !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        return nil
    }

    var anchor: String? {
        let pieces = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        return pieces.count > 1 ? String(pieces[1]) : nil
    }
}
#endif
