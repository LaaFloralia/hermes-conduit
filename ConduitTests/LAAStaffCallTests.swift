#if LAA_BUILD
import AVFoundation
import ImageIO
import XCTest
import AVFAudio
import Combine
@testable import Conduit

@MainActor
final class LAAStaffCallTests: XCTestCase {
    func testDefaultCallIsUnavailableOnlyWhileAnEmployeePlanIsPending() {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let app = harness.appState
        app.setGPTLiveEnabled(true)
        app.isConnected = true
        XCTAssertNil(app.phoneVoiceUnavailableReason)
        app.laaEmployeeGPTLivePlan = app.laaEmployeeCallPlan(profile: "laa-cto")
        XCTAssertEqual(app.phoneVoiceUnavailableReason, LAACopy.otherCallInProgress)
        XCTAssertTrue(LAACopy.dictationDuringCallHint.contains(LAACopy.otherCallInProgress))
        XCTAssertFalse(app.canStartPhoneVoiceConversation)
        app.laaEmployeeGPTLivePlan = nil
        XCTAssertNil(app.phoneVoiceUnavailableReason)
    }

    func testUnsupportedServerFeaturesDoNotAskForPluginUpdates() {
        XCTAssertEqual(GPTLiveAvailability.pluginMissing.userFacingReason, LAACopy.gptLiveUnavailable)
        XCTAssertEqual(GPTLiveClientError.notAPIKey(nil).errorDescription, LAACopy.gptLiveAPIUnavailable)
        XCTAssertEqual(GeminiLiveAvailability.pluginMissing.userFacingReason, LAACopy.serverFeatureUnavailable)
        XCTAssertEqual(GeminiLiveAvailability.pluginMissing.userFacingReason(for: .qwen), LAACopy.serverFeatureUnavailable)
        XCTAssertEqual(GrokLiveAvailability.pluginMissing.userFacingReason, LAACopy.serverFeatureUnavailable)
        XCTAssertEqual(VoiceSetupIssue.notifierPluginMissing.message, LAACopy.serverFeatureUnavailable)
        XCTAssertEqual(GPTLiveSession.voiceNote(requested: "vale", applied: nil), LAACopy.voiceNotConfirmed)
        XCTAssertEqual(AppState.chatTakeoverFailureMessage(ChatTakeoverError.pluginMissing), LAACopy.serverFeatureUnavailable)
        XCTAssertEqual(AppState.chatTakeoverFailureMessage(ChatTakeoverError.malformed), LAACopy.unreadableServerResponse)
        XCTAssertEqual(WatchGPTLiveSetup.statusUnavailableReason, LAACopy.watchVoiceStatusUnavailable)
        let watchModes: [WatchDirectBroker.AudioGrantMode] = [.gpt, .grok, .local]
        for mode in watchModes {
            XCTAssertEqual(WatchDirectBroker.unavailableGrantReason(mode), LAACopy.watchCallUnavailable)
        }
        XCTAssertEqual(ShortcutLogError.pluginTooOld.message, LAACopy.shortcutEventKept)
        XCTAssertEqual(ShortcutLogError.pluginMissing.message, LAACopy.shortcutEventNotKept)
        XCTAssertEqual(SpeechServerStatus.pluginMissingReason, LAACopy.speechServerUnavailable)
        XCTAssertEqual(SpeechServerVoiceStatus.pluginMissingReason, LAACopy.speechServerUnavailable)
        XCTAssertEqual(LocalLiveProtocol.pluginMissingReason, LAACopy.localLiveUnavailable)
        XCTAssertEqual(VoiceSetupIssue.notifierPluginMissing.carPlayTitleVariants, [LAACopy.serverUnavailableTitle])
        XCTAssertFalse(VoiceCallbackAvailability.unsupported.refusal.lowercased().contains("update"))
        XCTAssertEqual(GroupRoomFilesClient.Failure.malformed.errorDescription, LAACopy.unreadableServerResponse)
        XCTAssertEqual(ReplySourcesClient.Failure.malformed.errorDescription, LAACopy.unreadableServerResponse)
        XCTAssertTrue(PhoneSyncPause.pluginMissing.message.contains("一時停止"))
        XCTAssertTrue(HealthSyncPause.pluginMissing.message.contains("一時停止"))
        XCTAssertTrue(LocationSyncPause.pluginMissing.message.contains("一時停止"))
        for text in [LAACopy.artifactsUnavailable, LAACopy.workspaceActionsUnavailable,
                     LAACopy.groupFilesUnavailable, LAACopy.gptLiveUnavailable] {
            XCTAssertTrue(text.hasPrefix("このMacでは") && text.hasSuffix("を利用できません"))
            XCTAssertFalse(text.lowercased().contains("plugin"))
            XCTAssertFalse(text.contains("更新"))
        }
    }

    func testStaffProfilesAndUnknownProfile() {
        let expected: [String: String] = ["monet": "Monet", "argus": "Argus", "cfo": "Morgan",
                                          "cio": "Sherlock", "cos": "Merlin",
                                          "cso": "Talos", "cto": "Ada", "monet-uncensored": "Monet（無検閲）",
                                          "monet-dots": "Monet（Dots）"]
        for (id, name) in expected {
            XCTAssertEqual(LAAStaff(profile: "laa-\(id)")?.name, name)
        }
        XCTAssertNil(LAAStaff(profile: "default"))
        XCTAssertNil(LAAStaff(profile: "laa-other"))
        for retired in ["laa-ciel", "laa-ciel-uncensored", "laa-cmo"] {
            XCTAssertNil(LAAStaff(profile: retired))
        }
    }

