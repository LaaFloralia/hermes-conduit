#if LAA_BUILD
import SwiftUI

/// The LAA tabs reuse Conduit's chat list and conversation screens. The
/// remaining tabs share the LAA Bridge connection independently of Hermes.
struct LAAAppShell: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let onRequestSettings: () -> Void

    @StateObject private var bridge = LAABridgeSession()
    @ObservedObject var employeeCalls: LAAEmployeeCallCoordinator
    @State private var selectedTab: LAATab = LAATab.launched ?? .chats
    @State private var chatsPath: [V2Route] = []

    private var requiresLogin: Bool {
        appState.showLogin || (appState.connection == nil && appState.offlineChatPresentation == nil)
    }

    private var conversationVisible: Bool {
        selectedTab == .chats && chatsPath.last == .conversation
    }

    private var callCoveringTabs: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-LAA_UI_TEST_CALL_COVERS_TABS") { return true }
        #endif
        return LAATabBarVisibility.isCovered(
            legacyCallPresented: appState.isVoiceCallScreenPresented,
            employeeCallActive: employeeCalls.snapshot != nil,
            employeeCallPresented: employeeCalls.isShowingCall
        )
    }

    var body: some View {
        bar
            .overlay(alignment: .top) {
                if let notice = appState.pinSyncNotice {
                    V2NoticeBanner(notice: notice) { appState.dismissPinSyncNotice(notice.id) }
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                }
            }
            .environmentObject(bridge)
            .environmentObject(employeeCalls)
            .modifier(LAACallPresentation(calls: employeeCalls))
            .tint(LAAColor.link)
            .background(LAAColor.background.ignoresSafeArea())
            .environment(\.laaSettingsAction, onRequestSettings)
            .environment(\.v2Shell, V2ShellContext(
                pickProfile: { profile in
                    guard profile != appState.activeProfile, !appState.isProfileSwitching else { return }
                    Haptics.medium()
                    Task { await appState.switchProfile(to: profile) }
                },
                values: .init(isTabActive: selectedTab == .chats, isRootCovered: !chatsPath.isEmpty)
            ))
            .onChange(of: conversationVisible, initial: true) { _, visible in
                if appState.showSidebar == visible { appState.showSidebar = !visible }
            }
            .onChange(of: appState.showSidebar) { _, covered in
                if !covered, !conversationVisible {
                    if requiresLogin || appState.isVoiceCallScreenPresented {
                        appState.showSidebar = true
                    } else {
                        openConversation()
                    }
                } else if covered, conversationVisible {
                    closeConversation()
                }
            }
            // Match V2Shell's room lifecycle: popping the room leaves it, but
            // reopening the same room during the transition keeps it alive.
            .onChange(of: chatsPath.contains(.conversation)) { _, pushed in
                guard !pushed, appState.activeRoomSurface != nil else { return }
                let epoch = appState.groupRoomEpoch
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !chatsPath.contains(.conversation), appState.activeRoomSurface != nil else { return }
                    if appState.groupRoomEpoch == epoch {
                        appState.closeGroupRoom()
                    } else if !appState.isVoiceCallScreenPresented {
                        openConversation()
                    }
                }
            }
            .onChange(of: appState.activeRoomSurface?.room.roomID) { old, new in
                if old != nil, new == nil {
                    closeConversation()
                } else if new != nil, !conversationVisible, !appState.isVoiceCallScreenPresented {
                    openConversation()
                }
            }
            .onChange(of: requiresLogin) { _, needsLogin in
                if needsLogin { chatsPath.removeAll() }
            }
            .onDisappear { appState.showSidebar = false }
    }

    @ViewBuilder
    private var bar: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-LAA_UI_TEST_PAIR_ALL") {
            LAANotificationPairAllFixtureScreen()
        } else if ProcessInfo.processInfo.arguments.contains("-LAA_UI_TEST_BACKGROUND") {
            LAABackgroundUITestFixtureScreen()
        } else {
            normalBar
        }
        #else
        normalBar
        #endif
    }

    @ViewBuilder
    private var normalBar: some View {
        if #available(iOS 26.0, *) {
            tabs.tabBarMinimizeBehavior(.onScrollDown)
        } else if reduceTransparency {
            tabs.toolbarBackground(LAAColor.surface, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
        } else {
            tabs.toolbarBackground(.ultraThinMaterial, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
        }
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            chatsTab
                .modifier(LAAHideTabBarForCall(isPresented: callCoveringTabs))
                .tabItem { Label(LAATab.chats.title, systemImage: LAATab.chats.symbol) }
                .tag(LAATab.chats)
            ForEach(LAATab.destinations.filter { $0 != .chats }) { tab in
                Group {
                    if tab == .brain {
                        LAABrainView(onRequestSettings: onRequestSettings)
                    } else {
                        NavigationStack {
                            if tab == .usage {
                                LAAUsageView(onRequestSettings: onRequestSettings)
                            } else if tab == .work {
                                LAAWorkView(onRequestSettings: onRequestSettings)
                                    .toolbar {
                                        ToolbarItem(placement: .principal) {
                                            Text(verbatim: tab.title)
                                                .accessibilityAddTraits(.isHeader)
                                        }
                                    }
                            } else {
                                LAAPlaceholderScreen(tab: tab, onRequestSettings: onRequestSettings)
                            }
                        }
                    }
                }
                .modifier(LAAHideTabBarForCall(isPresented: callCoveringTabs))
                .tabItem { Label(tab.title, systemImage: tab.symbol) }
                .tag(tab)
            }
        }
    }

    @ViewBuilder
    private var chatsTab: some View {
        if requiresLogin {
            LoginView()
        } else {
            NavigationStack(path: $chatsPath) {
                V2ChatsView(appState: appState)
                    .equatable()
                    .laaGroupListEntry()
                    .navigationTitle(LAATab.chats.title)
                    .navigationDestination(for: V2Route.self) { route in
                        switch route {
                        case .conversation:
                            V2ConversationScreen()
                                .toolbar(.hidden, for: .tabBar)
                        case .project(let project):
                            V2ProjectPage(project: project)
                        case .artifacts:
                            V2ArtifactsPage()
                                .toolbar(.hidden, for: .tabBar)
                        }
                    }
            }
        }
    }

    private func openConversation() {
        selectedTab = .chats
        if chatsPath.last != .conversation { chatsPath.append(.conversation) }
    }

    private func closeConversation() {
        if chatsPath.last == .conversation { chatsPath.removeLast() }
    }
}

enum LAATabBarVisibility {
    static func isCovered(legacyCallPresented: Bool, employeeCallActive: Bool,
                          employeeCallPresented: Bool) -> Bool {
        employeeCallActive ? employeeCallPresented : legacyCallPresented
    }
}

private struct LAAHideTabBarForCall: ViewModifier {
    let isPresented: Bool

    func body(content: Content) -> some View {
        // Emit the preference without replacing the tab content or overriding
        // a detail screen's own hidden preference when the call is dismissed.
        content.overlay(alignment: .topLeading) {
            if isPresented {
                Color.clear
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .toolbar(.hidden, for: .tabBar)
            }
        }
    }
}
#endif
