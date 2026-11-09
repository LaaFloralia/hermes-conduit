#if LAA_BUILD
import SwiftUI

/// The one search field in LAA. Chat, Doc, Studio and Work all draw this same
/// glass capsule, inside the page and above the list, so the control looks the
/// same and sits in the same place in every section. The identifier lands on
/// the text field itself: the UI tests find the field by it, and the clear
/// button takes the same identifier with `.clear` after it.
struct LAASearchField: View {
    let placeholder: String
    @Binding var text: String
    let identifier: String
    /// The screen's own focus, so the Mac's ⌘F can put the cursor here.
    /// Screens without a menu item pass nothing.
    var focus: FocusState<Bool>.Binding? = nil

    var body: some View {
        HStack(spacing: LAASpacing.x3) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(LAAColor.secondaryText)
                .accessibilityHidden(true)
            field
            if !text.isEmpty {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(LAAColor.secondaryText)
                        .frame(minWidth: LAASpacing.minimumTouchTarget,
                               minHeight: LAASpacing.minimumTouchTarget)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: LAACopy.searchClear))
                .accessibilityIdentifier("\(identifier).clear")
                .macTooltip(LAACopy.searchClear)
            }
        }
        // The clear button carries the touch target, so the trailing inset is
        // the gap it leaves around its glyph; the leading one lines the icon up
        // with the text inside a card.
        .padding(.leading, LAASpacing.x4)
        .padding(.trailing, LAASpacing.x1)
        .frame(minHeight: LAASpacing.minimumTouchTarget)
        .laaGlass(in: Capsule())
    }

    @ViewBuilder private var field: some View {
        if let focus {
            textField.focused(focus)
        } else {
            textField
        }
    }

    private var textField: some View {
        TextField("", text: $text,
                  prompt: Text(verbatim: placeholder).foregroundStyle(LAAColor.secondaryText))
            .textFieldStyle(.plain)
            .laaTextStyle(.body)
            .foregroundStyle(LAAColor.text)
            .submitLabel(.search)
            .onSubmit { leaveField() }
            .accessibilityLabel(Text(verbatim: placeholder))
            .accessibilityIdentifier(identifier)
    }

    private func clear() {
        text = ""
        leaveField()
    }

    private func leaveField() {
        guard let focus else { return }
        focus.wrappedValue = false
    }
}

extension LAACopy {
    /// The clear button's name, read by VoiceOver and shown as the Mac's
    /// tooltip. One label for every section's search.
    static let searchClear = "検索を消す"
}
#endif
