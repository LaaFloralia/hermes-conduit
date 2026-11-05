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
    /// same way it was split.
    var sourceText: String {
        LAAMarkdownParser.text(from: segments.map { segment -> LAAMarkdownSegment in
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
        LAAMarkdownParser.segments(in: text).map { segment in
            switch segment {
            case .text(let text): return Segment(id: UUID(), content: .text(text))
            case .table(let table): return Segment(id: UUID(), content: .table(table))
            }
        }
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
        if segments.isEmpty { segments = [Segment(id: UUID(), content: .text(""))] }
        onChange(sourceText)
        revision += 1
    }

    /// Puts a table where the caret is and splits the run around it, so the
    /// grid is editable immediately.
    func insertTable(selection: NSRange) {
        let id = activeTextSegment ?? segments.first(where: { if case .text = $0.content { return true }; return false })?.id
        guard let id, let index = segments.firstIndex(where: { $0.id == id }),
              case .text(let text) = segments[index].content else { return }
        let edit = LAAMarkdownFormat.insertTable(text: text, selection: selection)
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
        onChange(sourceText)
        revision += 1
    }
}
#endif
