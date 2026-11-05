#if LAA_BUILD
import SwiftUI
import UIKit

/// One editable run of Markdown. UIKit owns the text while it is being typed
/// (so the IME, selection and undo are the system's), and the SwiftUI layer
/// hears about every settled change.
struct LAAMarkdownTextView: UIViewRepresentable {
    let text: String
    let session: LAAMarkdownEditingSession
    @Binding var height: CGFloat
    let autoFocus: Bool
    let isEnabled: Bool
    var identifier: String = ""
    let onTextChange: (String) -> Void
    let onSelectionChange: (NSRange) -> Void

    func makeUIView(context: Context) -> LAAMarkdownUITextView {
        let view = LAAMarkdownUITextView()
        view.delegate = context.coordinator
        view.onCheckboxTap = { [weak view] location in
            guard let view else { return }
            let edit = LAAMarkdownFormat.toggleCheckbox(text: view.text, selection: NSRange(location: location, length: 0))
            view.apply(edit)
        }
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: LAAMarkdownUITextView, context: Context) {
        context.coordinator.parent = self
        view.session = session
        view.isEditable = isEnabled
        if !identifier.isEmpty { view.accessibilityIdentifier = identifier }
        context.coordinator.autoFocus = autoFocus
        if view.text != text, view.markedTextRange == nil {
            if view.isFirstResponder, !view.applying {
                // The editor holding the keyboard is the live text: a model
                // that lags (an IME commit the delegate has not seen yet) must
                // never replace what the person just typed.
                context.coordinator.adoptLiveText(view)
            } else {
                let caret = view.selectedRange
                view.text = text
                view.selectedRange = NSRange(location: min(caret.location, (text as NSString).length), length: 0)
                context.coordinator.restyle(view, full: true)
            }
        }
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            context.coordinator.refreshHeight(view)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LAAMarkdownTextView
        private weak var view: LAAMarkdownUITextView?
        private var lastCaretLine = NSNotFound
        private var lastSelection: NSRange?
        private var styling = false
        var autoFocus = false
        private var didAutoFocus = false
        private var pendingHeight: CGFloat?

        init(parent: LAAMarkdownTextView) {
            self.parent = parent
        }

        func attach(_ view: LAAMarkdownUITextView) {
            self.view = view
            view.session = parent.session
            parent.session.attachIfNeeded(view)
            view.onTextSettled = { [weak self, weak view] in
                guard let self, let view else { return }
                self.sendText(view)
            }
            view.onSelectionSettled = { [weak self, weak view] in
                guard let self, let view else { return }
                self.selectionChanged(view)
            }
            restyle(view, full: true)
            reportSelection(view)
            if autoFocus, !didAutoFocus {
                didAutoFocus = true
                Task { @MainActor [weak view] in view?.becomeFirstResponder() }
            }
        }

        // MARK: UITextViewDelegate

        func textViewDidChange(_ textView: UITextView) {
            guard !styling, !isApplyingEdit(textView) else { return }
            guard (textView as? LAAMarkdownUITextView)?.acceptsLiveStyling == true else { return }
            let caret = textView.selectedRange.location
            restyle(textView, full: requiresFullRestyle(textView.text, caret: caret))
            sendText(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !styling, !isApplyingEdit(textView) else { return }
            selectionChanged(textView)
        }

        private func isApplyingEdit(_ textView: UITextView) -> Bool {
            (textView as? LAAMarkdownUITextView)?.applying == true
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // A paste spans lines the caret's paragraph restyle would miss.
            if text.contains("\n") || (text as NSString).length > 2,
               let markdown = textView as? LAAMarkdownUITextView {
                markdown.needsFullRestyleAfterEdit = true
            }
            guard text == "\n" else { return true }
            guard let markdownView = textView as? LAAMarkdownUITextView, markdownView.acceptsLiveStyling else { return true }
            guard let edit = LAAMarkdownFormat.returnInsertion(text: textView.text, caret: range.location) else { return true }
            markdownView.apply(edit)
            return false
        }

        // MARK: Helpers

        func adoptLiveText(_ textView: UITextView) {
            parent.onTextChange(textView.text)
        }

        private func sendText(_ textView: UITextView) {
            if let markdown = textView as? LAAMarkdownUITextView, markdown.needsFullRestyleAfterEdit {
                markdown.needsFullRestyleAfterEdit = false
                restyle(textView, full: true)
            }
            parent.onTextChange(textView.text)
            refreshHeight(textView)
            reportSelection(textView)
        }

        private func selectionChanged(_ textView: UITextView) {
            reportSelection(textView)
            guard (textView as? LAAMarkdownUITextView)?.acceptsLiveStyling == true else { return }
            let text = textView.text ?? ""
            let lines = LAAMarkdownParser.lines(in: text)
            let caret = textView.selectedRange.location
            let line = lines.first { NSLocationInRange(caret, $0.range) || caret == $0.range.location }
            let location = line?.range.location ?? NSNotFound
            guard location != lastCaretLine else { return }
            let previous = lastCaretLine
            lastCaretLine = location
            // The line being edited shows its inline markers; the one it left
            // hides them again.
            restyle(textView, locations: [previous, location])
        }

        private func reportSelection(_ textView: UITextView) {
            let selection = textView.selectedRange
            // nil until the first report: a segment that opens with the caret
            // at (0,0) still has to hand its id to the model, or a table would
            // be inserted into the segment that was focused before it.
            guard selection != lastSelection else { return }
            lastSelection = selection
            parent.onSelectionChange(selection)
            if let view = textView as? LAAMarkdownUITextView {
                view.session?.caretMoved(in: view)
                view.session?.updateBlock(view)
            }
        }

        private func requiresFullRestyle(_ text: String, caret: Int) -> Bool {
            guard (text as NSString).length < 4000 else { return false }
            let lines = LAAMarkdownParser.lines(in: text)
            guard let line = lines.first(where: { NSLocationInRange(caret, $0.range) || caret == $0.range.location }) else {
                return true
            }
            if case .fence = line.kind { return true }
            return line.text.contains("```") || line.text.contains("~~~")
        }

        /// Applies the styling for `locations` (line starts) plus the lines
        /// around them, leaving the rest of the document untouched so typing
        /// in a long note stays immediate.
        func restyle(_ textView: UITextView, locations: [Int]) {
            let text = textView.text ?? ""
            let lines = LAAMarkdownParser.lines(in: text)
            var target = NSRange(location: NSNotFound, length: 0)
            for location in locations where location != NSNotFound {
                guard let index = lines.firstIndex(where: { $0.range.location == location }) else { continue }
                for offset in [index - 1, index, index + 1] where lines.indices.contains(offset) {
                    target = union(target, lines[offset].range)
                }
            }
            guard target.location != NSNotFound else { return }
            apply(textView, target: target)
        }

        func restyle(_ textView: UITextView, full: Bool) {
            let text = textView.text ?? ""
            let target = NSRange(location: 0, length: (text as NSString).length)
            apply(textView, target: full ? target : dirtyRange(textView, text: text))
            if textView.markedTextRange == nil { refreshHeight(textView) }
        }

        private func dirtyRange(_ textView: UITextView, text: String) -> NSRange {
            let caret = min(max(0, textView.selectedRange.location), (text as NSString).length)
            let lines = LAAMarkdownParser.lines(in: text)
            guard let index = lines.firstIndex(where: { NSLocationInRange(caret, $0.range) || caret == $0.range.location }) else {
                return NSRange(location: 0, length: (text as NSString).length)
            }
            var target = lines[index].range
            if lines.indices.contains(index - 1) { target = union(target, lines[index - 1].range) }
            if lines.indices.contains(index + 1) { target = union(target, lines[index + 1].range) }
            return target
        }

        private func apply(_ textView: UITextView, target: NSRange) {
            let text = textView.text ?? ""
            let output = LAAMarkdownStyler.output(for: text, caretLocation: textView.selectedRange.location, limit: target)
            let storage = textView.textStorage
            let limit = NSRange(location: 0, length: storage.length)
            styling = true
            storage.beginEditing()
            for run in output.runs {
                let clipped = NSIntersectionRange(run.range, limit)
                guard clipped.length > 0 else { continue }
                guard NSIntersectionRange(clipped, target).length > 0 else { continue }
                if run.reset {
                    storage.setAttributes(run.attributes, range: clipped)
                } else {
                    storage.addAttributes(run.attributes, range: clipped)
                }
            }
            storage.endEditing()
            styling = false
            (textView as? LAAMarkdownUITextView)?.glyphs = output.glyphs
        }

        private func union(_ range: NSRange, _ other: NSRange) -> NSRange {
            if range.location == NSNotFound { return other }
            if other.location == NSNotFound { return range }
            let start = min(range.location, other.location)
            let end = max(NSMaxRange(range), NSMaxRange(other))
            return NSRange(location: start, length: end - start)
        }

        func refreshHeight(_ textView: UITextView) {
            let width = textView.bounds.width
            guard width > 0 else { return }
            let size = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            let height = max(LAASpacing.minimumTouchTarget, ceil(size.height))
            guard abs(height - parent.height) > 0.5 else { return }
            pendingHeight = height
            Task { @MainActor [weak self] in
                guard let self, let pending = self.pendingHeight else { return }
                if abs(pending - self.parent.height) > 0.5 { self.parent.height = pending }
            }
        }
    }
}

/// Keeps the selection and offers the format bar one active text run.
@MainActor
final class LAAMarkdownEditingSession: ObservableObject {
    enum Action: Equatable {
        case block(LAAMarkdownFormat.Block)
        case checkbox
        case inline(String)
        case table
    }

