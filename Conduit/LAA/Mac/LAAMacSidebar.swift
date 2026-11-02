#if LAA_BUILD && targetEnvironment(macCatalyst)
import SwiftUI

/// The Mac window's sidebar: the LAA heading, one row per section, and the
/// Mac's connection state with Settings beneath it. A `List` with a selection
/// binding gives click selection, the arrow keys and the system's own sidebar
/// keyboard behaviour; the colours are LAA's paper and teal rather than the
/// system sidebar's material.
struct LAAMacSidebar: View {
    @Binding var section: LAAMacSection
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var bridge: LAABridgeSession
    let onRequestSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            List(selection: selectionBinding) {
                Section {
                    ForEach(LAAMacSection.allCases) { item in
                        row(item)
                            .tag(item)
                    }
                } header: {
                    Text(verbatim: LAACopy.macSidebarSections.uppercased())
                        .laaTextStyle(.section).fontWeight(.bold).tracking(0.8)
                        .foregroundStyle(LAAColor.secondaryText)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, LAASpacing.minimumTouchTarget)
            footer
        }
        .background(LAAColor.background)
        .accessibilityIdentifier("laa.mac.sidebar")
    }

    /// `List` needs an optional selection; the sidebar always has one.
    private var selectionBinding: Binding<LAAMacSection?> {
        Binding(get: { section }, set: { if let new = $0 { section = new } })
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
        HStack(spacing: LAASpacing.x3) {
            Image(systemName: item.symbol)
                .font(.system(size: 15, weight: .regular))
                .frame(width: 22, alignment: .center)
                .foregroundStyle(section == item ? LAAColor.link : LAAColor.secondaryText)
                .accessibilityHidden(true)
            Text(verbatim: item.title)
                .laaTextStyle(.body)
                .foregroundStyle(LAAColor.text)
            Spacer(minLength: 0)
        }
        .frame(minHeight: LAASpacing.minimumTouchTarget)
        .contentShape(Rectangle())
        .accessibilityLabel(Text(verbatim: item.title))
        .accessibilityIdentifier("laa.mac.section.\(item.rawValue)")
        .help(item.title)
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
                    Text(verbatim: LAACopy.settings).laaTextStyle(.body)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(LAAColor.text)
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
