#if LAA_BUILD
import Foundation

/// The Markdown model behind the note editor. Editing never rewrites source it
/// was not asked to touch: a block keeps its original lines until the person
/// edits that block, so frontmatter, wiki links and syntax this app does not
/// render survive a save unchanged.
///
/// Foundation only, and every range is an `NSRange` over UTF-16 (UIKit's text
/// input), so the round trip can be tested without a simulator.
enum LAAMarkdownBlockKind: Equatable {
    case frontmatter
    case blank
    case heading(level: Int)
    case bullet
    case ordered(number: Int)
    case checkbox(checked: Bool)
    case quote
    case fence(language: String)
    case code
    case rule
    case table
    case raw
    case paragraph
}

/// One source line with the ranges the editor styles or hides. The marker
/// range is relative to the line's start: `# `, `- `, `1. `, `- [x] `, `> `.
struct LAAMarkdownLine: Equatable {
    let range: NSRange
    let text: String
    let kind: LAAMarkdownBlockKind
    let markerRange: NSRange
    let contentRange: NSRange
    let indent: Int

    var marker: String { (text as NSString).substring(with: markerRange) }
    var content: String { (text as NSString).substring(with: contentRange) }
    var isEmptyContent: Bool { content.trimmingCharacters(in: .whitespaces).isEmpty }
    var markerInDocument: NSRange { NSRange(location: range.location + markerRange.location, length: markerRange.length) }

    /// Nesting depth for lists: two spaces or one tab per level, capped so a
    /// deeply indented line still fits the phone's width.
    var listLevel: Int { min(indent / 2, 4) }
}

struct LAAMarkdownEdit: Equatable {
    let text: String
    let selection: NSRange
}

struct LAAMarkdownTable: Equatable {
    enum Alignment: String, Equatable {
        case none = "---"
        case left = ":--"
        case center = ":-:"
        case right = "--:"

        var marker: String { rawValue }
    }

    var header: [String]
    var alignments: [Alignment]
    var rows: [[String]]
    /// The lines as they were read. Present until the table is edited, so an
    /// untouched table is written back byte for byte (padding included).
    var rawLines: [String]?

    var columnCount: Int { max(header.count, max(alignments.count, rows.map(\.count).max() ?? 0)) }
    var edited: Bool { rawLines == nil }

    func cell(row: Int, column: Int) -> String {
        let source = row < 0 ? header : (rows.indices.contains(row) ? rows[row] : [])
        return source.indices.contains(column) ? source[column] : ""
    }

    mutating func setCell(_ value: String, row: Int, column: Int) {
        let column = max(0, column)
        if row < 0 {
            // The header can be narrower than a body row (a ragged table the
            // person wrote, or a column added in the grid): grow it instead of
            // indexing past its end.
            while header.count <= column { header.append("") }
            header[column] = value
        } else {
            if rows.isEmpty { rows.append([]) }
            let index = min(max(0, row), max(0, rows.count - 1))
            while rows[index].count <= column { rows[index].append("") }
            rows[index][column] = value
        }
        rawLines = nil
    }

    mutating func addRow() {
        normalise()
        rows.append(Array(repeating: "", count: columnCount))
        rawLines = nil
    }

    mutating func addColumn() {
        normalise()
        header.append("")
        while alignments.count < header.count { alignments.append(.none) }
        for index in rows.indices { rows[index].append("") }
        rawLines = nil
    }

    mutating func removeRow(_ row: Int) {
        guard rows.indices.contains(row) else { return }
        rows.remove(at: row)
        rawLines = nil
    }

    mutating func removeColumn(_ column: Int) {
        guard columnCount > 1, column < columnCount else { return }
        if header.indices.contains(column) { header.remove(at: column) }
        if alignments.indices.contains(column) { alignments.remove(at: column) }
        for index in rows.indices where rows[index].indices.contains(column) { rows[index].remove(at: column) }
        rawLines = nil
    }

    /// Cells stay rectangular so a saved table never has ragged rows.
    mutating func normalise() {
        let count = max(1, columnCount)
        while header.count < count { header.append("") }
        while alignments.count < count { alignments.append(.none) }
        for index in rows.indices {
            while rows[index].count < count { rows[index].append("") }
        }
    }

