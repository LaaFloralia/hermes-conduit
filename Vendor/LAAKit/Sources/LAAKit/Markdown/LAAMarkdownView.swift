import SwiftUI

/// One block of Markdown. IDs are stable for finalized blocks (index + content hash), so rows above the
/// streaming tail never change identity or height.
public struct LAAMarkdownBlock: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case paragraph
        case heading(level: Int)
        case bullet(depth: Int)
        case ordered(number: Int, depth: Int)
        case quote
        case code(language: String?)
        case rule
    }
    public let id: String
    public let kind: Kind
    public let text: String
}

/// Splits Markdown into blocks. Pure and deterministic; the streaming tail is re-parsed alone.
public enum LAAMarkdownParser {
    public static func blocks(_ source: String) -> [LAAMarkdownBlock] {
        var out: [LAAMarkdownBlock] = []
        var paragraph: [String] = []
        var code: (lang: String?, lines: [String])?
        var quote: [String] = []

        func push(_ kind: LAAMarkdownBlock.Kind, _ text: String) {
            out.append(LAAMarkdownBlock(id: "\(out.count)-\(stableHash(text))", kind: kind, text: text))
        }
        func flushParagraph() {
            if !paragraph.isEmpty { push(.paragraph, joinSoftBreaks(paragraph)); paragraph = [] }
        }
        func flushQuote() {
            if !quote.isEmpty { push(.quote, quote.joined(separator: "\n")); quote = [] }
        }

        for raw in source.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var block = code {
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    push(.code(language: block.lang), block.lines.joined(separator: "\n")); code = nil
                } else { block.lines.append(line); code = block }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph(); flushQuote()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                code = (lang.isEmpty ? nil : lang, [])
                continue
            }
            if trimmed.isEmpty { flushParagraph(); flushQuote(); continue }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            flushQuote()
            if let level = heading(trimmed) {
                flushParagraph()
                push(.heading(level: level), String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces))
                continue
            }
            if trimmed.count >= 3, Set(trimmed.replacingOccurrences(of: " ", with: "")).count == 1,
               let c = trimmed.first, "-*_".contains(c) {
                flushParagraph(); push(.rule, ""); continue
            }
            let indent = line.prefix(while: { $0 == " " }).count
            let depth = min(indent / 2, 3)
            if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().first == " " {
                flushParagraph()
                push(.bullet(depth: depth), String(trimmed.dropFirst(2)))
                continue
            }
            if let dot = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }), let n = Int(trimmed[..<dot]),
               trimmed[trimmed.index(after: dot)...].first == " " {
                flushParagraph()
                push(.ordered(number: n, depth: depth), String(trimmed[trimmed.index(dot, offsetBy: 2)...]))
                continue
            }
            paragraph.append(String(line.drop(while: { $0 == " " })))
        }
        flushParagraph(); flushQuote()
        if let block = code { push(.code(language: block.lang), block.lines.joined(separator: "\n")) }
        return out
    }

    /// Markdown soft breaks: a space between Latin words, nothing between Japanese lines; a trailing two spaces
    /// or backslash is a hard break.
    static func joinSoftBreaks(_ lines: [String]) -> String {
        var out = ""
        for (i, raw) in lines.enumerated() {
            var line = raw
            let hard = line.hasSuffix("  ") || line.hasSuffix("\\")
            if line.hasSuffix("\\") { line.removeLast() }
            line = line.trimmingCharacters(in: .whitespaces)
            out += line
            guard i < lines.count - 1 else { break }
            if hard { out += "\n"; continue }
            let next = lines[i + 1].trimmingCharacters(in: .whitespaces)
            if let a = line.unicodeScalars.last, let b = next.unicodeScalars.first, isCJK(a) || isCJK(b) { continue }
            out += " "
        }
        return out
    }

    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF: return true
        default: return false
        }
    }

    static func heading(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    /// FNV-1a: stable across launches (Hasher is seeded per process).
    static func stableHash(_ text: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { h = (h ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(h, radix: 36)
    }

    /// Inline Markdown → AttributedString; plain `path/file.ext:line` references become `laa-file` links.
    public static func inline(_ text: String) -> AttributedString {
        var source = text
        // Turn bare file references into Markdown links before parsing (skip inside `code`).
        var segments: [String] = []
        var inCode = false
        for piece in source.split(separator: "`", omittingEmptySubsequences: false) {
            if inCode {
                // A code span that is exactly a file reference becomes a file link (mono, accent, underline).
                let span = String(piece)
                if let ref = LAALink.fileReferences(in: span).first, ref.range == span.startIndex..<span.endIndex,
                   let url = LAALink.url(path: ref.path, line: ref.line) {
                    segments.append("[`\(LAALink.displayName(path: ref.path, line: ref.line))`](\(url.absoluteString))")
                } else {
                    segments.append("`" + span + "`")
                }
            }
            else {
                var s = String(piece)
                for ref in LAALink.fileReferences(in: s).reversed() {
                    guard let url = LAALink.url(path: ref.path, line: ref.line) else { continue }
                    s.replaceSubrange(ref.range, with: "[`\(LAALink.displayName(path: ref.path, line: ref.line))`](\(url.absoluteString))")
                }
                segments.append(s)
            }
            inCode.toggle()
        }
        source = segments.joined()
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(text)
    }
}

/// Markdown on paper in the reading face: headings 20/26 (600), paragraphs and lists at the reading size with
/// the fixed line box, inline code at 0.88×, code blocks 13/20 on `wash` (radius 12), quotes with a 2 pt rule.
/// Links are `accent` + underline; file links open in-app via the environment's `openURL`.
private extension Color {
    /// The run's foreground (links are already `accent`).
    init(link run: AttributedSubstring) { self = run.foregroundColor ?? .accentColor }
}

public struct LAAMarkdownView: View {
    let blocks: [LAAMarkdownBlock]
    @Environment(\.laaPalette) private var palette

    public init(_ markdown: String) { blocks = LAAMarkdownParser.blocks(markdown) }
    public init(blocks: [LAAMarkdownBlock]) { self.blocks = blocks }

    public var body: some View {
        VStack(alignment: .leading, spacing: LAAComponentToken.Transcript.paragraphGap) {
            ForEach(blocks) { block in
                LAAMarkdownBlockView(block: block)
                    .equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #if !os(watchOS)
        .textSelection(.enabled)
        #endif
    }
}

struct LAAMarkdownBlockView: View, Equatable {
    let block: LAAMarkdownBlock
    @Environment(\.laaPalette) private var palette

    nonisolated static func == (a: Self, b: Self) -> Bool { a.block == b.block }

    var body: some View {
        switch block.kind {
        case .paragraph:
            reading(block.text)
        case .heading(let level):
            reading(block.text, role: level <= 2 ? .heading : .body, strong: true)
                .padding(.top, level <= 2 ? LAASpace.s8 : 0)
                .accessibilityAddTraits(.isHeader)
        case .bullet(let depth):
            HStack(alignment: .firstTextBaseline, spacing: LAASpace.s8) {
                Text(depth == 0 ? "•" : "◦").laaReading().foregroundStyle(palette.textMuted)
                reading(block.text)
            }
            .padding(.leading, Double(depth) * LAASpace.s16)
        case .ordered(let number, let depth):
            HStack(alignment: .firstTextBaseline, spacing: LAASpace.s8) {
                Text("\(number).").laaReading().monospacedDigit().foregroundStyle(palette.textMuted)
                reading(block.text)
            }
            .padding(.leading, Double(depth) * LAASpace.s16)
        case .quote:
            reading(block.text)
                .foregroundStyle(palette.textMuted)
                .padding(.leading, LAASpace.s12)
                .overlay(alignment: .leading) { Rectangle().fill(palette.rule).frame(width: LAAStroke.ruleStrong) }
        case .code:
            ScrollView(.horizontal, showsIndicators: false) {
                Text(block.text)
                    .laaFont(LAAPlatform.current.canvas.codeBlock, design: .monospaced)
                    .lineSpacing(LAAPlatform.current.canvas.codeBlockLine - LAAPlatform.current.canvas.codeBlock * 1.2)
                    .foregroundStyle(palette.text)
                    .padding(LAASpace.s12)
                    .fixedSize(horizontal: LAAPlatform.current == .mac, vertical: false)
            }
            .background(RoundedRectangle(cornerRadius: LAARadius.selection).fill(palette.wash))
        case .rule:
            Rectangle().fill(palette.rule).frame(height: LAAStroke.rule).padding(.vertical, LAASpace.s8)
        }
    }

    private func reading(_ text: String, role: LAAType.Reading = .body, strong: Bool = false) -> some View {
        let value = styled(text)
        return LAAMarkdownBlockView.text(value, glyphSize: LAAType.readingSize(.body) * 0.88).modifier(LAAReadingModifier(role: role, strong: strong,
                                                       hasLinks: value.runs.contains { $0.link != nil }))
    }

    /// Text with a file glyph (SF Symbol; Text cannot inline a shape) before each file link.
    static func text(_ value: AttributedString, glyphSize: Double) -> Text {
        guard value.runs.contains(where: { $0.link?.scheme == LAALink.fileScheme }) else { return Text(value) }
        var result = Text(verbatim: "")
        for run in value.runs {
            if let link = run.link, link.scheme == LAALink.fileScheme {
                let glyph = Text(Image(systemName: LAALink.icon(forPath: link.path).sfSymbol))
                    .font(.system(size: glyphSize))
                    .foregroundColor(Color(link: value[run.range]))
                result = Text("\(result)\(glyph)\u{202F}")
            }
            result = Text("\(result)\(Text(AttributedString(value[run.range])))")
        }
        return result
    }

    private func styled(_ text: String) -> AttributedString {
        var value = LAAMarkdownParser.inline(text)
        let codeSize = LAAType.readingSize(.body) * 0.88
        for run in value.runs {
            if run.inlinePresentationIntent?.contains(.code) == true, run.link == nil {
                value[run.range].font = .system(size: codeSize, design: .monospaced)
                value[run.range].backgroundColor = palette.wash
            }
            if let link = run.link {
                value[run.range].foregroundColor = palette.accent
                value[run.range].underlineStyle = .single
                if link.scheme == LAALink.fileScheme {
                    value[run.range].font = .system(size: codeSize, design: .monospaced)
                    value[run.range].backgroundColor = palette.wash
                }
            }
        }
        return value
    }
}
