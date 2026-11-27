import SwiftUI

// Rows for the settings card that the app icon opens (tokens `tabBar.iphone.card`). The card is glass; these
// rows sit on it directly — never glass themselves (no nesting), separated by 1 pt `rule` lines. Rows are the
// settings the owner changes most, as direct controls, then one `LAASettingsCardEntry` to the full settings.

/// A setting row: icon, short name, and its control on the right (toggle, choice, status + action).
public struct LAASettingsCardRow<Trailing: View>: View {
    let title: String
    let icon: LAAIcon
    let trailing: Trailing
    @Environment(\.laaPalette) private var palette

    public init(_ title: String, icon: LAAIcon, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.icon = icon
        self.trailing = trailing()
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    public var body: some View {
        Group {
            // Accessibility sizes: the control moves under its name, at full width, so neither wraps per letter.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: LAASpace.s4) {
                    label
                    trailing
                }
                .padding(.vertical, LAASpace.s8)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: LAASpace.s12) {
                    label
                    Spacer(minLength: LAASpace.s8)
                    trailing
                }
            }
        }
        .frame(minHeight: LAATabBarToken.Card.row)
        .accessibilityElement(children: .combine)
    }

    private var label: some View {
        HStack(spacing: LAASpace.s12) {
            LAAIconImage(icon, size: LAAIconSize.row)
                .foregroundStyle(palette.textMuted)
            Text(title)
                .laaFont(LAAPlatform.current.canvas.body)
                .foregroundStyle(palette.text)
                .lineLimit(2)
                .layoutPriority(1)
        }
    }
}

/// A row that opens something (a settings page, the full settings). No trailing chevron (DESIGN.md: no ">").
public struct LAASettingsCardButton: View {
    let title: String
    let icon: LAAIcon
    let value: String?
    let action: () -> Void
    @Environment(\.laaPalette) private var palette

    public init(_ title: String, icon: LAAIcon, value: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.value = value; self.action = action
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    public var body: some View {
        Button(action: action) {
            HStack(spacing: LAASpace.s12) {
                LAAIconImage(icon, size: LAAIconSize.row)
                    .foregroundStyle(palette.accent)
                // Accessibility sizes: the value sits under the name instead of beside it.
                let stack = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                                                         : AnyLayout(HStackLayout(spacing: LAASpace.s8))
                stack {
                    Text(title)
                        .laaFont(LAAPlatform.current.canvas.body)
                        .foregroundStyle(palette.text)
                        .lineLimit(2)
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    if let value {
                        Text(value)
                            .laaFont(LAAPlatform.current.canvas.small)
                            .foregroundStyle(palette.textMuted)
                            .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: LAATabBarToken.Card.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(LAACardRowPressStyle())
    }
}

public extension EnvironmentValues {
    /// Closes the card that hosts these rows (the bar collapses, the sidebar popover closes). Rows that open
    /// another surface call it first.
    @Entry var laaCloseSettingsCard: (@MainActor () -> Void)? = nil
}

/// The last row: the full settings. Closes the card, then opens Settings.
public struct LAASettingsCardEntry: View {
    let action: () -> Void
    @Environment(\.laaCloseSettingsCard) private var close
    public init(action: @escaping () -> Void) { self.action = action }
    public var body: some View {
        LAASettingsCardButton("Settings", icon: .settings) {
            close?()
            action()
        }
        .accessibilityIdentifier("laa.tabbar.settings")
        .modifier(LAACardPinned())
    }
}

@available(iOS 18, macOS 15, watchOS 11, *)
extension ContainerValues {
    /// Set by `LAASettingsCardEntry`: the glass card keeps it below its scrolling rows.
    @Entry var laaCardPinned = false
}

private struct LAACardPinned: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, watchOS 11, *) {
            content.containerValue(\.laaCardPinned, true)
        } else {
            content
        }
    }
}

/// 1 pt `rule` between rows.
public struct LAASettingsCardDivider: View {
    @Environment(\.laaPalette) private var palette
    public init() {}
    public var body: some View {
        Rectangle().fill(palette.rule).frame(height: LAAStroke.rule).accessibilityHidden(true)
    }
}

/// 2–4 short options inside the card, without glass: the chosen one on the `selection` face (corner 12).
public struct LAASettingsCardChoice<ID: Hashable>: View {
    public struct Option: Identifiable {
        public let id: ID
        public let label: String
        public init(_ id: ID, _ label: String) { self.id = id; self.label = label }
    }

    @Binding var selection: ID
    let options: [Option]
    let name: String
    @Namespace private var space
    @Environment(\.laaPalette) private var palette
    @LAAReduceMotion private var reduceMotion

    public init(_ name: String, selection: Binding<ID>, options: [Option]) {
        self.name = name
        _selection = selection
        self.options = options
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let on = option.id == selection
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: LAAMotionToken.snappy.response,
                                                               dampingFraction: LAAMotionToken.snappy.damping)) {
                        selection = option.id
                    }
                } label: {
                    Text(option.label)
                        .laaFont(LAAPlatform.current.canvas.small, weight: on ? .semibold : .regular)
                        .foregroundStyle(on ? palette.accent : palette.textMuted)
                        .lineLimit(1)
                        .padding(.horizontal, LAASpace.s8)
                        .frame(minHeight: LAAControl.IPhone.compact.height)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: LAARadius.selection, style: .continuous)
                                    .fill(palette.selection)
                                    .modifier(Matched(id: "choice", space: space, enabled: !reduceMotion))
                            }
                        }
                        .frame(minHeight: LAAControl.IPhone.hitArea)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(option.label))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(name))
        .sensoryFeedback(.selection, trigger: selection)
    }
}