    var markdownLines: [String] {
        if let rawLines, !rawLines.isEmpty { return rawLines }
        // Each row keeps its own cells: a row wider than the header is still
        // the person's content, and padding or truncating it would rewrite
        // Markdown nobody edited. Ragged rows are valid.
        var output = ["| " + header.map(Self.escape).joined(separator: " | ") + " |"]
        let delimiters = max(1, max(header.count, alignments.count))
        output.append("| " + (0..<delimiters).map { index in
            (alignments.indices.contains(index) ? alignments[index] : .none).marker
        }.joined(separator: " | ") + " |")
        for row in rows {
            output.append("| " + row.map(Self.escape).joined(separator: " | ") + " |")
        }
        return output
    }

    var markdown: String { markdownLines.joined(separator: "\n") }

    /// A cell cannot hold a raw pipe (it would end the cell) or a newline (it
    /// would end the row).
    private static func escape(_ cell: String) -> String {
        cell.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func unescape(_ cell: String) -> String {
        cell.replacingOccurrences(of: "\\|", with: "|").trimmingCharacters(in: .whitespaces)
    }

    static func from(_ lines: [String]) -> LAAMarkdownTable? {
        guard lines.count >= 2 else { return nil }
        let header = cells(in: lines[0])
        let delimiter = cells(in: lines[1])
        guard !header.isEmpty, !delimiter.isEmpty, delimiter.allSatisfy({ isDelimiter($0) }) else { return nil }
        let alignments = delimiter.map { cell -> Alignment in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            let left = trimmed.hasPrefix(":")
            let right = trimmed.hasSuffix(":") && trimmed.count > 1
            switch (left, right) {
            case (true, true): return .center
            case (true, false): return .left
            case (false, true): return .right
            case (false, false): return .none
            }
        }
        // An empty row is still a row: skipping it here would delete it the
        // first time any cell in the table is edited.
        let rows = lines.dropFirst(2).map { cells(in: $0) }
        return LAAMarkdownTable(header: header, alignments: alignments, rows: rows, rawLines: lines)
    }

    private static func isDelimiter(_ cell: String) -> Bool {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        let middle = trimmed.dropFirst(trimmed.hasPrefix(":") ? 1 : 0).dropLast(trimmed.hasSuffix(":") ? 1 : 0)
        return !middle.isEmpty && middle.allSatisfy { $0 == "-" }
    }

    /// Splits on pipes that are not escaped, dropping the optional leading and
    /// trailing pipe. `\|` stays inside its cell.
    static func cells(in line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        // Character, not UTF-16 code unit: an emoji or any non-BMP character
        // is two units, and splitting one of them would corrupt the cell.
        for character in line {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                current.append(character)
                escaped = true
                continue
            }
            if character == "|" {
                cells.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        cells.append(current)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|"), !cells.isEmpty { cells.removeFirst() }
        if trimmed.hasSuffix("|"), !cells.isEmpty { cells.removeLast() }
        if cells.count == 1, cells[0].trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        return cells.map { unescape($0) }
    }
}

/// A note body split into plain Markdown runs and tables. Only tables leave
/// the text view, so selection, the IME and undo keep working across the rest
/// of the note.
enum LAAMarkdownSegment: Equatable {
    case text(String)
    case table(LAAMarkdownTable)

    var source: String {
        switch self {
        case .text(let text): return text
        case .table(let table): return table.markdown
        }
    }
}

enum LAAMarkdownParser {
    /// Splits lines without their newline. A trailing newline keeps an empty
    /// final line, so joining the lines restores the source exactly.
    static func split(_ text: String) -> [String] { text.components(separatedBy: "\n") }

    static func lines(in text: String) -> [LAAMarkdownLine] {
        let rawLines = split(text)
        var result: [LAAMarkdownLine] = []
        var fence: (marker: Character, count: Int)?
        var offset = 0
        var frontmatterOpen = false

        for (index, line) in rawLines.enumerated() {
            let length = (line as NSString).length
            let range = NSRange(location: offset, length: length)
            let leading = leadingWhitespace(line)
            let indent = leading
            let body = (line as NSString).substring(from: indent)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            var kind: LAAMarkdownBlockKind
            var markerRange = NSRange(location: 0, length: 0)
            var contentRange = NSRange(location: 0, length: length)

            if index == 0, trimmed == "---" {
                frontmatterOpen = true
                kind = .frontmatter
            } else if frontmatterOpen {
                if trimmed == "---" || trimmed == "..." { frontmatterOpen = false }
                kind = .frontmatter
            } else if let active = fence {
                if trimmed.count >= active.count, trimmed.allSatisfy({ $0 == active.marker }) {
                    fence = nil
                    kind = .fence(language: "")
                } else {
                    kind = .code
                }
            } else if body.hasPrefix("```") || body.hasPrefix("~~~") {
                let marker = body.first ?? "`"
                let count = body.prefix { $0 == marker }.count
                let language = body.dropFirst(count).trimmingCharacters(in: .whitespaces)
                fence = (marker, count)
                kind = .fence(language: language)
            } else if trimmed.isEmpty {
                kind = .blank
            } else if let heading = heading(body, indent: indent) {
                kind = .heading(level: heading.level)
                markerRange = heading.marker
                contentRange = heading.content
            } else if let item = listItem(body, indent: indent) {
                kind = item.kind
                markerRange = item.marker
                contentRange = item.content
            } else if isRule(line) {
                kind = .rule
            } else if trimmed.hasPrefix("|") {
                kind = .table
            } else if isRaw(line) {
                kind = .raw
            } else {
                kind = .paragraph
            }
            result.append(LAAMarkdownLine(range: range, text: line, kind: kind,
                                          markerRange: markerRange, contentRange: contentRange, indent: indent))
            offset += length + 1
        }
        return result
    }

    /// Characters, not bytes: a tab counts as one column here and two spaces
    /// are one list level.
    private static func leadingWhitespace(_ line: String) -> Int {
        let source = line as NSString
        var index = 0
        while index < source.length {
            let character = source.character(at: index)
            if character == 0x20 || character == 0x09 { index += 1 } else { break }
        }
        return index
    }

    private static func heading(_ body: String, indent: Int) -> (level: Int, marker: NSRange, content: NSRange)? {
        let source = body as NSString
        var hashes = 0
        while hashes < source.length, source.character(at: hashes) == 0x23 { hashes += 1 }
        guard hashes >= 1, hashes <= 6, hashes < source.length else { return nil }
        guard source.character(at: hashes) == 0x20 || source.character(at: hashes) == 0x09 else { return nil }
        var end = hashes
        while end < source.length, source.character(at: end) == 0x20 || source.character(at: end) == 0x09 { end += 1 }
        return (hashes,
                NSRange(location: indent, length: end),
                NSRange(location: indent + end, length: source.length - end))
    }

    private static func listItem(_ body: String, indent: Int) -> (kind: LAAMarkdownBlockKind, marker: NSRange, content: NSRange)? {
        let source = body as NSString
        func make(_ kind: LAAMarkdownBlockKind, _ length: Int) -> (LAAMarkdownBlockKind, NSRange, NSRange) {
            (kind,
             NSRange(location: indent, length: length),
             NSRange(location: indent + length, length: source.length - length))
        }
        guard source.length >= 2 else { return nil }
        let first = source.character(at: 0)

        if first == 0x2D || first == 0x2A || first == 0x2B {
            guard source.character(at: 1) == 0x20 else { return nil }
            if source.length >= 6, source.character(at: 2) == 0x5B, source.character(at: 4) == 0x5D,
               source.character(at: 5) == 0x20,
               source.character(at: 3) == 0x20 || source.character(at: 3) == 0x78 || source.character(at: 3) == 0x58 {
                return make(.checkbox(checked: source.character(at: 3) != 0x20), 6)
            }
            return make(.bullet, 2)
        }
        if first == 0x3E {
            return make(.quote, source.length >= 2 && source.character(at: 1) == 0x20 ? 2 : 1)
        }
        if first >= 0x30, first <= 0x39 {
            var digits = 0
            while digits < source.length, source.character(at: digits) >= 0x30, source.character(at: digits) <= 0x39 {
                digits += 1
            }
            guard digits > 0, digits < source.length else { return nil }
            let separator = source.character(at: digits)
            guard separator == 0x2E || separator == 0x29 else { return nil }
            var end = digits + 1
            guard end < source.length, source.character(at: end) == 0x20 else { return nil }
            while end < source.length, source.character(at: end) == 0x20 { end += 1 }
            let number = Int(source.substring(to: digits)) ?? 1
            return make(.ordered(number: number), end)
        }
        return nil
    }

    private static func isRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, let marker = trimmed.first, marker == "-" || marker == "*" || marker == "_" else { return false }
        return trimmed.allSatisfy { $0 == marker || $0 == " " }
    }

    /// Syntax specific to other editors is shown verbatim and never rewritten.
    private static func isRaw(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(":::") || trimmed.hasPrefix("%%") || trimmed.hasPrefix("<") { return true }
        return trimmed.range(of: #"^\[[^\]]+\]:"#, options: .regularExpression) != nil
    }

    // MARK: Segments

    static func segments(in text: String) -> [LAAMarkdownSegment] {
        let lines = split(text)
        var result: [LAAMarkdownSegment] = []
        var buffer: [String] = []
        var index = 0
        var fence: (marker: Character, count: Int)?

        func flushText() {
            guard !buffer.isEmpty else { return }
            result.append(.text(buffer.joined(separator: "\n")))
            buffer.removeAll()
        }

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            // Inside a code fence a line starting with a pipe is code, not a
            // table: it must stay in the text run, exactly as written.
            if let active = fence {
                buffer.append(lines[index])
                if trimmed.count >= active.count, trimmed.allSatisfy({ $0 == active.marker }) { fence = nil }
                index += 1
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~"),
               let marker = trimmed.first {
                fence = (marker, trimmed.prefix { $0 == marker }.count)
                buffer.append(lines[index])
                index += 1
                continue
            }
            guard trimmed.hasPrefix("|") else {
                buffer.append(lines[index]); index += 1; continue
            }
            var end = index
            while end < lines.count, lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("|") { end += 1 }
            if let table = LAAMarkdownTable.from(Array(lines[index..<end])) {
                flushText()
                result.append(.table(table))
                index = end
            } else {
                buffer.append(lines[index]); index += 1
            }
        }
        flushText()
        if result.isEmpty { result.append(.text("")) }
        return result
    }

    static func text(from segments: [LAAMarkdownSegment]) -> String {
        segments.map(\.source).joined(separator: "\n")
    }
}

/// Everything the editor's controls do, as functions on source text and a
/// selection. Keeping them out of UIKit lets the round trip, the block
/// toggles and Return continuation be tested directly.
enum LAAMarkdownFormat {
    enum Block: Equatable {
        case body, heading1, heading2, heading3, bullet, ordered, checkbox, quote
    }

    static func marker(for block: Block, number: Int = 1, indent: Int = 0) -> String {
        let spaces = String(repeating: " ", count: max(0, indent))
        switch block {
        case .body: return ""
        case .heading1: return spaces + "# "
        case .heading2: return spaces + "## "
        case .heading3: return spaces + "### "
        case .bullet: return spaces + "- "
        case .ordered: return spaces + "\(number > 0 ? number : 1). "
        case .checkbox: return spaces + "- [ ] "
        case .quote: return spaces + "> "
        }
    }

    static func block(of line: LAAMarkdownLine) -> Block {
        switch line.kind {
        case .heading(let level): return level >= 3 ? .heading3 : (level == 2 ? .heading2 : .heading1)
        case .bullet: return .bullet
        case .ordered: return .ordered
        case .checkbox: return .checkbox
        case .quote: return .quote
        default: return .body
        }
    }

    static func isList(_ block: Block) -> Bool {
        switch block {
        case .bullet, .ordered, .checkbox: return true
        default: return false
        }
    }

    /// Line ranges the selection touches; a caret selects its own line.
    static func lineRanges(in text: String, selection: NSRange) -> [NSRange] {
        let source = text as NSString
        guard source.length > 0 else { return [NSRange(location: 0, length: 0)] }
        let start = min(max(0, selection.location), source.length)
        let end = min(source.length, max(start, selection.location + selection.length))
        var result: [NSRange] = []
        var cursor = start
        while true {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            source.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: cursor, length: 0))
            result.append(NSRange(location: lineStart, length: contentsEnd - lineStart))
            if lineEnd >= end || lineEnd >= source.length || result.count > 500 { break }
            cursor = lineEnd
        }
        return result
    }

