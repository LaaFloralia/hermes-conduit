#if LAA_BUILD && DEBUG
import SwiftUI

/// Uses real conversation surfaces and pickers with an isolated fake gateway.
@MainActor
private final class LAABackgroundFixture: ObservableObject {
    let state: AppState
    let room: GroupRoom
    let bots: [BotProfile]
    @Published var createdName: String?

    init() {
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
        let events = [
            GroupEvent(roomID: room.roomID, seq: 1, eventID: "one", kind: "message.user",
                       actor: GroupActor(kind: "user", id: "user", profile: nil, displayName: nil, connectionID: nil),
                       authorityEpoch: 1, payload: ["text": .string("今日の予定を教えてください。"), "thread_id": .string("main")], createdAt: 1),
            GroupEvent(roomID: room.roomID, seq: 2, eventID: "two", kind: "message.member",
                       actor: GroupActor(kind: "member", id: "laa-ciel", profile: "laa-ciel", displayName: "Ciel", connectionID: nil),
                       authorityEpoch: 1, payload: ["text": .string("是。予定を確認して、必要な情報をお伝えします。"), "thread_id": .string("main")], createdAt: 2),
        ]
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in
                if mode == "error" { throw URLError(.cannotConnectToHost) }
                return GroupCapabilities(protocolVersion: 2, driverReady: true, authorityGatewayID: "fixture",
                    features: [], methods: GroupWire.requiredMethods.union(["groups.rename"]), maxLogLimit: 500)
            },
            list: { _ in (mode == "empty" ? [] : [room], nil) }, state: { _, _ in (room, nil) },
            log: { _, _, since, _ in GroupLogPage(events: events.filter { $0.seq > since }, cursor: 2,
                latestSeq: 2, hasMore: false, authorityGatewayID: "fixture", authorityEpoch: 1) }
        )
        let defaults = UserDefaults(suiteName: "LAABackgroundUITestFixture")!
        defaults.set("laa-ciel", forKey: "conduit.activeProfile")
        let app = AppState(defaults: defaults, loadSavedConnection: false,
                           clearSessionPresentationCache: {},
                           chatResumeLifecycleOperations: ChatResumeLifecycleOperations(botRoster: { _ in
                               BotRosterSnapshot(bots: bots, supportsBotProtocol: true)
                           }), groupChatOperations: operations)
        app.client = HermesClient(connection: HermesConnection(baseUrl: "https://background-ui-test.invalid", ticket: "fixture"), profile: "laa-ciel")
        app.isConnected = mode != "offline"
        _ = app.adoptDashboard(forNormalizedURL: "https://background-ui-test.invalid")
        app.activeSessionId = "fixture-chat"
        app.messages = [
            ChatMessage(id: "user", role: .user, content: "今日の予定を教えてください。", timestamp: "1"),
            ChatMessage(id: "assistant", role: .assistant, content: "是。予定を確認して、必要な情報をお伝えします。", timestamp: "2")
        ]
        self.state = app
        self.bots = bots
    }

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
    @EnvironmentObject private var bridge: LAABridgeSession

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
                V2ConversationScreen().environmentObject(fake.state)
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
                    LAAGroupListView().environmentObject(fake.state)
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
        .task {
            let args = ProcessInfo.processInfo.arguments
            func argument(_ name: String) -> String? {
                guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
                return args[i + 1]
            }
            if argument("-LAA_CAPTURE_SURFACE") == "group" { await fake.openGroup() }
            if let raw = argument("-LAA_CAPTURE_KIND"), let kind = LAABackground.Kind(rawValue: raw),
               let key = LAAConversationScope.current(fake.state) {
                if kind == .photo, let data = LAABackgroundFixturePhoto.data() {
                    try? LAABackgroundStore.shared.savePhoto(data, for: key, dim: 0.2, blur: 8)
                } else {
                    try? LAABackgroundStore.shared.save(LAABackground(kind: kind), for: key)
                }
            }
        }
    }
}

enum LAABackgroundFixturePhoto {
    static func data() -> Data? {
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
