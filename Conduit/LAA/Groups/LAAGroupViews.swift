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
                Label(String("グループ"), systemImage: "person.2")
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
                    Text(verbatim: "グループを開くには Hermes に接続してください。")
                } else {
                    switch appState.groupChatPhase {
                    case .idle, .loading: ProgressView(String("グループを読み込み中"))
                    case .gatewayUnsupported: Text(verbatim: "この接続先はグループに対応していません。")
                    case .failed(let message): Text(verbatim: "グループを読み込めませんでした：\(message)")
                    case .available:
                        NavigationLink(String("グループを作成")) {
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
                            Section(String("グループ")) {
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
            .navigationTitle(Text(verbatim: "グループ"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String("完了")) { dismiss() } } }
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
        roster.filter { bot in LAAWidgetEmployee.forProfile(bot.name) != nil && !bot.isHiddenByMeta }
    }
    private var selection: LAAGroupSelection {
        var selection = LAAGroupSelection(available: Set(available.map(\.name)))
        for id in selected { selection.toggle(id) }
        return selection
    }

    var body: some View {
        List {
            Section(String("グループ名")) {
                TextField(text: $name) { Text(verbatim: "名前") }.accessibilityIdentifier("groups.create.name")
            }
            Section {
                ForEach(LAAWidgetEmployee.allCases, id: \.self) { employee in
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
            } header: { Text(verbatim: "社員を選択（2〜6人）") }
            if failed { Text(verbatim: "作成できませんでした。接続先と選択した社員を確認して再試行してください。")
                .foregroundStyle(.red) }
        }
        .navigationTitle(Text(verbatim: "グループを作成"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String("作成")) {
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
struct LAAGroupSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if let surface = appState.activeRoomSurface {
                LAAGroupSettingsContent(room: surface.room,
                    canRename: appState.isConnected && appState.groupCapabilities?.supports("groups.rename") == true) { name, eventID in
                    guard let client = appState.client, appState.isConnected,
                          appState.groupCapabilities?.supports("groups.rename") == true else { return false }
                    let epoch = appState.groupRoomEpoch
                    do {
                        let room = try await client.groupsRename(roomID: surface.room.roomID, eventID: eventID, name: name)
                        guard appState.groupRoomEpoch == epoch, appState.activeDashboardID == surface.dashboardID,
                              appState.activeRoomSurface?.room.roomID == surface.room.roomID else { return false }
                        await appState.refreshGroupRooms()
                        guard appState.groupRoomEpoch == epoch, appState.activeDashboardID == surface.dashboardID else { return false }
                        await appState.openGroupRoom(room)
                        return true
                    } catch { return false }
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
            Section(String("グループ名")) {
                TextField(text: $name) { Text(verbatim: "名前") }.accessibilityIdentifier("groups.rename.name")
                Button(String("名前を変更")) {
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
                        Button(String("削除")) {}.disabled(true)
                            .accessibilityIdentifier("groups.member.remove.\(member.identityKey)")
                    }
                }
                Button(String("社員を追加")) {}.disabled(true).accessibilityIdentifier("groups.member.add")
            } header: { Text(verbatim: "参加者") }
              footer: { Text(verbatim: "この接続先には参加者を追加・削除する機能がありません。") }
        }
        .navigationTitle(Text(verbatim: "グループ設定"))
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String("完了")) { dismiss() } } }
        .onAppear { name = room.name }
    }
}
#endif