    private static func linesTouched(by selection: NSRange, in lines: [LAAMarkdownLine], text: String) -> [LAAMarkdownLine] {
        let targets = lineRanges(in: text, selection: selection)
        return lines.filter { line in targets.contains { $0.location == line.range.location } }
    }

    /// Converts every line the selection touches to `block`. Choosing the
    /// block a line already has returns it to a plain paragraph, so one button
    /// both applies and removes a format.
    static func setBlock(_ block: Block, text: String, selection: NSRange) -> LAAMarkdownEdit {
        let lines = LAAMarkdownParser.lines(in: text)
        let targets = linesTouched(by: selection, in: lines, text: text)
        let applies = !targets.isEmpty && targets.allSatisfy { self.block(of: $0) == block }
        let replacement = applies ? Block.body : block
        let source = NSMutableString(string: text)
        var delta = 0
        for line in targets.sorted(by: { $0.range.location < $1.range.location }) {
            if line.kind == .blank { continue }
            var number = 1
            if case .ordered(let existing) = line.kind { number = existing }
            let markerRange = line.markerInDocument
            let replacementText = marker(for: replacement, number: number)
            let adjusted = NSRange(location: markerRange.location + delta, length: markerRange.length)
            source.replaceCharacters(in: adjusted, with: replacementText)
            delta += (replacementText as NSString).length - markerRange.length
        }
        let length = (source as NSString).length
        let location = min(max(0, selection.location + delta), length)
        let trailing = min(selection.length, length - location)
        return LAAMarkdownEdit(text: source as String,
                               selection: NSRange(location: location, length: max(0, trailing)))
    }

