#if LAA_BUILD
import SwiftUI
import UIKit

/// A file a reply names, made a native link (ADVICE-V2 §3.5 "File links"):
/// `path/to/file.swift:42`, `/Users/…/RESULT.md`, `[label](file:///…)`, and
/// Google Drive file addresses. The transcript draws it as a small glyph and
/// `basename:line` in mono accent with a thin underline; a tap opens it in
/// the app through a route that already exists (Work's Bridge file read, the
/// Folder tab, the Drive viewer). Anything the app cannot open stays text.
struct LAAFileReference: Equatable {
    enum Location: Equatable {
        /// A path on the machine the reply ran on, absolute or relative.
        case path(String)
        /// A Google Drive file, by its id.
        case drive(String)
    }

    enum Kind: Equatable { case markdown, code, image, video, pdf, model3D, html, other, drive }

    let location: Location
    var line: Int? = nil

    var basename: String {
        switch location {
        case .path(let path): return (path as NSString).lastPathComponent
        case .drive: return "Google Drive"
        }
    }

    /// `ChatView.swift:42`; the name alone without a line.
    var label: String { line.map { "\(basename):\($0)" } ?? basename }

    var kind: Kind {
        guard case .path(let path) = location else { return .drive }
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "md", "markdown": return .markdown
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg": return .image
        case "mp4", "mov", "m4v", "mp3", "m4a", "wav": return .video
        case "pdf": return .pdf
        case "usdz", "glb", "gltf", "obj", "reality": return .model3D
        case "html", "htm": return .html
        case "txt", "rtf", "csv", "tsv", "log", "docx", "xlsx", "pptx", "key", "pages", "numbers", "zip", "tar", "gz":
            return .other
        default: return LAAFileLinks.codeTypes.contains(ext) ? .code : .other
        }
    }

    /// The SF Symbol stand-in for the kit's file glyphs.
    var symbol: String {
        switch kind {
        case .markdown, .other, .pdf, .html: return "doc"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .image: return "photo"
        case .video: return "video"
        case .model3D: return "cube"
        case .drive: return "externaldrive"
        }
    }
}

enum LAAFileLinks {
    /// The scheme of the links this layer writes for a path the caller
    /// resolves later (Work resolves against the session's folder).
    static let scheme = "laa-file"

    static let codeTypes: Set<String> = [
        "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "cs", "java", "kt", "kts", "go", "rs", "rb", "py", "js", "mjs",
        "cjs", "ts", "tsx", "jsx", "vue", "svelte", "dart", "php", "lua", "r", "sh", "zsh", "bash", "sql", "json", "jsonl",
        "yaml", "yml", "toml", "ini", "xml", "css", "scss", "plist", "entitlements", "xcconfig", "gradle", "env", "conf", "cfg",
    ]

    // MARK: Reading a link

    /// The file a link points at, or nil: `file://` (with `#L42`), an
    /// absolute path, this layer's `laa-file:` link, and Drive's file pages.
    static func reference(for url: URL) -> LAAFileReference? {
        if url.scheme == scheme {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let path = components.queryItems?.first(where: { $0.name == "path" })?.value, !path.isEmpty else { return nil }
            return LAAFileReference(location: .path(path), line: line(fromFragment: components.fragment))
        }
        if let id = driveID(url) { return LAAFileReference(location: .drive(id)) }
        // Chat's own path links open the file in the Folder tab (#1389).
        if let link = ConduitAppLink(url: url), case .file(let path) = link, hasFileName(path) {
            return LAAFileReference(location: .path(path))
        }
        if let path = LAAWorkFiles.localPath(url), hasFileName(path) {
            return LAAFileReference(location: .path(path), line: line(fromFragment: url.fragment))
        }
        return nil
    }

    /// The link this layer writes for `reference`.
    static func url(for reference: LAAFileReference) -> URL? {
        switch reference.location {
        case .drive(let id):
            return URL(string: "https://drive.google.com/file/d/\(id)/view")
        case .path(let path):
            var components = URLComponents()
            components.scheme = scheme
            components.host = "open"
            components.queryItems = [URLQueryItem(name: "path", value: path)]
            components.fragment = reference.line.map { "L\($0)" }
            return components.url
        }
    }

