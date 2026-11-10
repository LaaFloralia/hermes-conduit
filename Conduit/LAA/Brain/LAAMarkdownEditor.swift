#if LAA_BUILD
import SwiftUI

/// Editing a note as formatted Markdown: headings, lists, checkboxes and
/// tables read the way the saved note will, and the format bar changes the
/// block under the caret. The Markdown itself is still the document — nothing
/// is converted to a private rich-text format.
struct LAAMarkdownEditor: View {
    @StateObject private var model: LAAMarkdownDocumentModel
    @StateObject private var session = LAAMarkdownEditingSession()
    private struct AttachmentSelection: Identifiable { let id: UUID }
    @State private var attachmentSelection: AttachmentSelection?
    @State private var attachmentSource = ""
    @State private var heights: [UUID: CGFloat] = [:]
    let autoFocus: Bool
    let isEnabled: Bool
    var title: String? = nil
    var status: String? = nil
    var readingPositions: LAABrainReadingPositions? = nil
    var positionKey = ""
    var attachments: ((String) -> AnyView)? = nil
    var onOpenLink: ((String) -> Void)? = nil
    /// The draft as the save sheet holds it; a change that the editor did not
    /// make (a restored version, the other side of a conflict) reloads the
    /// document instead of leaving the old text under the caret.
    private let incomingText: String

    init(text: String, autoFocus: Bool = false, isEnabled: Bool = true,
         title: String? = nil, status: String? = nil,
         readingPositions: LAABrainReadingPositions? = nil, positionKey: String = "",
         attachments: ((String) -> AnyView)? = nil,
         onOpenLink: ((String) -> Void)? = nil,
         onChange: @escaping (String) -> Void) {
        _model = StateObject(wrappedValue: LAAMarkdownDocumentModel(text: text, onChange: onChange))
        self.incomingText = text
        self.autoFocus = autoFocus
        self.isEnabled = isEnabled
        self.title = title; self.status = status
        self.readingPositions = readingPositions; self.positionKey = positionKey
        self.onOpenLink = onOpenLink; self.attachments = attachments
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: LAASpacing.x3) {
                    if let title {
                        VStack(alignment: .leading, spacing: LAASpacing.x2) {
                            Text(verbatim: title).font(.custom("Georgia", size: 34, relativeTo: .largeTitle))
                                .foregroundStyle(LAAColor.text).accessibilityIdentifier("laa.brain.note.title")
                            if let status {
                                Text(verbatim: status).font(.caption).foregroundStyle(LAAColor.secondaryText)
                                    .accessibilityIdentifier("laa.brain.edit.status")
                            }
                        }.padding(.bottom, LAASpacing.x3)
                    }
                    ForEach(model.segments) { segment in
                        segmentView(segment)
                    }
                }
                .frame(width: max(0, geometry.size.width - LAASpacing.horizontal * 2), alignment: .leading)
                .padding(.horizontal, LAASpacing.horizontal)
                .padding(.vertical, LAASpacing.x3)
            }
            .modifier(BrainEditorReadingPosition(store: readingPositions, key: positionKey))
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if session.isEditing {
                LAAMarkdownFormatBar(session: session)
                    .padding(.horizontal, LAASpacing.x3)
                    .padding(.vertical, LAASpacing.x1)
                }
            }
        }
        .background(LAAColor.background)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in session.editingChanged(true) }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in session.editingChanged(false) }
        .sheet(item: $attachmentSelection) { selected in
            NavigationStack {
                TextEditor(text: $attachmentSource).font(.body.monospaced()).padding(LAASpacing.x4)
                    .navigationTitle("添付のリンク")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { attachmentSelection = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("適用") { model.updateAttachment(selected.id, source: attachmentSource); attachmentSelection = nil }
                        }
                    }
            }
        }
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
                onOpenLink: onOpenLink,
                onTextChange: { model.updateText(segment.id, text: $0) },
                onSelectionChange: { _ in model.activeTextSegment = segment.id }
            )
            .frame(height: heights[segment.id] ?? LAASpacing.minimumTouchTarget)
            .id(segment.id)
        case .attachment(let source):
            Group {
                if let attachments { attachments(source) }
                else { Text(verbatim: source).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }.id(segment.id)
                .contextMenu { Button("リンクを編集") { attachmentSource = source; attachmentSelection = AttachmentSelection(id: segment.id) } }
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
private struct BrainEditorReadingPosition: ViewModifier {
    let store: LAABrainReadingPositions?
    let key: String
    @ViewBuilder func body(content: Content) -> some View {
        if let store { content.modifier(LAABrainReadingPosition(store: store, key: key, loaded: true, hasAnchor: false)) }
        else { content }
    }
}
#endif