    @Published private(set) var block: LAAMarkdownFormat.Block = .body

    weak var textView: LAAMarkdownUITextView?
    private var lastSelection = NSRange(location: 0, length: 0)
    var onInsertTable: (() -> Void)?

    var selection: NSRange { lastSelection }

    func attachIfNeeded(_ view: LAAMarkdownUITextView) {
        guard textView == nil else { return }
        attach(view)
    }

    func attach(_ view: LAAMarkdownUITextView) {
        textView = view
        lastSelection = view.selectedRange
        updateBlock(view)
    }

    /// A structural change (a table appearing) rebuilds the runs, so the old
    /// text view is gone and must not keep the keyboard.
    func resignForStructureChange() {
        textView?.resignFirstResponder()
        textView = nil
    }

    func caretMoved(in view: LAAMarkdownUITextView) {
        lastSelection = view.selectedRange
    }

    func updateBlock(_ view: LAAMarkdownUITextView) {
        let style = LAAMarkdownFormat.blockStyle(at: view.selectedRange.location, in: view.text)
        if style != block { block = style }
    }

    func apply(_ action: Action) {
        guard action != .table else { onInsertTable?(); return }
        guard let view = textView, view.markedTextRange == nil else { return }
        // The bar may be tapped after the keyboard closed: restore the caret
        // the person last placed instead of applying at the file start.
        let selection = view.selectedRange.length > 0 || view.isFirstResponder ? view.selectedRange : lastSelection
        let edit: LAAMarkdownEdit
        switch action {
        case .block(let target):
            edit = LAAMarkdownFormat.setBlock(target, text: view.text, selection: selection)
        case .checkbox:
            edit = LAAMarkdownFormat.toggleCheckbox(text: view.text, selection: selection)
        case .inline(let marker):
            edit = LAAMarkdownFormat.wrapInline(marker, text: view.text, selection: selection)
        case .table:
            return
        }
        view.apply(edit)
        block = LAAMarkdownFormat.blockStyle(at: edit.selection.location, in: edit.text)
    }
}

/// A text view that draws list glyphs in the margin (the characters stay in
/// the source, hidden) and lets a tap on a checkbox tick it.
final class LAAMarkdownUITextView: UITextView {
    var glyphs: [LAAMarkdownStyler.Glyph] = [] {
        didSet { if glyphs != oldValue { setNeedsDisplay() } }
    }
    var onCheckboxTap: ((Int) -> Void)?
    var onTextSettled: (() -> Void)?
    var onSelectionSettled: (() -> Void)?
    weak var session: LAAMarkdownEditingSession?
    private(set) var applying = false
    /// A command replaces the whole document through the text input system,
    /// which drops every attribute it had: the next pass must style all of it,
    /// not only the caret's paragraph.
    var needsFullRestyleAfterEdit = false

