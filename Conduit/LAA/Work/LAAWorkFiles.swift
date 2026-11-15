#if LAA_BUILD
import SwiftUI

/// Files a Work reply names on the Mac. The Bridge serves them, inside its
/// owner-file boundary, from `GET /v1/sessions/:id/files?path=` as base64
/// (`bridge/src/sessions/owner-files.mjs`); the app turns that into the data
/// URL the chat's Markdown already opens `MEDIA:` files and `::preview` pages
/// with, so the same cards, previews and Quick Look draw them.
enum LAAWorkFiles {
    struct Payload: Decodable { let name: String?; let mimeType: String; let data: String }

    /// ASCII only, so a Japanese file name is sent escaped and a `+` is not
    /// read back as a space.
    private static let queryAllowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")

    static func requestPath(sessionID: String, path: String) -> String? {
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: queryAllowed) else { return nil }
        return "/v1/sessions/\(sessionID)/files?path=\(encoded)"
    }

    static func dataURL(_ payload: Payload) -> String? {
        let value = "data:\(payload.mimeType);base64,\(payload.data)"
        return DataURLLimits.isBoundedBase64DataURL(value) ? value : nil
    }

    @MainActor
    static func dataURL(bridge: LAABridgeSession, sessionID: String, path: String) async -> String? {
        guard let local = localPath(path), let request = requestPath(sessionID: sessionID, path: local) else { return nil }
        guard let payload: Payload = try? await bridge.read(request) else { return nil }
        return dataURL(payload)
    }

    /// The Mac path a link or a `MEDIA:`/preview path names: an absolute
    /// path, or a `file://` URL. Anything else (a web address, an app link)
    /// is not a file on the Mac.
    static func localPath(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("file://") { return URL(string: trimmed).flatMap(localPath(_:)) }
        guard trimmed.hasPrefix("/"), !trimmed.hasPrefix("//") else { return nil }
        return trimmed
    }

    static func localPath(_ url: URL) -> String? {
        if url.isFileURL { return url.path.hasPrefix("/") ? url.path : nil }
        guard url.scheme == nil, url.host == nil else { return nil }
        let path = url.path
        return path.hasPrefix("/") && !path.hasPrefix("//") ? path : nil
    }

    // MARK: - Paths in the text

    /// A link to the path, a code span holding only a path, or a bare path,
    /// in that order; a Markdown link or an autolink already in the text is
    /// kept as written.
    private static let tokens = try! NSRegularExpression(pattern:
        #"(!?\[[^\]\n]*\]\([^)\n]*\))|(<[^>\n]+>)|(`[^`\n]+`)|(?<![A-Za-z0-9_/.:%~="'-])((?:file://)?/Users/[^\s`"'<>()\[\]（）「」『』、。，,；;：:]+)"#)
    private static let wholePath = try! NSRegularExpression(pattern:
        #"^(?:file://)?/Users/[^\s`"'<>()\[\]]+$"#)
    /// A file, not a folder: the last part has an extension.
    private static let fileName = try! NSRegularExpression(pattern: #"/[^/]*[^/.]\.[A-Za-z0-9]{1,10}$"#)

    /// The text with every Mac file path it names made a link, so a tap can
    /// open it: `/Users/laa/work/x/RESULT.md`, `` `/Users/laa/…/a.png` `` and
    /// `file:///Users/…`. Folders (no extension), fenced code and paths inside
    /// links stay as they are. Only what is drawn changes; copy keeps the
    /// message as the agent wrote it.
    static func linkified(_ text: String) -> String {
        guard text.contains("/Users/") else { return text }
        var fence: (character: Character, length: Int)?
        let lines = text.components(separatedBy: "\n").map { line -> String in
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
            // A `MEDIA:` tag and a `::preview` are the chat's own blocks.
            if fence != nil || !line.contains("/Users/") || line.contains("MEDIA:") || line.contains("::preview{") { return line }
            return linkifiedLine(line)
        }
        return lines.joined(separator: "\n")
    }

    private static func linkifiedLine(_ line: String) -> String {
        let ns = line as NSString
        var result = ""
        var cursor = 0
        for match in tokens.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = NSMaxRange(match.range)
            let token = ns.substring(with: match.range)
            if match.range(at: 3).location != NSNotFound {
                let inner = String(token.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if isFilePath(inner), let destination = destination(inner) {
                    result += "[\(token)](\(destination))"
                } else {
                    result += token
                }
            } else if match.range(at: 4).location != NSNotFound {
                let (path, trailing) = splitTrailingPunctuation(token)
                if isFilePath(path), let destination = destination(path) {
                    result += "[\(escapedLabel(path))](\(destination))" + trailing
                } else {
                    result += token
                }
            } else {
                result += token
            }
        }
        result += ns.substring(from: cursor)
        return result
    }

    private static func isFilePath(_ value: String) -> Bool {
        let range = NSRange(location: 0, length: (value as NSString).length)
        return wholePath.firstMatch(in: value, range: range) != nil && fileName.firstMatch(in: value, range: range) != nil
    }

    private static func splitTrailingPunctuation(_ value: String) -> (String, String) {
        var path = value
        var trailing = ""
        while let last = path.last, ".!?".contains(last) {
            trailing = String(last) + trailing
            path.removeLast()
        }
        return (path, trailing)
    }

    private static func destination(_ value: String) -> String? {
        guard let path = localPath(value) else { return nil }
        return path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "()")))
    }

    private static func escapedLabel(_ value: String) -> String {
        var escaped = ""
        for character in value {
            if "*_~\\".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }
}

/// A tap on a Mac file link in a Work message: the file is read through the
/// Bridge and shown — an HTML page in the chat's page viewer, anything else in
/// Quick Look (pictures, PDF, text). Every other link goes where it went.
struct LAAWorkFileLinkOpener: ViewModifier {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.openURL) private var outerOpenURL
    let sessionID: String
    @State private var opening = false
    @State private var failed = false
    @State private var page: Page?
    @State private var task: Task<Void, Never>?

    struct Page: Identifiable { let id = UUID(); let name: String; let html: String }

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                guard let path = LAAWorkFiles.localPath(url) else {
                    outerOpenURL(url)
                    return .handled
                }
                open(path)
                return .handled
            })
            .overlay(alignment: .topTrailing) {
                if opening { ProgressView().padding(LAASpacing.x2).accessibilityLabel(Text(verbatim: "ファイルを開いています")) }
            }
            .alert(Text(verbatim: "ファイルを開けません"), isPresented: $failed) {
                Button(role: .cancel) {} label: { Text(verbatim: "OK") }
            } message: {
                Text(verbatim: "Macにないか、開けない場所のファイルです。")
            }
            .sheet(item: $page) { page in HTMLPreviewSheet(name: page.name, html: page.html) }
            .onDisappear { task?.cancel(); task = nil; opening = false }
    }

    private func open(_ path: String) {
        guard !opening else { return }
        opening = true
        task = Task { @MainActor in
            defer { opening = false; task = nil }
            guard let dataURL = await LAAWorkFiles.dataURL(bridge: bridge, sessionID: sessionID, path: path),
                  !Task.isCancelled else {
                if !Task.isCancelled { failed = true }
                return
            }
            let name = (path as NSString).lastPathComponent
            if TranscriptDirectives.isHTML(path), let html = HTMLPreviewPage.decodedDocument(fromDataURL: dataURL) {
                page = Page(name: name, html: html)
                return
            }
            if !(await MediaPreviewPresenter.shared.present(dataURL: dataURL, filename: name)), !Task.isCancelled {
                failed = true
            }
        }
    }
}
#endif