    /// Toggles `[ ]`/`[x]` on the selected lines, adding a checkbox to plain
    /// lines first.
    static func toggleCheckbox(text: String, selection: NSRange) -> LAAMarkdownEdit {
        let lines = LAAMarkdownParser.lines(in: text)
        let targets = linesTouched(by: selection, in: lines, text: text)
        let source = NSMutableString(string: text)
        var delta = 0
        for line in targets.sorted(by: { $0.range.location < $1.range.location }) {
            guard line.kind != .blank else { continue }
            let markerRange = line.markerInDocument
            let replacement: String
            if case .checkbox(let checked) = line.kind {
                replacement = marker(for: .checkbox).replacingOccurrences(of: "[ ]", with: checked ? "[ ]" : "[x]")
            } else {
                replacement = marker(for: .checkbox)
            }
            let adjusted = NSRange(location: markerRange.location + delta, length: markerRange.length)
            source.replaceCharacters(in: adjusted, with: replacement)
            delta += (replacement as NSString).length - markerRange.length
        }
        let length = (source as NSString).length
        let location = min(max(0, selection.location + delta), length)
        let trailing = min(selection.length, length - location)
        return LAAMarkdownEdit(text: source as String,
                               selection: NSRange(location: location, length: max(0, trailing)))
    }

