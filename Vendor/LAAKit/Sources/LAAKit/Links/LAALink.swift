import SwiftUI

/// What a link in prose points at. The kit only classifies; the app opens it in-app (Doc, code view, media,
/// Drive, Studio) through its own allow-listed routes. A `file://` link grants no file access by itself.
public enum LAALink: Equatable, Sendable {
    case file(path: String, line: Int?, column: Int?)
    case doc(id: String)
    case drive(id: String)
    case studio(id: String)
    case web(URL)
    case other(URL)

    /// Custom scheme the kit uses for `path:line` text it turns into links.
    public static let fileScheme = "laa-file"

    public static func classify(_ url: URL) -> LAALink {
        switch url.scheme?.lowercased() {
        case "file", fileScheme:
            var path = url.path(percentEncoded: false)
            var line: Int?, column: Int?
            if let fragment = url.fragment, fragment.hasPrefix("L") {
                let parts = fragment.dropFirst().split(separator: "C")
                line = parts.first.flatMap { Int($0) }
                column = parts.count > 1 ? Int(parts[1]) : nil
            } else if let (p, l, c) = splitLine(path) {
                path = p; line = l; column = c
            }
            return .file(path: path, line: line, column: column)
        case "laa-doc": return .doc(id: url.host() ?? url.path())
        case "laa-studio": return .studio(id: url.host() ?? url.path())
        case "https", "http":
            if url.host()?.hasSuffix("drive.google.com") == true || url.host()?.hasSuffix("docs.google.com") == true,
               let id = driveID(url) { return .drive(id: id) }
            return .web(url)
        default: return .other(url)
        }
    }

    /// `name.swift:42` or `name.swift:42:7`.
    static func splitLine(_ text: String) -> (String, Int, Int?)? {
        var parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let last = Int(parts.removeLast()) else { return nil }
        if parts.count >= 2, let line = Int(parts.last!) {
            parts.removeLast()
            return (parts.joined(separator: ":"), line, last)
        }
        return (parts.joined(separator: ":"), last, nil)
    }

    static func driveID(_ url: URL) -> String? {
        let comps = url.pathComponents
        if let i = comps.firstIndex(of: "d"), i + 1 < comps.count { return comps[i + 1] }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
    }

    /// Finds `dir/file.ext:line` references in plain text (outside code) so they can become links.
    public static func fileReferences(in text: String) -> [(range: Range<String.Index>, path: String, line: Int?)] {
        let pattern = /(^|[^\w\/.:-])((?:~|\.{1,2})?\/?(?:[\w.@-]+\/)*[\w@-][\w.@-]*\.[A-Za-z][A-Za-z0-9]{0,7})(?::(\d+)(?::\d+)?)?(?![\w\/])/
        var found: [(range: Range<String.Index>, path: String, line: Int?)] = []
        for match in text.matches(of: pattern) {
            let path = String(match.output.2)
            let line = match.output.3.flatMap { Int($0) }
            // A bare word with a dot (e.g. "e.g", "v1.2") is not a file: require a path separator or a line.
            guard path.contains("/") || line != nil else { continue }
            let start = match.output.2.startIndex
            found.append((start..<match.range.upperBound, path, line))
        }
        return found
    }

    /// Basename plus `:line` for display; the full path goes to accessibility and copy.
    public static func displayName(path: String, line: Int?) -> String {
        let base = path.split(separator: "/").last.map(String.init) ?? path
        return line.map { "\(base):\($0)" } ?? base
    }

    public static func url(path: String, line: Int?) -> URL? {
        var c = URLComponents()
        c.scheme = fileScheme
        c.host = ""
        c.path = path.hasPrefix("/") ? path : "/" + path
        if let line { c.fragment = "L\(line)" }
        return c.url
    }
}

/// A standalone file link (Doc lists, attachments): Phosphor file glyph + basename:line in mono, accent with a
/// thin underline on a `wash` ground, radius 4. Opens in-app through `action`.
public struct LAAFileLink: View {
    let path: String
    let line: Int?
    let action: () -> Void
    @Environment(\.laaPalette) private var palette

    public init(path: String, line: Int? = nil, action: @escaping () -> Void) {
        self.path = path; self.line = line; self.action = action
    }

    public var body: some View {
        let icon = LAAPlatform.current == .mac ? LAAComponentToken.FileLink.iconMac : LAAComponentToken.FileLink.iconIPhone
        Button(action: action) {
            HStack(spacing: LAASpace.s4) {
                LAAIconImage(fileIcon, size: icon)
                Text(LAALink.displayName(path: path, line: line))
                    .laaFont(LAAPlatform.current.canvas.codeInline, design: .monospaced)
                    .underline(true, color: palette.accent)
            }
            .foregroundStyle(palette.accent)
            .padding(.horizontal, LAASpace.s4)
            .background(RoundedRectangle(cornerRadius: LAAComponentToken.FileLink.radius).fill(palette.wash))
            .frame(minHeight: LAAPlatform.current == .mac ? LAAControl.Mac.hitArea : LAAControl.IPhone.hitArea)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(path + (line.map { " line \($0)" } ?? "")))
        .accessibilityAddTraits(.isLink)
    }

    private var fileIcon: LAAIcon { LAALink.icon(forPath: path) }
}

public extension LAALink {
    /// The file glyph for a path: doc, image, code or file.
    static func icon(forPath path: String) -> LAAIcon {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "md", "txt", "rtf": return .doc
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "mov", "mp4": return .image
        case "swift", "py", "ts", "tsx", "js", "mjs", "json", "sh", "css", "html", "yml", "yaml": return .code
        default: return .file
        }
    }
}
