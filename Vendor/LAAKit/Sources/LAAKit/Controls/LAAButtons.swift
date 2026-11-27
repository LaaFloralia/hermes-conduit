import SwiftUI

extension LAAPlatform {
    var controlHitArea: Double { self == .mac ? LAAControl.Mac.hitArea : LAAControl.IPhone.hitArea }
    var iconControl: LAAIconButtonSize { self == .mac ? LAAControl.Mac.iconButton : LAAControl.IPhone.iconButton }
    var secondaryControl: LAAControlSize { self == .mac ? LAAControl.Mac.secondary : LAAControl.IPhone.secondary }
    var compactControl: LAAControlSize { self == .mac ? LAAControl.Mac.secondary : LAAControl.IPhone.compact }
}

/// Button sizes from `control`: the visual stays small for its label; the hit area is padded to 44 (Mac 28)
/// with transparent space. One filled (primary) button per screen.
public struct LAAButtonStyle: ButtonStyle {
    public enum Kind: Sendable { case primary, secondary, compact, text }
    let kind: Kind
    @Environment(\.laaPalette) private var palette
    @Environment(\.isEnabled) private var enabled

    public init(_ kind: Kind) { self.kind = kind }

    private var size: LAAControlSize {
        switch (LAAPlatform.current, kind) {
        case (.mac, .primary): LAAControl.Mac.primary
        case (.iphone, .primary): LAAControl.IPhone.primary
        case (let platform, .compact): platform.compactControl
        case (let platform, _): platform.secondaryControl
        }
    }

    public func makeBody(configuration: Configuration) -> some View {
        let s = size
        let shape = RoundedRectangle(cornerRadius: s.radius, style: .continuous)
        configuration.label
            .laaFont(s.label, weight: s.weight >= 600 ? .semibold : .medium)
            .lineLimit(1)
            .padding(.horizontal, kind == .text ? 0 : s.paddingH)
            .frame(minHeight: s.height)
            .foregroundStyle(foreground)
            .background {
                switch kind {
                case .primary: shape.fill(palette.accentFill.opacity(configuration.isPressed ? 0.85 : 1))
                case .secondary, .compact: shape.fill(configuration.isPressed ? palette.selection : palette.surface)
                case .text: Color.clear
                }
            }
            .overlay {
                if kind == .secondary || kind == .compact { shape.strokeBorder(palette.rule, lineWidth: LAAStroke.rule) }
            }
            .frame(minWidth: LAAPlatform.current.controlHitArea, minHeight: LAAPlatform.current.controlHitArea)
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.45)
            .animation(.spring(response: LAAMotionToken.snappy.response, dampingFraction: LAAMotionToken.snappy.damping),
                       value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: palette.onAccent
        case .text: palette.accent
        case .secondary, .compact: palette.text
        }
    }
}

public extension ButtonStyle where Self == LAAButtonStyle {
    static var laaPrimary: LAAButtonStyle { LAAButtonStyle(.primary) }
    static var laaSecondary: LAAButtonStyle { LAAButtonStyle(.secondary) }
    static var laaCompact: LAAButtonStyle { LAAButtonStyle(.compact) }
    static var laaText: LAAButtonStyle { LAAButtonStyle(.text) }
}

/// An icon-only button: 36 visual (Mac 28) with a 20 (16) glyph, 44 (28) hit area, an accessibility label in
/// short English. Glass only when it floats; otherwise no tile behind the icon.
public struct LAAIconButton: View {
    let icon: LAAIcon
    let label: String
    let glass: Bool
    let action: () -> Void
    @Environment(\.laaPalette) private var palette

    public init(_ icon: LAAIcon, label: String, glass: Bool = false, action: @escaping () -> Void) {
        self.icon = icon; self.label = label; self.glass = glass; self.action = action
    }

    public var body: some View {
        let size = LAAPlatform.current.iconControl
        let hit = LAAPlatform.current.controlHitArea
        Button(action: action) {
            LAAIconImage(icon, size: size.icon)
                .foregroundStyle(palette.textMuted)
                .frame(width: size.visual, height: size.visual)
                .modifier(OptionalGlass(enabled: glass))
                .frame(minWidth: hit, minHeight: hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    private struct OptionalGlass: ViewModifier {
        let enabled: Bool
        func body(content: Content) -> some View {
            if enabled { content.laaGlass(in: Circle()) } else { content }
        }
    }
}

/// A segmented bar for 2–5 options: glass capsule track, the selected segment on `selection` with `accent`
/// text; icon + short English label. Selection is never colour alone (weight changes too).
public struct LAASegmentedBar<ID: Hashable>: View {
    public struct Item: Identifiable {
        public let id: ID
        public let label: String
        public let icon: LAAIcon?
        public init(id: ID, label: String, icon: LAAIcon? = nil) { self.id = id; self.label = label; self.icon = icon }
    }

    @Binding var selection: ID
    let items: [Item]
    @Namespace private var namespace
    @Environment(\.laaPalette) private var palette

    public init(selection: Binding<ID>, items: [Item]) {
        _selection = selection
        self.items = items
    }

    public var body: some View {
        let platform = LAAPlatform.current
        let size = platform.compactControl
        HStack(spacing: 0) {
            ForEach(items) { item in
                let on = item.id == selection
                Button {
                    withAnimation(.spring(response: LAAMotionToken.snappy.response, dampingFraction: LAAMotionToken.snappy.damping)) {
                        selection = item.id
                    }
                } label: {
                    HStack(spacing: LAASpace.s4) {
                        if let icon = item.icon { LAAIconImage(icon, size: LAAIconSize.inline, selected: on) }
                        Text(item.label).laaFont(size.label, weight: on ? .semibold : .regular)
                    }
                    .foregroundStyle(on ? palette.accent : palette.textMuted)
                    .frame(maxWidth: .infinity, minHeight: size.height)
                    .background {
                        if on {
                            // laa-design:allow pill Selection inside the glass segmented bar follows the OS shape.
                            Capsule().fill(palette.selection).matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                    .frame(minWidth: platform.controlHitArea, minHeight: platform.controlHitArea)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.horizontal, LAASpace.s4)
        .background {
            Color.clear.frame(height: size.height).laaGlassCapsule(interactive: true)
        }
    }
}