    /// Return inside a list continues it; Return on an empty item ends the
    /// list instead of leaving a bare marker behind.
    static func returnInsertion(text: String, caret: Int) -> LAAMarkdownEdit? {
        let source = text as NSString
        guard source.length > 0 else { return nil }
        let location = min(max(0, caret), source.length)
        var start = 0
        var end = 0
        var contentsEnd = 0
        source.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        let lineText = source.substring(with: NSRange(location: start, length: contentsEnd - start))
        guard let parsed = LAAMarkdownParser.lines(in: lineText).first else { return nil }
        var kind = parsed.kind
        if case .ordered(let number) = kind { kind = .ordered(number: number) }
        switch kind {
        case .bullet, .ordered, .checkbox, .quote: break
        default: return nil
        }
        if parsed.isEmptyContent, parsed.markerRange.length > 0 {
            let range = NSRange(location: start, length: parsed.markerRange.length)
            return LAAMarkdownEdit(text: source.replacingCharacters(in: range, with: ""),
                                   selection: NSRange(location: start, length: 0))
        }
        let marker: String
        switch kind {
        case .ordered(let number): marker = Self.marker(for: .ordered, number: number + 1, indent: parsed.indent)
        case .checkbox: marker = Self.marker(for: .checkbox, indent: parsed.indent)
        case .quote: marker = Self.marker(for: .quote, indent: parsed.indent)
        default: marker = Self.marker(for: .bullet, indent: parsed.indent)
        }
        let insertion = "\n" + marker
        return LAAMarkdownEdit(text: source.replacingCharacters(in: NSRange(location: location, length: 0), with: insertion),
                               selection: NSRange(location: location + (insertion as NSString).length, length: 0))
    }

