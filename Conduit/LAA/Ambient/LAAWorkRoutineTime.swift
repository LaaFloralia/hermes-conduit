#if LAA_BUILD
import Foundation

/// Next delivery time for the Mac staff panel, separate from Work navigation.
enum LAAWorkRoutineTime {
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter(); plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    /// "今日 09:00", "明日 09:00", "11/4 09:00" or "時刻未確認".
    static func next(_ text: String?, now: Date = Date()) -> String {
        guard let date = date(text) else { return "時刻未確認" }
        let calendar = Calendar.autoupdatingCurrent
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let clock = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        guard !calendar.isDate(date, inSameDayAs: now) else { return "今日 " + clock }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "明日 " + clock }
        let day = calendar.dateComponents([.month, .day], from: date)
        return "\(day.month ?? 0)/\(day.day ?? 0) " + clock
    }
}
#endif
