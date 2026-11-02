#if LAA_BUILD
import SwiftUI

/// The LAA list is a presentation of the existing Hermes state. Employee
/// taps use the same identity-preserving route as the employee widget.
@MainActor
struct LAAChatsView: View {
    @ObservedObject var appState: AppState
    /// The Mac's list column asks for a highlighted row and forwards the
    /// menu bar's search, reload and new-chat requests. The phone passes none.
    var selection: LAAChatsListSelection? = nil
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
        var unread: [String: Int] = [:]
        for person in people {
            if let count = appState.unreadChatCount(profile: person.profile), count > 0 { unread[person.profile] = count }
        }
        let runs = appState.sessions
            .filter { $0.source == .cron && !$0.isArchived }
            .sorted { ($0.lastActivityAt ?? 0) > ($1.lastActivityAt ?? 0) }
        return LAAChatsSnapshot(
            people: people,
            rooms: groupReadDashboard == appState.activeDashboardID ? loadedRooms : [],
            groupsState: groupsState,
            canCreateChat: appState.canTapNewChat,
            canCreateGroup: appState.isConnected && appState.groupChatPhase == .available,
            unreadByProfile: unread,
            cronJobs: appState.cronJobs,
            cronRuns: Array(runs.prefix(5)),
            cronZoneLabel: ProfileTimeZone.scheduleZoneLabel(profileSetting: appState.activeProfileTimeZoneSetting),
            cronProfile: appState.activeProfile
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
    }

    private var liveContent: some View {
        LAAChatsContent(snapshot: snapshot, settingsAvailable: settings != nil,
                        selection: selection,
                        openPerson: openPerson, openRoom: { room in
            Task { await appState.openGroupRoom(room) }
        }, openRun: { run in
            _ = appState.openChatFromLiveCall(run.id)
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