    /// Work: the link for a file a reply names. A relative path is read from
    /// the session's folder; without one, or from `~`, it stays text.
    static func workLink(_ reference: LAAFileReference, cwd: String?) -> URL? {
        guard case .path(let path) = reference.location else { return url(for: reference) }
        if path.hasPrefix("/") { return url(for: reference) }
        guard !path.hasPrefix("~"), let cwd, cwd.hasPrefix("/") else { return nil }
        let joined = (cwd as NSString).appendingPathComponent(path)
        let standardized = (joined as NSString).standardizingPath
        guard standardized.hasPrefix("/") else { return nil }
        return url(for: LAAFileReference(location: .path(standardized), line: reference.line))
    }

    /// A Google Drive file's id from its page: `drive.google.com/file/d/ID`,
    /// `docs.google.com/{document,spreadsheets,presentation}/d/ID`, `open?id=ID`.
    static func driveID(_ url: URL) -> String? {
        guard let host = url.host?.lowercased(), ["drive.google.com", "docs.google.com"].contains(host) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        if let index = parts.firstIndex(of: "d"), index + 1 < parts.count, validDriveID(parts[index + 1]) {
            return parts[index + 1]
        }
        if parts.last == "open",
           let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
           validDriveID(id) {
            return id
        }
        return nil
    }

    private static func validDriveID(_ id: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return (10...200).contains(id.count) && id.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func line(fromFragment fragment: String?) -> Int? {
        guard let fragment, fragment.hasPrefix("L"), let value = Int(fragment.dropFirst().prefix { $0.isNumber }), value > 0 else { return nil }
        return value
    }

    private static func hasFileName(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        return !ext.isEmpty && name.count > ext.count + 1
    }

    // MARK: Finding files in the text

    /// One file the text names, where it is, and what it points at.
    struct Match: Equatable {
        let range: NSRange
        let reference: LAAFileReference
    }

    /// A path with a folder and a known type, optionally `:line[:column]`.
    /// ASCII only, so a path ends where Japanese begins, and a closing
    /// bracket or sentence mark is never part of it.
    private static let pathPattern = try! NSRegularExpression(pattern:
        #"(?<![A-Za-z0-9_@+.~/:%-])((?:file://)?(?:~/|\.{1,2}/|/)?[A-Za-z0-9_@+.-]+(?:/[A-Za-z0-9_@+.-]+)+\.[A-Za-z0-9]{1,10})(?::(\d{1,6})(?::\d{1,4})?)?(?![A-Za-z0-9_/])"#)
    private static let drivePattern = try! NSRegularExpression(pattern:
        #"https://(?:drive|docs)\.google\.com/[A-Za-z0-9_\-./?=&%]+"#)

    /// The files plain text names (not code, not links), in order.
    static func matches(in text: String) -> [Match] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var found: [Match] = []
        for match in drivePattern.matches(in: text, range: whole) {
            var range = match.range
            var token = ns.substring(with: range)
            while let last = token.last, ".,;:!?)".contains(last) { token.removeLast(); range.length -= 1 }
            if let url = URL(string: token), let id = driveID(url) {
                found.append(Match(range: range, reference: LAAFileReference(location: .drive(id))))
            }
        }
        for match in pathPattern.matches(in: text, range: whole) {
            let pathRange = match.range(at: 1)
            guard !found.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) else { continue }
            var path = ns.substring(with: pathRange)
            if path.lowercased().hasPrefix("file://") { path = String(path.dropFirst("file://".count)) }
            // `1.2/3.4` and `a/b.c` read as numbers and words; a path needs a
            // known type.
            let ext = (path as NSString).pathExtension.lowercased()
            guard WorkspacePathLinks.fileTypes.contains(ext) || codeTypes.contains(ext),
                  path.rangeOfCharacter(from: .letters) != nil else { continue }
            let lineRange = match.range(at: 2)
            let line = lineRange.location == NSNotFound ? nil : Int(ns.substring(with: lineRange))
            found.append(Match(range: match.range, reference: LAAFileReference(location: .path(path), line: line)))
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    /// The Markdown with every file plain text names made a link labelled
    /// `basename:line` in a code span (mono). Fenced code, code spans,
    /// existing links and the chat's `MEDIA:`/`::preview` lines are kept;
    /// a file link already written keeps its target and takes the label.
    /// `resolve` turns a path into the link to write (nil: stays text).
    static func linkified(_ text: String, resolve: (LAAFileReference) -> URL?) -> String {
        guard text.contains("/") else { return text }
        var fence: (character: Character, length: Int)?
        return text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let run = trimmed.prefix { $0 == marker }.count
                if run >= 3 {
                    if let open = fence {
                        if open.character == marker, run >= open.length, trimmed.count == run { fence = nil }
                    } else {
                        fence = (marker, run)
                    }
                    return line
                }
            }
            if fence != nil || !line.contains("/") || line.contains("MEDIA:") || line.contains("::preview{") { return line }
            return linkifiedLine(line, resolve: resolve)
        }.joined(separator: "\n")
    }

    /// Links, autolinks and code spans are skipped as written.
    private static let protected = try! NSRegularExpression(pattern:
        #"(!?\[[^\]\n]*\]\(([^)\n]*)\))|(<[^>\n]+>)|(`+)[^`\n]*?\4"#)

    private static func linkifiedLine(_ line: String, resolve: (LAAFileReference) -> URL?) -> String {
        let ns = line as NSString
        var result = ""
        var cursor = 0
        func plain(_ range: NSRange) {
            let text = ns.substring(with: range)
            let sub = text as NSString
            var at = 0
            for match in matches(in: text) {
                result += sub.substring(with: NSRange(location: at, length: match.range.location - at))
                let token = sub.substring(with: match.range)
                if let url = resolve(match.reference) {
                    result += "[`\(match.reference.label)`](\(url.absoluteString))"
                } else {
                    result += token
                }
                at = NSMaxRange(match.range)
            }
            result += sub.substring(from: at)
        }
        for match in protected.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            plain(NSRange(location: cursor, length: match.range.location - cursor))
            let token = ns.substring(with: match.range)
            // A Markdown link to a file: its label becomes the file's.
            if match.range(at: 1).location != NSNotFound, !token.hasPrefix("!"),
               let url = URL(string: ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)),
               let reference = reference(for: url), let target = resolve(reference) {
                result += "[`\(reference.label)`](\(target.absoluteString))"
            } else {
                result += token
            }
            cursor = NSMaxRange(match.range)
        }
        plain(NSRange(location: cursor, length: ns.length - cursor))
        return result
    }

