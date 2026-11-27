import Foundation

extension AppState {
    /// Widget URLs have their own strict parser. A malformed URL in this
    /// namespace is still consumed so it cannot fall through to permissive
    /// app-link parsing.
    func routeWidgetLaunchURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "conduit",
              components.host?.lowercased() == "widget" else { return false }
        guard var link = WidgetLaunchLink(url: url) else { return true }
        #if LAA_BUILD
        // Usage does not need a dashboard or a chat session. Keep the request
        // until the LAA shell is mounted, including on a cold launch.
        if link.action == .usage {
            laaWidgetUsagePending = true
            return true
        }
        // The widget may have been installed before its first snapshot. Bind
        // that link to the app's current dashboard, without guessing a host.
        if let workspace = link.workspace,
           workspace.dashboardID == LAAEmployeeWidgetLinks.unresolvedDashboard,
           LAAWidgetEmployee.forProfile(workspace.profile) != nil,
           let dashboardID = activeDashboardID,
           let resolved = WidgetLaunchLink(action: link.action,
               workspace: WidgetWorkspaceID(dashboardID: dashboardID, profile: workspace.profile),
               reference: link.reference) {
            link = resolved
        }
        // The foreground/bootstrap path already owns this dashboard's
        // socket and catalog. Let it finish rather than demote its sync and
        // repeat the work on the employee route.
        if !laaEmployeeLaunchJoinsConnectionWork(link) { cancelChatResumeRestoration() }
        #else
        cancelChatResumeRestoration()
        #endif
        newChatLaunchStartedInApp = false
        widgetLaunchCoordinator.receive(link)
        // A New Chat's chat shows straight away, empty, while it waits for
        // what its launch needs.
        if showsPendingNewChat { revealChatForWidgetLaunch() }
        return true
    }

    func prepareWidgetLaunch(_ link: WidgetLaunchLink, lease: WidgetLaunchLease) async -> WidgetLaunchOutcome {
        guard lease.isCurrent else { return .deferred }
        guard widgetForegroundReady else { return .deferred }
        if link.action == .open, link.workspace == nil { return .handled }
        guard let workspace = link.workspace else { return .failed(AppLocalization.string("WidgetLaunch.WorkspaceUnavailable")) }
        guard savedDashboardRegistry.dashboard(with: workspace.dashboardID) != nil else {
            #if LAA_BUILD
            if LAAWidgetEmployee.forProfile(workspace.profile) != nil {
                return .failed(LAAEmployeeWidgetLinks.missingDashboardMessage)
            }
            #endif
            return .failed(AppLocalization.string("WidgetLaunch.WorkspaceUnavailable"))
        }
        if isVoiceCallInProgress {
            guard link.action == .open,
                  workspace.dashboardID == activeDashboardID,
                  workspace.profile == activeProfile else {
                return .failed(AppLocalization.string("End the call to open a chat in another workspace."))
            }
            return .handled
        }

        // A profile's client and identity can be between owners while the
        // previous switch is still finishing. Wait even when the desired
        // profile currently appears selected; its switch may yet roll back.
        guard !isProfileSwitching else { return .deferred }
        #if LAA_BUILD
        if link.action == .employeeChat, workspace.dashboardID == activeDashboardID {
            if !isConnected, !networkPathUsable {
                return laaEmployeeOfflineFailure(workspace: workspace, lease: lease)
            }
            if laaEmployeeBootstrapInFlight { return .deferred }
        }
        #endif

        if workspace.dashboardID != activeDashboardID {
            await switchDashboard(to: workspace.dashboardID, widgetLease: lease)
            guard lease.isCurrent else { return .deferred }
            guard activeDashboardID == workspace.dashboardID else {
                return showLogin ? .failed(AppLocalization.string("WidgetLaunch.WorkspaceUnavailable")) : .deferred
            }
        } else if !isConnected && !isConnecting {
            await switchDashboard(to: workspace.dashboardID, widgetLease: lease)
            guard lease.isCurrent else { return .deferred }
        }
        guard activeDashboardID == workspace.dashboardID else {
            return .failed(AppLocalization.string("WidgetLaunch.WorkspaceUnavailable"))
        }
        if showLogin, widgetAwaitingInteractiveAuthenticationDashboardID == workspace.dashboardID {
            return .deferred
        }
        guard isConnected else {
            #if LAA_BUILD
            if link.action == .employeeChat, !networkPathUsable {
                return laaEmployeeOfflineFailure(workspace: workspace, lease: lease)
            }
            if LAAWidgetEmployee.forProfile(workspace.profile) != nil, !isConnecting {
                return .failed(LAAEmployeeWidgetLinks.offlineMessage)
            }
            #endif
            return isConnecting ? .deferred : .failed(AppLocalization.string("WidgetLaunch.WorkspaceUnavailable"))
        }
        #if LAA_BUILD
        if LAAStaff.isHidden(profile: workspace.profile) {
            return .failed(AppLocalization.string("WidgetLaunch.WorkspaceUnavailable"))
        }
        #endif
        guard profiles.contains(where: { $0 == workspace.profile })
                || workspace.profile == "default"
                || workspace.profile == defaultProfileName else {
            #if LAA_BUILD
            if LAAWidgetEmployee.forProfile(workspace.profile) != nil, widgetSettledCatalogOwner != nil {
                return .failed(LAAEmployeeWidgetLinks.missingProfileMessage)
            }
            #endif
            return widgetSettledCatalogOwner == nil
                ? .deferred
                : .failed(AppLocalization.string("WidgetLaunch.WorkspaceUnavailable"))
        }
        if activeProfile != workspace.profile {
            let previousError = errorMessage
            let switched = await switchProfileForWidget(to: workspace.profile, lease: lease)
            guard lease.isCurrent else { return .deferred }
            guard switched, activeProfile == workspace.profile else {
                if let errorMessage, errorMessage != previousError {
                    return .failed(errorMessage)
                }
                #if LAA_BUILD
                if LAAWidgetEmployee.forProfile(workspace.profile) != nil {
                    return .failed("社員のチャットを開けませんでした。もう一度お試しください。")
                }
                #endif
                return .failed(AppLocalization.string("WidgetLaunch.WorkspaceUnavailable"))
            }
        }
        guard lease.isCurrent else { return .deferred }
        lease.bindTargetOwnership { [weak self] in
            self?.activeDashboardID == workspace.dashboardID && self?.activeProfile == workspace.profile
        }
        if link.action != .open, widgetSettledCatalogOwner != workspace {
            // The link itself cancels the launch or return-to-app sync that
            // would have read this catalog (routeWidgetLaunchURL), and a
            // cancelled sync drops the rows it fetched. Read it here rather
            // than wait for a load nothing else starts.
            #if LAA_BUILD
            let catalogSocket = link.action == .employeeChat && client?.isConnected == true ? client : nil
            #endif
            #if LAA_BUILD
            let loaded = await loadSessionsForWidgetLaunch(employeeChat: link.action == .employeeChat)
            #else
            let loaded = await loadSessionsForWidgetLaunch()
            #endif
            guard lease.isCurrent else { return .deferred }
            if widgetSettledCatalogOwner != workspace {
                #if LAA_BUILD
                if link.action == .employeeChat, !loaded {
                    if !networkPathUsable || catalogSocket?.isConnected == false {
                        return laaEmployeeOfflineFailure(workspace: workspace, lease: lease)
                    }
                    return .failed(AppLocalization.string("WidgetLaunch.ConversationUnavailable"))
                }
                #endif
                return .deferred
            }
        }
        if link.action == .resume, let reference = link.reference, reference.kind == .dashboard {
            guard widgetSettledCatalogOwner == workspace else { return .deferred }
            guard activeProfileSessions.contains(where: { $0.id == reference.sessionID
                || $0.alternateIds.contains(reference.sessionID)
                || $0.storedSessionId == reference.sessionID }) else {
                return .failed(AppLocalization.string("WidgetLaunch.ConversationUnavailable"))
            }
        }
        return .handled
    }

    func performWidgetLaunch(_ link: WidgetLaunchLink, lease: WidgetLaunchLease) async -> WidgetLaunchOutcome {
        guard lease.isCurrent else { return .deferred }
        if link.action == .open { return .handled }
        guard let workspace = link.workspace,
              activeDashboardID == workspace.dashboardID,
              activeProfile == workspace.profile else {
            return .failed(AppLocalization.string("WidgetLaunch.WorkspaceUnavailable"))
        }
        revealChatForWidgetLaunch()
        switch link.action {
        case .open:
            return .handled
        case .newChat:
            let previous = activeSessionId
            await createNewSession(widgetLease: lease)
            guard lease.isCurrent else { return .deferred }
            return activeSessionId != previous
                ? .handled
                : .failed(AppLocalization.string("WidgetLaunch.ConversationUnavailable"))
        case .resume:
            guard let reference = link.reference else {
                return .failed(AppLocalization.string("WidgetLaunch.ConversationUnavailable"))
            }
            return await openWidgetConversation(reference, workspace: workspace, lease: lease)
        case .talk:
            #if LAA_BUILD
            if let staff = LAAStaff(profile: workspace.profile), !staff.supportsCalls {
                return .failed("この会話はテキスト専用です")
            }
            #endif
            return await openWidgetVoice(workspace: workspace, lease: lease)
        #if LAA_BUILD
        case .usage:
            return .handled // Normally consumed by routeWidgetLaunchURL.
        case .employeeChat:
            guard isConnected, client?.isConnected != false else {
                // Preparation completed; do not turn authentication or a
                // missing client into a recoverable transport failure.
                if !networkPathUsable || (!showLogin && client?.isConnected == false) {
                    return laaEmployeeOfflineFailure(workspace: workspace, lease: lease)
                }
                return .failed(LAAEmployeeWidgetLinks.offlineMessage)
            }
            let liveSocket = client.flatMap { $0.isConnected ? $0 : nil }
            // Prefer the profile's saved dashboard chat, then its latest
            // available chat. Create only after a successful empty catalog.
            let rows = activeProfileSessions.filter { !$0.isArchived && $0.source == .chat }
            let saved = chatResumeWidgetReference(for: workspace.profile).map(Self.widgetReference(from:))
            let selection: (row: SessionSummary, reference: WidgetConversationReference)?
            if let saved, saved.kind == .dashboard, saved.scopeProfile == workspace.profile,
               let row = rows.first(where: { $0.id == saved.sessionID || $0.storedSessionId == saved.sessionID })
                    ?? rows.first(where: { $0.alternateIds.contains(saved.sessionID) }) {
                selection = (row, saved)
            } else {
                selection = ChatResumeSessionResolver.latestChat(in: rows).map { row in
                    (row, WidgetConversationReference(kind: .dashboard, scopeProfile: workspace.profile, botName: nil,
                        botLabel: nil, sessionID: row.storedSessionId ?? row.id, isUnverified: false))
                }
            }
            if let selection {
                if laaReuseAttachedEmployeeChat(selection.row, workspace: workspace, lease: lease) { return .handled }
                let outcome = await openWidgetConversation(selection.reference, workspace: workspace, lease: lease)
                if lease.isCurrent, outcome != .handled, outcome != .superseded,
                   !networkPathUsable || liveSocket?.isConnected == false {
                    return laaEmployeeOfflineFailure(workspace: workspace, lease: lease)
                }
                return outcome
            }
            guard widgetSettledCatalogOwner == workspace else { return .deferred }
            let created = await createNewSession(widgetLease: lease)
            guard lease.isCurrent else { return .deferred }
            guard let created, activeSessionId == created else {
                if !networkPathUsable || liveSocket?.isConnected == false {
                    return .failed(LAAEmployeeWidgetLinks.offlineMessage)
                }
                return .failed(AppLocalization.string("WidgetLaunch.ConversationUnavailable"))
            }
            return .handled
        #endif
        }
    }

    /// The chat a widget opens has to be what's on screen. The Sessions
    /// drawer (left open, or put up as the return surface before the link
    /// arrived) and the chat's own sheets would otherwise cover the new or
    /// resumed chat, and Talk's call screen would open over a list. Voice
    /// and Live sheets stay: one up is a call in progress, which prepare
    /// already refuses for anything but a plain open. This runs before the
    /// outcome is known on purpose: Talk's call screen can't present over
    /// them, and a launch that fails reports it over the chat. A call
    /// screen up early for its launch (Talk, Siri) needs the same room.
    func revealChatForWidgetLaunch() {
        dismissSidebarDrawer()
        requestSettingsDismissal()
        showModelPicker = false
        showContextSheet = false
        showWorkspaceSheet = false
        showGatewaySheet = false
        showAgentsSheet = false
        dismissChatCallTranscript()
    }
}
