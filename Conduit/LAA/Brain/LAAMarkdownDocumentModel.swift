#if LAA_BUILD
import SwiftUI

/// The note being edited, as the text runs and tables the editor lays out.
/// Text edits do not republish the whole document (that would redraw the
/// editor under the keyboard on every keystroke); only structural changes —
/// a table added or removed — do.
@MainActor
final class LAAMarkdownDocumentModel: ObservableObject {
    struct Segment: Identifiable {
        enum Content {
            case text(String)
            case table(LAAMarkdownTable)
        }
        let id: UUID
        var content: Content
        /// An empty run offered after a table that ends the note, so there is
        /// somewhere to put the caret and keep writing. While it stays empty it
        /// is not part of the saved text, and saving does not add a newline.
        var isTrailingEntry = false

        var isEmptyText: Bool {
            if case .text(let text) = content { return text.isEmpty }
            return false
        }
    }

    private(set) var segments: [Segment]
    @Published private(set) var revision = 0
    /// The text run the caret was last in, so the format bar's table button
    /// inserts where the person is writing.
    var activeTextSegment: UUID?

    private let onChange: (String) -> Void

    init(text: String, onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        self.segments = Self.build(text)
        self.activeTextSegment = segments.first { if case .text = $0.content { return true }; return false }?.id
    }

    /// The document text, rebuilt through the parser so it always joins the
    /// same way it was split. An untouched trailing entry contributes nothing,
    /// so opening and saving a table-only note writes the same bytes back.
    var sourceText: String {
        LAAMarkdownParser.text(from: segments.filter { !($0.isTrailingEntry && $0.isEmptyText) }.map { segment -> LAAMarkdownSegment in
            switch segment.content {
            case .text(let text): return .text(text)
            case .table(let table): return .table(table)
            }
        })
    }

    /// Takes a draft the editor did not type: restoring a version from the
    /// history, or the other side of a save conflict. Without this the grid
    /// and text views would keep the old text and the next keystroke would
    /// write it over the restored version.
    func reload(_ text: String) {
        guard text != sourceText else { return }
        segments = Self.build(text)
        activeTextSegment = segments.first { if case .text = $0.content { return true }; return false }?.id
        revision += 1
    }

    private static func build(_ text: String) -> [Segment] {
        var result = LAAMarkdownParser.segments(in: text).map { segment -> Segment in
            switch segment {
            case .text(let text): return Segment(id: UUID(), content: .text(text))
            case .table(let table): return Segment(id: UUID(), content: .table(table))
            }
        }
        // A note that ends on a table row has no text run after it, so the
        // caret has nowhere to go and the toolbar has no run to insert into.
        // Offer an empty one; it disappears from the saved text while empty.
        if case .table? = result.last?.content {
            result.append(Segment(id: UUID(), content: .text(""), isTrailingEntry: true))
        }
        return result
    }

    func segment(_ id: UUID) -> Segment? { segments.first { $0.id == id } }

    func updateText(_ id: UUID, text: String) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].content = .text(text)
        onChange(sourceText)
    }

    func table(_ id: UUID) -> LAAMarkdownTable? {
        guard let segment = segments.first(where: { $0.id == id }), case .table(let table) = segment.content else { return nil }
        return table
    }

    func updateTable(_ id: UUID, table: LAAMarkdownTable) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        guard case .table(let existing) = segments[index].content, existing != table else { return }
        // A cell edit is not structural: republishing here would re-render the
        // grid and the focused field under the IME on every keystroke. The
        // grid reads this model, so it never edits a stale snapshot.
        segments[index].content = .table(table)
        onChange(sourceText)
    }

    /// Rows and columns added or removed change the grid's shape, so those do
    /// republish.
    func updateTableStructure(_ id: UUID, table: LAAMarkdownTable) {
        updateTable(id, table: table)
        revision += 1
    }

    func removeTable(_ id: UUID) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments.remove(at: index)
        if segments.isEmpty { segments = [Segment(id: UUID(), content: .text(""), isTrailingEntry: true)] }
        ensureTrailingEntry()
        onChange(sourceText)
        revision += 1
    }

    /// Puts a table where the caret is and splits the run around it, so the
    /// grid is editable immediately. A table written straight after another
    /// one reads back as a single table, so a blank line is kept between the
    /// runs that hold them — the document is only split at table boundaries,
    /// and the neighbouring table is in the next run.
    func insertTable(selection: NSRange, into segmentID: UUID? = nil) {
        let id = segmentID ?? activeTextSegment
            ?? segments.first(where: { if case .text = $0.content { return true }; return false })?.id
        guard let id, let index = segments.firstIndex(where: { $0.id == id }),
              case .text(let text) = segments[index].content else { return }
        var edit = LAAMarkdownFormat.insertTable(text: text, selection: selection)
        if index > 0, isTable(segments[index - 1]), Self.startsWithTableRow(edit.text) {
            edit = LAAMarkdownEdit(text: "\n" + edit.text,
                                   selection: NSRange(location: edit.selection.location + 1,
                                                      length: edit.selection.length))
        }
        if index + 1 < segments.count, isTable(segments[index + 1]), Self.endsWithTableRow(edit.text) {
            edit = LAAMarkdownEdit(text: edit.text + "\n", selection: edit.selection)
        }
        let replacement = LAAMarkdownParser.segments(in: edit.text).map { segment -> Segment in
            switch segment {
            case .text(let text): return Segment(id: UUID(), content: .text(text))
            case .table(let table): return Segment(id: UUID(), content: .table(table))
            }
        }
        segments.replaceSubrange(index...index, with: replacement)
        if case .text(let first)? = segments.first?.content, first.isEmpty, segments.count > 1 {
            segments.removeFirst()
        }
        ensureTrailingEntry()
        onChange(sourceText)
        revision += 1
    }

    /// A note that ends on a table row has no run for the caret: after a table
    /// is added or removed, put the empty entry back. It costs no bytes while
    /// it stays empty, so an untouched save is unchanged.
    private func ensureTrailingEntry() {
        if case .table? = segments.last?.content {
            segments.append(Segment(id: UUID(), content: .text(""), isTrailingEntry: true))
        }
    }

    private func isTable(_ segment: Segment) -> Bool {
        if case .table = segment.content { return true }
        return false
    }

    private static func startsWithTableRow(_ text: String) -> Bool {
        guard let first = LAAMarkdownParser.split(text).first else { return false }
        return first.trimmingCharacters(in: .whitespaces).hasPrefix("|")
    }

    private static func endsWithTableRow(_ text: String) -> Bool {
        guard let last = LAAMarkdownParser.split(text).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return false }
        return last.trimmingCharacters(in: .whitespaces).hasPrefix("|")
    }
}
#endif
