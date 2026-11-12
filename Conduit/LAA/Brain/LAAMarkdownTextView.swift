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
    var onOpenLink: ((String) -> Void)? = nil
    let onTextChange: (String) -> Void
    let onSelectionChange: (NSRange) -> Void

    func makeUIView(context: Context) -> LAAMarkdownUITextView {
        let view = LAAMarkdownUITextView()
        view.delegate = context.coordinator
        view.onCheckboxTap = { [weak view] location in
            guard let view else { return }
            let caret = view.selectedRange
            let edit = LAAMarkdownFormat.toggleCheckbox(text: view.text, selection: NSRange(location: location, length: 0))
            view.apply(LAAMarkdownEdit(text: edit.text, selection: caret))
        }
        context.coordinator.autoFocus = autoFocus
        view.requestInitialFocus(autoFocus && isEnabled)
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: LAAMarkdownUITextView, context: Context) {
        context.coordinator.parent = self
        view.session = session
        view.onOpenLink = onOpenLink
        view.isEditable = isEnabled
        view.requestInitialFocus(autoFocus && isEnabled)
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

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: LAAMarkdownUITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        return CGSize(width: width, height: max(LAASpacing.minimumTouchTarget,
                      ceil(uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)))
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
        private var adoptGeneration = 0
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
            // Reporting from inside a view update would publish the format
            // bar's state mid-update; do it on the next run loop turn.
            Task { @MainActor [weak self, weak view] in
                guard let self, let view else { return }
                self.reportSelection(view)
            }
            view.requestInitialFocus(autoFocus)
        }

        // MARK: UITextViewDelegate

        func textViewDidBeginEditing(_ textView: UITextView) {
            // An already-selected (0, 0) caret still changes the active run.
            // Tables and attachments may have several text views around them.
            lastSelection = nil
            reportSelection(textView)
        }

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
            if text == "\t", let markdown = textView as? LAAMarkdownUITextView,
               markdown.acceptsLiveStyling,
               let edit = LAAMarkdownFormat.indentChange(text: textView.text, selection: range, outdent: false) {
                markdown.apply(edit)
                return false
            }
            guard text == "\n" else { return true }
            guard let markdownView = textView as? LAAMarkdownUITextView, markdownView.acceptsLiveStyling else { return true }
            let source = (textView.text as NSString).replacingCharacters(in: range, with: "")
            guard let edit = LAAMarkdownFormat.returnInsertion(text: source, caret: range.location) else { return true }
            markdownView.apply(edit)
            return false
        }

        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange,
                      interaction: UITextItemInteraction) -> Bool {
            guard URL.scheme == "laabrain-source",
                  let target = URLComponents(url: URL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "target" })?.value else { return true }
            parent.onOpenLink?(target)
            return false
        }

        // MARK: Helpers

        /// Called from `updateUIView`: publishing a draft change inside a view
        /// update is not allowed, so the report lands on the next turn. It
        /// reads the text when it lands — never a value captured here — and a
        /// superseded or mid-composition report is dropped, so input that
        /// arrives first is not rolled back to an older draft.
        func adoptLiveText(_ textView: UITextView) {
            adoptGeneration += 1
            let generation = adoptGeneration
            Task { @MainActor [weak self, weak textView] in
                guard let self, let textView,
                      let markdown = textView as? LAAMarkdownUITextView,
                      generation == self.adoptGeneration,
                      let text = markdown.settledTextForAdoption() else { return }
                self.parent.onTextChange(text)
            }
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
                Task { @MainActor [weak view] in
                    guard let view else { return }
                    view.session?.updateBlock(view)
                }
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
            if parent.onOpenLink != nil {
                for link in LAAMarkdownSourceLinks.links(in: text) where NSIntersectionRange(link.range, target).length > 0 {
                    var url = URLComponents(); url.scheme = "laabrain-source"; url.host = "open"
                    url.queryItems = [URLQueryItem(name: "target", value: link.target)]
                    if let value = url.url { storage.addAttribute(.link, value: value, range: link.range) }
                }
            }
            storage.endEditing()
            // Hidden Markdown markers must never become the next character's
            // font. In particular an empty checklist item still has a body-size caret.
            if textView.selectedRange.length == 0, textView.markedTextRange == nil,
               let base = output.runs.last(where: { $0.reset && $0.range.location <= textView.selectedRange.location }) {
                textView.typingAttributes = base.attributes
            }
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
        case indent(outdent: Bool)
        case undo, redo, dismissKeyboard
    }

    @Published private(set) var isEditing = false
    func editingChanged(_ editing: Bool) { if isEditing != editing { isEditing = editing } }

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
        if action == .dismissKeyboard {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            return
        }
        guard action != .table else { onInsertTable?(); return }
        guard let view = textView, view.markedTextRange == nil else { return }
        // The bar may be tapped after the keyboard closed: restore the caret
        // the person last placed instead of applying at the file start.
        let selection = view.selectedRange.length > 0 || view.isFirstResponder ? view.selectedRange : lastSelection
        let edit: LAAMarkdownEdit
        switch action {
        case .dismissKeyboard: view.resignFirstResponder(); return
        case .undo: view.undoManager?.undo(); return
        case .redo: view.undoManager?.redo(); return
        case .indent(let outdent):
            guard let change = LAAMarkdownFormat.indentChange(text: view.text, selection: selection, outdent: outdent) else { return }
            edit = change
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
    var onOpenLink: ((String) -> Void)?
    var onCheckboxTap: ((Int) -> Void)?
    var onTextSettled: (() -> Void)?
    var onSelectionSettled: (() -> Void)?
    weak var session: LAAMarkdownEditingSession?
    private(set) var applying = false
    /// A command replaces the whole document through the text input system,
    /// which drops every attribute it had: the next pass must style all of it,
    /// not only the caret's paragraph.
    var needsFullRestyleAfterEdit = false
    private var wantsInitialFocus = false
    private var didInitialFocus = false
    private var initialFocusScheduled = false

    func requestInitialFocus(_ requested: Bool) {
        wantsInitialFocus = wantsInitialFocus || requested
        fulfillInitialFocus()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        fulfillInitialFocus()
    }

    private func fulfillInitialFocus() {
        guard wantsInitialFocus, !didInitialFocus, !initialFocusScheduled, window != nil, isEditable else { return }
        initialFocusScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.initialFocusScheduled = false
            guard self.window != nil, self.isEditable, !self.didInitialFocus else { return }
            self.didInitialFocus = self.becomeFirstResponder()
        }
    }

    /// False while an IME composes: restyling or replacing characters then
    /// would abandon the conversion the person is in the middle of.
    var acceptsLiveStyling: Bool { markedTextRange == nil }

    /// The text this view may publish right now. Nil while an IME composes or
    /// once the view has left the hierarchy: publishing either would overwrite
    /// a newer draft.
    func settledTextForAdoption() -> String? {
        guard window != nil, acceptsLiveStyling else { return nil }
        return text
    }

    init() {
        super.init(frame: .zero, textContainer: nil)
        isEditable = true
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        alwaysBounceHorizontal = false
        showsHorizontalScrollIndicator = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        adjustsFontForContentSizeCategory = true
        showsVerticalScrollIndicator = false
        font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: LAAType.bodySize))
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = true
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Whole-document edit from a toolbar command. Goes through the text
    /// input system so one undo step puts the previous text back.
    func apply(_ edit: LAAMarkdownEdit) {
        guard markedTextRange == nil else { return }
        // Apply only the changed characters. Selecting and replacing the entire
        // note made UIKit reveal its end before returning to the list caret.
        let old = text ?? ""
        var oldStart = old.startIndex, newStart = edit.text.startIndex
        while oldStart < old.endIndex, newStart < edit.text.endIndex, old[oldStart] == edit.text[newStart] {
            old.formIndex(after: &oldStart); edit.text.formIndex(after: &newStart)
        }
        var oldEnd = old.endIndex, newEnd = edit.text.endIndex
        while oldEnd > oldStart, newEnd > newStart,
              old[old.index(before: oldEnd)] == edit.text[edit.text.index(before: newEnd)] {
            old.formIndex(before: &oldEnd); edit.text.formIndex(before: &newEnd)
        }
        let changed = NSRange(oldStart..<oldEnd, in: old)
        guard let from = position(from: beginningOfDocument, offset: changed.location),
              let to = position(from: from, offset: changed.length), let range = textRange(from: from, to: to) else { return }
        applying = true
        replace(range, withText: String(edit.text[newStart..<newEnd]))
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
        if accepted { session?.attach(self); session?.editingChanged(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { session?.editingChanged(false) }
        return accepted
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // This view is a paragraph inside the document's vertical scroll view.
        // UITextView can still change its internal offset to reveal a caret.
        if contentOffset != .zero { contentOffset = .zero }
        if isFirstResponder, markedTextRange == nil { revealCaretInDocument() }
        setNeedsDisplay()
    }

    private var lastRevealedCaret: CGRect = .null
    private var lastViewportSize: CGSize = .zero
    private var lastViewportInsets = UIEdgeInsets.zero

    // MARK: Caret

    /// UITextView draws the caret as tall as the line's box, and these lines
    /// are 1.7 times their font (headings add space above), so the caret stood
    /// far taller than the text. It is drawn from the typing font's ascender
    /// to its descender on the line's own baseline, read from TextKit 2's line
    /// fragments; when that geometry is unavailable the system's box is kept.
    override func caretRect(for position: UITextPosition) -> CGRect {
        let system = super.caretRect(for: position)
        return textCaretRect(for: position, system: system) ?? system
    }

    /// The line box the system would draw. Revealing the caret keeps using it,
    /// so the whole line, not only its glyphs, scrolls into view as before.
    func systemCaretRect(for position: UITextPosition) -> CGRect {
        super.caretRect(for: position)
    }

    private func textCaretRect(for position: UITextPosition, system: CGRect) -> CGRect? {
        guard !system.isNull, !system.isInfinite, system.height > 0,
              let manager = textLayoutManager else { return nil }
        let offset = self.offset(from: beginningOfDocument, to: position)
        guard let font = caretFont(at: offset),
              let line = caretLine(at: offset, near: system, manager: manager) else { return nil }
        let height = font.ascender - font.descender
        // A blank line is shorter than the text typed into it; a taller caret
        // would reach into the rows around it, so the system's box stays.
        guard height > 0, height <= line.bounds.height else { return nil }
        let scale = max(traitCollection.displayScale, 1)
        // Hidden markers set an empty item's baseline at the box's foot; the
        // caret never hangs below the line.
        let top = (min(line.baseline - font.ascender, line.bounds.maxY - height) * scale).rounded() / scale
        return CGRect(x: system.minX, y: top, width: system.width, height: (height * scale).rounded() / scale)
    }

    /// The font the next character takes: the typing attributes at the caret,
    /// otherwise the text at that position. Hidden Markdown markers (0.1 pt)
    /// never size the caret.
    private func caretFont(at offset: Int) -> UIFont? {
        func visible(_ value: Any?) -> UIFont? {
            guard let font = value as? UIFont, font.pointSize >= 1 else { return nil }
            return font
        }
        let selection = selectedRange
        if selection.length == 0, selection.location == offset || markedTextRange != nil,
           let font = visible(typingAttributes[.font]) {
            return font
        }
        let storage = textStorage
        for index in [offset, offset - 1] where index >= 0 && index < storage.length {
            if let font = visible(storage.attribute(.font, at: index, effectiveRange: nil)) { return font }
        }
        return visible(self.font)
    }

    /// The baseline and box, in this view's coordinates, of the line fragment
    /// the system placed the caret on.
    private func caretLine(at offset: Int, near system: CGRect,
                           manager: NSTextLayoutManager) -> (baseline: CGFloat, bounds: CGRect)? {
        let start = manager.documentRange.location
        var fragments: [NSTextLayoutFragment] = []
        for index in [offset, offset - 1] where index >= 0 {
            guard let location = manager.location(start, offsetBy: index),
                  let fragment = manager.textLayoutFragment(for: location),
                  !fragments.contains(where: { $0 === fragment }) else { continue }
            fragments.append(fragment)
        }
        let inset = textContainerInset
        var best: (baseline: CGFloat, bounds: CGRect, matchesText: Bool, distance: CGFloat)?
        for fragment in fragments {
            let frame = fragment.layoutFragmentFrame
            let local = offset - manager.offset(from: start, to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                let bounds = line.typographicBounds.offsetBy(dx: frame.minX + inset.left, dy: frame.minY + inset.top)
                guard bounds.height > 0 else { continue }
                let range = line.characterRange
                let matchesText = NSLocationInRange(local, range) || NSMaxRange(range) == local
                let distance = abs(bounds.midY - system.midY)
                // Text position first; at a soft wrap both lines hold the
                // offset, and the one the system drew on is the nearer.
                if let current = best,
                   current.matchesText && !matchesText || (current.matchesText == matchesText && current.distance <= distance) {
                    continue
                }
                best = (bounds.minY + line.glyphOrigin.y, bounds, matchesText, distance)
            }
        }
        // A line that does not overlap the system's box is not the caret's.
        guard let best, best.bounds.minY < system.maxY, best.bounds.maxY > system.minY else { return nil }
        return (best.baseline, best.bounds)
    }

    private func revealCaretInDocument() {
        guard let selectedTextRange else { return }
        let caret = systemCaretRect(for: selectedTextRange.end)
        var ancestor = superview
        while let container = ancestor {
            if let scroll = container as? UIScrollView, scroll.isScrollEnabled {
                guard caret != lastRevealedCaret || scroll.bounds.size != lastViewportSize || scroll.adjustedContentInset != lastViewportInsets else { return }
                lastRevealedCaret = caret; lastViewportSize = scroll.bounds.size; lastViewportInsets = scroll.adjustedContentInset
                let target = convert(caret.insetBy(dx: 0, dy: -16), to: scroll)
                scroll.scrollRectToVisible(target, animated: false)
                break
            }
            ancestor = container.superview
        }
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
                let box = checkboxRect(in: line)
                let path = UIBezierPath(ovalIn: box)
                path.lineWidth = 1.4
                if checked {
                    accent.setFill()
                    path.fill()
                    let check = UIBezierPath()
                    check.move(to: CGPoint(x: box.minX + 4, y: box.midY))
                    check.addLine(to: CGPoint(x: box.minX + 7, y: box.maxY - 4))
                    check.addLine(to: CGPoint(x: box.maxX - 3, y: box.minY + 4))
                    check.lineWidth = 2
                    check.lineCapStyle = .round
                    check.lineJoinStyle = .round
                    UIColor(LAAColor.background).setStroke()
                    check.stroke()
                } else {
                    ink.setStroke()
                    path.stroke()
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
        if let location = checkboxLocation(at: point) { onCheckboxTap?(location) }
        else if let target = linkTarget(at: point) { onOpenLink?(target) }
    }

    private func linkTarget(at point: CGPoint) -> String? {
        guard !isFirstResponder, onOpenLink != nil, let position = closestPosition(to: point) else { return nil }
        let location = offset(from: beginningOfDocument, to: position)
        for link in LAAMarkdownSourceLinks.links(in: text) {
            if NSLocationInRange(location, link.range) { return link.target }
        }
        return nil
    }

    func checkboxLocation(at point: CGPoint) -> Int? {
        var nearest: (location: Int, distance: CGFloat)?
        for glyph in glyphs {
            guard case .checkbox = glyph.kind, let line = lineRect(for: glyph.lineLocation) else { continue }
            let target = checkboxRect(in: line).insetBy(dx: -11, dy: -11)
            guard target.contains(point) else { continue }
            let distance = abs(point.y - line.midY)
            if distance < (nearest?.distance ?? .greatestFiniteMagnitude) { nearest = (glyph.lineLocation, distance) }
        }
        return nearest?.location
    }

    private func checkboxRect(in line: CGRect) -> CGRect {
        let size: CGFloat = 22
        let gap: CGFloat = 8
        return CGRect(x: max(line.minX - size - gap, 0), y: line.midY - size / 2, width: size, height: size)
    }
}

extension LAAMarkdownUITextView: UIGestureRecognizerDelegate {
    /// Only a tap on a checkbox is taken from the text view; every other touch
    /// keeps the system's selection and caret behaviour.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer is UITapGestureRecognizer else { return true }
        if checkboxLocation(at: touch.location(in: self)) != nil || linkTarget(at: touch.location(in: self)) != nil { return true }
        return false
    }
}
#endif
