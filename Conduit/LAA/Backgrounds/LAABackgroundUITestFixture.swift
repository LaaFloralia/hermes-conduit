#if LAA_BUILD && DEBUG
import SwiftUI

/// Uses real conversation surfaces and pickers with an isolated fake gateway.
@MainActor
final class LAABackgroundFixture: ObservableObject {
    let state: AppState
    let room: GroupRoom
    let bots: [BotProfile]
    @Published var createdName: String?

    init(chatFixtureOverride: String? = nil, defaultsSuiteName: String = "LAABackgroundUITestFixture",
         conversationID: String = "fixture-chat") {
        let members = [
            GroupMember(memberID: "laa-monet", profile: "laa-monet", handle: "monet", displayName: "Monet", target: nil, extra: [:]),
            GroupMember(memberID: "laa-cto", profile: "laa-cto", handle: "ada", displayName: "Ada", target: nil, extra: [:]),
        ]
        let room = GroupRoom(roomID: "fixture-room", name: "企画チーム", members: members,
                             authorityGatewayID: "fixture", authorityEpoch: 1, revision: 1,
                             createdAt: 1, updatedAt: 1, disbandedAt: nil, latestSeq: 2)
        self.room = room
        let bots = LAAWidgetEmployee.allCases.map { employee in
            BotProfile(name: employee.profile, botTitle: nil, displayName: employee.name, profileDescription: "", model: nil,
                       provider: nil, hasAvatar: false, isPinned: false, isHiddenByMeta: false, appearanceColor: nil,
                       canonicalSession: nil, lastActive: nil, lastPreview: nil)
        }
        let args = ProcessInfo.processInfo.arguments
        let mode = args.firstIndex(of: "-LAA_GROUPS_STATE").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        let chatFixture = chatFixtureOverride ?? args.firstIndex(of: "-LAA_V2_CHAT_FIXTURE").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        let now = Date().timeIntervalSince1970
        var events = [
            GroupEvent(roomID: room.roomID, seq: 1, eventID: "one", kind: "message.user",
                       actor: GroupActor(kind: "user", id: "user", profile: nil, displayName: nil, connectionID: nil),
                       authorityEpoch: 1, payload: ["text": .string("今日の予定を教えてください。"), "thread_id": .string("main")], createdAt: 1),
            GroupEvent(roomID: room.roomID, seq: 2, eventID: "two", kind: "message.member",
                       actor: GroupActor(kind: "member", id: "laa-monet", profile: "laa-monet", displayName: "Monet", connectionID: nil),
                       authorityEpoch: 1, payload: ["text": .string("是。予定を確認して、必要な情報をお伝えします。"), "thread_id": .string("main")], createdAt: 2),
        ]
        if chatFixture != nil {
            events = [
                GroupEvent(roomID: room.roomID, seq: 1, eventID: "one", kind: "message.user",
                           actor: GroupActor(kind: "user", id: "user", profile: nil, displayName: nil, connectionID: nil),
                           authorityEpoch: 1, payload: ["text": .string("今日の予定を整理して、次の一手を教えて。")], createdAt: now - 60),
                GroupEvent(roomID: room.roomID, seq: 2, eventID: "two", kind: "message.member",
                           actor: GroupActor(kind: "member", id: "laa-monet", profile: "laa-monet", displayName: "Monet", connectionID: nil),
                           authorityEpoch: 1, payload: ["text": .string(Self.richMessage)], createdAt: now),
            ]
        }
        if chatFixture == "empty" { events = [] }
        if chatFixture == "simple" {
            events = [
                GroupEvent(roomID: room.roomID, seq: 1, eventID: "one", kind: "message.user",
                    actor: GroupActor(kind: "user", id: "user", profile: nil, displayName: nil, connectionID: nil),
                    authorityEpoch: 1, payload: ["text": .string("今日の予定を整理して。")], createdAt: now - 120),
                GroupEvent(roomID: room.roomID, seq: 2, eventID: "two", kind: "message.member",
                    actor: GroupActor(kind: "member", id: "laa-monet", profile: "laa-monet", displayName: "Monet", connectionID: nil),
                    authorityEpoch: 1, payload: ["text": .string("午前は予定を確認しましょう。")], createdAt: now - 60),
                GroupEvent(roomID: room.roomID, seq: 3, eventID: "three", kind: "message.member",
                    actor: GroupActor(kind: "member", id: "laa-cto", profile: "laa-cto", displayName: "Ada", connectionID: nil),
                    authorityEpoch: 1, payload: ["text": .string("午後の資料は私が用意します。")], createdAt: now)
            ]
        }
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in
                if mode == "error" { throw URLError(.cannotConnectToHost) }
                return GroupCapabilities(protocolVersion: 2, driverReady: true, authorityGatewayID: "fixture",
                    features: [], methods: GroupWire.requiredMethods.union(["groups.rename"]), maxLogLimit: 500)
            },
            list: { _ in (mode == "empty" ? [] : [room], nil) }, state: { _, _ in (room, nil) },
            log: { _, _, since, _ in GroupLogPage(events: events.filter { $0.seq > since }, cursor: events.count,
                latestSeq: events.count, hasMore: false, authorityGatewayID: "fixture", authorityEpoch: 1) },
            send: { _, roomID, eventID, text, threadID in
                let event = GroupEvent(roomID: roomID, seq: events.count + 1, eventID: eventID, kind: "message.user",
                    actor: GroupActor(kind: "user", id: "user", profile: nil, displayName: nil, connectionID: nil),
                    authorityEpoch: 1, payload: ["text": .string(text), "thread_id": .string(threadID)], createdAt: Date().timeIntervalSince1970)
                events.append(event)
                return GroupSendResult(event: event, accepted: true, driverStarted: false)
            }
        )
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        // Another employee's chat: "-LAA_FIXTURE_PROFILE laa-cto".
        let employee = args.firstIndex(of: "-LAA_FIXTURE_PROFILE")
            .flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "laa-monet"
        defaults.set(employee, forKey: "conduit.activeProfile")
        let app = AppState(defaults: defaults, loadSavedConnection: false,
                           clearSessionPresentationCache: {},
                           chatResumeLifecycleOperations: ChatResumeLifecycleOperations(botRoster: { _ in
                               BotRosterSnapshot(bots: bots, supportsBotProtocol: true)
                           }), groupChatOperations: operations)
        app.client = HermesClient(connection: HermesConnection(baseUrl: "https://background-ui-test.invalid", ticket: "fixture"), profile: employee)
        app.isConnected = mode != "offline"
        _ = app.adoptDashboard(forNormalizedURL: "https://background-ui-test.invalid")
        app.activeSessionId = conversationID
        app.messages = [
            ChatMessage(id: "user", role: .user, content: "今日の予定を教えてください。", timestamp: "1"),
            ChatMessage(id: "assistant", role: .assistant, content: "是。予定を確認して、必要な情報をお伝えします。", timestamp: "2")
        ]
        if let chatFixture {
            if chatFixture == "media" {
                app.messages = [ChatMessage(id: "assistant", role: .assistant,
                    content: "# 素材をまとめました\n\n画像とファイルをこの会話から開けます。\n\nMEDIA: /fixtures/monet.png\n\nMEDIA: /fixtures/design-notes.pdf",
                    timestamp: String(now))]
                if let dashboard = app.activeDashboardID,
                   let hero = StaffAssetResolver.bundled.resolve(profile: "laa-monet").hero,
                   let data = try? Data(contentsOf: hero) {
                    let key = TranscriptImageCache.key(dashboard: dashboard.uuidString, profile: "laa-monet", path: "/fixtures/monet.png")
                    TranscriptImageCache.store(data, fileExtension: "png", for: key)
                }
            } else {
                app.messages = [
                    ChatMessage(id: "user", role: .user, content: "今日の予定を整理して、次の一手を教えて。", timestamp: String(now - 60), rowId: 1),
                    ChatMessage(id: "assistant", role: .assistant, content: Self.richMessage, timestamp: String(now),
                                rowId: 2, reactions: [MessageReaction(emoji: "❤️", author: "user", at: now)])
                ]
            }
        }
        if chatFixture == "simple" || chatFixture == "typing" || chatFixture == "empty" {
            app.messages = chatFixture == "empty" ? [] : [
                ChatMessage(id: "user", role: .user, content: "今日の予定を整理して。", timestamp: String(now - 60), rowId: 1),
                ChatMessage(id: "assistant", role: .assistant, content: "午前は予定を確認し、午後は資料を仕上げましょう。", timestamp: String(now), rowId: 2)
            ]
            app.messageReactionSender = { _, _, emoji in
                MessageReactionResult(rowId: 2, reactions: emoji.map { [MessageReaction(emoji: $0, author: "user", at: now)] } ?? [])
            }
            if chatFixture == "typing" {
                app.messages.removeLast()
                app.messages.append(ChatMessage(id: "reason", role: .reasoning, content: "予定を確認しています。", timestamp: String(now)))
                app.handleStreamEvent(.sessionBusy(sessionId: conversationID, busy: true))
            }
        }
        // What Hermes reports for the chat's running agent: "model,provider,effort".
        if let runtime = args.firstIndex(of: "-LAA_FIXTURE_RUNTIME").flatMap({ args.indices.contains($0 + 1) ? args[$0 + 1] : nil }) {
            let parts = runtime.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            var info: [String: AnyCodable] = [:]
            if parts.count > 0 { info["model"] = .string(parts[0]) }
            if parts.count > 1 { info["provider"] = .string(parts[1]) }
            if parts.count > 2 { info["reasoning_effort"] = .string(parts[2]) }
            app.handleStreamEvent(.sessionInfo(sessionId: conversationID, snapshot: SessionRuntimeSnapshot(object: info)))
        }
        // Hermes' model calls for the composer's pickers: "several" offers
        // three Claude models (Mythos asks to confirm first), "single" one.
        if let models = args.firstIndex(of: "-LAA_FIXTURE_CHAT_MODELS").flatMap({ args.indices.contains($0 + 1) ? args[$0 + 1] : nil }) {
            app.laaChatModelOperationsForTesting = LAAChatModelFixture(variant: models, session: conversationID, app: app).operations
        }
        if args.contains("-LAA_FIXTURE_CLARIFY") {
            let transport = LAAClarifyFixtureTransport()
            let connection = HermesConnection(baseUrl: "https://fixture.invalid", ticket: "synthetic")
            let client = HermesClient(connection: connection, profile: app.activeProfile, transportFactory: { transport }, keepaliveInterval: nil, monitorsPath: false)
            app.connection = connection; app.client = client
            client.onEvent = { [weak app] event in app?.handleStreamEvent(event) }
            transport.socket.onAnswer = { [weak app] id, answer in
                guard id == "srq-fixture-budget" else { return }
                app?.handleStreamEvent(.messageInterim(sessionId: conversationID, text: "同じ質問への回答を受領：" + answer, alreadyStreamed: false))
                app?.handleStreamEvent(.sessionBusy(sessionId: conversationID, busy: false))
            }
            Task { @MainActor in
                try? await client.connect()
                app.handleStreamEvent(.toolStart(sessionId: conversationID, toolName: "clarify", toolInput: "{}", toolID: "call-fixture-budget"))
                transport.socket.deliver(["jsonrpc": "2.0", "id": "srq-fixture-budget", "method": "clarify", "params": ["session_id": conversationID, "question": "試験用の予算上限は？"]])
                if let end = args.firstIndex(of: "-LAA_FIXTURE_CLARIFY_END").flatMap({ args.indices.contains($0 + 1) ? args[$0 + 1] : nil }) {
                    try? await Task.sleep(for: .seconds(1))
                    if end == "timeout" {
                        app.handleStreamEvent(.toolComplete(sessionId: conversationID, toolName: "clarify", toolOutput: #"{"outcome":"timed_out","responses":[{"question":"試験用の予算上限は？","status":"unanswered"}]}"#, toolID: "call-fixture-budget"))
                    } else {
                        transport.socket.deliver(["jsonrpc": "2.0", "method": "event", "params": ["session_id": conversationID, "type": "request.cancel", "payload": ["id": "srq-fixture-budget", "method": "clarify", "reason": end == "cancelled" ? "interrupted" : end]]])
                    }
                }
            }
        }
        if chatFixture == "long" {
            // Taller than the screen, so a send can start scrolled up.
            app.messages = (1...24).map { index in
                ChatMessage(id: "long-\(index)", role: index.isMultiple(of: 2) ? .assistant : .user,
                            content: "長い会話の\(index)件目。予定と資料の確認を続けています。",
                            timestamp: String(now - Double(240 - index)), rowId: index)
            }
        }
        if chatFixture == "long120" {
            // Many screens of rows of uneven height: where the chat opens is
            // decided before most of them have been measured.
            app.messages = (1...120).map { index in
                ChatMessage(id: "long-\(index)", role: index.isMultiple(of: 2) ? .assistant : .user,
                            content: "長い会話の\(index)件目。" + String(repeating: "予定と資料の確認を続けています。", count: 1 + index % 6),
                            timestamp: String(now - Double(1200 - index)), rowId: index)
            }
        }
        if args.contains("-LAA_FIXTURE_PREVIEW_FAILED"), let dashboardID = app.activeDashboardID {
            let link = WidgetLaunchLink(action: .employeeChat, workspace: .init(dashboardID: dashboardID, profile: employee), reference: nil)!
            app.widgetLaunchPendingLinkChanged(link)
            app.laaEmployeeChatLaunchEnded(link, outcome: .failed("fixture unavailable"))
        }
        self.state = app
        self.bots = bots
    }

    private static let richMessage = """
    # 今日の進め方

    優先することを3つにまとめました。

    1. 午前の予定を確認
    2. 進行中の作業を整理
    3. 判断待ちをまとめる

    > 判断が必要なものから順に確認します。

    ```
    next_step: review
    ```

    [詳しいメモを開く](https://example.com/notes)
    """

    func openGroup() async {
        await state.refreshGroupChatSupport()
        await state.openGroupRoom(room)
    }
}

