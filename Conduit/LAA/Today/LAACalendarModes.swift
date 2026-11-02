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
    var title: String { switch self { case .day: return AppLocalization.string("Day view"); case .week: return AppLocalization.string("Week view"); case .month: return AppLocalization.string("Month view"); case .list: return AppLocalization.string("Agenda view") } }
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
