#if LAA_BUILD
import SwiftUI

/// Editing a note as formatted Markdown: headings, lists, checkboxes and
/// tables read the way the saved note will, and the format bar changes the
/// block under the caret. The Markdown itself is still the document — nothing
/// is converted to a private rich-text format.
struct LAAMarkdownEditor: View {
    @StateObject private var model: LAAMarkdownDocumentModel
    @StateObject private var session = LAAMarkdownEditingSession()
    @State private var heights: [UUID: CGFloat] = [:]
    let autoFocus: Bool
    let isEnabled: Bool
    /// The draft as the save sheet holds it; a change that the editor did not
    /// make (a restored version, the other side of a conflict) reloads the
    /// document instead of leaving the old text under the caret.
    private let incomingText: String

    init(text: String, autoFocus: Bool = false, isEnabled: Bool = true,
         onChange: @escaping (String) -> Void) {
        _model = StateObject(wrappedValue: LAAMarkdownDocumentModel(text: text, onChange: onChange))
        self.incomingText = text
        self.autoFocus = autoFocus
        self.isEnabled = isEnabled
    }

    var body: some View {
        VStack(spacing: 0) {
            LAAMarkdownFormatBar(session: session)
                .background(LAAColor.background)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: LAASpacing.x3) {
                    ForEach(model.segments) { segment in
                        segmentView(segment)
                    }
                }
                .padding(.horizontal, LAASpacing.x4)
                .padding(.vertical, LAASpacing.x3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(LAAColor.background)
        .onAppear { session.onInsertTable = { insertTable() } }
        .onChange(of: incomingText) { _, newValue in
            // Only a draft the editor did not produce (a restored version or
            // the other side of a conflict) reaches this: the editor's own
            // edits already equal the model's text.
            guard newValue != model.sourceText else { return }
            session.resignForStructureChange()
            model.reload(newValue)
        }
    }

    @ViewBuilder private func segmentView(_ segment: LAAMarkdownDocumentModel.Segment) -> some View {
        switch segment.content {
        case .text(let text):
            LAAMarkdownTextView(
                text: text,
                session: session,
                height: Binding(get: { heights[segment.id] ?? LAASpacing.minimumTouchTarget },
                                set: { heights[segment.id] = $0 }),
                autoFocus: autoFocus && firstTextSegment == segment.id,
                isEnabled: isEnabled,
                identifier: "laa.brain.edit.text",
                onTextChange: { model.updateText(segment.id, text: $0) },
                onSelectionChange: { _ in model.activeTextSegment = segment.id }
            )
            .frame(height: heights[segment.id] ?? LAASpacing.minimumTouchTarget)
            .id(segment.id)
        case .table:
            LAAMarkdownTableEditor(model: model, segmentID: segment.id)
                .id(segment.id)
        }
    }

    private var firstTextSegment: UUID? {
        model.segments.first { if case .text = $0.content { return true }; return false }?.id
    }

    private func insertTable() {
        guard model.insertTable(selection: session.selection, into: model.activeTextSegment) else { return }
        session.resignForStructureChange()
    }
}
#endif