    // MARK: Drawing

    /// The glyph in front of each file link of a drawn text (14 pt, in the
    /// link's colour), and the link set in mono. The glyph copies as nothing.
    static func decorated(_ text: NSAttributedString, color: UIColor) -> NSAttributedString {
        var inserts: [(Int, String)] = []
        var monos: [NSRange] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
            guard let url, let reference = reference(for: url) else { return }
            inserts.append((range.location, reference.symbol))
            monos.append(range)
        }
        guard !inserts.isEmpty else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        for range in monos {
            text.enumerateAttribute(.font, in: range) { value, subrange, _ in
                guard let font = value as? UIFont, !font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) else { return }
                let mono = LAAReadingStyle.inlineCodeFont(for: font)
                    ?? .monospacedSystemFont(ofSize: (font.pointSize * LAAReadingStyle.inlineCodeScale).rounded(), weight: .regular)
                result.addAttribute(.font, value: mono, range: subrange)
            }
        }
        for (location, symbol) in inserts.reversed() {
            let font = (result.attribute(.font, at: location, effectiveRange: nil) as? UIFont) ?? .preferredFont(forTextStyle: .body)
            let size = min(16, max(14, font.pointSize * 0.85))
            let configuration = UIImage.SymbolConfiguration(pointSize: size, weight: .regular)
            guard let image = UIImage(systemName: symbol, withConfiguration: configuration)?
                .withTintColor(color, renderingMode: .alwaysOriginal) else { continue }
            let attachment = NSTextAttachment(image: image)
            attachment.bounds = CGRect(x: 0, y: (font.capHeight - image.size.height) / 2, width: image.size.width, height: image.size.height)
            let glyph = NSMutableAttributedString(attachment: attachment)
            glyph.append(NSAttributedString(string: "\u{2009}"))
            var attributes = result.attributes(at: location, effectiveRange: nil)
            attributes[.link] = nil
            attributes[MarkdownProseRun.copiesAs] = ""
            glyph.addAttributes(attributes, range: NSRange(location: 0, length: glyph.length))
            result.insert(glyph, at: location)
        }
        return result
    }
}
#endif
