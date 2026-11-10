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
            guard staff == .monet || found != nil else { return nil }
            let profile = found ?? expected
            let name = staff.name
            let localMessage = appState.activeRoomSurface == nil && appState.conversationIdentityProfile == profile
                ? appState.messages.last(where: { $0.role == .assistant || $0.role == .user }) : nil
            let rosterPreview = appState.botRoster.first(where: { AppState.profilesMatch($0.name, profile) })?.lastPreview
            return LAAChatsPerson(profile: profile, name: name, role: staff.role,
                                  available: found == expected,
                                  lastMessage: (localMessage?.content ?? rosterPreview).map { ChatQuote.excerpt(of: $0) },
                                  lastMessageAt: localMessage.flatMap { MessageTimestampFormatter.date(from: $0.timestamp) })
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
        let unread = appState.unreadChatCounts(profiles: Set(people.map(\.profile)))
            .filter { $0.value > 0 }
        return LAAChatsSnapshot(
            people: people,
            rooms: groupReadDashboard == appState.activeDashboardID ? loadedRooms : [],
            groupsState: groupsState,
            canCreateChat: appState.canTapNewChat,
            canCreateGroup: appState.isConnected && appState.groupChatPhase == .available,
            unreadByProfile: unread
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
                        openPerson: openPerson, callPerson: { person in
            guard let dashboard = appState.activeDashboardID,
                  let link = WidgetLaunchLink(action: .talk,
                    workspace: WidgetWorkspaceID(dashboardID: dashboard, profile: person.profile), reference: nil) else { return }
            _ = appState.routeWidgetLaunchURL(link.url)
        }, openRoom: { room in
            Task { await appState.openGroupRoom(room) }
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
                .laaSheetSize(.form)
            }
        }
        .task(id: "\(appState.activeDashboardID?.uuidString ?? "-")|\(appState.activeProfile)|\(appState.isConnected)|\(appState.turnState == .synchronizing)|\(shown)") {
            guard shown else { return }
            // The catalog and roster are independent reads:
            // start them together instead of waiting for each round trip in
            // turn. The group capability and the room list are one read (the
            // list is only read when the gateway advertises groups), and that
            // read's own rooms are what this list shows.
            async let catalog: Void = appState.loadSessionCatalogIfNeeded()
            guard appState.isConnected else {
                await catalog
                return
            }
            async let roster: Void = appState.refreshBotRoster()
            await readRooms()
            _ = await (catalog, roster)
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
        await readRooms()
        if appState.isAllProfilesChatsOn { appState.refreshAllProfilesCatalog() }
    }

    /// The room section's one read: the same probe-and-list call the group
    /// screens use, so the rooms on screen are the rooms this read found.
    /// The outcome is kept apart from an empty list: a failed first read is
    /// `.failed` (with the last list, if any, left on screen), never "no
    /// rooms". A read whose epoch, dashboard or connection changed, or that
    /// was cancelled, is not adopted.
    private func readRooms() async {
        guard appState.isConnected, let client = appState.client,
              let dashboard = appState.activeDashboardID else { return }
        let read = UUID()
        groupReadID = read
        if groupReadDashboard != dashboard {
            // Another dashboard's rooms are not this one's, and neither is
            // its readiness: an empty list must never read as loaded.
            loadedRooms = []
            groupReadDashboard = dashboard
            groupReadState = .loading
        } else if groupReadState != .ready {
            // A ready list already on screen stays while it refreshes: going
            // back to loading would blank the section and redraw the whole
            // list. The read still runs on every entry, so a new room arrives.
            groupReadState = .loading
        }
        let outcome = await appState.refreshGroupChatSupport()
        guard !Task.isCancelled, groupReadID == read, appState.client === client,
              appState.activeDashboardID == dashboard else { return }
        switch outcome {
        case .read(let rooms):
            loadedRooms = rooms
            groupReadState = .ready
        case .failed(let message):
            groupReadState = .failed(message)
        case .unavailable, .cancelled, .superseded:
            // The snapshot's own state (offline, unsupported) or a newer read
            // owns the section; this answer is not the one to show.
            break
        }
    }

    private func openPerson(_ person: LAAChatsPerson) {
        guard person.available, LAAStaff(profile: person.profile) != nil,
              let dashboardID = appState.activeDashboardID,
              let link = WidgetLaunchLink(action: .employeeChat,
                  workspace: WidgetWorkspaceID(dashboardID: dashboardID, profile: person.profile), reference: nil) else { return }
        _ = appState.routeWidgetLaunchURL(link.url)
    }
}
#endif
