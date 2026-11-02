#if LAA_BUILD
import Foundation

struct LAACalendarEvent: Codable, Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let location: String?

    var googleID: String? = nil
    var calendarId: String? = nil
    var notes: String? = nil
    var meetingLink: String? = nil
    var etag: String? = nil
    var attendees: [LAACalendarAttendee]? = nil
    var attachments: [LAACalendarAttachment]? = nil
    var recurrence: [String]? = nil
    var recurringEventId: String? = nil
    var timeZone: String? = nil

    func overlaps(start: Date, end: Date) -> Bool { self.start < end && self.end > start }
}

struct LAACalendarAttendee: Codable { let email: String; let name: String?; let response: String? }
struct LAACalendarAttachment: Codable { let title: String; let url: String }

/// The widget shares only the latest successful Google read, never OAuth credentials.
struct LAACalendarSnapshot: Codable {
    let updatedAt: Date
    let events: [LAACalendarEvent]

    func isFresh(at now: Date) -> Bool { !(now < updatedAt) && now.timeIntervalSince(updatedAt) < 3600 }

    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetSnapshotStore.appGroup)?
            .appendingPathComponent("google-calendar-v1.json")
    }
    static func read() -> Self? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    static func save(_ value: Self?) {
        guard let url else { return }
        guard let value else { try? FileManager.default.removeItem(at: url); return }
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
#endif
