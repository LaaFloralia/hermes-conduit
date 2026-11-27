#if LAA_BUILD
import Combine
import Foundation
import XCTest
@testable import Conduit

@MainActor
final class LAAChatConnectionTests: XCTestCase {
    private let session = "fixture-live"
    private let stored = "fixture-stored"
    private let epoch = "epoch-a"

    func testCachedOpeningEnablesSendBeforeAttachAndKeepsOneEditableEcho() async throws {
        let dashboard = UUID()
        let profile = "laa-monet"
        let workspace = WidgetWorkspaceID(dashboardID: dashboard, profile: profile)
        let link = try XCTUnwrap(WidgetLaunchLink(action: .employeeChat, workspace: workspace, reference: nil))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = OfflineChatCacheStore(directory: directory)
        let row = SessionSummary(id: stored, alternateIds: [], title: "Fixture", model: "Fixture", updatedLabel: "now",
                                 profile: profile, source: .chat, isActive: false, isArchived: false, lineageRootId: nil)
        cache.record(dashboardID: dashboard, profile: profile, sessionID: stored, title: row.title,
                     messages: [.init(id: "saved", role: .assistant, content: "Fixture cached row", timestamp: "1")],
                     sessions: [row])
        for iteration in 1...5 {
            let defaults = makeScratchDefaults("LAAChatConnectionTests-opening")
            let state = AppState(defaults: defaults, loadSavedConnection: false,
                                 sessionPresentationCache: SessionPresentationCache(defaults: defaults), offlineChatCache: cache)
            let start = ContinuousClock.now
            state.widgetLaunchPendingLinkChanged(link)
            let preview = state.laaEmployeeChatPreview
            XCTAssertFalse(preview.canQueue("fixture turn", isComposing: false))
            try await wait { preview.presentation?.displayedMessages.first?.id == "saved" }
            let firstCachedRow = start.duration(to: .now)
            XCTAssertTrue(preview.canQueue("fixture turn", isComposing: false))
            XCTAssertFalse(preview.canQueue("fixture turn", isComposing: true))
            let newCanSend = start.duration(to: .now)
            let key = ComposerDraftKey(profile: profile, sessionID: stored, dashboardID: dashboard)
            XCTAssertTrue(state.laaQueueEmployeeOpeningSend("fixture turn", draftKey: key))
            let echoID = try XCTUnwrap(preview.queuedSend?.id)
            XCTAssertFalse(state.laaQueueEmployeeOpeningSend("do not duplicate", draftKey: key))
            XCTAssertEqual(preview.queuedSend?.id, echoID)
            // Exercise the old rule against the same controlled timeline:
            // the enabled flag was false for the entire fixture attach delay.
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertNotNil(state.laaOpeningEmployeeChat)
            state.laaEmployeeChatLaunchEnded(link, outcome: nil)
            XCTAssertNil(state.laaOpeningEmployeeChat)
            let oldAttachGate = start.duration(to: .now)
            XCTAssertNil(preview.queuedSend)
            XCTAssertEqual(state.composerDraftStore.draft(for: key).text, "fixture turn")
            print("LAA_PERF opening_run=\(iteration) old_send_gate=\(oldAttachGate) new_send_gate=\(newCanSend) cached_row_shared_path=\(firstCachedRow)")
        }
    }

    func testFailedOpeningKeepsDraftEditableButCannotQueueUntilRetry() throws {
        let dashboard = UUID()
        let profile = "laa-monet"
        let workspace = WidgetWorkspaceID(dashboardID: dashboard, profile: profile)
        let link = try XCTUnwrap(WidgetLaunchLink(action: .employeeChat, workspace: workspace, reference: nil))
        let key = ComposerDraftKey(profile: profile, sessionID: stored, dashboardID: dashboard)
        let defaults = makeScratchDefaults("LAAChatConnectionTests-failed")
        let state = AppState(defaults: defaults, loadSavedConnection: false,
                             sessionPresentationCache: SessionPresentationCache(defaults: defaults))
        state.widgetLaunchPendingLinkChanged(link)
        state.laaEmployeeChatPreview.begin(workspace: workspace, directory: FileManager.default.temporaryDirectory, preferredSessionID: stored)
        state.laaEmployeeChatLaunchEnded(link, outcome: .failed("fixture unavailable"))
        XCTAssertFalse(state.laaEmployeeChatPreview.canQueue("draft", isComposing: false))
        XCTAssertFalse(state.laaQueueEmployeeOpeningSend("draft", draftKey: key))
        XCTAssertNil(state.laaEmployeeChatPreview.queuedSend)

        state.widgetLaunchPendingLinkChanged(link)
        state.laaEmployeeChatPreview.begin(workspace: workspace, directory: FileManager.default.temporaryDirectory, preferredSessionID: stored)
        XCTAssertTrue(state.laaEmployeeChatPreview.canQueue("draft", isComposing: false))
        state.laaDismissEmployeeChatPreview()
    }

