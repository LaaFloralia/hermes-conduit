#if LAA_BUILD
import SwiftUI
import WidgetKit

struct LAANextEventEntry: TimelineEntry {
    let date: Date
    let event: LAACalendarEvent?
    let authorized: Bool
}
struct LAANextEventProvider: TimelineProvider {
    func placeholder(in context: Context) -> LAANextEventEntry { .init(date: Date(), event: nil, authorized: true) }
    func getSnapshot(in context: Context, completion: @escaping (LAANextEventEntry) -> Void) { completion(entry(at: Date())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LAANextEventEntry>) -> Void) {
        let now = Date()
        let snapshot = LAACalendarSnapshot.read()
        let events = snapshot?.events ?? []
        let expiration = snapshot?.updatedAt.addingTimeInterval(3600) ?? now.addingTimeInterval(3600)
        let dates = Array(Set([now, max(now, expiration)] + events.map(\.end).filter { $0 > now && $0 < expiration })).sorted()
        let entries = dates.map { date in Self.entry(at: date, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(3600))))
    }
    private func entry(at date: Date) -> LAANextEventEntry { Self.entry(at: date, snapshot: LAACalendarSnapshot.read()) }
    private static func entry(at date: Date, snapshot: LAACalendarSnapshot?) -> LAANextEventEntry {
        let fresh = snapshot?.isFresh(at: date) == true
        let event = fresh ? snapshot?.events.filter { $0.end > date }.min { $0.start < $1.start } : nil
        return .init(date: date, event: event, authorized: fresh)
    }
}
struct LAANextEventWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LAANextEvent", provider: LAANextEventProvider()) { entry in
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "次の予定").font(.caption).foregroundStyle(.secondary)
                if let event = entry.event {
                    Text(verbatim: event.allDay ? "終日" : event.start.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "ja_JP")))).font(.headline)
                    Text(verbatim: event.title).font(.body).lineLimit(3)
                } else if entry.authorized { Text(verbatim: "予定はありません").font(.body) }
                else { Text(verbatim: "Todayを開いて予定を更新してください").font(.body) }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .containerBackground(.background, for: .widget)
        }.configurationDisplayName("Next event").description("Your next calendar event.").supportedFamilies([.systemSmall])
    }
}
#endif