struct LAACardRowPressStyle: ButtonStyle {
    @Environment(\.laaPalette) private var palette
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: LAARadius.selection, style: .continuous)
                    .fill(palette.selection)
                    .padding(.horizontal, -LAASpace.s8)
                    .opacity(configuration.isPressed ? 1 : 0)
            }
    }
}

/// Mac and iPad sidebar: the app icon and name at the foot of the sidebar; it opens the same card as a popover.
public struct LAASidebarAppEntry<Card: View>: View {
    let app: LAAAppIdentity
    let card: () -> Card
    @State private var open = false
    @Environment(\.laaPalette) private var palette

    public init(app: LAAAppIdentity, @ViewBuilder card: @escaping () -> Card) {
        self.app = app
        self.card = card
    }

    public var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: LAASpace.s8) {
                app.icon.resizable().scaledToFill()
                    .frame(width: LAAIconSize.tab, height: LAAIconSize.tab)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                Text(app.name)
                    .font(.system(size: LAAPlatform.current.canvas.small, weight: .medium))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(minHeight: LAAPlatform.current == .mac ? LAAControl.Mac.hitArea : LAAControl.IPhone.hitArea)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(app.name.isEmpty ? "Settings" : "\(app.name), Settings"))
        .accessibilityIdentifier("laa.sidebar.app")
        .popover(isPresented: $open, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: LAASpace.s12) {
                    app.icon.resizable().scaledToFill()
                        .frame(width: LAATabBarToken.Card.headerIcon, height: LAATabBarToken.Card.headerIcon)
                        .clipShape(Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(app.name).laaFont(LAAPlatform.current.canvas.heading, weight: .semibold)
                            .foregroundStyle(palette.text)
                        Text(app.version).font(.system(size: LAAPlatform.current.canvas.label).monospacedDigit())
                            .foregroundStyle(palette.textMuted)
                    }
                }
                .padding(.bottom, LAASpace.s8)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                card()
            }
            .environment(\.laaCloseSettingsCard, { open = false })
            .padding(LAATabBarToken.Card.padding)
            .frame(width: 320)
            .environment(\.laaPalette, palette)
        }
    }
}
