#if LAA_BUILD
import Foundation

struct LAAChatsPerson: Identifiable, Equatable {
    let profile: String
    let name: String
    let role: String
    let available: Bool
    var id: String { profile }
}

enum LAAChatsLoadState: Equatable {
    case loading, ready, offline, unsupported
    case failed(String)
}

struct LAAChatsSnapshot {
    var people: [LAAChatsPerson]
    var rooms: [GroupRoom]
    var sessions: [SessionSummary]
    var activeProfile: String
    var groupsState: LAAChatsLoadState
    var sessionsState: LAAChatsLoadState
    var canCreateChat: Bool
    var canCreateGroup: Bool
}

/// Search only what the existing Hermes catalogs have actually returned.
enum LAAChatsSearch {
    static func matches(_ query: String, _ values: [String?]) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return true }
        return values.compactMap { $0 }.contains {
            $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    static func person(_ person: LAAChatsPerson, matches query: String) -> Bool {
        matches(query, [person.name, person.role, person.profile])
    }

    static func room(_ room: GroupRoom, matches query: String) -> Bool {
        matches(query, [room.name] + room.members.flatMap { [$0.displayName, $0.profile, $0.handle] })
    }

    static func session(_ session: SessionSummary, ownerName: String?, matches query: String) -> Bool {
        matches(query, [session.title, session.preview, ownerName, session.profile])
    }

    static func emptySearchState(groups: LAAChatsLoadState, sessions: LAAChatsLoadState) -> LAAChatsLoadState {
        let states = [groups, sessions]
        if states.contains(.offline) { return .offline }
        if states.contains(where: { if case .failed = $0 { return true }; return $0 == .unsupported }) {
            return .failed("")
        }
        if states.contains(.loading) { return .loading }
        return .ready
    }
}
#endif
