#if LAA_BUILD
import SwiftUI

/// The Liquid Glass format menu above the editor. It acts on the caret and
/// selection of the text run that has focus, the way a word processor's
/// toolbar does, and shows which block the caret is in.
/// One sheet of glass holds the whole row; the glyphs are plain and only the
/// block under the caret is filled.
private enum LAAMarkdownBarMetrics {
    static let content: CGFloat = 36
    static let height: CGFloat = 54
}

struct LAAMarkdownFormatBar: View {
    @ObservedObject var session: LAAMarkdownEditingSession

    private struct Item: Identifiable {
        let id: String
        let label: String
        let symbol: String
        let accessibility: String
        let action: LAAMarkdownEditingSession.Action
        let selected: Bool
    }

    private var items: [Item] {
        let block = session.block
        // The owner's block formats come first, so they stay on a 440pt screen
        // without scrolling; the character formats follow.
        return [
            Item(id: "bullet", label: "•", symbol: "list.bullet", accessibility: "箇条書き",
                 action: .block(.bullet), selected: block == .bullet),
            Item(id: "ordered", label: "1.", symbol: "list.number", accessibility: "番号付きリスト",
                 action: .block(.ordered), selected: block == .ordered),
            Item(id: "checkbox", label: "☑", symbol: "checklist", accessibility: "チェックボックス",
                 action: .checkbox, selected: block == .checkbox),
            Item(id: "quote", label: "❝", symbol: "text.quote", accessibility: "引用",
                 action: .block(.quote), selected: block == .quote),
            Item(id: "bold", label: "B", symbol: "bold", accessibility: "太字",
                 action: .inline("**"), selected: false),
            Item(id: "italic", label: "I", symbol: "italic", accessibility: "斜体",
                 action: .inline("*"), selected: false),
            Item(id: "strike", label: "S", symbol: "strikethrough", accessibility: "取り消し線",
                 action: .inline("~~"), selected: false),
            Item(id: "code", label: "`", symbol: "chevron.left.forwardslash.chevron.right", accessibility: "コード",
                 action: .inline("`"), selected: false)
        ]
    }

    var body: some View {
        // The bar is one row tall, and the row itself is the glass: ten
        // separate pieces of glass in one line were neither the HIG's
        // "sparingly" nor cheap to composite while scrolling. The table
        // action sits outside the scroll view, pinned to the trailing edge,
        // so it is reachable on a 440pt screen without scrolling.
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LAASpacing.x1) {
                    headingMenu
                    Divider().frame(height: 22)
                    ForEach(items) { item in
                        Button { session.apply(item.action) } label: {
                            formatGlyph(item)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: item.accessibility))
                        .accessibilityIdentifier("laa.markdown.format.\(item.id)")
                    }
                }
                .padding(.horizontal, LAASpacing.x2)
            }
            Button { session.apply(.table) } label: {
                Image(systemName: "tablecells").font(.callout.weight(.semibold))
                    .foregroundStyle(LAAColor.text)
                    .frame(minWidth: LAAMarkdownBarMetrics.content, minHeight: LAAMarkdownBarMetrics.content)
                    .padding(.horizontal, LAASpacing.x1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "表を挿入"))
            .accessibilityIdentifier("laa.markdown.format.table")
            .padding(.trailing, LAASpacing.x2)
        }
        .frame(height: LAAMarkdownBarMetrics.height)
        .modifier(LAAFormatBarGlass())
        // `contain` keeps the bar itself addressable while each button keeps
        // its own identifier: a bare identifier on a container is inherited by
        // its direct children, which hid the pinned table button from tests
        // and VoiceOver alike.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("laa.markdown.formatBar")
    }

    @ViewBuilder private func formatGlyph(_ item: Item) -> some View {
        Group {
            if item.id == "bold" || item.id == "italic" {
                Text(verbatim: item.label).font(.callout.weight(.semibold))
            } else if item.id == "strike" {
                Text(verbatim: item.label).strikethrough()
            } else if item.id == "code" {
                Text(verbatim: item.label).font(.system(.callout, design: .monospaced))
            } else {
                Text(verbatim: item.label).font(.callout.weight(.semibold))
            }
        }
        .foregroundStyle(item.selected ? LAAColor.link : LAAColor.text)
        .frame(minWidth: LAAMarkdownBarMetrics.content, minHeight: LAAMarkdownBarMetrics.content)
        // The fill covers the 44pt-wide target, not just the glyph.
        .padding(.horizontal, LAASpacing.x1)
        .background {
            if item.selected {
                Capsule().fill(LAAColor.selectionFill)
            }
        }
        .contentShape(Rectangle())
    }

    private var isHeading: Bool {
        session.block == .heading1 || session.block == .heading2 || session.block == .heading3
    }

    private var headingMenu: some View {
        Menu {
            Button { session.apply(.block(.heading1)) } label: {
                Text(verbatim: "見出し1")
            }
            Button { session.apply(.block(.heading2)) } label: {
                Text(verbatim: "見出し2")
            }
            Button { session.apply(.block(.heading3)) } label: {
                Text(verbatim: "見出し3")
            }
            Button { session.apply(.block(.body)) } label: {
                Text(verbatim: "本文")
            }
        } label: {
            HStack(spacing: 2) {
                Text(verbatim: "H").font(.callout.weight(.semibold))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(isHeading ? LAAColor.link : LAAColor.text)
            .frame(minWidth: LAASpacing.minimumTouchTarget - 6, minHeight: LAAMarkdownBarMetrics.content)
            .background {
                if isHeading {
                    Capsule().fill(LAAColor.selectionFill)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(verbatim: "見出し"))
        .accessibilityIdentifier("laa.markdown.format.heading")
    }
}

/// The row's single sheet of glass. Before iOS 26 and with Reduce
/// Transparency it falls back to the opaque card with a hairline, as
/// `LAAGlassControl` does.
private struct LAAFormatBarGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(LAAColor.surface, in: Capsule())
                .overlay { Capsule().strokeBorder(LAAColor.separator, lineWidth: 1) }
        }
    }
}
#endif