    /// False while an IME composes: restyling or replacing characters then
    /// would abandon the conversion the person is in the middle of.
    var acceptsLiveStyling: Bool { markedTextRange == nil }

    init() {
        super.init(frame: .zero, textContainer: nil)
        isEditable = true
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        textContainer.lineFragmentPadding = 0
        showsVerticalScrollIndicator = false
        font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: LAAType.bodySize))
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Whole-document edit from a toolbar command. Goes through the text
    /// input system so one undo step puts the previous text back.
    func apply(_ edit: LAAMarkdownEdit) {
        guard let full = textRange(from: beginningOfDocument, to: endOfDocument) else { return }
        applying = true
        replace(full, withText: edit.text)
        let length = (edit.text as NSString).length
        selectedRange = NSRange(location: min(edit.selection.location, length),
                                length: min(edit.selection.length, max(0, length - min(edit.selection.location, length))))
        applying = false
        needsFullRestyleAfterEdit = true
        typingAttributes = [
            .font: UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: LAAType.bodySize)),
            .foregroundColor: UIColor(LAAColor.text)
        ]
        onTextSettled?()
        onSelectionSettled?()
        setNeedsDisplay()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { session?.attach(self) }
        return accepted
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard !glyphs.isEmpty else { return }
        let ink = UIColor(LAAColor.secondaryText)
        let accent = UIColor(LAAColor.link)
        for glyph in glyphs {
            guard let line = lineRect(for: glyph.lineLocation), line.intersects(rect) else { continue }
            let x = max(line.minX - LAAMarkdownStyler.gutter + 2, 0)
            switch glyph.kind {
            case .bullet:
                let size: CGFloat = 5
                let dot = CGRect(x: x + 5, y: line.midY - size / 2 + 1, width: size, height: size)
                ink.setFill()
                UIBezierPath(ovalIn: dot).fill()
            case .checkbox(let checked):
                let box = CGRect(x: x + 1, y: line.midY - 8, width: 16, height: 16)
                let path = UIBezierPath(roundedRect: box, cornerRadius: 4)
                path.lineWidth = 1.4
                (checked ? accent : ink).setStroke()
                path.stroke()
                if checked {
                    let check = UIBezierPath()
                    check.move(to: CGPoint(x: box.minX + 4, y: box.midY))
                    check.addLine(to: CGPoint(x: box.minX + 7, y: box.maxY - 4))
                    check.addLine(to: CGPoint(x: box.maxX - 3, y: box.minY + 4))
                    check.lineWidth = 2
                    check.lineCapStyle = .round
                    check.lineJoinStyle = .round
                    accent.setStroke()
                    check.stroke()
                }
            }
        }
    }

    private func lineRect(for location: Int) -> CGRect? {
        guard location >= 0, location <= (text as NSString).length,
              let position = position(from: beginningOfDocument, offset: location),
              let range = textRange(from: position, to: position) else { return nil }
        let rect = firstRect(for: range)
        guard rect.height > 0 else { return nil }
        return rect
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        guard let location = checkboxLocation(at: point) else { return }
        onCheckboxTap?(location)
    }

    private func checkboxLocation(at point: CGPoint) -> Int? {
        for glyph in glyphs {
            guard case .checkbox = glyph.kind, let line = lineRect(for: glyph.lineLocation) else { continue }
            let x = max(line.minX - LAAMarkdownStyler.gutter + 2, 0)
            let box = CGRect(x: x, y: line.midY - 12, width: 22, height: 24)
            if box.contains(point) { return glyph.lineLocation }
        }
        return nil
    }
}

extension LAAMarkdownUITextView: UIGestureRecognizerDelegate {
    /// Only a tap on a checkbox is taken from the text view; every other touch
    /// keeps the system's selection and caret behaviour.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer is UITapGestureRecognizer else { return true }
        if checkboxLocation(at: touch.location(in: self)) != nil { return true }
        return false
    }
}
#endif
