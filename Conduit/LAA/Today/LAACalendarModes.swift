#if LAA_BUILD
import Foundation

struct LAAGoogleCalendar: Codable, Identifiable {
    let id: String; let title: String; let color: String
    let selected: Bool; let writable: Bool
}
struct LAAGoogleCalendarList: Decodable { let items: [LAAGoogleCalendar] }
struct LAACalendarLocalState: Codable {
    let calendars: [LAAGoogleCalendar]; let selectedIDs: [String]; let events: [LAACalendarEvent]
    var skippedCount: Int? = nil
}
enum LAACalendarDates {
    static func allDayRange(start: Date, end: Date, calendar: Calendar = .current) -> DateInterval {
        let first = calendar.startOfDay(for: start)
        let proposed = calendar.startOfDay(for: end)
        return DateInterval(start: first, end: proposed > first ? proposed : calendar.date(byAdding: .day, value: 1, to: first)!)
    }
}
enum LAACalendarMode: String, CaseIterable {
    case day, week, month, list
    static let visibleModes: [Self] = [.list, .week, .month]
    var title: String { switch self { case .day, .list: return AppLocalization.string("Agenda view"); case .week: return AppLocalization.string("Week view"); case .month: return AppLocalization.string("Month view") } }
    static func agendaDays(events: [LAACalendarEvent], now: Date, calendar: Calendar = .current) -> [Date] {
        let today = calendar.startOfDay(for: now)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }.filter { day in
            if day == today { return true }
            let end = calendar.date(byAdding: .day, value: 1, to: day)!
            return events.contains { $0.overlaps(start: day, end: end) }
        }
    }
    func range(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        let day = calendar.startOfDay(for: date)
        switch self {
        case .day: return DateInterval(start: day, end: calendar.date(byAdding: .day, value: 1, to: day)!)
        case .week: return calendar.dateInterval(of: .weekOfYear, for: date)!
        case .month:
            let month = calendar.dateInterval(of: .month, for: date)!
            let start = calendar.dateInterval(of: .weekOfYear, for: month.start)!.start
            return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 42, to: start)!)
        case .list: return DateInterval(start: day, end: calendar.date(byAdding: .day, value: 7, to: day)!)
        }
    }
}
#endif
