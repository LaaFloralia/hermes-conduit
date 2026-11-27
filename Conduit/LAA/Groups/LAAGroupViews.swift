#if LAA_BUILD
import SwiftUI

/// The hosted-room contract freezes membership on creation. This local
/// selection is used only to create a room, never to pretend an edit worked.
struct LAAGroupSelection {
    static let maximumMembers = 7

    private(set) var selected: Set<String> = []
    let available: Set<String>

    mutating func toggle(_ profile: String) {
        guard available.contains(profile) else { return }
        if selected.contains(profile) { selected.remove(profile) }
        else if selected.count < Self.maximumMembers { selected.insert(profile) }
    }
    func canCreate(name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (2...Self.maximumMembers).contains(selected.count) && selected.isSubset(of: available)
    }
}

@MainActor
/// Who a new group can include, sectioned as the Chat list is. The
/// uncensored Monet stays out of groups.
enum LAAGroupCandidates {
    struct Section { let title: String; let staff: [LAAStaff] }

    static var sections: [Section] {
        [Section(title: LAACopy.groupSelectEmployees, staff: [.monet]),
         Section(title: LAACopy.chatsEmployees, staff: LAAStaff.members(of: .employee))]
    }

    static var all: [LAAStaff] { sections.flatMap(\.staff) }
}

struct LAAGroupListView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !appState.isConnected {
                    Text(verbatim: "グループを開くにはMacに接続してください。")
                } else {
                    switch appState.groupChatPhase {
                    case .idle, .loading: ProgressView(String("Loading Group"))
                    case .gatewayUnsupported: Text(verbatim: "この接続先はグループに対応していません。")
                    case .failed(let message): Text(verbatim: "グループを読み込めませんでした：\(message)")
                    case .available:
                        NavigationLink(LAACopy.chatsNewGroup) {
                            LAAGroupCreateView(roster: appState.botRoster, capabilities: appState.groupCapabilities) { name, bots, roomID, confidential in
                                let created = await appState.createGroupRoom(name: name, bots: bots, roomID: roomID, confidential: confidential)
                                if created { dismiss() }
                                return created
                            }
                        }.accessibilityIdentifier("groups.create.open")
                        if appState.groupRooms.isEmpty {
                            Text(verbatim: "グループはまだありません。")
                                .foregroundStyle(.secondary)
                        } else {
                            Section(LAACopy.chatsGroups) {
                                ForEach(appState.groupRooms) { room in
                                    Button {
                                        Task { await appState.openGroupRoom(room); dismiss() }
                                    } label: {
                                        VStack(alignment: .leading) {
                                            Text(room.name)
                                            Text(room.members.compactMap(\.displayName).joined(separator: "、"))
                                                .laaTextStyle(.note).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(Text(verbatim: LAACopy.chatsGroups))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(LAACopy.groupDone) { dismiss() } } }
            .task {
                guard appState.isConnected else { return }
                await appState.refreshBotRoster()
                await appState.refreshGroupChatSupport()
            }
            .refreshable { await appState.refreshBotRoster(); await appState.refreshGroupChatSupport() }
        }
        .laaSheetSize(.page)
    }
}

@MainActor
struct LAAGroupCreateView: View {
    let roster: [BotProfile]
    let capabilities: GroupCapabilities?
    let create: (String, [BotProfile], String, Bool) async -> Bool
    @State private var name = ""
    @State private var confidential = false
    @State private var selected: Set<String>
    @State private var roomID = GroupCreateAttempt.mintRoomID()
    @State private var attempted: GroupCreateAttempt.Inputs?
    @State private var creating = false
    @State private var failed = false

    init(roster: [BotProfile], capabilities: GroupCapabilities? = nil, preselected: Set<String> = [],
         create: @escaping (String, [BotProfile], String, Bool) async -> Bool) {
        self.roster = roster
        self.capabilities = capabilities
        self.create = create
        _selected = State(initialValue: preselected)
    }

    private var available: [BotProfile] {
        roster.filter { bot in LAAGroupCandidates.all.contains { "laa-\($0.rawValue)" == bot.name } && !bot.isHiddenByMeta }
    }
    private var selection: LAAGroupSelection {
        var selection = LAAGroupSelection(available: Set(available.map(\.name)))
        for bot in available where selected.contains(bot.name) { selection.toggle(bot.name) }
        return selection
    }

    var body: some View {
        let current = selection
        List {
            Section(LAACopy.groupName) {
                TextField(text: $name) { Text(verbatim: LAACopy.groupNameField) }.accessibilityIdentifier("groups.create.name")
            }
            if capabilities?.supportsConfidentialRooms == true {
                Toggle(isOn: $confidential) { Text(verbatim: LAACopy.groupConfidential) }
                    .disabled(creating)
                    .accessibilityIdentifier("groups.create.confidential")
            }
            // The same placement and order as the Chat list: Monet, then
            // the employees (owner, 2026-11-23 and 11-26).
            ForEach(LAAGroupCandidates.sections, id: \.title) { section in
                Section {
                    ForEach(section.staff, id: \.self) { staff in
                        let profile = "laa-\(staff.rawValue)"
                        let isAvailable = available.contains { $0.name == profile }
                        Button {
                            var next = selection
                            next.toggle(profile)
                            selected = next.selected
                        } label: {
                            HStack {
                                Text(verbatim: LAAChatPerson.name(staff.name))
                                Spacer()
                                if !isAvailable { Text(verbatim: "接続先にいません").laaTextStyle(.note).foregroundStyle(.secondary) }
                                else { Image(systemName: current.selected.contains(profile) ? "checkmark.circle.fill" : "circle") }
                            }
                        }
                        .disabled(!isAvailable || creating)
                        .accessibilityIdentifier("groups.employee.\(profile)")
                    }
                } header: {
                    Text(verbatim: section.title)
                }
            }
            if current.selected.contains("laa-monet"), capabilities?.supportsRoomChair == true {
                Text(verbatim: LAACopy.groupMonetChair).laaTextStyle(.note).foregroundStyle(.secondary)
            } else if current.selected.count == LAAGroupSelection.maximumMembers {
                Text(verbatim: LAACopy.groupAllHandsUnavailable).laaTextStyle(.note).foregroundStyle(.secondary)
            }
            if failed { Text(verbatim: "作成できませんでした。接続先と選択した社員を確認して再試行してください。")
                .foregroundStyle(.red) }
        }
        .navigationTitle(Text(verbatim: LAACopy.chatsNewGroup))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(LAACopy.groupCreate) {
                    guard !creating else { return }
                    let inputs = GroupCreateAttempt.Inputs(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                                            members: current.selected, confidential: confidential)
                    roomID = GroupCreateAttempt.roomID(for: inputs, current: roomID, attempted: attempted)
                    attempted = inputs
                    let bots = available.filter { current.selected.contains($0.name) }
                    creating = true
                    Task {
                        let ok = await create(inputs.name, bots, roomID, inputs.confidential)
                        failed = !ok
                        creating = false
                    }
                }
                .disabled(creating || !current.canCreate(name: name)
                          || (current.selected.count == LAAGroupSelection.maximumMembers && capabilities?.supportsRoomChair != true))
                .accessibilityIdentifier("groups.create.submit")
            }
        }
        .laaSheetSize(.form)
    }
}

