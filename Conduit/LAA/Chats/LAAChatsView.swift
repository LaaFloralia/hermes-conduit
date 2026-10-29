#if LAA_BUILD
import SwiftUI

/// The LAA list is a presentation of the existing Hermes state. Employee
/// taps use the same identity-preserving route as the employee widget.
@MainActor
struct LAAChatsView: View {
    @ObservedObject var appState: AppState
    @Environment(\.v2Shell) private var shell
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.laaSettingsAction) private var settings
    @State private var showingGroupCreator = false
    @State private var groupReadID = UUID()
    @State private var groupReadDashboard: UUID?
    @State private var groupReadState: LAAChatsLoadState = .loading
    @State private var loadedRooms: [GroupRoom] = []

    private var shown: Bool { shell.isTabActive && !shell.isRootCovered }

    private var snapshot: LAAChatsSnapshot {
        let people = LAAStaff.allCases.compactMap { staff -> LAAChatsPerson? in
            let expected = "laa-\(staff.rawValue)"
            let found = appState.profiles.first { AppState.profilesMatch($0, expected) }
            guard staff == .ciel || found != nil else { return nil }
            let profile = found ?? expected
            let name = appState.profileHermesNames[profile] ?? staff.name
            return LAAChatsPerson(profile: profile, name: name, role: staff.role,
                                  available: found == expected && appState.isConnected)
        }
        let sessionsState: LAAChatsLoadState
        if !appState.isConnected && !appState.isConnecting {
            sessionsState = .offline
        } else {
            switch appState.sessionCatalogPhase {
            case .notLoaded: sessionsState = .loading
            case .loaded: sessionsState = .ready
            case .failed(let message): sessionsState = .failed(message)
            }
        }
        let groupsState: LAAChatsLoadState
        if !appState.isConnected {
            groupsState = appState.isConnecting ? .loading : .offline
        } else {
            switch appState.groupChatPhase {
            case .idle, .loading: groupsState = .loading
            case .available:
                groupsState = groupReadDashboard == appState.activeDashboardID ? groupReadState : .loading
            case .gatewayUnsupported: groupsState = .unsupported
            case .failed(let message): groupsState = .failed(message)
            }
        }
        return LAAChatsSnapshot(
            people: people,
            rooms: groupReadDashboard == appState.activeDashboardID ? loadedRooms : [],
            sessions: AllProfilesChats.newestFirst(appState.chatListSessions.filter { !$0.isArchived }),
            activeProfile: appState.activeProfile,
            groupsState: groupsState, sessionsState: sessionsState,
            canCreateChat: appState.canTapNewChat,
            canCreateGroup: appState.isConnected && appState.groupChatPhase == .available
        )
    }

    var body: some View {
        Group {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-LAA_UI_TEST_CHATS") {
                LAAChatsFixtureView()
            } else {
                liveContent
            }
            #else
            liveContent
            #endif
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var liveContent: some View {
        LAAChatsContent(snapshot: snapshot, settingsAvailable: settings != nil,
                        openPerson: openPerson, openRoom: { room in
            Task { await appState.openGroupRoom(room) }
        }, openSession: { session in
            appState.dismissSidebarDrawer()
            appState.openListedSession(session)
        }, newChat: {
            appState.startNewChat()
        }, newGroup: {
            showingGroupCreator = true
        }, openSettings: {
            settings?()
        }, retry: {
            Task { await refresh() }
        }, searchChanged: {
            if shown { appState.noteChatListInteraction() }
        })
        .sheet(isPresented: $showingGroupCreator) {
            NavigationStack {
                LAAGroupCreateView(roster: appState.botRoster) { name, bots, roomID in
                    let created = await appState.createGroupRoom(name: name, bots: bots, roomID: roomID)
                    if created { showingGroupCreator = false }
                    return created
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(LAACopy.chatsCancel) { showingGroupCreator = false }
                    }
                }
            }
        }
        .task(id: "\(appState.activeDashboardID?.uuidString ?? "-")|\(appState.activeProfile)|\(appState.isConnected)|\(appState.turnState == .synchronizing)|\(shown)") {
            guard shown else { return }
            await appState.loadSessionCatalogIfNeeded()
            if appState.isConnected {
                await appState.refreshBotRoster()
                await appState.refreshGroupChatSupport()
                await readRooms()
            }
        }
        .task(id: "\(appState.activeProfile)|\(shown)") {
            guard shown else { return }
            await appState.runChatListPolling()
        }
        .task(id: "\(appState.activeProfile)|\(appState.isAllProfilesChatsOn)|\(appState.isConnected)|\(shown)") {
            guard shown, appState.isConnected, appState.isAllProfilesChatsOn else { return }
            await appState.runAllProfilesCatalogPolling()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && shown { appState.chatListBecameActive() }
        }
        .refreshable { await refresh() }
    }

    private func refresh() async {
        guard appState.isConnected else { return }
        await appState.loadSessions(forceRefresh: true)
        await appState.refreshBotRoster()
        await appState.refreshGroupChatSupport()
        await readRooms()
        if appState.isAllProfilesChatsOn { appState.refreshAllProfilesCatalog() }
    }

    /// AppState retains its last room list on a failed refresh without
    /// reporting that read's result. Use the same client to confirm this
    /// read, so a failed first read is never presented as an empty list.
    private func readRooms() async {
        guard appState.groupChatPhase == .available, let client = appState.client,
              let dashboard = appState.activeDashboardID else { return }
        let read = UUID()
        groupReadID = read
        if groupReadDashboard != dashboard { loadedRooms = [] }
        groupReadDashboard = dashboard
        groupReadState = .loading
        do {
            let result = try await client.groupsList()
            guard !Task.isCancelled, groupReadID == read, appState.client === client,
                  appState.activeDashboardID == dashboard else { return }
            loadedRooms = result.rooms.filter { !$0.isDisbanded }
            groupReadState = .ready
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, groupReadID == read, appState.client === client,
                  appState.activeDashboardID == dashboard else { return }
            groupReadState = .failed(UserFacingError.message(for: error))
        }
    }

    private func openPerson(_ person: LAAChatsPerson) {
        guard person.available, let employee = LAAWidgetEmployee.forProfile(person.profile) else { return }
        let link = LAAEmployeeWidgetLinks.link(employee: employee, action: .employeeChat, snapshot: nil)
        _ = appState.routeWidgetLaunchURL(link.url)
    }
}
#endif