    func testDotsEmployeeChatRoutePreservesProfileWithoutAddingAVoiceWidget() throws {
        let workspace = WidgetWorkspaceID(dashboardID: UUID(), profile: "laa-monet-dots")
        let link = try XCTUnwrap(WidgetLaunchLink(action: .employeeChat, workspace: workspace, reference: nil))
        XCTAssertEqual(WidgetLaunchLink(url: link.url)?.workspace, workspace)
        XCTAssertEqual(WidgetLaunchLink(url: link.url)?.action, .employeeChat)
        XCTAssertNil(LAAWidgetEmployee.forProfile(workspace.profile))
        XCTAssertNil(WidgetLaunchLink(action: .employeeChat,
            workspace: WidgetWorkspaceID(dashboardID: workspace.dashboardID, profile: "laa-unknown"), reference: nil))
    }

    func testCallKitPresentationUsesBundledIconAndStaffNames() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "callkit-icon-template-120", withExtension: "png"))
        let configuration = LAACallKitPresentation.configuration()
        XCTAssertEqual(configuration.iconTemplateImageData, try Data(contentsOf: url))
        XCTAssertEqual(LAACallKitPresentation.localizedName, "LAA")
        for staff in LAAStaff.allCases {
            XCTAssertEqual(LAACallKitPresentation.callerName(profile: "laa-\(staff.rawValue)", fallback: "original"), staff.name)
        }
        XCTAssertEqual(LAACallKitPresentation.callerName(profile: "default", fallback: "original"), "original")
        XCTAssertEqual(LAACallKitPresentation.outgoingUpdate(name: "Talos").localizedCallerName, "Talos")
    }

    func testLegacyDefaultCallerNameKeepsNamedProfilesAndUsesMonetFallback() {
        XCTAssertEqual(HermesCallerName.name(profile: nil, mainName: nil), "Monet")
        XCTAssertEqual(HermesCallerName.name(profile: "default", mainName: "Hermes"), "Monet")
        XCTAssertEqual(HermesCallerName.name(profile: "default", mainName: "Hermes", profileName: "Ada"), "Ada")
        XCTAssertEqual(HermesCallerName.name(profile: "default", mainName: "Morgan", profileName: "Ada"), "Morgan")
        XCTAssertEqual(HermesCallCopy.missedCallTitle(from: "Hermes"), HermesCallCopy.missedCallTitle(from: "Monet"))
    }

    func testPlacedCallNameFollowsConversationAndKeepsDefaultName() {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let appState = harness.appState
        appState.setActiveProfileForTesting("default")
        let defaultName = HermesCallerName.name(profile: "default", mainName: appState.profileDisplayName("default"))
        XCTAssertEqual(appState.placedCallName, defaultName)

        appState.noteBotChatSessionForTesting("staff-chat", profile: "laa-cso")
        appState.activeSessionId = "staff-chat"
        XCTAssertEqual(appState.placedCallName, "Talos")

        appState.setActiveProfileForTesting("laa-cfo")
        XCTAssertEqual(appState.placedCallName, "Talos")
        appState.laaEmployeeGPTLivePlan = appState.laaEmployeeCallPlan(profile: "laa-cto")
        XCTAssertEqual(appState.placedCallName, "Ada", "a widget call names its selected employee")
        appState.laaEmployeeGPTLivePlan = nil
        appState.activeSessionId = nil
        XCTAssertEqual(appState.placedCallName, "Morgan")
    }

    func testProviderConsentStartsOnlyAfterAcceptedSheetDismisses() {
        let control = FakeControl()
        control.consent = .geminiLive
        let calls = LAAEmployeeCallCoordinator(control: control)
        calls.start(profile: "laa-monet", name: "Monet", conversationID: "chat-one")
        XCTAssertEqual(calls.consentRequest?.mode, .geminiLive)
        XCTAssertNil(calls.snapshot)
        calls.answerConsent(false)
        calls.consentDidDismiss()
        XCTAssertNil(control.context)
        XCTAssertNil(control.grantedConsent)

        calls.start(profile: "laa-monet", name: "Monet", conversationID: "chat-one")
        calls.answerConsent(true)
        XCTAssertEqual(control.grantedConsent, .geminiLive)
        XCTAssertNil(calls.snapshot)
        calls.consentDidDismiss()
        XCTAssertEqual(control.context?.conversationID, "chat-one")
        XCTAssertTrue(calls.isShowingCall)
    }

    func testComposerCallUsesTheEmployeeConversationAndReturnsToIt() {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let app = harness.appState
        app.setActiveProfileForTesting("default")
        app.noteBotChatSessionForTesting("morgan-chat", profile: "laa-cfo")
        app.activeSessionId = "morgan-chat"
        let control = FakeControl()
        let calls = LAAEmployeeCallCoordinator(control: control)

        XCTAssertTrue(calls.startEmployeeConversation(app))
        XCTAssertEqual(control.context?.profile, "laa-cfo")
        XCTAssertEqual(control.context?.name, "Morgan")
        XCTAssertEqual(control.context?.conversationID, "morgan-chat")
        XCTAssertEqual(app.activeProfile, "default")
        let first = control.context?.id
        app.laaEmployeeGPTLivePlan = app.laaEmployeeCallPlan(profile: "laa-cfo")
        calls.showChat()
        XCTAssertNil(LAAEmployeeCallAvailability.reason(appState: app, bridge: .paired, calls: calls))
        XCTAssertTrue(calls.startEmployeeConversation(app))
        XCTAssertTrue(calls.isShowingCall)
        XCTAssertEqual(control.context?.id, first)
        calls.end()
        app.laaEmployeeGPTLivePlan = nil
        app.activeSessionId = nil
        XCTAssertFalse(calls.startEmployeeConversation(app))
    }

    func testDotsHasNoInAppCallAndRetainsItsExternalLinkConfiguration() {
        let shortcut = URL(string: "shortcuts://run-shortcut?name=Monet%E3%81%AB%E9%9B%BB%E8%A9%B1")!
        let page = "https://chatgpt.com/dots/00000000-0000-4000-8000-000000000000~0123abcd"
        XCTAssertEqual(LAAStaff.monetDots.dotCallURL(onMac: false, info: nil), shortcut)
        XCTAssertEqual(LAAStaff.monetDots.dotCallURL(onMac: true, info: ["LAADotsCallURL": page]), URL(string: page))
        XCTAssertNil(LAAStaff.monetDots.dotCallURL(onMac: true, info: nil))
        XCTAssertNil(LAAStaff.monetDots.dotCallURL(onMac: true, info: ["LAADotsCallURL": "https://example.com/dots/x"]))
        XCTAssertNil(LAAStaff.monet.dotCallURL(onMac: false, info: nil))
        XCTAssertEqual(LAAEmployeeCallAvailability.dotCallHint(shortcut), "ChatGPTでMonetと通話します")
        XCTAssertEqual(LAAEmployeeCallAvailability.dotCallHint(URL(string: page)!), "ブラウザでMonetの通話画面を開きます")

        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let app = harness.appState
        app.setActiveProfileForTesting("default")
        app.noteBotChatSessionForTesting("dots-chat", profile: "laa-monet-dots")
        app.activeSessionId = "dots-chat"
        let calls = LAAEmployeeCallCoordinator(control: FakeControl())
        XCTAssertEqual(LAAEmployeeCallAvailability.reason(appState: app, bridge: .unpaired, calls: calls), "この会話はテキスト専用です")
        XCTAssertFalse(calls.startEmployeeConversation(app))
        app.noteBotChatSessionForTesting("uncensored-chat", profile: "laa-monet-uncensored")
        app.activeSessionId = "uncensored-chat"
        XCTAssertEqual(LAAEmployeeCallAvailability.reason(appState: app, bridge: .paired, calls: calls), "この会話はテキスト専用です")
    }

    func testDotsPhoneOpensTheDotsPageWhenTheShortcutFails() throws {
        let shortcut = URL(string: "shortcuts://run-shortcut?name=Monet%E3%81%AB%E9%9B%BB%E8%A9%B1")!
        let page = "https://chatgpt.com/dots/00000000-0000-4000-8000-000000000000~0123abcd"
        let url = try XCTUnwrap(LAAStaff.monetDots.dotCallURL(onMac: false, info: ["LAADotsCallURL": page]))
        XCTAssertEqual(url.scheme, "shortcuts")
        XCTAssertEqual(url.host, "x-callback-url")
        XCTAssertEqual(url.path, "/run-shortcut")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "name" }?.value, "Monetに電話")
        // One escape only: the query parser gives the original link back, and
        // the raw link is not written into the URL twice.
        XCTAssertEqual(items.first { $0.name == "x-error" }?.value, page)
        XCTAssertTrue(url.absoluteString.contains("x-error=https%3A%2F%2Fchatgpt.com%2Fdots%2F"))
        XCTAssertFalse(url.absoluteString.contains("%253A"))
        XCTAssertEqual(LAAEmployeeCallAvailability.dotCallHint(url), "ChatGPTでMonetと通話します")
        // No page yet, or one that is not the dot: the plain shortcut stays.
        XCTAssertEqual(LAAStaff.monetDots.dotCallURL(onMac: false, info: nil), shortcut)
        XCTAssertEqual(LAAStaff.monetDots.dotCallURL(onMac: false, info: ["LAADotsCallURL": "https://example.com/dots/x"]), shortcut)
    }

    func testBindingVoiceControlRefreshesAvailability() {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let calls = LAAEmployeeCallCoordinator(control: LAAEmployeeVoiceControl())
        XCTAssertEqual(calls.unavailableReason, "通話を準備中です")
        var notifications = 0
        let observer = calls.objectWillChange.sink { _ in notifications += 1 }
        calls.bindVoiceControl(harness.appState)
        XCTAssertEqual(notifications, 1)
        XCTAssertNil(calls.unavailableReason)
        observer.cancel()
    }

    func testVoiceAdapterTracksRealStatusAndExternalEnd() async {
        let fake = FakeVoiceHost()
        fake.voiceStatus = LAAEmployeeVoiceStatus(phase: .connected, muted: true, speaker: false,
                                                   nativeRoute: true, level: 0.4)
        fake.resolvedConversation = "new-chat"
        let control = LAAEmployeeVoiceControl(host: fake.makeHost())
        let connected = expectation(description: "voice connected")
        let updated = expectation(description: "voice updated")
        let ended = expectation(description: "voice ended externally")
        var snapshots: [LAAEmployeeCallSnapshot] = []
        control.onUpdate = { snapshot in
            snapshots.append(snapshot)
            if snapshot.phase == .connected, snapshots.count == 1 { connected.fulfill() }
            else if snapshot.phase == .connected { updated.fulfill() }
            else if snapshot.phase == .ended { ended.fulfill() }
        }
        let context = LAAEmployeeCallContext(profile: "laa-monet", name: "Monet", conversationID: nil)
        control.start(context)
        await fulfillment(of: [connected], timeout: 5)
        XCTAssertEqual(snapshots.last?.context.conversationID, "new-chat")
        XCTAssertEqual(snapshots.last?.audioLevel, 0.4)
        XCTAssertEqual(snapshots.last?.speaking, false)
        XCTAssertEqual(snapshots.last?.usesSystemRoutePicker, true)
        XCTAssertNotNil(snapshots.last?.connectedAt)
        XCTAssertEqual(fake.beginCount, 1)
        control.setMuted(false)
        control.setSpeaker(true)
        XCTAssertEqual(fake.mute, false)
        XCTAssertEqual(fake.speaker, true)
        fake.voiceStatus.muted = false
        fake.voiceStatus.level = nil
        fake.voiceStatus.speaking = true
        fake.voiceStatus.voiceNote = "選んだ声を確認できません"
        fake.changed.send()
        await fulfillment(of: [updated], timeout: 5)
        XCTAssertNil(snapshots.last?.audioLevel)
        XCTAssertEqual(snapshots.last?.speaking, true)
        XCTAssertEqual(snapshots.last?.voiceNote, "選んだ声を確認できません")
        fake.voiceStatus.phase = .ended
        fake.changed.send()
        await fulfillment(of: [ended], timeout: 5)
        XCTAssertEqual(snapshots.last?.phase, .ended)
        XCTAssertEqual(fake.endCount, 0)
    }

    func testVoiceAdapterAdoptsAnExistingCallWithoutOpeningAnother() {
        let fake = FakeVoiceHost()
        fake.canAdopt = true
        fake.voiceStatus = LAAEmployeeVoiceStatus(phase: .connected)
        let control = LAAEmployeeVoiceControl(host: fake.makeHost())
        let context = LAAEmployeeCallContext(profile: "default", name: "Monet", conversationID: nil)
        var updates: [LAAEmployeeCallSnapshot] = []
        control.onUpdate = { updates.append($0) }

        XCTAssertTrue(control.adopt(context))
        XCTAssertFalse(control.adopt(context), "a second entry cannot take over an existing call")
        XCTAssertEqual(fake.openCount, 0)
        XCTAssertEqual(fake.beginCount, 1)
        XCTAssertEqual(updates.last?.phase, .connected)
        control.end()
        XCTAssertEqual(fake.endCount, 1)
        XCTAssertEqual(updates.last?.phase, .ended)
    }

    func testCoordinatorPresentsAnExistingVoiceCallAsMonet() {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let app = harness.appState
        app.setActiveProfileForTesting("default")
        let calls = LAAEmployeeCallCoordinator(control: LAAEmployeeVoiceControl())
        calls.adoptVoiceIfNeeded(app)
        XCTAssertNil(calls.snapshot)
        app.showVoiceSheet = true
        calls.adoptVoiceIfNeeded(app)
        XCTAssertEqual(calls.snapshot?.context.name, "Monet")
        XCTAssertTrue(calls.isShowingCall)
        let id = calls.snapshot?.context.id
        calls.adoptVoiceIfNeeded(app)
        XCTAssertEqual(calls.snapshot?.context.id, id)
        calls.end()
        XCTAssertNil(calls.snapshot)
    }

    func testAdoptedIdleLiveCallShowsFailureAndCanClose() {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let app = harness.appState
        app.showGeminiLiveSheet = true
        let calls = LAAEmployeeCallCoordinator(control: LAAEmployeeVoiceControl())
        calls.adoptVoiceIfNeeded(app)
        if case .failed = calls.snapshot?.phase {} else { XCTFail("An idle presented call must remain dismissible") }
        calls.end()
        XCTAssertFalse(app.showGeminiLiveSheet)
        XCTAssertNil(calls.snapshot)
    }

    func testShortcutCallDoesNotInheritAnUnrelatedOpenChat() {
        let fresh = LAAEmployeeCallCoordinator.existingIdentity(
            activeProfile: "default", conversationProfile: "laa-cfo", conversationID: "old-chat",
            employeeProfile: nil, isClassic: false, thread: nil)
        XCTAssertEqual(fresh.profile, "default")
        XCTAssertNil(fresh.conversationID)

        let thread = VoiceThreadTarget(runtimeSessionID: "live-chat", storedSessionID: "saved-chat",
                                       title: "Chat", profile: "laa-cfo")
        let attached = LAAEmployeeCallCoordinator.existingIdentity(
            activeProfile: "default", conversationProfile: "laa-cfo", conversationID: "live-chat",
            employeeProfile: nil, isClassic: false, thread: thread)
        XCTAssertEqual(attached.profile, "laa-cfo")
        XCTAssertEqual(attached.conversationID, "live-chat")
    }

    func testEndingPendingVoiceOpenCannotRestartIt() async {
        let fake = FakeVoiceHost()
        fake.holdOpen = true
        let began = expectation(description: "open waiting")
        fake.didBegin = { began.fulfill() }
        let control = LAAEmployeeVoiceControl(host: fake.makeHost())
        var snapshots: [LAAEmployeeCallSnapshot] = []
        control.onUpdate = { snapshots.append($0) }
        let context = LAAEmployeeCallContext(profile: "laa-monet", name: "Monet", conversationID: "chat")
        control.start(context)
        await fulfillment(of: [began], timeout: 5)
        control.end()
        fake.pendingOpen?.resume(returning: .opened(context))
        fake.pendingOpen = nil
        await Task.yield()
        XCTAssertEqual(fake.endCount, 1)
        XCTAssertEqual(fake.beginCount, 0)
        XCTAssertEqual(snapshots.map(\.phase), [.ended])
    }

    func testVoiceOpenFailureRemainsAvailableToDismiss() async {
        let fake = FakeVoiceHost()
        fake.failOpen = true
        let control = LAAEmployeeVoiceControl(host: fake.makeHost())
        let calls = LAAEmployeeCallCoordinator(control: control)
        let failed = expectation(description: "voice open failed")
        let observation = calls.$snapshot.sink { snapshot in
            if case .failed = snapshot?.phase { failed.fulfill() }
        }
        calls.start(profile: "laa-monet", name: "Monet", conversationID: "chat")
        await fulfillment(of: [failed], timeout: 5)
        calls.showChat()
        calls.showCall()
        XCTAssertTrue(calls.isShowingCall)
        calls.end()
        XCTAssertNil(calls.snapshot)
        XCTAssertEqual(fake.endCount, 1)
        observation.cancel()
    }

    func testDefaultProfileKeepsExistingClassicCallAndChat() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.appState.activeSessionId = "session-1"
        let kit = FakePlacedCallKit()
        let placed = makePlacedCallsForTesting(appState: harness.appState, kit: kit)
        let control = LAAEmployeeVoiceControl()
        control.bind(harness.appState)
        let calls = LAAEmployeeCallCoordinator(control: control)
        calls.start(profile: "default", name: "LAA", conversationID: "session-1")
        for _ in 0..<1_000 where !placed.isWaitingForCallAudio { await Task.yield() }
        XCTAssertTrue(placed.isWaitingForCallAudio)
        XCTAssertFalse(harness.appState.showVoiceSheet)
        kit.onPlacedCallStarted?()
        kit.onPlacedCallAudioActivated?()
        for _ in 0..<1_000 where calls.snapshot?.phase != .connected { await Task.yield() }
        XCTAssertTrue(harness.appState.showVoiceSheet)
        XCTAssertTrue(harness.controller.hasLiveVoiceSession)
        XCTAssertEqual(calls.snapshot?.phase, .connected)
        XCTAssertEqual(calls.snapshot?.context.profile, "default")
        XCTAssertEqual(calls.snapshot?.context.conversationID, "session-1")
        calls.showChat()
        XCTAssertFalse(calls.isShowingCall)
        calls.showCall()
        calls.end()
        XCTAssertFalse(harness.appState.showVoiceSheet)
        XCTAssertNil(calls.snapshot)
        XCTAssertEqual(harness.appState.activeSessionId, "session-1")
        XCTAssertEqual(harness.appState.conversationIdentityProfile, "default")
        XCTAssertEqual(kit.endRequests, 1)
        kit.onPlacedCallEnded?(false)
    }

    func testSystemHangupDuringCallKitActivationReturnsToChat() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.appState.activeSessionId = "session-1"
        let kit = FakePlacedCallKit()
        let placed = makePlacedCallsForTesting(appState: harness.appState, kit: kit)
        let control = LAAEmployeeVoiceControl()
        control.bind(harness.appState)
        let calls = LAAEmployeeCallCoordinator(control: control)
        calls.start(profile: "default", name: "LAA", conversationID: "session-1")
        for _ in 0..<1_000 where !placed.isWaitingForCallAudio { await Task.yield() }
        XCTAssertTrue(placed.isWaitingForCallAudio)
        kit.onPlacedCallStarted?()
        kit.onPlacedCallEnded?(true)
        for _ in 0..<1_000 where calls.snapshot != nil { await Task.yield() }
        XCTAssertNil(calls.snapshot)
        XCTAssertFalse(calls.isShowingCall)
        XCTAssertEqual(harness.appState.activeSessionId, "session-1")
        XCTAssertFalse(harness.appState.showVoiceSheet)
    }

    func testBundledAssetsResolveOnlyWhatIsPresent() {
        let root = URL(fileURLWithPath: "/test-bundle", isDirectory: true)
        let paths: Set<String> = ["/test-bundle/staff", "/test-bundle/staff/monet/monet-avatar-512.png",
                                  "/test-bundle/staff/monet/monet-idle-512.mov",
                                  "/test-bundle/staff/monet/monet-turn.heic",
                                  "/test-bundle/callkit-icon-template-120.png"]
        let resolver = StaffAssetResolver(root: root, exists: { paths.contains($0.path) })
        let monet = resolver.resolve(profile: "laa-monet")
        XCTAssertEqual(monet.avatar?.path, "/test-bundle/staff/monet/monet-avatar-512.png")
        XCTAssertEqual(resolver.resolve(profile: "laa-monet-dots"), monet)
        XCTAssertFalse(LAAStaff.monetDots.supportsCalls)
        XCTAssertNotNil(monet.loop)
        XCTAssertNotNil(monet.turn)
        XCTAssertNil(resolver.resolve(profile: "laa-cfo").turn)
        XCTAssertNil(resolver.resolve(profile: "laa-monet-uncensored").avatar)
        XCTAssertNil(monet.hero)
        XCTAssertNil(resolver.resolve(profile: "laa-cfo").avatar)
        XCTAssertNotNil(resolver.resolve(profile: "default").defaultMark)
        XCTAssertEqual(resolver.resolve(profile: "unknown"), StaffAssets())
    }

    func testAdoptedStaffAssetsAreInTheAppBundle() {
        for staff in LAAStaff.allCases {
            let assets = StaffAssetResolver.bundled.resolve(profile: "laa-\(staff.rawValue)")
            XCTAssertNotNil(assets.avatar, "Missing avatar for \(staff.rawValue)")
            XCTAssertNotNil(assets.hero, "Missing hero for \(staff.rawValue)")
            XCTAssertNotNil(assets.loop, "Missing loop for \(staff.rawValue)")
            XCTAssertNotNil(assets.turn, "Missing turn for \(staff.rawValue)")
        }
        XCTAssertNotNil(StaffAssetResolver.bundled.resolve(profile: "default").defaultMark)
    }

    func testTheLoopRunsFasterWhileTheEmployeeIsActive() {
        XCTAssertEqual(StaffAvatarActivity.resting.playbackRate, 1)
        XCTAssertGreaterThan(StaffAvatarActivity.lively.playbackRate, StaffAvatarActivity.resting.playbackRate)
    }

    func testEveryMascotTurnsThroughItsWholeSetOfTransparentFrames() throws {
        for staff in LAAStaff.allCases {
            let url = try XCTUnwrap(StaffAssetResolver.bundled.resolve(profile: "laa-\(staff.rawValue)").turn)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetCount(source), 60, staff.rawValue)
            for index in [0, 30, 59] {
                let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
                XCTAssertEqual(frame.width, 768, staff.rawValue)
                XCTAssertNotEqual(frame.alphaInfo, .none, staff.rawValue)
                XCTAssertNotEqual(frame.alphaInfo, .noneSkipFirst, staff.rawValue)
            }
        }
    }

    /// AVFoundation composites HEVC alpha as premultiplied; straight colour
    /// shows as a white rim around the mascot on a light background.
    func testEveryLoopIsPremultiplied() async throws {
        for staff in LAAStaff.allCases {
            let url = try XCTUnwrap(StaffAssetResolver.bundled.resolve(profile: "laa-\(staff.rawValue)").loop)
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            let sample = try XCTUnwrap(output.copyNextSampleBuffer())
            let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            var edge = 0, brighterThanAlpha = 0
            for y in 0..<CVPixelBufferGetHeight(buffer) {
                let row = base + y * CVPixelBufferGetBytesPerRow(buffer)
                for x in 0..<CVPixelBufferGetWidth(buffer) {
                    let pixel = row + x * 4
                    guard pixel[3] > 20, pixel[3] < 235 else { continue }
                    edge += 1
                    if max(pixel[0], pixel[1], pixel[2]) > pixel[3] &+ 8 { brighterThanAlpha += 1 }
                }
            }
            XCTAssertGreaterThan(edge, 0, staff.rawValue)
            XCTAssertLessThan(Double(brighterThanAlpha) / Double(edge), 0.06, staff.rawValue)
        }
    }

    func testTheMascotTurnsAllTheWayRoundAndComesBackTheShortWay() {
        var spin = StaffTurnSpin()
        spin.drag(dx: 1.1 / StaffTurnSpin.turnsPerPoint)
        XCTAssertGreaterThan(spin.turn, 1)
        XCTAssertEqual(spin.frame(of: 60), 6)
        spin.release(velocityX: 0)
        XCTAssertFalse(spin.isFacingFront)
        for _ in 0..<600 { spin.advance(by: 1.0 / 60) }
        XCTAssertEqual(spin.turn, 1, accuracy: 0.01)
        XCTAssertTrue(spin.isFacingFront)
        XCTAssertEqual(spin.frame(of: 60), 0)
    }

    func testTurningBackwardsKeepsTheFrameInRange() {
        var spin = StaffTurnSpin()
        spin.drag(dx: -0.25 / StaffTurnSpin.turnsPerPoint)
        XCTAssertEqual(spin.frame(of: 60), 45)
        spin.drag(dx: 0.2499 / StaffTurnSpin.turnsPerPoint)
        XCTAssertEqual(spin.frame(of: 60), 0)
    }

    func testAFlickCarriesOnAndNothingMovesWhileHeld() {
        var spin = StaffTurnSpin()
        spin.drag(dx: 10)
        let held = spin.turn
        spin.advance(by: 1)
        XCTAssertEqual(spin.turn, held)
        spin.release(velocityX: 300)
        spin.advance(by: 0.1)
        XCTAssertGreaterThan(spin.turn, held)
    }

    func testAnEmployeeWearsTheMascotWhateverHermesHolds() {
        let resolver = StaffAssetResolver.bundled
        let mascot = try? XCTUnwrap(resolver.resolve(profile: "laa-monet").avatar)
        XCTAssertEqual(AppState().profileAvatarURL(for: "laa-monet"), mascot)
        XCTAssertTrue(mascot.map(resolver.isMascot) ?? false)
        XCTAssertFalse(resolver.isMascot(URL(fileURLWithPath: "/tmp/avatar.png")))
    }

    func testTheStillLeavesOnlyOnceTheVideoIsOnScreen() {
        var policy = StaffAvatarPlaybackPolicy(visible: true, active: true, reduceMotion: false,
                                               lowPower: false, scrolling: false, hasLoop: true)
        XCTAssertTrue(policy.showsStill(videoOnScreen: false))
        XCTAssertFalse(policy.showsStill(videoOnScreen: true))
        policy.scrolling = true
        XCTAssertTrue(policy.showsStill(videoOnScreen: true))
    }

    func testLoopRequiresEveryPlaybackCondition() {
        var policy = StaffAvatarPlaybackPolicy(visible: true, active: true, reduceMotion: false,
                                               lowPower: false, scrolling: false, hasLoop: true)
        XCTAssertTrue(policy.shouldPlay)
        policy.visible = false; XCTAssertFalse(policy.shouldPlay); policy.visible = true
        policy.active = false; XCTAssertFalse(policy.shouldPlay); policy.active = true
        policy.reduceMotion = true; XCTAssertFalse(policy.shouldPlay); policy.reduceMotion = false
        policy.lowPower = true; XCTAssertFalse(policy.shouldPlay); policy.lowPower = false
        policy.scrolling = true; XCTAssertFalse(policy.shouldPlay); policy.scrolling = false
        policy.hasLoop = false; XCTAssertFalse(policy.shouldPlay)
    }

    func testUnavailableVoiceExplainsTheActualSetupIssue() {
        XCTAssertEqual(LAAEmployeeCallAvailability.voiceReason(.voiceOff), "音声をオンにしてください")
        XCTAssertEqual(LAAEmployeeCallAvailability.voiceReason(.speechRecognitionDenied), "音声認識を許可してください")
        XCTAssertEqual(LAAEmployeeCallAvailability.voiceReason(.noSpeechToText(detail: nil)), "音声入力を設定してください")
        XCTAssertEqual(LAAEmployeeCallAvailability.voiceReason(.noTextToSpeech), "音声出力を設定してください")
        XCTAssertNil(LAAEmployeeCallAvailability.voiceReason(profile: "laa-monet", canStart: false, issue: .noTextToSpeech))
        XCTAssertEqual(LAAEmployeeCallAvailability.voiceReason(profile: "default", canStart: false, issue: .noTextToSpeech),
                       "音声出力を設定してください")
    }

    func testPairingFailureExplainsItsState() {
        XCTAssertNil(LAAEmployeeCallAvailability.bridgeReason(.paired))
        XCTAssertEqual(LAAEmployeeCallAvailability.bridgeReason(.unpaired), "端末を接続すると通話できます")
        XCTAssertEqual(LAAEmployeeCallAvailability.bridgeReason(.revoked), "端末を再接続してください")
        XCTAssertEqual(LAAEmployeeCallAvailability.bridgeReason(.unauthorized), "端末を再接続してください")
        XCTAssertEqual(LAAEmployeeCallAvailability.bridgeReason(.keychainError), "接続情報を読み込めません")
    }

    func testCallRetainsConversationAndLateEventsCannotResurrectIt() {
        let control = FakeControl()
        let calls = LAAEmployeeCallCoordinator(control: control)
        calls.start(profile: "laa-monet", name: "Monet", conversationID: "chat-one")
        let initial = try! XCTUnwrap(calls.snapshot)
        XCTAssertEqual(initial.context.conversationID, "chat-one")
        XCTAssertTrue(calls.isShowingCall)
        control.publish(phase: .connected)
        calls.showChat()
        XCTAssertFalse(calls.isShowingCall)
        calls.showCall()
        XCTAssertTrue(calls.isShowingCall)
        calls.toggleMute(); XCTAssertEqual(control.requestedMute, true)
        calls.toggleSpeaker(); XCTAssertEqual(control.requestedSpeaker, true)
        calls.end(); XCTAssertEqual(calls.snapshot?.phase, .ending)
        calls.end(); XCTAssertEqual(control.endCount, 1)
        control.publish(phase: .connected)
        XCTAssertEqual(calls.snapshot?.phase, .ending)
        control.publish(phase: .ended)
        XCTAssertNil(calls.snapshot)
        XCTAssertFalse(calls.isShowingCall)
        control.onUpdate?(initial)
        XCTAssertNil(calls.snapshot)
    }

    func testUnavailableAndOtherCallCannotStartAndFailureCanClose() {
        let control = FakeControl()
        let calls = LAAEmployeeCallCoordinator(control: control)
        control.unavailableReason = "未接続"
        calls.start(profile: "laa-monet", name: "Monet", conversationID: nil)
        XCTAssertNil(calls.snapshot)
        control.unavailableReason = nil
        calls.start(profile: "laa-monet", name: "Monet", conversationID: nil)
        let first = calls.snapshot?.context.id
        calls.start(profile: "laa-cfo", name: "Morgan", conversationID: "other")
        XCTAssertEqual(calls.snapshot?.context.id, first)
        control.publish(phase: .failed("接続できません"))
        control.publish(phase: .connected)
        XCTAssertEqual(calls.snapshot?.phase, .failed("接続できません"))
        calls.end()
        XCTAssertNil(calls.snapshot)
        XCTAssertFalse(calls.isShowingCall)
    }

    func testMeasuredLevelAndElapsedAreBounded() {
        XCTAssertEqual(LAAEmployeeCallView.level(nil), 0)
        XCTAssertEqual(LAAEmployeeCallView.level(.nan), 0)
        XCTAssertEqual(LAAEmployeeCallView.level(-1), 0)
        XCTAssertEqual(LAAEmployeeCallView.level(2), 1)
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(LAAEmployeeCallView.elapsed(since: start, now: start.addingTimeInterval(61)), "01:01")
        XCTAssertEqual(LAAEmployeeCallView.elapsed(since: start, now: start.addingTimeInterval(-1)), "00:00")
    }

    func testAudioRouteLabelsUseTheActualOutputName() {
        XCTAssertEqual(LAAAudioRouteLabel.labels([]), "出力先なし")
        XCTAssertEqual(LAAAudioRouteLabel.label(type: .builtInReceiver, name: "Receiver"), "受話口")
        XCTAssertEqual(LAAAudioRouteLabel.label(type: .builtInSpeaker, name: "Speaker"), "スピーカー")
        XCTAssertEqual(LAAAudioRouteLabel.label(type: .bluetoothHFP, name: " Monet’s AirPods "), "Monet’s AirPods")
        XCTAssertEqual(LAAAudioRouteLabel.label(type: .bluetoothA2DP, name: ""), "Bluetooth")
        XCTAssertEqual(LAAAudioRouteLabel.label(type: .headphones, name: "Headphones"), "Headphones")
        XCTAssertEqual(LAAAudioRouteLabel.labels([(.builtInSpeaker, "Speaker"), (.bluetoothLE, "AirPods")]), "スピーカー, AirPods")
    }
}

