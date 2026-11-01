#if LAA_BUILD
import SwiftUI
import UIKit

enum LAAComposerMarkdown {
    enum Format { case heading, list, bold, code, checkbox }

    /// Operates in UITextView's UTF-16 coordinates and leaves the original
    /// selection inside inline markers. Never replaces marked IME text.
    static func apply(_ format: Format, to view: UITextView) {
        guard view.isEditable, view.markedTextRange == nil else { return }
        let source = view.text as NSString
        let selection = view.selectedRange
        guard selection.location != NSNotFound, selection.location <= source.length,
              selection.length <= source.length - selection.location else { return }
        let selected = source.substring(with: selection)
        let range: NSRange
        let replacement: String
        let resultSelection: NSRange
        switch format {
        case .bold, .code:
            let marker = format == .bold ? "**" : (selected.contains("\n") ? "```\n" : "`")
            let suffix = format == .code && selected.contains("\n") ? "\n```" : marker
            range = selection
            replacement = marker + selected + suffix
            resultSelection = NSRange(location: selection.location + (marker as NSString).length, length: selection.length)
        case .heading, .list, .checkbox:
            let prefix = format == .heading ? "# " : (format == .list ? "- " : "- [ ] ")
            let line = source.lineRange(for: selection)
            let original = source.substring(with: line)
            // Do not create a phantom prefixed line after a trailing newline.
            let endsInNewline = original.hasSuffix("\n")
            let content = endsInNewline ? String(original.dropLast()) : original
            replacement = content.components(separatedBy: "\n").map { prefix + $0 }.joined(separator: "\n") + (endsInNewline ? "\n" : "")
            range = line
            let length = (replacement as NSString).length
            resultSelection = NSRange(location: line.location + length - (endsInNewline ? 1 : 0), length: 0)
        }
        guard let start = view.position(from: view.beginningOfDocument, offset: range.location),
              let end = view.position(from: start, offset: range.length),
              let textRange = view.textRange(from: start, to: end) else { return }
        view.replace(textRange, withText: replacement)
        view.selectedRange = resultSelection
        view.delegate?.textViewDidChange?(view)
        view.scrollRangeToVisible(resultSelection)
    }

    static func install(on view: UITextView, preview: @escaping () -> Void) {
        let bar = UIToolbar()
        bar.sizeToFit()
        let actions: [(String, String, Format)] = [
            ("見出し", "textformat.size", .heading), ("箇条書き", "list.bullet", .list),
            ("太字", "bold", .bold), ("コード", "chevron.left.forwardslash.chevron.right", .code),
            ("チェックボックス", "checklist", .checkbox),
        ]
        let children = actions.map { title, symbol, format in
            UIAction(title: title, image: UIImage(systemName: symbol)) { [weak view] _ in
                guard let view else { return }
                apply(format, to: view)
            }
        }
        let formatting = UIBarButtonItem(title: "書式", image: UIImage(systemName: "textformat"), primaryAction: nil,
                                         menu: UIMenu(children: children))
        formatting.accessibilityIdentifier = "composer.markdown.format"
        let display = UIBarButtonItem(title: "プレビュー", image: UIImage(systemName: "eye"), primaryAction: UIAction { _ in preview() })
        display.accessibilityIdentifier = "composer.markdown.preview"
        bar.items = [formatting, UIBarButtonItem(systemItem: .flexibleSpace), display]
        view.inputAccessoryView = bar
    }
}

struct LAAComposerMarkdownPreview: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                MarkdownText(source: text).frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .navigationTitle(Text(verbatim: "プレビュー"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { dismiss() } label: { Text(verbatim: "閉じる") } } }
        }
    }
}
#endif
