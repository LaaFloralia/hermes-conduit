#if LAA_BUILD && targetEnvironment(macCatalyst)
import SwiftUI

/// The Mac window's sidebar: the LAA heading, one row per section, and the
/// Mac's connection state with Settings beneath it.
///
/// The rows are drawn rather than a `List`'s selection, so the selected row
/// uses LAA's own colours — `LAAColor.selectionFill` behind `LAAColor.link` —
/// instead of the system's accent fill. The arrow keys walk the rows and
/// Return opens the focused one, because each row is a Button.
struct LAAMacSidebar: View {
    @Binding var section: LAAMacSection
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var bridge: LAABridgeSession
    let onRequestSettings: () -> Void

    @State private var hovered: LAAMacSection?
    @FocusState private var focused: LAAMacSection?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            ScrollView {
                VStack(alignment: .leading, spacing: LAASpacing.x1) {
                    Text(verbatim: LAACopy.macSidebarSections.uppercased())
                        .laaTextStyle(.section).fontWeight(.bold).tracking(0.8)
                        .foregroundStyle(LAAColor.secondaryText)
                        .padding(.horizontal, LAASpacing.x2)
                        .padding(.bottom, LAASpacing.x1)
                    ForEach(LAAMacSection.allCases) { item in
                        row(item)
                    }
                }
                .padding(.horizontal, LAASpacing.x2)
                .padding(.top, LAASpacing.x2)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onKeyPress(.downArrow) { moveFocus(by: 1) }
            .onKeyPress(.upArrow) { moveFocus(by: -1) }
            footer
        }
        .background(LAAColor.background)
        .accessibilityIdentifier("laa.mac.sidebar")
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x1) {
            Text(verbatim: LAACopy.brand)
                .font(LAAType.screenTitle)
                .foregroundStyle(LAAColor.text)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: LAACopy.macSidebarSubtitle)
                .laaTextStyle(.secondary)
                .foregroundStyle(LAAColor.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, LAASpacing.x4)
        .padding(.top, LAASpacing.x4)
        .padding(.bottom, LAASpacing.x3)
    }

    private func row(_ item: LAAMacSection) -> some View {
        let selected = section == item
        return Button {
            section = item
        } label: {
            HStack(spacing: LAASpacing.x3) {
                Image(systemName: item.symbol)
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 22, alignment: .center)
                    .foregroundStyle(selected ? LAAColor.link : LAAColor.secondaryText)
                    .accessibilityHidden(true)
                Text(verbatim: item.title)
                    .laaTextStyle(.body)
                    .foregroundStyle(selected ? LAAColor.link : LAAColor.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, LAASpacing.x2)
            .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumTouchTarget, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: LAARadius.card)
                    .fill(selected ? LAAColor.selectionFill
                          : (hovered == item ? LAAColor.subtleSurface : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused, equals: item)
        .onHover { inside in
            if inside { hovered = item } else if hovered == item { hovered = nil }
        }
        .accessibilityLabel(Text(verbatim: item.title))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("laa.mac.section.\(item.rawValue)")
        .help(item.title)
    }

    private func moveFocus(by delta: Int) -> KeyPress.Result {
        let sections = LAAMacSection.allCases
        guard let index = sections.firstIndex(where: { $0 == (focused ?? section) }) else {
            focused = sections.first
            return .handled
        }
        let next = min(max(index + delta, 0), sections.count - 1)
        focused = sections[next]
        section = sections[next]
        return .handled
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            Rectangle().fill(LAAColor.separator).frame(height: 1)
            HStack(spacing: LAASpacing.x2) {
                Circle()
                    .fill(connection.colour)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(verbatim: connection.text)
                    .laaTextStyle(.secondary)
                    .foregroundStyle(LAAColor.secondaryText)
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("laa.mac.connection")
            Button(action: onRequestSettings) {
                HStack(spacing: LAASpacing.x3) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .regular))
                        .frame(width: 22)
                        .foregroundStyle(LAAColor.secondaryText)
                    Text(verbatim: LAACopy.settings).laaTextStyle(.body).foregroundStyle(LAAColor.text)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: LAASpacing.minimumTouchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: LAACopy.settings))
            .accessibilityIdentifier("laa.settings.open")
            .help(LAACopy.settings)
        }
        .padding(.horizontal, LAASpacing.x4)
        .padding(.bottom, LAASpacing.x4)
        .padding(.top, LAASpacing.x2)
    }

    /// What the Mac shows about its Bridge: the same states the phone's
    /// connection line names, and no claim beyond what was read.
    private var connection: (text: String, colour: Color) {
        switch bridge.status {
        case .unpaired: return (LAACopy.macNotPaired, LAAColor.secondaryText)
        case .revoked, .unauthorized: return (LAACopy.macRePairRequired, LAAColor.attention)
        case .keychainError: return (LAACopy.macKeychainError, LAAColor.attention)
        case .paired:
            if appState.isConnected { return (LAACopy.macConnected, LAAColor.link) }
            return (appState.isConnecting ? LAACopy.macChecking : LAACopy.macOffline,
                    appState.isConnecting ? LAAColor.secondaryText : LAAColor.attention)
        }
    }
}
#endif
