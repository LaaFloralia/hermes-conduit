#if LAA_BUILD
import Foundation

struct LAAChatsPerson: Identifiable, Equatable {
    let profile: String
    let name: String
    let role: String
    let available: Bool
    var lastMessage: String? = nil
    var lastMessageAt: Date? = nil
    var id: String { profile }
}

enum LAAChatsLoadState: Equatable {
    case loading, ready, offline, unsupported
    case failed(String)
}

/// The Mac's list column: which row stays highlighted, and the keyboard
/// requests the menu bar sends it. The phone passes none of this.
struct LAAChatsListSelection: Equatable {
    var profile: String? = nil
    var roomID: String? = nil
    var focusSearch = 0
    var reload = 0
    var newChat = 0

    var isEmpty: Bool { profile == nil && roomID == nil }
}

struct LAAChatsSnapshot {
    var people: [LAAChatsPerson]
    var rooms: [GroupRoom]
    var groupsState: LAAChatsLoadState
    var canCreateChat: Bool
    var canCreateGroup: Bool
    /// Unread messages per profile, when the loaded list can count them.
    var unreadByProfile: [String: Int] = [:]
    /// The active profile's scheduled jobs and its recent cron runs.
    var cronJobs: [CronJob] = []
    var cronRuns: [SessionSummary] = []
    var cronZoneLabel: String? = nil
    /// Whether `cronJobs` was read. An unread or failed read is not "none".
    var cronState: LAAChatsLoadState = .ready
    /// Rows Hermes sent that this app could not read: the list is partial.
    var cronSkipped: Int = 0
    /// The profile whose Hermes connection produced these jobs; a job that
    /// runs in its own conversation belongs to it.
    var cronProfile: String = ""
}

/// What the Chats list says about scheduled jobs. Readiness and failure stay
/// apart from an empty list, and an unread list is never "stopped".
enum LAAChatsCron {
    static func loadState(_ phase: CronJobsPhase, connected: Bool) -> LAAChatsLoadState {
        switch phase {
        case .ready: return .ready
        case .failed: return .failed(LAACopy.chatsCronUnavailable)
        case .loading, .idle: return connected ? .loading : .offline
        }
    }
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

    /// Groups are the only source that loads; an empty search waits for it.
    static func emptySearchState(groups: LAAChatsLoadState) -> LAAChatsLoadState {
        switch groups {
        case .failed, .unsupported: return .failed("")
        default: return groups
        }
    }
}
#endif
