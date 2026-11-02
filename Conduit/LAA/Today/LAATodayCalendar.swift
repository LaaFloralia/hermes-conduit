#if LAA_BUILD
import Combine
import Foundation
import WidgetKit

struct LAACalendarResponse: Decodable {
    struct Event: Decodable {
        let id: String
        let title: String
        let start: String
        let end: String
        let allDay: Bool
        let location: String?

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
            return LAACalendarEvent(id: id, title: title, start: first, end: last, allDay: allDay, location: location)
        }
    }
    let items: [Event]
}

@MainActor final class LAATodayCalendar: ObservableObject {
    @Published private(set) var events: [LAACalendarEvent] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var loaded = false
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
        await refresh(isPaired: bridge.status == .paired, now: now) {
            let response: LAABridgeResponse<LAACalendarResponse> = try await bridge.request(
                method: "GET", path: Self.requestPath(now: now), timeout: 20)
            return response.data
        }
    }

    func refresh(isPaired: Bool, now: Date = Date(), load: () async throws -> LAACalendarResponse) async {
        generation += 1
        let current = generation
        events = []; loaded = false; errorMessage = nil
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
            case "calendar_not_found": return "連携先のGoogleカレンダーが見つかりません。"
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
    init(eventsForTesting: [LAACalendarEvent]? = nil, errorForTesting: String? = nil) {
        events = eventsForTesting ?? []
        loaded = eventsForTesting != nil
        errorMessage = errorForTesting
    }
    #endif
}
#endif