    /// Tab indents list items, Shift-Tab lifts them. Nil lets the text view
    /// keep its default behaviour.
    static func indentChange(text: String, selection: NSRange, outdent: Bool) -> LAAMarkdownEdit? {
        let lines = LAAMarkdownParser.lines(in: text)
        let targets = linesTouched(by: selection, in: lines, text: text)
        guard !targets.isEmpty, targets.allSatisfy({ isList(block(of: $0)) }) else { return nil }
        let source = NSMutableString(string: text)
        var delta = 0
        for line in targets.sorted(by: { $0.range.location > $1.range.location }) {
            if outdent {
                guard line.indent > 0 else { continue }
                let remove = min(2, line.indent)
                source.replaceCharacters(in: NSRange(location: line.range.location, length: remove), with: "")
                delta -= remove
            } else {
                source.replaceCharacters(in: NSRange(location: line.range.location, length: 0), with: "  ")
                delta += 2
            }
        }
        let length = (source as NSString).length
        let location = min(max(0, selection.location + delta), length)
        let trailing = min(selection.length, length - location)
        return LAAMarkdownEdit(text: source as String,
                               selection: NSRange(location: location, length: max(0, trailing)))
    }

    static func wrapInline(_ marker: String, text: String, selection: NSRange) -> LAAMarkdownEdit {
        let source = text as NSString
        let length = source.length
        let location = min(max(0, selection.location), length)
        let selected = min(selection.length, length - location)
        let markerLength = (marker as NSString).length
        guard markerLength > 0 else { return LAAMarkdownEdit(text: text, selection: selection) }

        if selected == 0 {
            let insertion = marker + marker
            return LAAMarkdownEdit(text: source.replacingCharacters(in: NSRange(location: location, length: 0), with: insertion),
                                   selection: NSRange(location: location + markerLength, length: 0))
        }
        let range = NSRange(location: location, length: selected)
        let inner = source.substring(with: range)
        if (inner as NSString).length >= markerLength * 2, inner.hasPrefix(marker), inner.hasSuffix(marker) {
            let stripped = (inner as NSString).substring(with: NSRange(location: markerLength,
                                                                       length: (inner as NSString).length - markerLength * 2))
            return LAAMarkdownEdit(text: source.replacingCharacters(in: range, with: stripped),
                                   selection: NSRange(location: location, length: (stripped as NSString).length))
        }
        let before = location >= markerLength
            ? source.substring(with: NSRange(location: location - markerLength, length: markerLength)) : ""
        let afterEnd = location + selected
        let after = afterEnd + markerLength <= length
            ? source.substring(with: NSRange(location: afterEnd, length: markerLength)) : ""
        if before == marker, after == marker {
            let outer = NSRange(location: location - markerLength, length: selected + markerLength * 2)
            return LAAMarkdownEdit(text: source.replacingCharacters(in: outer, with: inner),
                                   selection: NSRange(location: location - markerLength, length: selected))
        }
        return LAAMarkdownEdit(text: source.replacingCharacters(in: range, with: marker + inner + marker),
                               selection: NSRange(location: location + markerLength, length: selected))
    }

    /// Puts a table under the caret's line (or replaces an empty line) and
    /// leaves the caret after it, so the grid appears where the person was
    /// writing.
    static func insertTable(text: String, selection: NSRange, columns: Int = 2) -> LAAMarkdownEdit {
        let source = text as NSString
        let count = max(1, columns)
        var table = LAAMarkdownTable(header: (0..<count).map { "見出し\($0 + 1)" },
                                     alignments: Array(repeating: .none, count: count),
                                     rows: [Array(repeating: "", count: count)], rawLines: nil)
        table.normalise()
        let block = table.markdown
        let line = lineRanges(in: text, selection: selection)[0]
        let lineText = source.substring(with: line).trimmingCharacters(in: .whitespaces)
        if lineText.isEmpty {
            return LAAMarkdownEdit(text: source.replacingCharacters(in: line, with: block),
                                   selection: NSRange(location: line.location + (block as NSString).length, length: 0))
        }
        let insertion = "\n" + block
        let at = line.location + line.length
        return LAAMarkdownEdit(text: source.replacingCharacters(in: NSRange(location: at, length: 0), with: insertion),
                               selection: NSRange(location: at + (insertion as NSString).length, length: 0))
    }

    /// Which block a whole line shows, for the format bar's selected state.
    static func blockStyle(at location: Int, in text: String) -> Block {
        let lines = LAAMarkdownParser.lines(in: text)
        guard let line = lines.first(where: { NSLocationInRange(location, $0.range) || location == $0.range.location }) else {
            return .body
        }
        return block(of: line)
    }
}
/// Inline spans inside one line's content: the range to draw with a style and
/// the markers around it to hide. The source text is never changed, so a save
/// keeps every marker exactly as written.
enum LAAMarkdownInline {
    enum Style: Equatable {
        case bold, italic, strike, code, highlight, link
    }

