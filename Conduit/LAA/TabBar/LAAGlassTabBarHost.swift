#if LAA_BUILD
import LAAKit
import SwiftUI

/// Screens that hid the system tab bar (a conversation's composer, detail pages, an opening chat) hide the
/// glass bar the same way: each one registers while it is on screen. TabView runs onDisappear when its tab
/// is left, so a hidden detail in another tab does not hide the bar here.
@MainActor
final class LAATabBarVisibility: ObservableObject {
    static let shared = LAATabBarVisibility()
    @Published private(set) var hiders: Set<UUID> = []

    var isHidden: Bool { !hiders.isEmpty }

    func hide(_ id: UUID) { hiders.insert(id) }
    func show(_ id: UUID) { hiders.remove(id) }

    nonisolated static func isCovered(legacyCallPresented: Bool, employeeCallActive: Bool,
                          employeeCallPresented: Bool) -> Bool {
        employeeCallActive ? employeeCallPresented : legacyCallPresented
    }
}

private struct LAATabBarHider: ViewModifier {
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { LAATabBarVisibility.shared.hide(id) }
            .onDisappear { LAATabBarVisibility.shared.show(id) }
    }
}

extension View {
    /// Hides the bottom bar while this screen is shown (the LAA build's replacement for
    /// `.toolbar(.hidden, for: .tabBar)`, which it still sets for the system bar's state).
    func laaHidesTabBar() -> some View {
        toolbar(.hidden, for: .tabBar).modifier(LAATabBarHider())
    }
}

/// The settings card the app icon opens (DESIGN.md「ナビ・タブ」). Rows are real settings from Settings,
/// the ones changed most, as direct controls; everything else stays one tap away in Settings.
///   Mac mini — 接続: the Bridge state the owner checks first, and reconnect.
///   Mode — 外観: System / Light / Dark, the most frequent appearance change.
///   Theme — 外観の組: the five theme sets as their two colour dots.
///   Notifications — 通知: whether this iPhone receives them; on/off.
/// Left in Settings: model defaults (each Chat picks its model in the composer), Chat, Voice, calls,
/// skills, predictive input, data and licences.
struct LAAAppSettingsCard: View {
    let openSettings: () -> Void
    /// The Mac sidebar already shows the connection line above the entry; the card does not repeat it.
    var showsMac = true
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var bridge: LAABridgeSession
    @ObservedObject private var notifications = PushNotificationService.shared
    @Environment(\.laaPalette) private var palette
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if showsMac {
            macRow
            LAASettingsCardDivider()
        }
        LAASettingsCardRow("Mode", icon: .appearance) {
            LAASettingsCardChoice("Mode", selection: Binding(
                get: { appState.themePreference },
                set: { appState.themePreference = $0 }
            ), options: [.init(.system, "Auto"), .init(.light, "Light"), .init(.dark, "Dark")])
        }
        .accessibilityIdentifier("laa.tabbar.mode")
        LAASettingsCardDivider()
        LAASettingsCardRow("Theme", icon: .theme) { themeChoice }
            .accessibilityIdentifier("laa.tabbar.theme")
        LAASettingsCardDivider()
        LAASettingsCardRow("Notifications", icon: .notification) {
            Toggle("Notifications", isOn: Binding(
                get: { notifications.isEnabled },
                set: { on in
                    Task {
                        if on { await notifications.enable() } else { await notifications.disable() }
                        if on, notifications.isEnabled { await appState.refreshNotifierPluginStatus() }
                    }
                }
            ))
            .labelsHidden()
            .tint(palette.accent)
            .disabled(notifications.isWorking)
        }
        .accessibilityIdentifier("laa.tabbar.notifications")
        LAASettingsCardDivider()
        LAASettingsCardEntry(action: openSettings)
    }

    private var macRow: some View {
        LAASettingsCardRow("Mac mini", icon: .mac) {
            HStack(spacing: LAASpace.s8) {
                Text(verbatim: connection.mark)
                    .foregroundStyle(connection.colour)
                    .accessibilityHidden(true)
                Text(verbatim: connection.text)
                    .laaFont(LAAPlatform.current.canvas.small)
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(1)
                Button {
                    if bridge.status == .paired { Task { await appState.reconnect() } } else { openSettings() }
                } label: {
                    LAAIconImage(.sync, size: LAAIconSize.row)
                        .foregroundStyle(palette.accent)
                        .frame(width: LAAControl.IPhone.hitArea, height: LAAControl.IPhone.hitArea)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(appState.isConnecting)
                .accessibilityLabel(Text(verbatim: "Reconnect"))
                .accessibilityIdentifier("laa.tabbar.reconnect")
            }
        }
        .accessibilityIdentifier("laa.tabbar.mac")
    }

    /// The same states the Mac sidebar names, with the status shapes (● ▲ ○), never colour alone.
    private var connection: (text: String, mark: String, colour: Color) {
        switch bridge.status {
        case .unpaired: return (LAACopy.macNotPaired, "○", palette.textMuted)
        case .revoked, .unauthorized: return (LAACopy.macRePairRequired, "▲", palette.caution)
        case .keychainError: return (LAACopy.macKeychainError, "▲", palette.caution)
        case .paired:
            if appState.isConnected { return (LAACopy.macConnected, "●", palette.positive) }
            if appState.isConnecting { return (LAACopy.macChecking, "○", palette.textMuted) }
            return (LAACopy.macOffline, "▲", palette.caution)
        }
    }

    private var themeChoice: some View {
        HStack(spacing: LAASpace.s4) {
            ForEach(LAAThemeSets.all) { set in
                let colours = set.colors(dark: scheme == .dark)
                let selected = LAAAppTheme.store.themeID == set.id
                Button { LAAAppTheme.select(set.id) } label: {
                    HStack(spacing: 2) {
                        Circle().fill(Color(laa: colours.accent))
                        Circle().fill(Color(laa: colours.second))
                    }
                    .frame(width: LAAIconSize.row, height: LAAComponentToken.statusDot)
                    .padding(.vertical, LAASpace.s8)
                    .padding(.horizontal, LAASpace.s4)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: LAAKit.LAARadius.selection, style: .continuous)
                                .fill(palette.selection)
                        }
                    }
                    .frame(minWidth: 36, minHeight: LAAControl.IPhone.hitArea)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: set.name))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "Theme"))
    }
}

extension LAAAppIdentity {
    /// Hortensia's name, version and its icon artwork (the bundle's Icon Composer icon is not readable as an
    /// image, so the asset catalog carries the same art as `LAAAppIconArt`).
    static var hortensia: LAAAppIdentity {
        .main(name: "Hortensia", icon: Image("LAAAppIconArt"))
    }
}
#endif
