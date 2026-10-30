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
            GroupMember(memberID: "laa-ciel", profile: "laa-ciel", handle: "ciel", displayName: "Ciel", target: nil, extra: [:]),
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
                       actor: GroupActor(kind: "member", id: "laa-ciel", profile: "laa-ciel", displayName: "Ciel", connectionID: nil),
                       authorityEpoch: 1, payload: ["text": .string("是。予定を確認して、必要な情報をお伝えします。"), "thread_id": .string("main")], createdAt: 2),
        ]
        if chatFixture != nil {
            events = [
                GroupEvent(roomID: room.roomID, seq: 1, eventID: "one", kind: "message.user",
                           actor: GroupActor(kind: "user", id: "user", profile: nil, displayName: nil, connectionID: nil),
                           authorityEpoch: 1, payload: ["text": .string("今日の予定を整理して、次の一手を教えて。")], createdAt: now - 60),
                GroupEvent(roomID: room.roomID, seq: 2, eventID: "two", kind: "message.member",
                           actor: GroupActor(kind: "member", id: "laa-ciel", profile: "laa-ciel", displayName: "Ciel", connectionID: nil),
                           authorityEpoch: 1, payload: ["text": .string(Self.richMessage)], createdAt: now),
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
        defaults.set("laa-ciel", forKey: "conduit.activeProfile")
        let app = AppState(defaults: defaults, loadSavedConnection: false,
                           clearSessionPresentationCache: {},
                           chatResumeLifecycleOperations: ChatResumeLifecycleOperations(botRoster: { _ in
                               BotRosterSnapshot(bots: bots, supportsBotProtocol: true)
                           }), groupChatOperations: operations)
        app.client = HermesClient(connection: HermesConnection(baseUrl: "https://background-ui-test.invalid", ticket: "fixture"), profile: "laa-ciel")
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
                    content: "# 素材をまとめました\n\n画像とファイルをこの会話から開けます。\n\nMEDIA: /fixtures/ciel.png\n\nMEDIA: /fixtures/design-notes.pdf",
                    timestamp: String(now))]
                if let dashboard = app.activeDashboardID,
                   let hero = StaffAssetResolver.bundled.resolve(profile: "laa-ciel").hero,
                   let data = try? Data(contentsOf: hero) {
                    let key = TranscriptImageCache.key(dashboard: dashboard.uuidString, profile: "laa-ciel", path: "/fixtures/ciel.png")
                    TranscriptImageCache.store(data, fileExtension: "png", for: key)
                }
            } else {
                app.messages = [
                    ChatMessage(id: "user", role: .user, content: "今日の予定を整理して、次の一手を教えて。", timestamp: String(now - 60)),
                    ChatMessage(id: "assistant", role: .assistant, content: Self.richMessage, timestamp: String(now))
                ]
            }
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
    @State private var sheet: FixtureSheet?
    @State private var bridgeResult = "未確認"
    @State private var captureReady = false
    @State private var pushesChat = ProcessInfo.processInfo.arguments.contains("-LAA_FIXTURE_PUSH_CHAT")
    @EnvironmentObject private var bridge: LAABridgeSession
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

    @ViewBuilder private var conversationScreen: some View {
        if ProcessInfo.processInfo.arguments.contains("-LAA_FORCE_COMPACT_CHAT") {
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
#endif