    func testQueuedPreviewSubmitsOnceAfterItsOwnLiveAttach() async throws {
        let dashboard = SavedDashboard(id: UUID(), label: "Fixture", normalizedURL: "https://r1.invalid")
        let profile = "laa-monet"
        let workspace = WidgetWorkspaceID(dashboardID: dashboard.id, profile: profile)
        let link = try XCTUnwrap(WidgetLaunchLink(action: .employeeChat, workspace: workspace, reference: nil))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeScratchDefaults("LAAChatConnectionTests-attach")
        let cache = OfflineChatCacheStore(directory: directory.appendingPathComponent("cache"))
        let draftStore = ComposerDraftStore(fileURL: directory.appendingPathComponent("drafts.json"))
        let selected = employeeRow(profile: profile)
        cache.record(dashboardID: dashboard.id, profile: profile, sessionID: stored, title: "Fixture",
                     messages: [ChatMessage(id: "cached", role: .assistant, content: "Fixture", timestamp: "1")],
                     sessions: [selected])
        let state = AppState(defaults: defaults, loadSavedConnection: false,
                             dashboardRegistry: .init(activeDashboardID: dashboard.id, dashboards: [dashboard]),
                             sessionPresentationCache: SessionPresentationCache(defaults: defaults),
                             offlineChatCache: cache, composerDraftStore: draftStore)
        _ = state.handleScenePhase(.active)
        state.deviceConditionsChanged(.init(pathSatisfied: true))
        state.showLogin = false
        state.setActiveProfileForTesting(profile)
        let (previousClient, previousSocket) = try await connect(profile: profile, capabilities: ["client_turn_id": true])
        defer { previousClient.disconnect() }
        state.client = previousClient
        state.connection = previousClient.connection
        state.isConnected = true
        state.sessions = [selected]
        state.profiles = [profile]
        state.widgetSettledCatalogOwner = workspace
        XCTAssertTrue(state.routeWidgetLaunchURL(link.url))
        _ = try await request("session.resume", previousSocket)
        let key = ComposerDraftKey(profile: profile, sessionID: stored, dashboardID: dashboard.id)
        try await wait { state.laaEmployeeChatPreview.presentation?.composerSessionID == self.stored }
        XCTAssertTrue(draftStore.save(.init(text: "fixture turn", attachments: [], replyReference: nil), for: key))
        XCTAssertTrue(state.laaQueueEmployeeOpeningSend("fixture turn", draftKey: key))
        let id = try XCTUnwrap(state.laaEmployeeChatPreview.queuedSend?.id)
        // Disconnect the actual transport while the first resume is held.
        // Nothing has been sent, and there is no user retry in this test.
        previousClient.disconnect()
        state.isConnected = false
        try await wait { state.laaEmployeeChatPreview.recoversAfterTransportLoss }
        XCTAssertEqual(state.laaEmployeeChatPreview.queuedSend?.id, id)
        XCTAssertFalse(state.laaEmployeeChatPreview.canQueue("second turn", isComposing: false))
        XCTAssertFalse(previousSocket.methods.contains("prompt.submit"))
        let (client, socket) = try await connect(profile: profile, capabilities: ["client_turn_id": true])
        defer { client.disconnect() }
        state.client = client
        state.connection = client.connection
        state.isConnected = true
        let resume = try await request("session.resume", socket)
        XCTAssertEqual(state.laaEmployeeChatPreview.queuedSend?.id, id)
        XCTAssertFalse(socket.methods.contains("prompt.submit"))
        let rotatedRuntimeID = "rotated-runtime"
        try socket.reply(resume, ["session_id": rotatedRuntimeID, "stored_session_id": stored, "running": false])
        let prompt = try await request("prompt.submit", socket)
        let params = try XCTUnwrap(prompt["params"] as? [String: Any])
        XCTAssertEqual(params["session_id"] as? String, rotatedRuntimeID)
        XCTAssertEqual(params["client_turn_id"] as? String, id.uuidString)
        XCTAssertEqual(params["text"] as? String, "fixture turn")
        try socket.reply(prompt, ["status": "streaming"])
        state.settlePendingComposerSend()
        try await wait { state.deliveringPendingComposerSendIDs.isEmpty }
        XCTAssertEqual(socket.methods.filter { $0 == "prompt.submit" }.count, 1)
        XCTAssertEqual(state.messages.filter { $0.role == .user }.count, 1)
        XCTAssertFalse(previousSocket.methods.contains("prompt.submit"))
    }

    func testEmployeeGenericFailureDoesNotAutoRetryEvenWithOfflineBannerText() async throws {
        let profile = "laa-monet"
        let dashboard = SavedDashboard(id: UUID(), label: "Fixture", normalizedURL: "https://r1.invalid")
        let workspace = WidgetWorkspaceID(dashboardID: dashboard.id, profile: profile)
        let link = try XCTUnwrap(WidgetLaunchLink(action: .employeeChat, workspace: workspace, reference: nil))
        let defaults = makeScratchDefaults("LAAChatConnectionTests-retry-required")
        let state = AppState(defaults: defaults, loadSavedConnection: false,
                             dashboardRegistry: .init(activeDashboardID: dashboard.id, dashboards: [dashboard]),
                             sessionPresentationCache: SessionPresentationCache(defaults: defaults), composerDraftStore: .init())
        _ = state.handleScenePhase(.active)
        state.deviceConditionsChanged(.init(pathSatisfied: true))
        state.showLogin = false
        state.setActiveProfileForTesting(profile)
        state.widgetLaunchPendingLinkChanged(link)
        state.laaEmployeeChatPreview.begin(workspace: workspace, directory: FileManager.default.temporaryDirectory, preferredSessionID: stored)
        let key = ComposerDraftKey(profile: profile, sessionID: stored, dashboardID: dashboard.id)
        state.laaEmployeeChatLaunchEnded(link, outcome: .failed(LAAEmployeeWidgetLinks.offlineMessage))
        XCTAssertFalse(state.laaEmployeeChatPreview.canQueue("fixture draft", isComposing: false))
        XCTAssertFalse(state.laaQueueEmployeeOpeningSend("fixture draft", draftKey: key))
        state.widgetLaunchPendingLinkChanged(link)
        state.laaEmployeeChatPreview.begin(workspace: workspace, directory: FileManager.default.temporaryDirectory, preferredSessionID: stored)
        XCTAssertTrue(state.laaQueueEmployeeOpeningSend("fixture draft", draftKey: key))
        let queued = try XCTUnwrap(state.laaEmployeeChatPreview.queuedSend)
        state.laaEmployeeChatLaunchEnded(link, outcome: .failed(LAAEmployeeWidgetLinks.offlineMessage))
        XCTAssertFalse(state.laaEmployeeChatPreview.recoversAfterTransportLoss)
        let (client, socket) = try await connect(profile: profile, capabilities: ["client_turn_id": true])
        defer { client.disconnect() }
        state.client = client
        state.connection = client.connection
        state.isConnected = true
        XCTAssertNil(state.widgetLaunchCoordinator.pendingLink)
        XCTAssertEqual(state.laaEmployeeChatPreview.queuedSend?.id, queued.id)
        XCTAssertFalse(socket.methods.contains("session.resume"))
        XCTAssertFalse(socket.methods.contains("prompt.submit"))
    }

