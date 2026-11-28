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

    var staff: LAAStaff? { LAAStaff(profile: profile) }
    /// Where the list puts this person; nil for a profile LAA does not know.
    var placement: LAAStaff.Placement? { staff?.placement }
}

/// A row's preview in the list: the latest live row, else the latest cached
/// one, else the roster's `last_session.preview`. A reply that is only
/// Hermes' no-reply token ([SILENT]) leaves no message for the reader, so the
/// list skips it here and keeps the row before it. Records are not changed.
enum LAAChatsPreview {
    /// Protocol text, not localized: what a turn answers when it sends nothing.
    static let noReplySentinel = "[SILENT]"

    struct Choice: Equatable {
        let text: String
        let timestamp: String?
    }

    /// The whole text is the token, outer whitespace aside; case counts.
    static func isNoReplySentinel(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) == noReplySentinel
    }

    /// Someone's words: a user or assistant row with text, except an
    /// assistant row that is only the token. A person's own "[SILENT]" stays.
    static func shows(role: MessageRole, content: String) -> Bool {
        guard role == .user || role == .assistant, !content.isEmpty else { return false }
        guard !isInternalNotice(content) else { return false }
        return !(role == .assistant && isNoReplySentinel(content))
    }

    /// Hermes' own notices ("[System: The active model … has changed …]" and
    /// the other `[System: …]` lines) are not someone's words (BUS-558).
    static func isInternalNotice(_ text: String) -> Bool {
        MessageNormalizer.modelChangeActivity(fromText: text) != nil
            || MessageNormalizer.systemNoticeText(fromText: text) != nil
    }

    static func latest(_ messages: [ChatMessage]) -> ChatMessage? {
        messages.last { shows(role: $0.role, content: $0.content) }
    }

    static func latest(_ messages: [OfflineCachedMessage]) -> OfflineCachedMessage? {
        messages.last { shows(role: $0.role, content: $0.content) }
    }

    /// The roster preview carries no role: only the exact token is left out.
    static func choose(live: ChatMessage?, cached: OfflineCachedMessage?, roster: String?) -> Choice? {
        if let live { return Choice(text: live.content, timestamp: live.timestamp) }
        if let cached { return Choice(text: cached.content, timestamp: cached.timestamp) }
        guard let roster, !isNoReplySentinel(roster), !isInternalNotice(roster) else { return nil }
        // A cron report never shows its internal header line.
        return Choice(text: MessageNormalizer.cronReport(roster)?.body ?? roster, timestamp: nil)
    }
}

/// The Chat list's sections, in order: Monet (with its uncensored variant),
/// then the employees. Groups follow them.
enum LAAChatsPlacement {
    static func monet(_ people: [LAAChatsPerson]) -> LAAChatsPerson? {
        people.first { $0.staff == .monet }
    }

    /// Monet's own variants under it: only the uncensored one.
    static func monetVariants(_ people: [LAAChatsPerson]) -> [LAAChatsPerson] {
        people.filter { $0.staff != .monet && $0.placement == .monet }
    }

    static func people(_ people: [LAAChatsPerson], in placement: LAAStaff.Placement) -> [LAAChatsPerson] {
        people.filter { $0.staff != .monet && $0.placement == placement }
    }
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
