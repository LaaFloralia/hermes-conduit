#if LAA_BUILD
import LAAKit
import SwiftUI

/// The LAA tabs reuse Conduit's chat list and conversation screens. The
/// remaining tabs share the LAA Bridge connection independently of Hermes.
struct LAAAppShell: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.scenePhase) private var scenePhase
    let onRequestSettings: () -> Void

    @ObservedObject private var workLinkRequest = LAAWorkLinkRequest.shared
    @StateObject private var usageState = LAAUsageState()
    @ObservedObject private var dailyRequest = LAABrainDailyRequest.shared
    @ObservedObject var employeeCalls: LAAEmployeeCallCoordinator
    @State private var selectedTab: LAATab = LAATab.launched ?? .chats
    @State private var showUsage = false
    @State private var settingsCardOpen = false
    @ObservedObject private var tabBarVisibility = LAATabBarVisibility.shared
    @ObservedObject private var ownerAvatar = LAAOwnerAvatarStore.shared
    @AppStorage("laa.work.decisionCount") private var decisionCount = 0
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
            .environmentObject(usageState)
            .modifier(LAADecisionBadgeSync(bridge: bridge, active: scenePhase == .active))
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
            .laaOwnerAvatarSync(bridge, active: scenePhase == .active)
            .laaStaffThinkingSync(bridge, active: scenePhase == .active)
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
                NavigationStack { LAAUsageView(state: usageState).modifier(LAAUsageSheetClose()) }
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
            .onChange(of: conversationVisible, initial: true) { wasVisible, visible in
                // An opening chat keeps the list "covered": the chat underneath
                // isn't on screen yet, so it isn't counted as seen.
                let covered = !visible || appState.laaOpeningEmployeeChat != nil
                if appState.showSidebar != covered { appState.showSidebar = covered }
                // Only leaving drops it: a cold widget launch opens its chat
                // before the screen is up, and must not cancel itself.
                if wasVisible, !visible { appState.laaCancelOpeningEmployeeChat() }
            }
            // A tapped employee's chat shows at once; the conversation replaces
            // the opening screen when the switch lands (LAAConversationRoute).
            .onChange(of: appState.laaOpeningEmployeeChat, initial: true) { old, new in
                if new != nil {
                    appState.requestSettingsDismissal()
                    openConversation()
                } else if old != nil, appState.showSidebar, conversationVisible {
                    // Still covered: the launch ended without opening a chat
                    // (its failure is a notice), so return to the list.
                    closeConversation()
                }
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
        if ProcessInfo.processInfo.environment["CONDUIT_UITEST"] == "1", ProcessInfo.processInfo.arguments.contains("-LAA_UI_TEST_HABITS") {
            LAAHabitsUITestScreen()
        } else if ProcessInfo.processInfo.arguments.contains("-LAA_UI_TEST_PAIR_ALL") {
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

    /// The tabs keep TabView's resident roots and selection; the system bar is hidden and the LAA glass bar
    /// (two capsules: tabs and the app icon that opens the settings card) takes its place (2026-11-26).
    private var normalBar: some View {
        TabView(selection: $selectedTab) {
            chatsTab
                .modifier(LAATabRoot(barVisible: !barHidden && !requiresLogin))
                .tag(LAATab.chats)
            ForEach(LAATab.destinations.filter { $0 != .chats }) { tab in
                LAANonChatTab(tab: tab, isActive: selectedTab == tab,
                              generation: workLinkRequest.generation,
                              eventID: workLinkRequest.calendarEvent?.id,
                              calendarID: workLinkRequest.calendarEvent?.calendarID,
                              initialStudioSelected: workLinkRequest.url?.host != "assets",
                              usageState: usageState, selectedTab: $selectedTab,
                              onRequestSettings: onRequestSettings)
                    .equatable()
                .modifier(LAATabRoot(barVisible: !barHidden))
                .tag(tab)
            }
        }
        // While the settings card is open, the screen behind it (including its navigation bar's actions, which
        // live outside the card's modal scope in UIKit) leaves the accessibility tree; the card and Close stay.
        .accessibilityHidden(settingsCardOpen)
        .environment(\.laaBehindSettingsCard, settingsCardOpen)
        .laaGlassTabBar(glassTabs, selection: $selectedTab, isExpanded: $settingsCardOpen, isHidden: barHidden,
                        app: .hortensia(ownerAvatar)) {
            LAAAppSettingsCard(openSettings: {
                settingsCardOpen = false
                onRequestSettings()
            })
        }
        .onChange(of: selectedTab) { _, _ in settingsCardOpen = false }
        .onChange(of: scenePhase) { _, phase in if phase != .active { settingsCardOpen = false } }
    }

    private var glassTabs: [LAAGlassTab<LAATab>] {
        LAATab.destinations.map { tab in
            if let doc = tab.barArtwork {
                return LAAGlassTab(tab, title: tab.title, image: doc.regular, selectedImage: doc.selected)
            }
            return LAAGlassTab(tab, title: tab.title, icon: tab.icon, badge: tab == .work ? decisionCount : 0)
        }
    }

    /// A call covering the tabs, or a screen that hid the system bar (a conversation, a detail page).
    private var barHidden: Bool { callCoveringTabs || tabBarVisibility.isHidden }
    @State private var loginSafeBottom: Double = 34

    @ViewBuilder
    private var chatsTab: some View {
        if requiresLogin {
            LoginView(tabBarClearance: barHidden ? 0 : LAAGlassTabBarLayout.contentClearance(safeBottom: loginSafeBottom))
                // Without a home indicator (iPhone SE) the bar sits higher: size the clearance from this screen.
                .onGeometryChange(for: Double.self) { $0.safeAreaInsets.bottom } action: { loginSafeBottom = $0 }
        } else {
            NavigationStack(path: $chatsPath) {
                // LAAChatsContent owns the bar (an empty title and the
                // settings button); a title here would repeat the "Chat"
                // heading in the body.
                LAAChatsView(appState: appState)
                    .navigationDestination(for: V2Route.self) { route in
                        switch route {
                        case .conversation:
                            LAAConversationRoute()
                        case .project(let project):
                            V2ProjectPage(project: project)
                        case .artifacts:
                            V2ArtifactsPage()
                                .laaHidesTabBar()
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

/// AppState publishes while a conversation streams. Compare only destination
/// inputs here so those updates do not rebuild the four other tab roots. Their
/// own observable data and environment still update normally; navigation and
/// scroll state stay in the existing tab identity.
private struct LAANonChatTab: View, Equatable {
    let tab: LAATab
    let isActive: Bool
    let generation: UInt64
    let eventID: String?
    let calendarID: String?
    let initialStudioSelected: Bool
    let usageState: LAAUsageState
    @Binding var selectedTab: LAATab
    let onRequestSettings: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tab == rhs.tab && lhs.isActive == rhs.isActive && lhs.generation == rhs.generation
            && lhs.eventID == rhs.eventID && lhs.calendarID == rhs.calendarID
            && lhs.initialStudioSelected == rhs.initialStudioSelected && lhs.usageState === rhs.usageState
        // The Binding location and settings action belong to the shell's
        // lifetime, so they do not change when AppState publishes.
    }

    var body: some View {
        if tab == .brain {
            LAABrainView(onRequestSettings: onRequestSettings)
        } else {
            NavigationStack {
                if tab == .today {
                    LAATodayView(openBrain: { selectedTab = .brain }, onRequestSettings: onRequestSettings,
                                 initialEventID: eventID, initialCalendarID: calendarID)
                        .id(generation)
                } else if tab == .studio {
                    LAAAssetsView(onRequestSettings: onRequestSettings, initialStudioSelected: initialStudioSelected)
                } else if tab == .usage {
                    LAAUsageView(state: usageState)
                } else if tab == .work {
                    LAAWorkHub(onRequestSettings: onRequestSettings)
                } else {
                    LAAAssetsView(onRequestSettings: onRequestSettings)
                }
            }
        }
    }
}

/// Each tab root hides the system bar and keeps its last row clear of the glass bar.
private struct LAATabRoot: ViewModifier {
    let barVisible: Bool

    func body(content: Content) -> some View {
        content
            .toolbar(.hidden, for: .tabBar)
            .laaTabBarClearance(barVisible)
    }
}
#endif