    func testEmployeePreviewNeverSendsUnboundOrMismatchedDraftIntoLatestChat() async throws {
        let profile = "laa-monet"
        let dashboard = SavedDashboard(id: UUID(), label: "Fixture", normalizedURL: "https://r1.invalid")
        let workspace = WidgetWorkspaceID(dashboardID: dashboard.id, profile: profile)
        let link = try XCTUnwrap(WidgetLaunchLink(action: .employeeChat, workspace: workspace, reference: nil))
        for cachedTarget in [nil, stored] as [String?] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("drafts.json")
            let drafts = ComposerDraftStore(fileURL: file)
            let cache = OfflineChatCacheStore(directory: directory.appendingPathComponent("cache"))
            if let cachedTarget {
                cache.record(dashboardID: dashboard.id, profile: profile, sessionID: cachedTarget, title: "Original",
                             messages: [ChatMessage(id: "cached", role: .assistant, content: "Fixture", timestamp: "1")],
                             sessions: [employeeRow(profile: profile)])
            }
            let defaults = makeScratchDefaults("LAAChatConnectionTests-restore")
            let state = AppState(defaults: defaults, loadSavedConnection: false,
                                 dashboardRegistry: .init(activeDashboardID: dashboard.id, dashboards: [dashboard]),
                                 sessionPresentationCache: SessionPresentationCache(defaults: defaults),
                                 offlineChatCache: cache, composerDraftStore: drafts)
            state.setActiveProfileForTesting(profile)
            let (client, socket) = try await connect(profile: profile, capabilities: ["client_turn_id": true])
            defer { client.disconnect() }
            state.client = client
            state.connection = client.connection
            state.isConnected = true
            let differentID = "unrelated-durable"
            state.sessions = [employeeRow(profile: profile, durableID: differentID)]
            state.widgetSettledCatalogOwner = workspace
            state.widgetLaunchPendingLinkChanged(link)
            if let cachedTarget {
                try await wait { state.laaEmployeeChatPreview.presentation?.composerSessionID == cachedTarget }
            }
            let key = ComposerDraftKey(profile: profile, sessionID: cachedTarget ?? ComposerDraftKey.newConversationSessionID,
                                       dashboardID: dashboard.id)
            let unrelatedKey = ComposerDraftKey(profile: profile, sessionID: differentID, dashboardID: dashboard.id)
            let original = ComposerDraft(text: "original", attachments: [], replyReference: nil)
            let unrelated = ComposerDraft(text: "do not overwrite", attachments: [], replyReference: nil)
            XCTAssertTrue(drafts.save(original, for: key))
            XCTAssertTrue(drafts.save(unrelated, for: unrelatedKey))
            XCTAssertEqual(state.laaEmployeeChatPreview.canQueue(original.text, isComposing: false), cachedTarget != nil)
            XCTAssertEqual(state.laaQueueEmployeeOpeningSend(original.text, draftKey: key), cachedTarget != nil)
            let performing = Task { await state.performWidgetLaunch(link, lease: WidgetLaunchLease(isCurrent: { true })) }
            let resume = try await request("session.resume", socket)
            try socket.reply(resume, ["session_id": session, "stored_session_id": differentID, "running": false])
            let outcome = await performing.value
            XCTAssertEqual(outcome, .handled)
            state.laaEmployeeChatLaunchEnded(link, outcome: outcome)
            state.settlePendingComposerSend()
            XCTAssertNil(state.pendingComposerSend)
            XCTAssertFalse(socket.methods.contains("prompt.submit"))
            let reopened = ComposerDraftStore(fileURL: file)
            XCTAssertEqual(reopened.draft(for: key), original)
            XCTAssertEqual(reopened.draft(for: unrelatedKey), unrelated)
        }
    }

    func testEmployeeQueuePreservesNonTextDraftsAndRequiresAdmittedAttachment() async throws {
        let profile = "laa-monet"
        let dashboard = SavedDashboard(id: UUID(), label: "Fixture", normalizedURL: "https://r1.invalid")
        let workspace = WidgetWorkspaceID(dashboardID: dashboard.id, profile: profile)
        let link = try XCTUnwrap(WidgetLaunchLink(action: .employeeChat, workspace: workspace, reference: nil))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let draftFile = directory.appendingPathComponent("drafts.json")
        let drafts = ComposerDraftStore(fileURL: draftFile)
        let defaults = makeScratchDefaults("LAAChatConnectionTests-attachment-proof")
        let state = AppState(defaults: defaults, loadSavedConnection: false,
                             dashboardRegistry: .init(activeDashboardID: dashboard.id, dashboards: [dashboard]),
                             chatResumeLifecycleOperations: .init(refreshContext: { _, _ in }),
                             sessionPresentationCache: SessionPresentationCache(defaults: defaults), composerDraftStore: drafts)
        state.setActiveProfileForTesting(profile)
        let (client, socket) = try await connect(profile: profile, capabilities: ["client_turn_id": true])
        defer { client.disconnect() }
        state.client = client
        state.connection = client.connection
        state.isConnected = true
        state.activeSessionId = session
        state.sessions = [employeeRow(profile: profile)]
        state.widgetSettledCatalogOwner = workspace
        let key = ComposerDraftKey(profile: profile, sessionID: stored, dashboardID: dashboard.id)
        let quoted = ComposerDraft(text: "", attachments: [],
                                  replyReference: .init(authorName: "Fixture", text: "Quoted", isOwnMessage: false))
        let attachment = Attachment(id: "fixture-file", name: "Fixture.txt", uri: "https://r1.invalid/fixture.txt",
                                    mimeType: "text/plain", kind: .document)
        let withFile = ComposerDraft(text: "file draft", attachments: [attachment])
        state.widgetLaunchPendingLinkChanged(link)
        state.laaEmployeeChatPreview.begin(workspace: workspace, directory: directory, preferredSessionID: stored)
        for draft in [quoted, withFile] {
            XCTAssertTrue(drafts.save(draft, for: key))
            XCTAssertFalse(state.laaQueueEmployeeOpeningSend(draft.text.isEmpty ? "new words" : draft.text, draftKey: key))
            XCTAssertNil(state.laaEmployeeChatPreview.queuedSend)
            XCTAssertEqual(ComposerDraftStore(fileURL: draftFile).draft(for: key), draft)
        }

        let plain = ComposerDraft(text: "saved chat fixture", attachments: [])
        for attachOutsideAppState in [false, true] {
            // Even a raw attach for the runtime is not evidence that this
            // workspace adopted the durable chat into its current viewport.
            if attachOutsideAppState { try await attach(client, socket) }
            XCTAssertEqual(client.laaHasAttachment(session), attachOutsideAppState)
            state.widgetLaunchPendingLinkChanged(link)
            state.laaEmployeeChatPreview.begin(workspace: workspace, directory: directory, preferredSessionID: stored)
            XCTAssertTrue(drafts.save(plain, for: key))
            XCTAssertTrue(state.laaQueueEmployeeOpeningSend(plain.text, draftKey: key))
            state.laaEmployeeChatLaunchEnded(link, outcome: .handled)
            state.settlePendingComposerSend()
            XCTAssertNil(state.laaEmployeeChatPreview.queuedSend)
            XCTAssertNil(state.pendingComposerSend)
            XCTAssertFalse(socket.methods.contains("prompt.submit"))
            XCTAssertEqual(ComposerDraftStore(fileURL: draftFile).draft(for: key), plain)
        }
    }

    func testEmployeeOpenReusesOnlyTheSelectedChatAttachedOnTheCurrentSocket() async throws {
        let profile = "laa-monet"
        let dashboard = SavedDashboard(id: UUID(), label: "Fixture", normalizedURL: "https://r1.invalid")
        let workspace = WidgetWorkspaceID(dashboardID: dashboard.id, profile: profile)
        let link = try XCTUnwrap(WidgetLaunchLink(action: .employeeChat, workspace: workspace, reference: nil))
        let defaults = makeScratchDefaults("LAAChatConnectionTests-reuse")
        let selected = employeeRow(profile: profile)
        let transport = LaneR1Transport()
        let socket = transport.socket
        var catalogReads = 0
        var ticketMints = 0
        let state = AppState(defaults: defaults, loadSavedConnection: false,
                             dashboardRegistry: .init(activeDashboardID: dashboard.id, dashboards: [dashboard]),
                             chatResumeLifecycleOperations: .init(loadCatalog: { _, _ in
                                 catalogReads += 1
                                 return [selected]
                             }, mintTicket: { _ in
                                 ticketMints += 1
                                 return "fresh-fixture-ticket"
                             }, refreshContext: { _, _ in }, pendingApprovals: { _, _ in [] }, makeTransport: { transport }),
                             sessionPresentationCache: SessionPresentationCache(defaults: defaults))
        defer {
            state.client?.disconnect()
            KeychainHelper.clearConnection(dashboardID: dashboard.id)
        }
        _ = state.handleScenePhase(.active)
        state.showLogin = false
        state.setActiveProfileForTesting("default")
        state.connection = .init(baseUrl: dashboard.normalizedURL, ticket: "previous-fixture-ticket")
        state.isConnected = true
        state.profiles = ["default", profile]
        state.widgetLaunchPendingLinkChanged(link)
        let lease = WidgetLaunchLease(isCurrent: { true })
        XCTAssertFalse(state.laaReuseAttachedEmployeeChat(selected, workspace: workspace, lease: lease))

        // Exercise the actual cross-profile preparation: one scoped ticket,
        // catalog and attach, then the employee performer reuses that attach.
        let preparing = Task { await state.prepareWidgetLaunch(link, lease: lease) }
        try await wait { transport.open != nil }
        transport.open?(socket)
        try socket.event(["type": "gateway.ready", "payload": ["replay_epoch": epoch]])
        let handshake = try await request("client.capabilities", socket)
        try socket.reply(handshake, [:])
        let resume = try await request("session.resume", socket)
        try socket.reply(resume, ["session_id": session, "stored_session_id": stored, "running": false])
        let prepared = await preparing.value
        XCTAssertEqual(prepared, .handled)
        let client = try XCTUnwrap(state.client)
        defer { client.disconnect() }
        XCTAssertEqual(client.profile, profile)
        let moved = employeeRow(profile: profile, durableID: "different-durable")
        XCTAssertFalse(state.laaReuseAttachedEmployeeChat(moved, workspace: workspace, lease: lease),
                       "Sharing a historical runtime alias doesn't prove the selected chat is attached")
        XCTAssertFalse(state.laaReuseAttachedEmployeeChat(selected, workspace: workspace,
                                                         lease: WidgetLaunchLease(isCurrent: { false })))
        let outcome = await state.performWidgetLaunch(link, lease: lease)
        XCTAssertEqual(outcome, .handled)
        XCTAssertEqual(ticketMints, 1)
        XCTAssertEqual(catalogReads, 1)
        XCTAssertEqual(socket.methods.filter { $0 == "session.resume" }.count, 1)

        let (replacement, replacementSocket) = try await connect(profile: profile)
        defer { replacement.disconnect() }
        try await attach(replacement, replacementSocket)
        state.client = replacement
        state.connection = replacement.connection
        XCTAssertFalse(state.laaReuseAttachedEmployeeChat(selected, workspace: workspace, lease: lease),
                       "A raw attachment on a replacement client was not admitted into AppState's viewport")
        let fallback = Task { await state.performWidgetLaunch(link, lease: WidgetLaunchLease(isCurrent: { true })) }
        let fallbackResume = try await request("session.resume", replacementSocket, occurrence: 2)
        try replacementSocket.reply(fallbackResume, ["session_id": session, "stored_session_id": stored, "running": false])
        let fallbackOutcome = await fallback.value
        XCTAssertEqual(fallbackOutcome, .handled)
    }

    /// D-25: a Retry on a stalled open starts it over without dropping the
    /// copy on screen or the queued message, which is sent exactly once
    /// with its own turn id when the chat attaches.
    func testRetryOnAStalledOpenKeepsTheQueuedMessageAndSendsItOnce() async throws {
        let dashboard = SavedDashboard(id: UUID(), label: "Fixture", normalizedURL: "https://r1.invalid")
        let profile = "laa-monet"
        let workspace = WidgetWorkspaceID(dashboardID: dashboard.id, profile: profile)
        let link = try XCTUnwrap(WidgetLaunchLink(action: .employeeChat, workspace: workspace, reference: nil))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeScratchDefaults("LAAChatConnectionTests-stall-retry")
        let cache = OfflineChatCacheStore(directory: directory.appendingPathComponent("cache"))
        let draftStore = ComposerDraftStore(fileURL: directory.appendingPathComponent("drafts.json"))
        let selected = employeeRow(profile: profile)
        cache.record(dashboardID: dashboard.id, profile: profile, sessionID: stored, title: "Fixture",
                     messages: [ChatMessage(id: "cached", role: .assistant, content: "Fixture", timestamp: "1")],
                     sessions: [selected])
        let state = AppState(defaults: defaults, loadSavedConnection: false,
                             dashboardRegistry: .init(activeDashboardID: dashboard.id, dashboards: [dashboard]),
                             sessionPresentationCache: SessionPresentationCache(defaults: defaults),
                             offlineChatCache: cache, composerDraftStore: draftStore)
        _ = state.handleScenePhase(.active)
        state.deviceConditionsChanged(.init(pathSatisfied: true))
        state.showLogin = false
        state.setActiveProfileForTesting(profile)
        let (client, socket) = try await connect(profile: profile, capabilities: ["client_turn_id": true])
        defer { client.disconnect() }
        state.client = client
        state.connection = client.connection
        state.isConnected = true
        state.sessions = [selected]
        state.profiles = [profile]
        state.widgetSettledCatalogOwner = workspace
        XCTAssertTrue(state.routeWidgetLaunchURL(link.url))
        // The open stalls on its resume.
        _ = try await request("session.resume", socket)
        let key = ComposerDraftKey(profile: profile, sessionID: stored, dashboardID: dashboard.id)
        try await wait { state.laaEmployeeChatPreview.presentation?.composerSessionID == self.stored }
        XCTAssertTrue(draftStore.save(.init(text: "fixture turn", attachments: [], replyReference: nil), for: key))
        XCTAssertTrue(state.laaQueueEmployeeOpeningSend("fixture turn", draftKey: key))
        let id = try XCTUnwrap(state.laaEmployeeChatPreview.queuedSend?.id)

        state.laaRetryEmployeeChat()
        XCTAssertEqual(state.laaOpeningEmployeeChat, profile, "the opening screen stays")
        XCTAssertNotNil(state.laaEmployeeChatPreview.presentation, "with its copy")
        XCTAssertEqual(state.laaEmployeeChatPreview.queuedSend?.id, id, "and its queued message")
        XCTAssertNotNil(state.widgetLaunchCoordinator.pendingLink, "the open started over")
        XCTAssertFalse(socket.methods.contains("prompt.submit"))

        // The restarted open may ask again or reuse the held resume: answer
        // every resume asked for.
        for _ in 0..<250 where socket.requests.filter({ $0["method"] as? String == "session.resume" }).count < 2 {
            try await Task.sleep(for: .milliseconds(2))
        }
        for resume in socket.requests.filter({ $0["method"] as? String == "session.resume" }).reversed() {
            try socket.reply(resume, ["session_id": session, "stored_session_id": stored, "running": false])
        }
        let prompt = try await request("prompt.submit", socket)
        let params = try XCTUnwrap(prompt["params"] as? [String: Any])
        XCTAssertEqual(params["client_turn_id"] as? String, id.uuidString)
        XCTAssertEqual(params["text"] as? String, "fixture turn")
        try socket.reply(prompt, ["status": "streaming"])
        state.settlePendingComposerSend()
        try await wait { state.deliveringPendingComposerSendIDs.isEmpty }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(socket.methods.filter { $0 == "prompt.submit" }.count, 1, "sent exactly once")
    }

    func testEmployeeOfflinePreflightQueuesAfterFailureAndAutoSendsOnce() async throws {
        try await assertEmployeeOfflinePreflight(autoRecover: true)
    }

    func testEmployeeOfflineQueueRestoresOriginalDraftOnDismiss() async throws {
        try await assertEmployeeOfflinePreflight(autoRecover: false)
    }

    private func assertEmployeeOfflinePreflight(autoRecover: Bool) async throws {
        let profile = "laa-monet"
        let dashboard = SavedDashboard(id: UUID(), label: "Fixture", normalizedURL: "https://r1.invalid")
        let workspace = WidgetWorkspaceID(dashboardID: dashboard.id, profile: profile)
        let link = try XCTUnwrap(WidgetLaunchLink(action: .employeeChat, workspace: workspace, reference: nil))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = OfflineChatCacheStore(directory: directory.appendingPathComponent("cache"))
        let draftFile = directory.appendingPathComponent("drafts.json")
        let drafts = ComposerDraftStore(fileURL: draftFile)
        let selected = employeeRow(profile: profile)
        cache.record(dashboardID: dashboard.id, profile: profile, sessionID: stored, title: "Fixture",
                     messages: [ChatMessage(id: "cached", role: .assistant, content: "Fixture", timestamp: "1")],
                     sessions: [selected])
        let defaults = makeScratchDefaults("LAAChatConnectionTests-offline-preflight")
        let state = AppState(defaults: defaults, loadSavedConnection: false,
                             dashboardRegistry: .init(activeDashboardID: dashboard.id, dashboards: [dashboard]),
                             sessionPresentationCache: SessionPresentationCache(defaults: defaults),
                             offlineChatCache: cache, composerDraftStore: drafts,
                             deviceConditionsUpdates: Empty<DeviceConditions, Never>().eraseToAnyPublisher())
        _ = state.handleScenePhase(.active)
        state.showLogin = false
        state.setActiveProfileForTesting(profile)
        state.profiles = [profile]
        state.deviceConditionsChanged(.init(pathSatisfied: false))
        XCTAssertTrue(state.routeWidgetLaunchURL(link.url))
        try await wait {
            state.laaEmployeeChatPreview.recoversAfterTransportLoss && state.laaEmployeeChatPreview.queueTargetSessionID == self.stored
        }
        XCTAssertEqual(state.laaEmployeeChatPreview.failure, LAAEmployeeWidgetLinks.offlineMessage)
        XCTAssertFalse(state.laaIsEmployeeChatWaiting(for: workspace))
        XCTAssertNil(state.widgetLaunchCoordinator.pendingLink)
        let key = ComposerDraftKey(profile: profile, sessionID: stored, dashboardID: dashboard.id)
        let otherKey = ComposerDraftKey(profile: profile, sessionID: "other-chat", dashboardID: dashboard.id)
        let typed = ComposerDraft(text: "offline text", attachments: [], replyReference: nil)
        let other = ComposerDraft(text: "other draft", attachments: [], replyReference: nil)
        XCTAssertTrue(drafts.save(typed, for: key))
        XCTAssertTrue(drafts.save(other, for: otherKey))
        XCTAssertFalse(state.laaQueueEmployeeOpeningSend(other.text, draftKey: otherKey))
        XCTAssertTrue(state.laaEmployeeChatPreview.canQueue(typed.text, isComposing: false))
        XCTAssertTrue(state.laaQueueEmployeeOpeningSend(typed.text, draftKey: key))
        let queued = try XCTUnwrap(state.laaEmployeeChatPreview.queuedSend)
        XCTAssertEqual(queued.draftKey, key)
        XCTAssertNil(state.pendingComposerSend)
        XCTAssertEqual(ComposerDraftStore(fileURL: draftFile).draft(for: key), .empty)
        if !autoRecover {
            let newer = ComposerDraft(text: "new words", attachments: [],
                                      replyReference: .init(authorName: "Fixture", text: "Later quote", isOwnMessage: false))
            XCTAssertTrue(drafts.save(newer, for: key))
            state.laaDismissEmployeeChatPreview()
            let reopened = ComposerDraftStore(fileURL: draftFile)
            XCTAssertEqual(reopened.draft(for: key).text, "offline text\n\nnew words")
            XCTAssertEqual(reopened.draft(for: key).replyReference, newer.replyReference)
            XCTAssertEqual(reopened.draft(for: otherKey), other)
            return
        }

        let (client, socket) = try await connect(profile: profile, capabilities: ["client_turn_id": true])
        defer { client.disconnect() }
        state.client = client
        state.connection = client.connection
        state.sessions = [selected]
        state.widgetSettledCatalogOwner = workspace
        state.isConnected = true // The network path is still offline.
        XCTAssertNil(state.widgetLaunchCoordinator.pendingLink)
        XCTAssertFalse(socket.methods.contains("prompt.submit"))
        state.deviceConditionsChanged(.init(pathSatisfied: true))
        let resume = try await request("session.resume", socket)
        XCTAssertEqual(state.laaEmployeeChatPreview.queuedSend?.id, queued.id)
        XCTAssertFalse(socket.methods.contains("prompt.submit"))
        let live = "live-after-offline-preflight"
        try socket.reply(resume, ["session_id": live, "stored_session_id": stored, "running": false])
        let prompt = try await request("prompt.submit", socket)
        let params = try XCTUnwrap(prompt["params"] as? [String: Any])
        XCTAssertEqual(params["session_id"] as? String, live)
        XCTAssertEqual(params["client_turn_id"] as? String, queued.id.uuidString)
        XCTAssertEqual(params["text"] as? String, typed.text)
        try socket.reply(prompt, ["status": "streaming"])
        try await wait { state.deliveringPendingComposerSendIDs.isEmpty }
        state.settlePendingComposerSend()
        XCTAssertEqual(socket.methods.filter { $0 == "prompt.submit" }.count, 1)
        let reopened = ComposerDraftStore(fileURL: draftFile)
        XCTAssertEqual(reopened.draft(for: key), .empty)
        XCTAssertEqual(reopened.draft(for: otherKey), other)
    }

    func testEmployeeWaitingRequiresPendingOwnerAndEndsOnFailure() throws {
        let profile = "laa-monet"
        let dashboard = SavedDashboard(id: UUID(), label: "Fixture", normalizedURL: "https://r1.invalid")
        let workspace = WidgetWorkspaceID(dashboardID: dashboard.id, profile: profile)
        let otherWorkspace = WidgetWorkspaceID(dashboardID: UUID(), profile: profile)
        let link = try XCTUnwrap(WidgetLaunchLink(action: .employeeChat, workspace: workspace, reference: nil))
        let defaults = makeScratchDefaults("LAAChatConnectionTests-waiting-owner")
        let state = AppState(defaults: defaults, loadSavedConnection: false,
                             dashboardRegistry: .init(activeDashboardID: dashboard.id, dashboards: [dashboard]),
                             sessionPresentationCache: SessionPresentationCache(defaults: defaults))
        _ = state.handleScenePhase(.active)
        state.setActiveProfileForTesting(profile)
        state.deviceConditionsChanged(.init(pathSatisfied: true))
        XCTAssertFalse(state.laaIsEmployeeChatWaiting(for: workspace))
        XCTAssertTrue(state.routeWidgetLaunchURL(link.url))
        XCTAssertTrue(state.laaIsEmployeeChatWaiting(for: workspace))
        XCTAssertFalse(state.laaIsEmployeeChatWaiting(for: otherWorkspace))
        state.deviceConditionsChanged(.init(pathSatisfied: false))
        XCTAssertFalse(state.laaIsEmployeeChatWaiting(for: workspace))
        state.deviceConditionsChanged(.init(pathSatisfied: true))
        state.laaEmployeeChatLaunchEnded(link, outcome: .failed(LAAEmployeeWidgetLinks.offlineMessage))
        XCTAssertFalse(state.laaIsEmployeeChatWaiting(for: workspace))
        state.laaDismissEmployeeChatPreview()
    }

    func testEmployeeCatalogFailureEndsTheWaitWithoutCreatingAChat() async throws {
        enum CatalogFailure: Error { case unavailable }
        let profile = "laa-monet"
        let dashboard = SavedDashboard(id: UUID(), label: "Fixture", normalizedURL: "https://r1.invalid")
        let workspace = WidgetWorkspaceID(dashboardID: dashboard.id, profile: profile)
        let link = try XCTUnwrap(WidgetLaunchLink(action: .employeeChat, workspace: workspace, reference: nil))
        let defaults = makeScratchDefaults("LAAChatConnectionTests-catalog")
        var reads = 0
        let state = AppState(defaults: defaults, loadSavedConnection: false,
                             dashboardRegistry: .init(activeDashboardID: dashboard.id, dashboards: [dashboard]),
                             sessionCatalogLoader: { _ in reads += 1; throw CatalogFailure.unavailable },
                             sessionPresentationCache: SessionPresentationCache(defaults: defaults))
        _ = state.handleScenePhase(.active)
        state.setActiveProfileForTesting(profile)
        state.profiles = [profile]
        state.isConnected = true
        state.widgetLaunchPendingLinkChanged(link)
        let outcome = await state.prepareWidgetLaunch(link, lease: WidgetLaunchLease(isCurrent: { true }))
        guard case .failed = outcome else { return XCTFail("A known failed read is not a wait") }
        state.laaEmployeeChatLaunchEnded(link, outcome: outcome)
        XCTAssertNotNil(state.laaEmployeeChatPreview.failure)
        XCTAssertNil(state.activeSessionId)
        XCTAssertEqual(reads, 1)
    }

    func testReasoningOptsInOnlyOnCreateAndEveryResumeWhenAdvertised() async throws {
        let capability = ["reasoning_delta_optin": true]
        for (ready, reply, expected) in [([:], [:], false), (capability, [:], true), ([:], capability, true)] {
            let (client, socket) = try await connect(capabilities: ready, capabilityReply: reply)
            defer { client.disconnect() }
            let create = Task { try await client.createSession() }
            let createRequest = try await request("session.create", socket)
            XCTAssertEqual((createRequest["params"] as? [String: Any])?["include_reasoning_deltas"] as? Bool,
                           expected ? true : nil)
            try socket.reply(createRequest, ["session_id": session, "stored_session_id": stored])
            _ = try await create.value
            for occurrence in 1...2 {
                let id = stored
                let resume = Task { try await client.openSession(id) }
                let resumeRequest = try await request("session.resume", socket, occurrence: occurrence)
                XCTAssertEqual((resumeRequest["params"] as? [String: Any])?["include_reasoning_deltas"] as? Bool,
                               expected ? true : nil)
                try socket.reply(resumeRequest, ["session_id": session, "stored_session_id": stored])
                _ = try await resume.value
            }
            XCTAssertFalse(socket.methods.contains("config.set"))
        }
    }

    func testFirstWireEventImmediatelyPublishesReasoningOrWork() async throws {
        for (event, text) in [("reasoning.delta", "first thought"), ("thinking.delta", "working"),
                              ("status.update", "preparing fixture turn"), ("message.start", ""), ("tool.start", "")] {
            let defaults = makeScratchDefaults("LAAChatConnectionTests")
            let state = AppState(defaults: defaults, loadSavedConnection: false,
                                 sessionPresentationCache: SessionPresentationCache(defaults: defaults))
            state.activeSessionId = session
            let (client, socket) = try await connect()
            var observed = false
            var wireArrival = ContinuousClock.now
            client.onEvent = { streamEvent in
                let started = ContinuousClock.now
                state.handleStreamEvent(streamEvent)
                XCTAssertTrue(state.isBusy, event)
                if event == "reasoning.delta" { XCTAssertEqual(state.liveReasoningSegment?.content, text) }
                else { XCTAssertNil(state.liveReasoningSegment, "status must not render as thought") }
                if event == "thinking.delta" || event == "status.update" {
                    XCTAssertEqual(state.liveTurn.thinkingStatus, LAACopy.chatThinking)
                }
                let now = ContinuousClock.now
                let elapsed = wireArrival.duration(to: now)
                XCTAssertLessThan(elapsed, .milliseconds(50))
                print("LAA_PERF first_event=\(event) wire_to_projection=\(elapsed) reducer=\(started.duration(to: now))")
                observed = true
            }
            wireArrival = .now
            try socket.event(frame(event, at: 1, text: text))
            try await wait { observed }
            client.disconnect()
        }
    }

    func testReadyStatusDoesNotStartWorkAndProgressYieldsToThought() async throws {
        let defaults = makeScratchDefaults("LAAChatConnectionTests-status")
        let state = AppState(defaults: defaults, loadSavedConnection: false,
                             sessionPresentationCache: SessionPresentationCache(defaults: defaults))
        state.activeSessionId = session
        state.handleStreamEvent(.statusUpdate(sessionId: session, kind: .other("status"), text: "ready"))
        XCTAssertFalse(state.isBusy)
        state.handleStreamEvent(.statusUpdate(sessionId: "different-chat", kind: .other("lifecycle"), text: "working"))
        XCTAssertFalse(state.isBusy)
        state.handleStreamEvent(.statusUpdate(sessionId: session, kind: .other("lifecycle"), text: "working"))
        XCTAssertTrue(state.isBusy)
        XCTAssertNil(state.liveReasoningSegment)
        state.handleStreamEvent(.reasoningDelta(sessionId: session, text: "first private thought"))
        XCTAssertEqual(state.liveReasoningSegment?.content, "first private thought")
    }

    func testReconnectMergesBufferedAndReplayedDeltasAndOpenRequestsOnce() async throws {
        for cut in 1...3 {
            let (old, first) = try await connect()
            try await attach(old, first)
            var text = ""
            old.onEvent = { if case .messageDelta(_, let delta) = $0 { text += delta } }
            for sequence in 1...cut {
                try first.event(frame("message.delta", at: sequence, text: "\(sequence)"))
            }
            try await wait { text.count == cut }
            first.drop()
            try await wait { !old.isConnected }
            let cursor = try XCTUnwrap(old.laaReplayCursor(for: session))
            XCTAssertEqual(cursor.sequence, cut)

            let optedIn = cut == 2
            let (next, second) = try await connect(capabilities: optedIn ? ["reasoning_delta_optin": true] : [:])
            var clarify = 0
            next.onEvent = {
                if case .messageDelta(_, let delta) = $0 { text += delta }
                if case .clarify = $0 { clarify += 1 }
            }
            let runtimeID = session
            let durableID = stored
            let reattach = Task { await next.laaReplaySession(runtimeID, from: cursor, storedID: durableID,
                                                               profile: nil, isCurrent: { true }) }
            let activate = try await request(optedIn ? "session.resume" : "session.activate", second)
            let attachParams = try XCTUnwrap(activate["params"] as? [String: Any])
            XCTAssertEqual(attachParams["omit_messages"] as? Bool, true)
            XCTAssertEqual(attachParams["include_reasoning_deltas"] as? Bool, optedIn ? true : nil)
            XCTAssertEqual(attachParams["session_id"] as? String, optedIn ? stored : session)
            try second.reply(activate, ["session_id": session, "running": true])
            let since = try await request("session.events.since", second)
            XCTAssertEqual((since["params"] as? [String: Any])?["last_seen"] as? Int, cut)
            // Live 5 raced the snapshot, live 4 duplicates the last replay frame.
            try second.event(frame("message.delta", at: 5, text: "5"))
            try second.event(frame("message.delta", at: 4, text: "4"))
            let open: [String: Any] = ["jsonrpc": "2.0", "id": "srq-fixture", "method": "clarify",
                                      "params": ["session_id": session, "question": "Fixture question?"]]
            try second.deliver(open)
            try second.reply(since, ["epoch": epoch, "latest_seq": 5, "truncated": false,
                                    "events": ((cut + 1)...4).map { frame("message.delta", at: $0, text: "\($0)") },
                                    "open_requests": [open]])
            let result = await reattach.value
            XCTAssertEqual(result?.running, true)
            try second.event(frame("message.delta", at: 5, text: "duplicate"))
            try second.event(frame("message.delta", at: 6, text: "6"))
            try await wait { text.hasSuffix("6") }
            XCTAssertEqual(text, "123456", "disconnect after \(cut)")
            XCTAssertEqual(clarify, 1)
            XCTAssertFalse(second.methods.contains("prompt.submit"))
            XCTAssertFalse(second.methods.contains("config.set"))
            next.disconnect()
        }
    }

    func testTruncatedRingEpochChangeAndGapRefusePartialReplay() async throws {
        for variant in ["truncated", "changedEpoch", "gap"] {
            let (client, socket) = try await connect()
            var text = ""
            client.onEvent = { if case .messageDelta(_, let delta) = $0 { text += delta } }
            let runtimeID = session
            let cursor = LAAChatEventReplay.Cursor(epoch: epoch, sequence: 1)
            let reattach = Task { await client.laaReplaySession(runtimeID, from: cursor, storedID: nil,
                                                                 profile: nil, isCurrent: { true }) }
            try socket.reply(try await request("session.activate", socket), ["session_id": session, "running": true])
            try socket.reply(try await request("session.events.since", socket), [
                "epoch": variant == "changedEpoch" ? "epoch-b" : epoch,
                "latest_seq": 3, "truncated": variant == "truncated",
                "events": [frame("message.delta", at: variant == "gap" ? 3 : 2, text: "must not apply")],
            ])
            let result = await reattach.value
            XCTAssertNil(result, variant)
            XCTAssertEqual(text, "", variant)
            XCTAssertFalse(socket.methods.contains("prompt.submit"))
            client.disconnect()
        }
    }

    func testContextWaitsForAttachmentAndRetriesOnlyOnceAfterNotInMemory() async throws {
        let (client, socket) = try await connect()
        do { _ = try await client.contextBreakdown(session); XCTFail("only a live attachment may read context") }
        catch { XCTAssertFalse(socket.methods.contains("session.context_breakdown")) }
        try await attach(client, socket)
        let runtimeID = session
        let read = Task { try await client.contextBreakdown(runtimeID, canReattach: { true }, adoptReattached: { _ in true }) }
        let first = try await request("session.context_breakdown", socket)
        try socket.deliver(["id": try XCTUnwrap(first["id"]), "jsonrpc": "2.0",
                            "error": ["code": 4001, "message": "not in memory"]])
        let resume = try await request("session.resume", socket, occurrence: 2)
        XCTAssertEqual((resume["params"] as? [String: Any])?["session_id"] as? String, stored)
        try socket.reply(resume, ["session_id": "fixture-rebound", "stored_session_id": stored])
        let second = try await request("session.context_breakdown", socket, occurrence: 2)
        XCTAssertEqual((second["params"] as? [String: Any])?["session_id"] as? String, "fixture-rebound")
        try socket.reply(second, [:])
        _ = try await read.value
        XCTAssertEqual(socket.methods.filter { $0 == "session.context_breakdown" }.count, 2)
        client.disconnect()
    }

    private func frame(_ type: String, at sequence: Int, text: String) -> [String: Any] {
        ["type": type, "session_id": session, "seq": sequence,
         "payload": ["text": text, "kind": "lifecycle", "tool": "fixture", "tool_use_id": "fixture-tool"]]
    }

    private func employeeRow(profile: String, durableID: String? = nil) -> SessionSummary {
        SessionSummary(id: durableID ?? stored, alternateIds: [session], title: "Fixture", model: "Fixture",
                       updatedLabel: "now", profile: profile, source: .chat, isActive: true,
                       isArchived: false, lineageRootId: nil)
    }

    private func connect(profile: String? = nil, capabilities: [String: Any] = [:], capabilityReply: [String: Any] = [:]) async throws -> (HermesClient, LaneR1Socket) {
        let transport = LaneR1Transport()
        let client = HermesClient(connection: .init(baseUrl: "https://r1.invalid", ticket: "fixture"), profile: profile,
                                  transportFactory: { transport }, monitorsPath: false)
        let connected = Task { try await client.connect() }
        try await wait { transport.open != nil }
        transport.open?(transport.socket)
        try await connected.value
        var payload = capabilities
        payload["replay_epoch"] = epoch
        try transport.socket.event(["type": "gateway.ready", "payload": payload])
        // Capabilities is the observable acknowledgement that ready was parsed.
        let handshake = try await request("client.capabilities", transport.socket)
        try transport.socket.reply(handshake, capabilityReply)
        return (client, transport.socket)
    }

    private func attach(_ client: HermesClient, _ socket: LaneR1Socket) async throws {
        let id = stored
        let attaching = Task { try await client.openSession(id) }
        try socket.reply(try await request("session.resume", socket), ["session_id": session, "stored_session_id": stored])
        _ = try await attaching.value
    }

    private func request(_ method: String, _ socket: LaneR1Socket, occurrence: Int = 1) async throws -> [String: Any] {
        try await wait { socket.requests.filter { $0["method"] as? String == method }.count >= occurrence }
        return socket.requests.filter { $0["method"] as? String == method }[occurrence - 1]
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        struct FixtureTimeout: Error {}
        XCTFail("Fixture did not reach expected state")
        throw FixtureTimeout()
    }
}

