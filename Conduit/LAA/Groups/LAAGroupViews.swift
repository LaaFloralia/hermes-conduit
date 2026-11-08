#if LAA_BUILD
import SwiftUI

/// The hosted-room contract freezes membership on creation. This local
/// selection is used only to create a room, never to pretend an edit worked.
struct LAAGroupSelection {
    private(set) var selected: Set<String> = []
    let available: Set<String>

    mutating func toggle(_ profile: String) {
        guard available.contains(profile) else { return }
        if selected.contains(profile) { selected.remove(profile) }
        else if selected.count < 6 { selected.insert(profile) }
    }
    func canCreate(name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (2...6).contains(selected.count) && selected.isSubset(of: available)
    }
}

private struct LAAGroupListEntry: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @State private var showing = false
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) {
            Button { showing = true } label: {
                Label(LAACopy.chatsGroups, systemImage: "person.2")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .background(LAAColors.surface)
            .accessibilityIdentifier("groups.open")
        }
        .sheet(isPresented: $showing) { LAAGroupListView().environmentObject(appState) }
    }
}
extension View {
    func laaGroupListEntry() -> some View { modifier(LAAGroupListEntry()) }
}

@MainActor
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
                    case .idle, .loading: ProgressView(String("グループを読み込み中"))
                    case .gatewayUnsupported: Text(verbatim: "この接続先はグループに対応していません。")
                    case .failed(let message): Text(verbatim: "グループを読み込めませんでした：\(message)")
                    case .available:
                        NavigationLink(LAACopy.chatsNewGroup) {
                            LAAGroupCreateView(roster: appState.botRoster) { name, bots, roomID in
                                let created = await appState.createGroupRoom(name: name, bots: bots, roomID: roomID)
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
                                                .font(.caption).foregroundStyle(.secondary)
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
    }
}

@MainActor
struct LAAGroupCreateView: View {
    let roster: [BotProfile]
    let create: (String, [BotProfile], String) async -> Bool
    @State private var name = ""
    @State private var selected = Set<String>()
    @State private var roomID = GroupCreateAttempt.mintRoomID()
    @State private var attempted: GroupCreateAttempt.Inputs?
    @State private var creating = false
    @State private var failed = false

    private var available: [BotProfile] {
        roster.filter { bot in LAAWidgetEmployee.forProfile(bot.name) != nil && LAAWidgetEmployee.forProfile(bot.name) != .monetUncensored && !bot.isHiddenByMeta }
    }
    private var selection: LAAGroupSelection {
        var selection = LAAGroupSelection(available: Set(available.map(\.name)))
        for id in selected { selection.toggle(id) }
        return selection
    }

    var body: some View {
        List {
            Section(LAACopy.groupName) {
                TextField(text: $name) { Text(verbatim: LAACopy.groupNameField) }.accessibilityIdentifier("groups.create.name")
            }
            Section {
                ForEach(LAAWidgetEmployee.allCases.filter { $0 != .monetUncensored }, id: \.self) { employee in
                    let isAvailable = available.contains { $0.name == employee.profile }
                    Button {
                        var next = selection
                        next.toggle(employee.profile)
                        selected = next.selected
                    } label: {
                        HStack {
                            Text(employee.name)
                            Spacer()
                            if !isAvailable { Text(verbatim: "接続先にいません").font(.caption).foregroundStyle(.secondary) }
                            else { Image(systemName: selected.contains(employee.profile) ? "checkmark.circle.fill" : "circle") }
                        }
                    }
                    .disabled(!isAvailable || creating)
                    .accessibilityIdentifier("groups.employee.\(employee.profile)")
                }
            } header: { Text(verbatim: LAACopy.groupSelectEmployees) }
            if failed { Text(verbatim: "作成できませんでした。接続先と選択した社員を確認して再試行してください。")
                .foregroundStyle(.red) }
        }
        .navigationTitle(Text(verbatim: LAACopy.chatsNewGroup))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(LAACopy.groupCreate) {
                    guard !creating else { return }
                    let inputs = GroupCreateAttempt.Inputs(name: name.trimmingCharacters(in: .whitespacesAndNewlines), members: selected)
                    roomID = GroupCreateAttempt.roomID(for: inputs, current: roomID, attempted: attempted)
                    attempted = inputs
                    let bots = available.filter { selected.contains($0.name) }
                    creating = true
                    Task {
                        let ok = await create(inputs.name, bots, roomID)
                        failed = !ok
                        creating = false
                    }
                }
                .disabled(creating || !selection.canCreate(name: name))
                .accessibilityIdentifier("groups.create.submit")
            }
        }
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
                    .font(.footnote).foregroundStyle(.secondary) }
                if failed { Text(verbatim: "変更できませんでした。接続を確認して再試行してください。")
                    .font(.footnote).foregroundStyle(.red) }
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
