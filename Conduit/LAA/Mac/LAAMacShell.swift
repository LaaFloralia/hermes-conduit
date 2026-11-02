#if LAA_BUILD && targetEnvironment(macCatalyst)
import SwiftUI

/// The Mac window: a sidebar of sections beside a detail column, in place of
/// the phone's five tabs. The reused iPhone screens keep their compact size
/// class inside the columns, so their layout and controls are unchanged; the
/// shell branches on `laaDesktop`, never on the size class.
///
/// Everything `LAAAppShell` keeps outside the tabs — the notice banner, the
/// in-call bar, the Usage sheet and its refresh loop, widget and daily
/// requests, Settings — is kept here too, so a Mac keeps the phone's
/// behaviour and only its frame changes.
struct LAAMacShell: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.scenePhase) private var scenePhase
    let onRequestSettings: () -> Void
    @ObservedObject var employeeCalls: LAAEmployeeCallCoordinator

    @ObservedObject private var commands = LAAMacCommandsModel.shared
    @ObservedObject private var workLinkRequest = LAAWorkLinkRequest.shared
    @ObservedObject private var dailyRequest = LAABrainDailyRequest.shared
    @StateObject private var usageState = LAAUsageState()

    /// The section the window shows. Persisted per window, so reopening the
    /// app returns to where the reader was.
    @SceneStorage("laa.mac.section") private var storedSection = LAAMacSection.chats.rawValue
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showUsage = false
    /// The chat section's detail column holds a conversation, so the in-call
    /// bar can step aside the way it does on the phone.
    @State private var chatConversationShown = false
    #if DEBUG
    @State private var seededDailyFixture = false
    #endif

    private var section: LAAMacSection { LAAMacSection(rawValue: storedSection) ?? .chats }
    private var sectionBinding: Binding<LAAMacSection> {
        Binding(get: { section }, set: { storedSection = $0.rawValue })
    }

    private var requiresLogin: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CONDUIT_UITEST"] == "1",
           ProcessInfo.processInfo.arguments.contains("-LAA_UI_TEST_FORCE_LOGIN") { return true }
        #endif
        return appState.showLogin || (appState.connection == nil && appState.offlineChatPresentation == nil)
    }

    private var conversationVisible: Bool {
        section == .chats && chatConversationShown && !requiresLogin
    }

    var body: some View {
        split
            .overlay(alignment: .top) {
                if let notice = appState.pinSyncNotice {
                    V2NoticeBanner(notice: notice) { appState.dismissPinSyncNotice(notice.id) }
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                }
            }
            .environmentObject(bridge)
            .environmentObject(employeeCalls)
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
            .environment(\.laaDesktop, true)
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
                guard let host = workLinkRequest.url?.host, let target = LAAMacSection(linkHost: host) else { return }
                storedSection = target.rawValue
                appState.requestSettingsDismissal()
            }
            .onChange(of: dailyRequest.id, initial: true) { _, request in
                guard request != nil else { return }
                storedSection = LAAMacSection.brain.rawValue
                appState.requestSettingsDismissal()
            }
            .onChange(of: commands.pendingSection) { _, requested in
                guard let requested else { return }
                storedSection = requested.rawValue
                commands.pendingSection = nil
            }
            .onChange(of: commands.toggleSidebar) { _, _ in
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            }
            .onChange(of: commands.openSettings) { _, _ in onRequestSettings() }
            .onChange(of: commands.closeConversation) { _, _ in appState.showSidebar = true }
            // Another section has no conversation on screen, so the chat
            // stops counting as seen and its streaming rows stop redrawing.
            .onChange(of: section) { _, new in
                appState.showSidebar = !(new == .chats && chatConversationShown)
            }
            .onChange(of: requiresLogin) { _, needsLogin in
                if needsLogin { chatConversationShown = false }
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

    private var split: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LAAMacSidebar(section: sectionBinding, onRequestSettings: onRequestSettings)
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .background(LAAColor.background.ignoresSafeArea())
    }

    @ViewBuilder
    private var detail: some View {
        if requiresLogin {
            // Sign-in replaces every section: the card sits in the middle of
            // the window at a readable width, not stretched across it.
            LoginView()
                .laaReadableWidth(LAADesktopMetrics.documentWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LAAColor.background.ignoresSafeArea())
                .environment(\.horizontalSizeClass, .compact)
        } else {
            switch section {
            case .chats:
                LAAMacChatsSection(commands: commands,
                                   conversationShown: $chatConversationShown)
            case .work:
                NavigationStack { LAAWorkHub(onRequestSettings: onRequestSettings) }
                    .laaCompactColumn()
            case .today:
                NavigationStack {
                    LAATodayView(openBrain: { storedSection = LAAMacSection.brain.rawValue },
                                 onRequestSettings: onRequestSettings,
                                 initialEventID: workLinkRequest.calendarEvent?.id,
                                 initialCalendarID: workLinkRequest.calendarEvent?.calendarID)
                        .id(workLinkRequest.generation)
                }
                .laaCompactColumn()
            case .brain:
                LAABrainView(onRequestSettings: onRequestSettings)
                    .laaCompactColumn()
            case .studio:
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: LAASpacing.x6) {
                            LAATabHeading(title: LAAMacSection.studio.title)
                            LAAStudioHomeView()
                        }
                        .padding(LAASpacing.horizontal)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(LAAColor.background.ignoresSafeArea())
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { LAASettingsButton(action: onRequestSettings) } }
                }
                .laaCompactColumn()
            case .drive:
                NavigationStack { LAAAssetsView(onRequestSettings: onRequestSettings) }
                    .laaCompactColumn()
            case .usage:
                NavigationStack {
                    LAAUsageView(state: usageState, onRequestSettings: onRequestSettings)
                        .laaReadableWidth()
                }
                .laaCompactColumn()
            }
        }
    }
}

private extension View {
    /// The reused iPhone screens keep the compact size class they were laid
    /// out for, inside a column that can be any width.
    func laaCompactColumn() -> some View {
        environment(\.horizontalSizeClass, .compact)
            .background(LAAColor.background.ignoresSafeArea())
    }
}
#endif
