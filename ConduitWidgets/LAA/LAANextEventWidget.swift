#if LAA_BUILD
import EventKit
import SwiftUI
import WidgetKit

struct LAANextEventEntry: TimelineEntry {
    let date: Date
    let event: LAACalendarEvent?
}
struct LAANextEventProvider: TimelineProvider {
    func placeholder(in context: Context) -> LAANextEventEntry { .init(date: Date(), event: nil) }
    func getSnapshot(in context: Context, completion: @escaping (LAANextEventEntry) -> Void) { completion(entry(at: Date())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LAANextEventEntry>) -> Void) {
        let now = Date()
        let events = authorizedEvents().filter { $0.end > now }.sorted { $0.start < $1.start }
        let dates = [now] + Array(Set(events.map(\.end).filter { $0 > now })).sorted()
        let entries = dates.map { date in LAANextEventEntry(date: date, event: events.first { $0.end > date }) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(3600))))
    }
    private func authorizedEvents() -> [LAACalendarEvent] {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess ? LAACalendarSnapshot.read() : []
    }
    private func entry(at date: Date) -> LAANextEventEntry {
        .init(date: date, event: authorizedEvents().filter { $0.end > date }.min { $0.start < $1.start })
    }
}
struct LAANextEventWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LAANextEvent", provider: LAANextEventProvider()) { entry in
            VStack(alignment: .leading, spacing: 8) {
                Text("Next event").font(.caption).foregroundStyle(.secondary)
                if let event = entry.event {
                    Text(event.allDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened)).font(.headline)
                    Text(verbatim: event.title).font(.body).lineLimit(3)
                } else { Text("予定はありません").font(.body) }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .containerBackground(.background, for: .widget)
        }.configurationDisplayName("Next event").description("Your next calendar event.").supportedFamilies([.systemSmall])
    }
}
#endif