    struct Span: Equatable {
        let style: Style
        let range: NSRange
        let markers: [NSRange]
    }

    private struct Marker {
        let open: String
        let close: String
        let style: Style
        let multiplier: Int
    }

    private static let markers: [Marker] = [
        Marker(open: "**", close: "**", style: .bold, multiplier: 2),
        Marker(open: "__", close: "__", style: .bold, multiplier: 2),
        Marker(open: "~~", close: "~~", style: .strike, multiplier: 2),
        Marker(open: "==", close: "==", style: .highlight, multiplier: 2),
        Marker(open: "`", close: "`", style: .code, multiplier: 1),
        Marker(open: "*", close: "*", style: .italic, multiplier: 1),
        Marker(open: "_", close: "_", style: .italic, multiplier: 1)
    ]

    /// Spans in document coordinates for one line. `contentRange` is the
    /// line's text after its block marker.
    static func spans(in line: String, contentRange: NSRange) -> [Span] {
        let source = line as NSString
        let content = source.substring(with: contentRange) as NSString
        var result: [Span] = []
        var cursor = 0

        while cursor < content.length {
            // Code spans are literal; nothing inside them is styled.
            if content.character(at: cursor) == 0x60 {  // `
                if let close = find("`", in: content, from: cursor + 1) {
                    let textStart = cursor + 1
                    let textLength = close - textStart
                    if textLength > 0 {
                        result.append(Span(style: .code,
                                           range: NSRange(location: contentRange.location + textStart, length: textLength),
                                           markers: [NSRange(location: contentRange.location + cursor, length: 1),
                                                     NSRange(location: contentRange.location + close, length: 1)]))
                    }
                    cursor = close + 1
                    continue
                }
            }
            if content.character(at: cursor) == 0x5B, cursor + 1 < content.length, content.character(at: cursor + 1) == 0x5B {  // [[
                if let close = find("]]", in: content, from: cursor + 2) {
                    let inner = content.substring(with: NSRange(location: cursor + 2, length: close - cursor - 2))
                    let alias = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                    let label = alias.count > 1 ? String(alias[1]) : String(alias[0])
                    let labelStart = cursor + 2 + (alias.count > 1 ? (alias[0] as NSString).length + 1 : 0)
                    result.append(Span(style: .link,
                                       range: NSRange(location: contentRange.location + labelStart, length: (label as NSString).length),
                                       markers: [NSRange(location: contentRange.location + cursor, length: labelStart - cursor),
                                                 NSRange(location: contentRange.location + labelStart + (label as NSString).length,
                                                         length: (inner as NSString).length - (labelStart - cursor - 2) - (label as NSString).length + 2)]))
                    cursor = close + 2
                    continue
                }
            }
            var matched = false
            for marker in markers {
                guard content.range(of: marker.open, options: [], range: NSRange(location: cursor, length: content.length - cursor)).location == cursor else { continue }
                let openEnd = cursor + (marker.open as NSString).length
                guard openEnd < content.length else { continue }
                if marker.open == "*", openEnd < content.length, content.character(at: openEnd) == 0x2A { continue }
                if marker.open == "_", openEnd < content.length, content.character(at: openEnd) == 0x5F { continue }
                guard let close = find(marker.close, in: content, from: openEnd) else { continue }
                let textLength = close - openEnd
                guard textLength > 0, content.character(at: close - 1) != 0x20 else { continue }
                result.append(Span(style: marker.style,
                                   range: NSRange(location: contentRange.location + openEnd, length: textLength),
                                   markers: [NSRange(location: contentRange.location + cursor, length: openEnd - cursor),
                                             NSRange(location: contentRange.location + close, length: (marker.close as NSString).length)]))
                cursor = close + (marker.close as NSString).length
                matched = true
                break
            }
            if matched { continue }
            cursor += 1
        }
        return result
    }

    private static func find(_ needle: String, in source: NSString, from: Int) -> Int? {
        let range = source.range(of: needle, options: [], range: NSRange(location: from, length: source.length - from))
        return range.location == NSNotFound ? nil : range.location
    }
}
#endif