@MainActor
struct LAABackgroundUITestFixtureScreen: View {
    private enum FixtureSheet: String, Identifiable {
        case create, settings, groupList, pairing
        var id: String { rawValue }
    }

    @StateObject private var fake = LAABackgroundFixture()
    @StateObject private var fixtureCalls = LAAStaffCallFixture.makeCoordinator()
    @StateObject private var pairedBridge = LAABridgeSession(statusForTesting: .paired)
    @State private var sheet: FixtureSheet?
    @State private var bridgeResult = "未確認"
    @State private var captureReady = false
    @State private var pushesChat = ProcessInfo.processInfo.arguments.contains("-LAA_FIXTURE_PUSH_CHAT")
    @EnvironmentObject private var bridge: LAABridgeSession
    @EnvironmentObject private var calls: LAAEmployeeCallCoordinator
    @EnvironmentObject private var rootState: AppState
    @Environment(\.colorScheme) private var inheritedColorScheme
    private var appState: AppState { fake.state }
    private let previousThemeKey = "laa.fixture.previousTheme"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !ProcessInfo.processInfo.arguments.contains("-LAA_CAPTURE_SURFACE") {
                    HStack {
                        Button(String("社員")) { fake.state.closeGroupRoom() }.accessibilityIdentifier("fixture.chat")
                        Button(String("グループ")) { Task { await fake.openGroup() } }.accessibilityIdentifier("fixture.group")
                        Button(String("作成")) { sheet = .create }.accessibilityIdentifier("fixture.create")
                        Button(String("設定")) { sheet = .settings }.accessibilityIdentifier("fixture.settings")
                        Button(String("接続")) { sheet = .pairing }.accessibilityIdentifier("fixture.bridge")
                        Button(String("一覧")) { sheet = .groupList }.accessibilityIdentifier("fixture.groups.list")
                    }.font(.caption).padding(4)
                }
                if ProcessInfo.processInfo.arguments.contains("-LAA_UI_TEST_REAL_BRIDGE") {
                    HStack {
                        Text(verbatim: bridge.status == .unpaired ? "未接続" : "登録済み")
                            .accessibilityIdentifier("fixture.bridge.status")
                        Button(String("接続確認")) {
                            Task {
                                do { try await bridge.verify(); bridgeResult = "接続確認済み" }
                                catch { bridgeResult = bridge.status == .revoked ? "失効を確認" : "接続確認に失敗" }
                            }
                        }.accessibilityIdentifier("fixture.bridge.verify")
                        Text(bridgeResult).accessibilityIdentifier("fixture.bridge.result")
                    }
                }
                if let name = fake.createdName { Text(verbatim: "作成済み：\(name)").accessibilityIdentifier("fixture.created") }
                conversationScreen.environmentObject(fake.state)
            }
            .navigationTitle(pushesChat ? AppLocalization.string("Chats") : "")
            .navigationDestination(isPresented: $pushesChat) {
                conversationScreen.environmentObject(fake.state)
                    .transformEnvironment(\.v2Shell) { $0.isRootCovered = true }
            }
            .sheet(item: $sheet) { selected in
                switch selected {
                case .create:
                    NavigationStack {
                        LAAGroupCreateView(roster: fake.bots) { name, bots, _ in
                            guard (2...6).contains(bots.count) else { return false }
                            fake.createdName = name
                            sheet = nil
                            return true
                        }
                    }
                case .pairing:
                    LAAPairingView().environmentObject(bridge)
                case .groupList:
                    LAAGroupListView().environmentObject(appState)
                case .settings:
                    NavigationStack {
                        LAAGroupSettingsContent(room: fake.room, canRename: true) { name, _ in
                            fake.createdName = name
                            return true
                        }
                    }
                }
            }
        }
        .environmentObject(fake.state)
        .preferredColorScheme(fixtureColorScheme)
        .environment(\.colorScheme, fixtureColorScheme ?? inheritedColorScheme)
        .overlay(alignment: .topLeading) {
            if captureReady {
                // Fixed size: The nearly invisible test marker must not change the screenshot layout.
                Text(verbatim: "Ready")
                    .font(.system(size: 1))
                    .opacity(0.02)
                    .accessibilityIdentifier("fixture.capture.ready")
                    .allowsHitTesting(false)
            }
        }
        .task {
            let args = ProcessInfo.processInfo.arguments
            func argument(_ name: String) -> String? {
                guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
                return args[i + 1]
            }
            if args.contains("-LAA_V2_RESTORE_APPEARANCE") {
                if let raw = UserDefaults.standard.string(forKey: previousThemeKey), let previous = ThemePreference(rawValue: raw) {
                    rootState.themePreference = previous
                    UserDefaults.standard.removeObject(forKey: previousThemeKey)
                }
                captureReady = true
                return
            }
            if argument("-LAA_CAPTURE_SURFACE") != nil {
                if UserDefaults.standard.string(forKey: previousThemeKey) == nil {
                    UserDefaults.standard.set(rootState.themePreference.rawValue, forKey: previousThemeKey)
                }
                rootState.themePreference = args.contains("-LAA_V2_DARK") ? .dark : .light
            }
            if argument("-LAA_CAPTURE_SURFACE") == "group" || args.contains("-LAA_FIXTURE_PUSH_GROUP") {
                await fake.openGroup()
            }
            if let raw = argument("-LAA_CAPTURE_KIND") {
                guard let kind = LAABackground.Kind(rawValue: raw), let key = LAAConversationScope.current(fake.state) else { return }
                do {
                    if kind == .photo {
                        let white = args.contains("-LAA_CAPTURE_WHITE")
                        guard let data = LAABackgroundFixturePhoto.data(white: white) else { return }
                        try LAABackgroundStore.shared.savePhoto(data, for: key, dim: white ? 0 : 0.2, blur: white ? 0 : 8)
                    } else {
                        try LAABackgroundStore.shared.save(LAABackground(kind: kind), for: key)
                    }
                    captureReady = true
                } catch {
                    return
                }
            }
        }
    }

    private var conversationScreen: some View {
        let callable = ProcessInfo.processInfo.arguments.contains("-LAA_FIXTURE_CALLABLE")
        return baseConversationScreen
            .environmentObject(callable ? pairedBridge : bridge)
            .environmentObject(callable ? fixtureCalls : calls)
    }

    @ViewBuilder private var baseConversationScreen: some View {
        if ProcessInfo.processInfo.arguments.contains("-LAA_FIXTURE_PREVIEW_FAILED") {
            LAAConversationRoute()
                .overlay(alignment: .topTrailing) {
                    Button("接続を復元") {
                        // The fixture performs the same successful launch handoff,
                        // with no credentials or live employee state.
                        if let workspace = fake.state.laaEmployeeChatPreview.workspace,
                           let link = WidgetLaunchLink(action: .employeeChat, workspace: workspace, reference: nil) {
                            fake.state.laaEmployeeChatLaunchEnded(link, outcome: .handled)
                        }
                    }.accessibilityIdentifier("fixture.preview.recover")
                }
        } else if ProcessInfo.processInfo.arguments.contains("-LAA_FORCE_COMPACT_CHAT") {
            V2ConversationScreen()
                .frame(width: 440)
                .environment(\.horizontalSizeClass, .compact)
        } else {
            V2ConversationScreen()
        }
    }

    private var fixtureColorScheme: ColorScheme? {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-LAA_V2_DARK") { return .dark }
        return args.contains("-LAA_V2_CHAT_FIXTURE") ? .light : nil
    }
}

