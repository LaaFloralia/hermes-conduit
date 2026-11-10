#if LAA_BUILD
import SwiftUI

struct LAAScreenHeader: View {
    let title: String
    var identifier = ""
    var body: some View {
        Text(verbatim: title).font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader).accessibilityIdentifier(identifier)
    }
}

struct LAASectionHeader<MenuContent: View>: View {
    let title: String
    private let menu: MenuContent
    init(_ title: String, @ViewBuilder menu: () -> MenuContent) {
        self.title = title; self.menu = menu()
    }
    var body: some View {
        HStack {
            Text(verbatim: title).laaTextStyle(.section).foregroundStyle(LAAColor.text)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: LAASpacing.x2)
            if MenuContent.self != EmptyView.self {
                Menu { menu } label: {
                    Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
                }
                .foregroundStyle(LAAColor.link)
                .accessibilityLabel(Text(verbatim: "\(title)のメニュー"))
            }
        }.textCase(nil)
    }
}
extension LAASectionHeader where MenuContent == EmptyView {
    init(_ title: String) { self.init(title) { EmptyView() } }
}

/// A section of rows on the same paper background as the screen.
struct LAAListSurface<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct LAAListDivider: View {
    var body: some View { EmptyView() }
}
struct LAAListRow<Content: View>: View {
    private let action: (() -> Void)?
    private let content: Content
    init(action: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.action = action; self.content = content()
    }
    var body: some View {
        if let action {
            Button(action: action) { row }.buttonStyle(LAAListRowStyle())
        } else { row }
    }
    private var row: some View {
        content.laaTextStyle(.rowTitle).foregroundStyle(LAAColor.text)
            .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 4).contentShape(Rectangle())
    }
}
struct LAAListRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? LAAColor.selectionFill : .clear,
                                       in: RoundedRectangle(cornerRadius: 12))
    }
}

struct LAAToolbarIconButton: View {
    let systemName: String
    let label: String
    var identifier = ""
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 20, weight: .regular))
                .foregroundStyle(LAAColor.link).frame(width: 44, height: 44).contentShape(Circle())
        }
        .buttonStyle(.plain).laaGlass(in: Circle())
        .accessibilityLabel(Text(verbatim: label)).accessibilityIdentifier(identifier).macTooltip(label)
    }
}

/// Each control gets a separate ToolbarItem, including on Catalyst.
struct LAAScreenToolbar: ToolbarContent {
    @Environment(\.laaDesktop) private var desktop
    let createLabel: String
    var createIdentifier = ""
    var canCreate = true
    let create: () -> Void
    let settings: () -> Void
    @ToolbarContentBuilder var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            if canCreate { createItem.sharedBackgroundVisibility(.hidden) }
            if !desktop { settingsItem.sharedBackgroundVisibility(.hidden) }
        } else {
            if canCreate { createItem }
            if !desktop { settingsItem }
        }
    }
    private var createItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            LAAToolbarIconButton(systemName: "plus", label: createLabel, identifier: createIdentifier, action: create)
        }
    }
    private var settingsItem: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            LAAToolbarIconButton(systemName: "gearshape", label: "設定", identifier: "laa.settings.open", action: settings)
        }
    }

}

enum LAAButtonKind { case primary, secondary, text, destructive }
struct LAAActionButtonStyle: ButtonStyle {
    let kind: LAAButtonKind
    func makeBody(configuration: Configuration) -> some View {
        LAAActionButtonLabel(kind: kind, isPressed: configuration.isPressed, label: configuration.label)
    }
}
private struct LAAActionButtonLabel<Label: View>: View {
    let kind: LAAButtonKind
    let isPressed: Bool
    let label: Label
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Group {
            if kind == .secondary || kind == .destructive { styledLabel.laaGlass(in: Capsule()) }
            else { styledLabel.background(kind == .primary ? LAAColor.filledButton : .clear, in: Capsule()) }
        }.opacity(!enabled ? 0.45 : isPressed ? 0.7 : 1)
    }
    private var styledLabel: some View {
        label.font(kind == .primary ? .body.weight(.semibold) : .callout.weight(.semibold))
            .foregroundStyle(kind == .primary ? LAAColor.filledButtonText : kind == .destructive ? LAAColor.end : kind == .secondary ? LAAColor.text : LAAColor.link)
            .padding(.horizontal, 20).frame(minHeight: kind == .primary ? 50 : 44)
            .contentShape(Capsule())
    }
}

extension View {
    func laaButton(_ kind: LAAButtonKind = .secondary) -> some View { buttonStyle(LAAActionButtonStyle(kind: kind)) }
}
struct LAAStatusTag: View {
    let title: String
    var attention = false
    var body: some View {
        Text(verbatim: markedTitle).laaTextStyle(.note).fontWeight(.semibold)
            .foregroundStyle(waiting ? LAAColor.background : failed ? LAAColor.attention : complete ? LAAColor.secondaryText : LAAColor.link)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(waiting ? LAAColor.attention : failed || complete ? LAAColor.subtleSurface : LAAColor.selectionFill, in: RoundedRectangle(cornerRadius: 4))
    }
}
private extension LAAStatusTag {
    var waiting: Bool { attention || title.contains("判断待ち") }
    var failed: Bool { title.contains("失敗") }
    var complete: Bool { title.contains("完了") }
    var markedTitle: String {
        guard !["●", "?", "✓", "!"].contains(where: title.hasPrefix) else { return title }
        let mark = waiting ? "?" : failed ? "!" : complete ? "✓" : "●"
        return "\(mark) \(title)"
    }
}

struct LAAActivityDots: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.24)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 0.24) % 3
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle().fill(LAAColor.link)
                        .frame(width: 8, height: 8)
                        .opacity([1.0, 0.60, 0.35][(index - step + 3) % 3])
                }
            }
        }.accessibilityHidden(true)
    }
}

struct LAALoadingDots: View {
    @State private var visible = false

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, minHeight: 88)
            .overlay { if visible { LAAActivityDots() } }
            .accessibilityLabel(Text(verbatim: "読み込み中"))
            .accessibilityHidden(!visible)
            .task {
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                visible = true
            }
    }
}

struct LAAInlineFailure: View {
    let reason: String
    let retry: () -> Void
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: reason).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
            Spacer(minLength: 0)
            Button(action: retry) { Text(verbatim: "再試行") }.laaButton(.text).fixedSize()
        }
    }
}
struct LAAEmptyState: View {
    let message: String
    var body: some View {
        Text(verbatim: message).laaTextStyle(.body).foregroundStyle(LAAColor.secondaryText)
            .multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 112)
    }
}
#endif