private final class LaneR1Transport: HermesWebSocketTransport {
    let socket = LaneR1Socket()
    var open: ((any HermesWebSocket) -> Void)?
    func makeSocket(request: URLRequest, onOpen: @escaping (any HermesWebSocket) -> Void,
                    onCloseBeforeOpen: @escaping (any HermesWebSocket) -> Void) -> any HermesWebSocket {
        open = onOpen
        return socket
    }
    func invalidate() {}
}

private final class LaneR1Socket: HermesWebSocket, @unchecked Sendable {
    private struct Disconnected: Error {}
    private let lock = NSLock()
    private var _requests: [[String: Any]] = []
    private let stream = AsyncThrowingStream<URLSessionWebSocketTask.Message, Error>.makeStream()
    // HermesClient has one receiver per socket; its iterator is never used concurrently.
    private lazy var iterator = stream.stream.makeAsyncIterator()
    var requests: [[String: Any]] { lock.withLock { _requests } }
    var methods: [String] { requests.compactMap { $0["method"] as? String } }
    var closeCode: URLSessionWebSocketTask.CloseCode { .invalid }
    func resume() {}
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) { drop() }
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        do {
            if case .string(let text) = message,
               let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                lock.withLock { _requests.append(object) }
            }
            completionHandler(nil)
        } catch { completionHandler(error) }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        guard let message = try await iterator.next() else { throw Disconnected() }
        return message
    }
    func drop() { stream.continuation.finish(throwing: Disconnected()) }
    func deliver(_ payload: [String: Any]) throws {
        let bytes = try JSONSerialization.data(withJSONObject: payload)
        stream.continuation.yield(.string(String(decoding: bytes, as: UTF8.self)))
    }
    func event(_ body: [String: Any]) throws { try deliver(["jsonrpc": "2.0", "method": "event", "params": body]) }
    func reply(_ request: [String: Any], _ result: [String: Any]) throws {
        try deliver(["jsonrpc": "2.0", "id": try XCTUnwrap(request["id"]), "result": result])
    }
}
#endif