@MainActor
enum LAAGroupRename {
    static func isAvailable(_ state: AppState) -> Bool {
        state.isConnected && state.client != nil && state.groupCapabilities?.supports("groups.rename") == true
    }

    static func perform(_ state: AppState, surface: AppState.GroupRoomSurface, name: String, eventID: String) async -> Bool {
        guard isAvailable(state), let client = state.client else { return false }
        let epoch = state.groupRoomEpoch
        do {
            let room = try await client.groupsRename(roomID: surface.room.roomID, eventID: eventID, name: name)
            guard state.groupRoomEpoch == epoch, state.activeDashboardID == surface.dashboardID,
                  state.activeRoomSurface?.room.roomID == surface.room.roomID else { return false }
            await state.refreshGroupRooms()
            guard state.groupRoomEpoch == epoch, state.activeDashboardID == surface.dashboardID else { return false }
            await state.openGroupRoom(room)
            return true
        } catch { return false }
    }
}

@MainActor
struct LAAGroupSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if let surface = appState.activeRoomSurface {
                LAAGroupSettingsContent(room: surface.room,
                    canRename: LAAGroupRename.isAvailable(appState)) { name, eventID in
                    await LAAGroupRename.perform(appState, surface: surface, name: name, eventID: eventID)
                }
            } else { Text(verbatim: "グループが開かれていません。") }
        }
        .laaSheetSize(.form)
    }
}

@MainActor
struct LAAGroupSettingsContent: View {
    let room: GroupRoom
    let canRename: Bool
    let rename: (String, String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var eventID = UUID().uuidString.lowercased()
    @State private var attemptedName: String?
    @State private var saving = false
    @State private var failed = false

    var body: some View {
        Form {
            Section(LAACopy.groupName) {
                TextField(text: $name) { Text(verbatim: LAACopy.groupNameField) }.accessibilityIdentifier("groups.rename.name")
                Button(LAACopy.groupRename) {
                    let next = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let attemptedName, attemptedName != next { eventID = UUID().uuidString.lowercased() }
                    attemptedName = next
                    saving = true
                    Task { let ok = await rename(next, eventID); saving = false; failed = !ok; if ok { dismiss() } }
                }
                .disabled(!canRename || saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == room.name)
                .accessibilityIdentifier("groups.rename.submit")
                if !canRename { Text(verbatim: "この接続先では名前を変更できません。過去の履歴は保持されます。")
                    .laaTextStyle(.secondary).foregroundStyle(.secondary) }
                if failed { Text(verbatim: "変更できませんでした。接続を確認して再試行してください。")
                    .laaTextStyle(.secondary).foregroundStyle(.red) }
            }
            Section {
                ForEach(room.members, id: \.identityKey) { member in
                    HStack {
                        Text(member.displayName ?? member.profile ?? member.identityKey)
                        Spacer()
                        Button(LAACopy.groupRemove) {}.disabled(true)
                            .accessibilityIdentifier("groups.member.remove.\(member.identityKey)")
                    }
                }
                Button(LAACopy.groupAddEmployee) {}.disabled(true).accessibilityIdentifier("groups.member.add")
            } header: { Text(verbatim: LAACopy.groupMembers) }
              footer: { Text(verbatim: "この接続先には参加者を追加・削除する機能がありません。") }
        }
        .navigationTitle(Text(verbatim: LAACopy.groupSettings))
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(LAACopy.groupDone) { dismiss() } } }
        .onAppear { name = room.name }
    }
}
#endif
