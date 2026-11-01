#if LAA_BUILD
import Combine
import EventKit
import Foundation
import WidgetKit

struct LAACalendarEvent: Codable, Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let location: String?

    func overlaps(start: Date, end: Date) -> Bool { self.start < end && self.end > start }
}

enum LAACalendarSnapshot {
    static let key = "laa.calendar.events.v1"
    static var defaults: UserDefaults? { UserDefaults(suiteName: WidgetSnapshotStore.appGroup) }
    static func read() -> [LAACalendarEvent] {
        guard let data = defaults?.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([LAACalendarEvent].self, from: data)) ?? []
    }
    static func write(_ events: [LAACalendarEvent]) {
        if let data = try? JSONEncoder().encode(events) { defaults?.set(data, forKey: key) }
        WidgetCenter.shared.reloadTimelines(ofKind: "LAANextEvent")
    }
}

@MainActor final class LAATodayCalendar: ObservableObject {
    @Published var events: [LAACalendarEvent] = []
    @Published var status = EKEventStore.authorizationStatus(for: .event)
    private let store = EKEventStore()

    func request() async {
        do { _ = try await store.requestFullAccessToEvents() } catch { }
        refresh()
    }
    func refresh(now: Date = Date()) {
        status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess else { events = []; LAACalendarSnapshot.write([]); return }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 30, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate).map {
            LAACalendarEvent(id: ($0.eventIdentifier ?? UUID().uuidString) + "-" + String($0.startDate.timeIntervalSince1970), title: $0.title ?? "Untitled", start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay, location: $0.location)
        }.sorted { $0.start < $1.start }
        LAACalendarSnapshot.write(events)
    }
}
#endif
