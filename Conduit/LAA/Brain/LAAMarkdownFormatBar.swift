#if LAA_BUILD
import SwiftUI

/// One row above the keyboard; less frequent formats live in the heading menu.
struct LAAMarkdownFormatBar: View {
    @ObservedObject var session: LAAMarkdownEditingSession
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 0) {
            control("checkbox", "checklist", LAACopy.Brain.checklist, .block(.checkbox), selected: session.block == .checkbox)
            control("bullet", "list.bullet", LAACopy.Brain.bullet, .block(.bullet), selected: session.block == .bullet)
            control("ordered", "list.number", LAACopy.Brain.ordered, .block(.ordered), selected: session.block == .ordered)
            Menu {
                Button("見出し1") { session.apply(.block(.heading1)) }
                Button("見出し2") { session.apply(.block(.heading2)) }
                Button("見出し3") { session.apply(.block(.heading3)) }
                Button("本文") { session.apply(.block(.body)) }
                Divider()
                Button("引用") { session.apply(.block(.quote)) }
                Button("太字") { session.apply(.inline("**")) }
                Button("斜体") { session.apply(.inline("*")) }
                Button("コード") { session.apply(.inline("`")) }
                Button("表を挿入") { session.apply(.table) }
                    .accessibilityIdentifier("laa.markdown.format.table")
            } label: { glyph("textformat", selected: isHeading) }
                .accessibilityLabel(Text(verbatim: LAACopy.Brain.format))
                .accessibilityIdentifier("laa.markdown.format.heading")
            control("outdent", "decrease.indent", LAACopy.Brain.outdent, .indent(outdent: true))
            control("indent", "increase.indent", LAACopy.Brain.indent, .indent(outdent: false))
            control("undo", "arrow.uturn.backward", LAACopy.Brain.undo, .undo)
                .contextMenu { Button("やり直す") { session.apply(.redo) } }
            control("dismiss", "keyboard.chevron.compact.down", LAACopy.Brain.dismissKeyboard, .dismissKeyboard)
        }
        .frame(maxWidth: .infinity)
        .modifier(LAAFormatBarGlass())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("laa.markdown.formatBar")
    }

    private var isHeading: Bool {
        session.block == .heading1 || session.block == .heading2 || session.block == .heading3
    }

    private func control(_ id: String, _ symbol: String, _ label: String,
                         _ action: LAAMarkdownEditingSession.Action, selected: Bool = false) -> some View {
        Button { session.apply(action) } label: { glyph(symbol, selected: selected) }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: label))
            .accessibilityIdentifier("laa.markdown.format.\(id)")
    }

    private func glyph(_ symbol: String, selected: Bool) -> some View {
        Image(systemName: symbol)
            .font(.callout.weight(.medium))
            .foregroundStyle(selected ? LAAColor.link : LAAColor.text)
            .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumTouchTarget)
            .frame(minWidth: LAASpacing.minimumTouchTarget)
            .background {
                if selected { Circle().fill(LAAColor.selectionFill).padding(LAASpacing.x1) }
            }
            .contentShape(Rectangle())
    }
}

private struct LAAFormatBarGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(LAAColor.surface, in: Capsule())
                .overlay { Capsule().strokeBorder(LAAColor.separator, lineWidth: 1) }
        }
    }
}
#endif