@MainActor
private final class FakeControl: LAAEmployeeCallControlling {
    var unavailableReason: String?
    var onUpdate: ((LAAEmployeeCallSnapshot) -> Void)?
    var context: LAAEmployeeCallContext?
    var requestedMute: Bool?
    var requestedSpeaker: Bool?
    var endCount = 0
    var consent: LiveVoiceModeName?
    var grantedConsent: LiveVoiceModeName?
    func requiredConsent(for context: LAAEmployeeCallContext) -> LiveVoiceModeName? { consent }
    func grantConsent(_ mode: LiveVoiceModeName) { grantedConsent = mode }
    func start(_ context: LAAEmployeeCallContext) { self.context = context }
    func setMuted(_ muted: Bool) { requestedMute = muted }
    func setSpeaker(_ speaker: Bool) { requestedSpeaker = speaker }
    func end() { endCount += 1 }
    func publish(phase: LAAEmployeeCallPhase) {
        guard let context else { return }
        onUpdate?(LAAEmployeeCallSnapshot(context: context, phase: phase))
    }
}

@MainActor
private final class FakeVoiceHost {
    let changed = PassthroughSubject<Void, Never>()
    var voiceStatus = LAAEmployeeVoiceStatus(phase: .connecting)
    var resolvedConversation: String?
    var holdOpen = false
    var failOpen = false
    var pendingOpen: CheckedContinuation<LAAEmployeeVoiceOpenResult, Never>?
    var didBegin: (() -> Void)?
    var beginCount = 0
    var openCount = 0
    var canAdopt = false
    var endCount = 0
    var mute: Bool?
    var speaker: Bool?

    func makeHost() -> LAAEmployeeVoiceHost {
        LAAEmployeeVoiceHost(
            unavailable: { nil }, consent: { _ in nil }, grant: { _ in },
            open: { context in
                self.openCount += 1
                if self.failOpen { return .failed }
                if self.holdOpen {
                    return await withCheckedContinuation { continuation in
                        self.pendingOpen = continuation
                        self.didBegin?()
                    }
                }
                return .opened(LAAEmployeeCallContext(id: context.id, profile: context.profile, name: context.name,
                                                      conversationID: self.resolvedConversation ?? context.conversationID))
            },
            adopt: { self.canAdopt },
            status: { self.voiceStatus },
            observe: { changed in [self.changed.sink { _ in changed() }] },
            beginClassicListening: { self.beginCount += 1 },
            mute: { self.mute = $0 }, speaker: { self.speaker = $0 },
            end: { self.endCount += 1 }
        )
    }
}
#endif