enum LAABackgroundFixturePhoto {
    static func data(white: Bool = false) -> Data? {
        if white {
            return UIGraphicsImageRenderer(size: CGSize(width: 100, height: 200)).image { context in
                UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 200))
            }.pngData()
        }
        let fixture = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("background-fixture.jpg")
        if let data = try? Data(contentsOf: fixture) { return data }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 900)).image { context in
            UIColor(red: 0.85, green: 0.75, blue: 0.58, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 900))
            UIColor(red: 0.2, green: 0.38, blue: 0.35, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 500, width: 640, height: 400))
        }
        return image.pngData()
    }
}
/// Stands in for Hermes behind the chat's model and effort pickers. It
/// answers as Hermes does: a switch is reported back through
/// `model.options`, not by the picker itself.
@MainActor
private final class LAAChatModelFixture {
    let variant: String
    private let providers: [ProviderInfo]
    private var model: String?
    private var provider: String?

    init(variant: String, session: String, app: AppState) {
        self.variant = variant
        let shown = app.laaChatRuntime.shown(for: [session])
        model = shown.model; provider = shown.provider
        let ids = variant == "single" ? ["claude-opus-5-5"] : ["claude-opus-5-5", "claude-mythos-5-2", "claude-fable-5-2"]
        providers = [ProviderInfo(name: "claude", models: ids.map { ModelInfo(id: $0, label: nil, reasoningCapable: true) },
                                  displayName: "Claude")]
    }

    var operations: LAAChatModelOperations {
        LAAChatModelOperations(
            options: { [self] _ in
                var rows = providers
                if variant == "astra", let astra = ProviderInfo(from: AnyCodable(jsonObject: ["slug": "openai-codex", "models": ["gpt-6-astra"], "capabilities": ["gpt-6-astra": ["reasoning": true]]])) { rows.append(astra) }
                return (model, provider, rows)
            },
            setModel: { [self] _, model, provider, confirmed in
                if model.contains("mythos") && !confirmed {
                    return ModelSwitchOutcome(model: model, confirmRequired: true,
                                              confirmMessage: "Mythosは上位のモデルです。この会話を切り替えますか？")
                }
                self.model = model; self.provider = provider
                return ModelSwitchOutcome(model: model)
            },
            setReasoning: { _, _ in },
            setSpeed: { _, _ in })
    }
}
#endif
