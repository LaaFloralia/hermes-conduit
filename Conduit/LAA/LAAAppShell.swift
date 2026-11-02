#if LAA_BUILD
import SwiftUI

/// The LAA tabs reuse Conduit's chat list and conversation screens. The
/// remaining tabs share the LAA Bridge connection independently of Hermes.
struct LAAAppShell: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scenePhase
    let onRequestSettings: () -> Void

    @ObservedObject private var workLinkRequest = LAAWorkLinkRequest.shared
    @StateObject private var usageState = LAAUsageState()
    @ObservedObject private var dailyRequest = LAABrainDailyRequest.shared
    @ObservedObject var employeeCalls: LAAEmployeeCallCoordinator
    @State private var selectedTab: LAATab = LAATab.launched ?? .chats
    @State private var showUsage = false
    @State private var chatsPath: [V2Route] = []
    #if DEBUG
    @State private var seededDailyFixture = false
    #endif

    private var requiresLogin: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CONDUIT_UITEST"] == "1",
           ProcessInfo.processInfo.arguments.contains("-LAA_UI_TEST_FORCE_LOGIN") { return true }
        #endif
        return appState.showLogin || (appState.connection == nil && appState.offlineChatPresentation == nil)
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
            // A shortcut or widget may start a call outside a chat. Keep a
            // return control visible there too when the call is minimised.
            .safeAreaInset(edge: .top, spacing: 0) {
                if let context = employeeCalls.snapshot?.context,
                   !conversationVisible || context.profile != appState.conversationIdentityProfile
                    || context.conversationID != appState.activeSessionId {
                    LAAInCallBar(calls: employeeCalls, profile: context.profile, conversationID: context.conversationID)
                }
            }
            .tint(LAAColor.link)
            .background(LAAColor.background.ignoresSafeArea())
            .environment(\.laaSettingsAction, onRequestSettings)
            .task(id: "\(bridge.revision)|\(scenePhase == .active)") {
                let active = scenePhase == .active
                await usageState.synchronize(bridge: bridge, active: active)
                guard active else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(120)) } catch { return }
                    guard !Task.isCancelled else { return }
                    await usageState.refreshAutomatically(bridge: bridge)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { LAAUsageBackground.schedule() }
            }
            .onChange(of: appState.laaWidgetUsagePending, initial: true) { _, pending in
                guard pending else { return }
                showUsage = true
                appState.laaWidgetUsagePending = false
                appState.requestSettingsDismissal()
            }
            .sheet(isPresented: $showUsage) {
                NavigationStack { LAAUsageView(state: usageState, onRequestSettings: onRequestSettings) }
                    .environmentObject(bridge)
            }
            .onChange(of: workLinkRequest.generation, initial: true) { _, _ in
                guard let host = workLinkRequest.url?.host else { return }
                switch host {
                case "work": selectedTab = .work
                case "today": selectedTab = .today
                case "brain": selectedTab = .brain
                case "assets": selectedTab = .studio
                default: return
                }
                appState.requestSettingsDismissal()
            }
            .onChange(of: dailyRequest.id, initial: true) { _, request in
                guard request != nil else { return }
                selectedTab = .brain
                appState.requestSettingsDismissal()
            }
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
            .onAppear {
                #if DEBUG
                LAAPluginUITestFixture.seedStatusIfEnabled(appState)
                if !seededDailyFixture && ProcessInfo.processInfo.arguments.contains("-laa-brain-daily-fixture") {
                    seededDailyFixture = true
                    dailyRequest.enqueue()
                }
                #endif
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
        } else if ProcessInfo.processInfo.environment["CONDUIT_UITEST"] == "1",
                  ProcessInfo.processInfo.arguments.contains("-LAA_UI_TEST_PLUGIN_CATALOG") {
            LAAPluginCatalogUITestScreen()
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
                            if tab == .today {
                                LAATodayView(openBrain: { selectedTab = .brain }, onRequestSettings: onRequestSettings,
                                             initialEventID: workLinkRequest.calendarEvent?.id, initialCalendarID: workLinkRequest.calendarEvent?.calendarID)
                                    .id(workLinkRequest.generation)
                            } else if tab == .studio {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: LAASpacing.x6) {
                                        LAATabHeading(title: LAATab.studio.title)
                                        // Drive keeps one entry inside the five tabs: the
                                        // Assets screen stays reachable without a sixth tab.
                                        NavigationLink {
                                            LAAAssetsView(onRequestSettings: onRequestSettings)
                                        } label: {
                                            HStack(spacing: LAASpacing.x3) {
                                                Image(systemName: "folder")
                                                    .foregroundStyle(LAAColor.link)
                                                VStack(alignment: .leading, spacing: LAASpacing.x1) {
                                                    Text(verbatim: "Drive")
                                                    Text(verbatim: "Google Driveのファイルを開く、アップロードする")
                                                        .laaTextStyle(.secondary)
                                                        .foregroundStyle(LAAColor.secondaryText)
                                                }
                                                Spacer(minLength: 0)
                                                Image(systemName: "chevron.right")
                                                    .foregroundStyle(LAAColor.secondaryText)
                                            }
                                            .padding(LAASpacing.x4)
                                            .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(Text(verbatim: "Drive"))
                                        .accessibilityIdentifier("studio.drive")
                                        LAAStudioHomeView()
                                    }.padding(LAASpacing.horizontal)
                                }
                                .background(LAAColor.background.ignoresSafeArea())
                                .navigationBarTitleDisplayMode(.inline)
                                .toolbarBackground(.hidden, for: .navigationBar)
                                .toolbar { ToolbarItem(placement: .topBarTrailing) { LAASettingsButton(action: onRequestSettings) } }
                            } else if tab == .usage {
                                LAAUsageView(state: usageState, onRequestSettings: onRequestSettings)
                            } else if tab == .work {
                                LAAWorkHub(onRequestSettings: onRequestSettings)
                            } else {
                                LAAAssetsView(onRequestSettings: onRequestSettings)
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
                // LAAChatsContent owns the bar (an empty title and the
                // settings button); a title here would repeat the "Chats"
                // heading in the body.
                LAAChatsView(appState: appState)
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
