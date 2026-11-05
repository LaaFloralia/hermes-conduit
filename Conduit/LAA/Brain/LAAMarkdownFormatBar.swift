#if LAA_BUILD
import SwiftUI

/// The Liquid Glass format menu above the editor. It acts on the caret and
/// selection of the text run that has focus, the way a word processor's
/// toolbar does, and shows which block the caret is in.
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
        return [
            Item(id: "bold", label: "B", symbol: "bold", accessibility: "太字",
                 action: .inline("**"), selected: false),
            Item(id: "italic", label: "I", symbol: "italic", accessibility: "斜体",
                 action: .inline("*"), selected: false),
            Item(id: "strike", label: "S", symbol: "strikethrough", accessibility: "取り消し線",
                 action: .inline("~~"), selected: false),
            Item(id: "code", label: "`", symbol: "chevron.left.forwardslash.chevron.right", accessibility: "コード",
                 action: .inline("`"), selected: false),
            Item(id: "bullet", label: "•", symbol: "list.bullet", accessibility: "箇条書き",
                 action: .block(.bullet), selected: block == .bullet),
            Item(id: "ordered", label: "1.", symbol: "list.number", accessibility: "番号付きリスト",
                 action: .block(.ordered), selected: block == .ordered),
            Item(id: "checkbox", label: "☑", symbol: "checklist", accessibility: "チェックボックス",
                 action: .checkbox, selected: block == .checkbox),
            Item(id: "quote", label: "❝", symbol: "text.quote", accessibility: "引用",
                 action: .block(.quote), selected: block == .quote)
        ]
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LAASpacing.x2) {
                headingMenu
                Divider().frame(height: 22)
                ForEach(items) { item in
                    Button { session.apply(item.action) } label: {
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
                        .frame(minWidth: LAASpacing.minimumTouchTarget - 8, minHeight: 30)
                        .padding(.horizontal, LAASpacing.x1)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .laaGlass(in: .capsule, selected: item.selected)
                    .accessibilityLabel(Text(verbatim: item.accessibility))
                    .accessibilityIdentifier("laa.markdown.format.\(item.id)")
                }
                Divider().frame(height: 22)
                Button { session.apply(.table) } label: {
                    Image(systemName: "tablecells").font(.callout.weight(.semibold))
                        .frame(minWidth: LAASpacing.minimumTouchTarget - 8, minHeight: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .laaGlass(in: .capsule)
                .accessibilityLabel(Text(verbatim: "表を挿入"))
                .accessibilityIdentifier("laa.markdown.format.table")
            }
            .padding(.horizontal, LAASpacing.x4)
            .padding(.vertical, LAASpacing.x2)
        }
        .scrollClipDisabled()
        .accessibilityIdentifier("laa.markdown.formatBar")
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
            .frame(minWidth: LAASpacing.minimumTouchTarget - 6, minHeight: 30)
            .contentShape(Rectangle())
        }
        .laaGlass(in: .capsule, selected: session.block == .heading1 || session.block == .heading2 || session.block == .heading3)
        .accessibilityLabel(Text(verbatim: "見出し"))
        .accessibilityIdentifier("laa.markdown.format.heading")
    }
}
#endif
