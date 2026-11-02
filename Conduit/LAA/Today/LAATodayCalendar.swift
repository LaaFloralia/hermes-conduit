#if LAA_BUILD
import Combine
import Foundation
import WidgetKit

enum LAACalendarRequest {
    static func eventPath(id: String, calendarID: String? = nil) throws -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard !id.isEmpty, id.utf8.count <= 1024,
              let segment = id.addingPercentEncoding(withAllowedCharacters: unreserved) else { throw LAABridgeError.invalidResponse }
        var path = "/v1/calendar/events/" + segment
        if let calendarID {
            guard !calendarID.isEmpty, calendarID.utf8.count <= 1024,
                  let query = calendarID.addingPercentEncoding(withAllowedCharacters: unreserved) else { throw LAABridgeError.invalidResponse }
            path += "?calendarId=" + query
        }
        return path
    }
}

struct LAACalendarResponse: Codable {
    struct Event: Codable {
        let id: String
        let title: String
        let start: String
        let end: String
        let allDay: Bool
        let location: String?

        var calendarId: String? = nil
        var description: String? = nil
        var meetingLink: String? = nil
        var etag: String? = nil
        var attendees: [LAACalendarAttendee]? = nil
        var attachments: [LAACalendarAttachment]? = nil
        var recurrence: [String]? = nil
        var recurringEventId: String? = nil
        var timeZone: String? = nil

        func value(calendar inputCalendar: Calendar = .current) throws -> LAACalendarEvent {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = inputCalendar.timeZone
            func date(_ text: String) -> Date? {
                if allDay {
                    guard text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
                    let parts = text.split(separator: "-").compactMap { Int($0) }
                    guard parts.count == 3 else { return nil }
                    let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
                    guard let value = calendar.date(from: components),
                          calendar.component(.year, from: value) == parts[0],
                          calendar.component(.month, from: value) == parts[1],
                          calendar.component(.day, from: value) == parts[2] else { return nil }
                    return value
                }
                let formatter = ISO8601DateFormatter()
                if let value = formatter.date(from: text) { return value }
                formatter.formatOptions.insert(.withFractionalSeconds)
                return formatter.date(from: text)
            }
            guard let first = date(start), let last = date(end), first < last else { throw LAABridgeError.invalidResponse }
            var event = LAACalendarEvent(id: calendarId.map { $0 + ":" + id } ?? id, title: title, start: first, end: last, allDay: allDay, location: location)
            event.googleID = id; event.calendarId = calendarId; event.notes = description; event.meetingLink = meetingLink
            event.etag = etag; event.attendees = attendees; event.attachments = attachments; event.recurrence = recurrence
            event.recurringEventId = recurringEventId; event.timeZone = timeZone
            return event
        }
    }
    let items: [Event]
    var skippedCount: Int? = nil
}

@MainActor final class LAATodayCalendar: ObservableObject {
    @Published private(set) var events: [LAACalendarEvent] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var loaded = false
    @Published private(set) var skippedCount = 0
    @Published private(set) var calendars: [LAAGoogleCalendar] = []
    @Published var selectedCalendarIDs: Set<String> = []
    @Published var selectedDate = Date()
    @Published var mode: LAACalendarMode = .list
    private var cacheKey: String?
    private var generation = 0
    // LAA personal copy is rendered with Text(verbatim:).
    private static let connectMessage = "予定を表示するには、Macに接続してください。"

    static func requestPath(now: Date = Date(), calendar: Calendar = .current) -> String {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        let formatter = ISO8601DateFormatter()
        var parts = URLComponents()
        parts.path = "/v1/calendar/events"
        parts.queryItems = [URLQueryItem(name: "start", value: formatter.string(from: start)),
                           URLQueryItem(name: "end", value: formatter.string(from: end))]
        return parts.string ?? "/v1/calendar/events"
    }

