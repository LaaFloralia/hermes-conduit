#if LAA_BUILD && DEBUG
import SwiftUI

/// A deterministic list for UI tests. It exercises the production content
/// and callbacks without issuing mutations to a real Hermes account.
struct LAAChatsFixtureView: View {
    private struct Selection: Identifiable {
        let id = UUID()
        let label: String
    }
    @State private var selection: Selection?
    @State private var showingGroupCreator = false
    @State private var createdGroup: String?

    private var mode: String {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-LAA_CHATS_STATE"), args.indices.contains(i + 1) else { return "normal" }
        return args[i + 1]
    }
    private var state: LAAChatsLoadState {
        switch mode {
        case "loading": return .loading
        case "error": return .failed("Hermesから読み込めませんでした。")
        case "offline": return .offline
        case "unsupported": return .unsupported
        default: return .ready
        }
    }
    private var members: [GroupMember] {
        ["ciel", "cto", "cos"].compactMap { LAAStaff(rawValue: $0) }.map {
            GroupMember(memberID: "laa-\($0.rawValue)", profile: "laa-\($0.rawValue)",
                        handle: nil, displayName: $0.name, target: nil, extra: [:])
        }
    }
    private var snapshot: LAAChatsSnapshot {
        let people = LAAStaff.allCases.map {
            LAAChatsPerson(profile: "laa-\($0.rawValue)", name: $0.name, role: $0.role, available: mode != "offline")
        }
        let rooms = mode == "normal" ? [GroupRoom(roomID: "team", name: "LAA team", members: members,
            authorityGatewayID: "fixture", authorityEpoch: 1, revision: 1, createdAt: 1, updatedAt: 2,
            disbandedAt: nil, latestSeq: 1)] : []
        let sessions = mode == "normal" ? [
            SessionSummary(id: "week", alternateIds: [], title: "今週の予定", model: "", updatedLabel: "9:32",
                           lastActivityAt: 20, profile: "laa-ciel", source: .chat, isActive: false,
                           isArchived: false, preview: "今日の優先事項を整理しました"),
            SessionSummary(id: "design", alternateIds: [], title: "Design review", model: "", updatedLabel: "昨日",
                           lastActivityAt: 10, profile: "laa-cto", source: .chat, isActive: false,
                           isArchived: false, preview: "Review the draft")
        ] : []
        return LAAChatsSnapshot(people: people, rooms: rooms, sessions: sessions, activeProfile: "laa-ciel",
                                groupsState: state, sessionsState: state,
                                canCreateChat: mode == "normal", canCreateGroup: mode == "normal")
    }
    private var bots: [BotProfile] {
        LAAWidgetEmployee.allCases.map { employee in
            BotProfile(name: employee.profile, botTitle: nil, displayName: employee.name, profileDescription: "",
                       model: nil, provider: nil, hasAvatar: false, isPinned: false, isHiddenByMeta: false,
                       appearanceColor: nil, canonicalSession: nil, lastActive: nil, lastPreview: nil)
        }
    }

    var body: some View {
        LAAChatsContent(snapshot: snapshot, settingsAvailable: true,
                        openPerson: { selection = Selection(label: "person:\($0.profile)") },
                        openRoom: { selection = Selection(label: "group:\($0.roomID)") },
                        openSession: { selection = Selection(label: "session:\($0.id)") },
                        newChat: { selection = Selection(label: "new-chat") },
                        newGroup: { showingGroupCreator = true },
                        openSettings: { selection = Selection(label: "settings") }, retry: {}, searchChanged: {})
        .overlay(alignment: .bottom) {
            if let createdGroup {
                Text(verbatim: "created:\(createdGroup)").accessibilityIdentifier("laa.chats.fixture.created")
            }
        }
        .sheet(item: $selection) { value in
            NavigationStack {
                Text(verbatim: value.label).accessibilityIdentifier("laa.chats.fixture.selection")
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button { selection = nil } label: { Text(verbatim: "Done") }
                            .accessibilityIdentifier("laa.chats.fixture.done")
                    } }
            }
        }
        .sheet(isPresented: $showingGroupCreator) {
            NavigationStack {
                LAAGroupCreateView(roster: bots) { name, _, _ in
                    createdGroup = name
                    showingGroupCreator = false
                    return true
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingGroupCreator = false } } }
            }
        }
    }
}
#endif