    func refresh(bridge: LAABridgeSession, now: Date = Date()) async {
        guard bridge.status == .paired, let deviceID = bridge.deviceID else {
            cacheKey = nil; calendars = []; selectedCalendarIDs = []
            await refresh(isPaired: false) { LAACalendarResponse(items: []) }; return
        }
        let identity = deviceID + ":calendar"
        if cacheKey != identity {
            cacheKey = identity
            let cached = LAAGoogleCache.read(LAACalendarLocalState.self, key: identity)
            calendars = cached?.calendars ?? []; selectedCalendarIDs = Set(cached?.selectedIDs ?? [])
            events = cached?.events ?? []; skippedCount = cached?.skippedCount ?? 0; loaded = cached != nil
        }
        isLoading = true; errorMessage = nil
        generation += 1; let current = generation
        defer { if current == generation { isLoading = false } }
        do {
            let list: LAABridgeResponse<LAAGoogleCalendarList> = try await bridge.request(method: "GET", path: "/v1/calendar/calendars")
            guard current == generation else { return }
            let previous = Set(calendars.map(\.id))
            calendars = list.data.items
            if previous.isEmpty { selectedCalendarIDs = Set(calendars.filter(\.selected).map(\.id)) }
            else { selectedCalendarIDs.formIntersection(Set(calendars.map(\.id))) }
            if selectedCalendarIDs.isEmpty {
                events = []; skippedCount = 0; loaded = true; saveLocal()
                LAACalendarSnapshot.save(nil)
                WidgetCenter.shared.reloadTimelines(ofKind: "LAANextEvent")
                return
            }
            let range = mode.range(containing: selectedDate)
            var parts = URLComponents(); parts.path = "/v1/calendar/events"
            let iso = ISO8601DateFormatter()
            parts.queryItems = [URLQueryItem(name: "start", value: iso.string(from: range.start)), URLQueryItem(name: "end", value: iso.string(from: range.end))]
                + selectedCalendarIDs.sorted().map { URLQueryItem(name: "calendarId", value: $0) }
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            let response: LAABridgeResponse<LAACalendarResponse> = try await bridge.request(method: "GET", path: parts.string!, timeout: 30)
            let values = try response.data.items.map { try $0.value() }.sorted { $0.start < $1.start }
            guard current == generation, !Task.isCancelled else { return }
            events = values; skippedCount = response.data.skippedCount ?? 0; loaded = true; saveLocal()
            // Only publish a next-event snapshot when this range contains now.
            if range.start <= now && range.end > now {
                LAACalendarSnapshot.save(.init(updatedAt: now, events: values))
                WidgetCenter.shared.reloadTimelines(ofKind: "LAANextEvent")
            }
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            errorMessage = Self.message(for: error)
        }
    }

    private func saveLocal() {
        guard let cacheKey else { return }
        LAAGoogleCache.save(LAACalendarLocalState(calendars: calendars, selectedIDs: Array(selectedCalendarIDs), events: events, skippedCount: skippedCount), key: cacheKey)
    }

    func refresh(isPaired: Bool, now: Date = Date(), load: () async throws -> LAACalendarResponse) async {
        generation += 1
        let current = generation
        events = []; skippedCount = 0; loaded = false; errorMessage = nil
        LAACalendarSnapshot.save(nil)
        WidgetCenter.shared.reloadTimelines(ofKind: "LAANextEvent")
        guard isPaired else {
            isLoading = false
            errorMessage = Self.connectMessage
            return
        }
        isLoading = true
        defer { if current == generation { isLoading = false } }
        do {
            let response = try await load()
            let values = try response.items.map { try $0.value() }.sorted { $0.start < $1.start }
            guard current == generation, !Task.isCancelled else { return }
            events = values; loaded = true
            LAACalendarSnapshot.save(.init(updatedAt: now, events: values))
            WidgetCenter.shared.reloadTimelines(ofKind: "LAANextEvent")
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            errorMessage = Self.message(for: error)
        }
    }

    static func message(for error: Error) -> String {
        if let error = error as? LAABridgeHTTPError {
            switch error.code {
            case "calendar_not_configured": return "Googleカレンダーは未連携です。Mac側の連携設定が必要です。"
            case "calendar_auth_required": return "Googleカレンダーの認証が切れています。Mac側で再連携してください。"
            case "calendar_access_denied": return "Googleカレンダーの読取権限を確認してください。"
            case "calendar_unavailable": return "Googleカレンダーに接続できませんでした。しばらく待って再読み込みしてください。"
            case "calendar_not_found": return "予定またはカレンダーが見つかりません。再読み込みしてください。"
            case "calendar_conflict": return "別の場所で変更されています。再読み込みしてください。"
            case "calendar_too_many_events": return "予定が多いため取得できませんでした。連携先を確認してください。"
            case "calendar_invalid_response": return "Googleカレンダーの応答を読み取れませんでした。再読み込みしてください。"
            default:
                if error.status == 401 { return "Macとの接続が切れています。再接続してください。" }
                if error.status == 403 { return "この端末にはカレンダーの読取権限がありません。Mac側の設定が必要です。" }
                if error.status == 404 { return "Mac側のカレンダー連携を更新してください。" }
            }
        }
        if let error = error as? LAABridgeError, error == .unauthorized || error == .revoked {
            return "Macとの接続が切れています。再接続してください。"
        }
        return "予定を取得できませんでした。Macとネットワークの接続を確認し、再読み込みしてください。"
    }

    #if DEBUG
    init(eventsForTesting: [LAACalendarEvent]? = nil, errorForTesting: String? = nil, calendarsForTesting: [LAAGoogleCalendar] = []) {
        calendars = calendarsForTesting
        selectedCalendarIDs = Set(calendarsForTesting.map(\.id))
        events = eventsForTesting ?? []
        loaded = eventsForTesting != nil
        errorMessage = errorForTesting
    }
    #endif
}
#endif
