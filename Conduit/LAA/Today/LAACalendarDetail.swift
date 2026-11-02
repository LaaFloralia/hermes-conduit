#if LAA_BUILD
import SwiftUI

struct LAACalendarDetail: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.dismiss) private var dismiss
    let event: LAACalendarEvent
    let calendars: [LAAGoogleCalendar]
    let changed: () -> Void
    var onClose: (() -> Void)? = nil
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var busy = false
    @State private var message: String?
    @State private var series: LAACalendarEvent?
    private var writable: Bool { calendars.first(where: { $0.id == event.calendarId })?.writable == true && event.etag != nil && event.googleID != nil }
    var body: some View {
        NavigationStack {
            List {
                Text(verbatim: event.title).font(.title2).textSelection(.enabled)
                    .accessibilityIdentifier("laa.calendar.detail.title")
                Text(verbatim: event.start.formatted(date: .abbreviated, time: event.allDay ? .omitted : .shortened) + " – " + event.end.formatted(date: .abbreviated, time: event.allDay ? .omitted : .shortened))
                if let location = event.location, !location.isEmpty {
                    Text(verbatim: location).textSelection(.enabled)
                    if let url = URL(string: "https://maps.apple.com/?q=" + (location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")) {
                        Link(destination: url) { Text(verbatim: "地図を開く") }
                    }
                }
                if let link = event.meetingLink, let url = safeURL(link) { Link(destination: url) { Text(verbatim: "会議に参加") } }
                if let notes = event.notes, !notes.isEmpty { Text(verbatim: notes).textSelection(.enabled) }
                ForEach(Array((event.attendees ?? []).enumerated()), id: \.offset) { _, attendee in
                    VStack(alignment: .leading) { Text(verbatim: attendee.name ?? attendee.email); Text(verbatim: attendee.email + " · " + (attendee.response ?? "")).font(.caption) }
                }
                ForEach(Array((event.attachments ?? []).enumerated()), id: \.offset) { _, attachment in
                    if let url = safeURL(attachment.url) { Link(destination: url) { Text(verbatim: attachment.title) } }
                }
                if writable {
                    if event.recurringEventId != nil {
                        Text(verbatim: "編集・削除はこの回だけに適用します。全体を変えるには繰り返し全体を開いてください。").font(.caption)
                        Button { Task { await openSeries() } } label: { Text(verbatim: "繰り返し全体を開く") }.disabled(busy)
                    }
                    Button { editing = true } label: { Text(verbatim: "編集") }.disabled(busy)
                    Button(role: .destructive) { confirmDelete = true } label: { Text(verbatim: "削除") }.disabled(busy)
                }
                if let message { Text(verbatim: message).foregroundStyle(LAAColor.attention) }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(LAAColor.surface)
            .toolbar {
                if onClose == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: { Text(verbatim: "閉じる") }
                    }
                }
            }
            .sheet(isPresented: $editing) {
                LAACalendarEditor(event: event, calendars: calendars, date: event.start) {
                    changed()
                    if onClose == nil { dismiss() }
                }.environmentObject(bridge)
            }
            .sheet(item: $series) { value in LAACalendarDetail(event: value, calendars: calendars) { changed(); dismiss() }.environmentObject(bridge) }
            .confirmationDialog(Text(verbatim: event.recurrence?.isEmpty == false ? "繰り返し全体を削除しますか？" : "この予定を削除しますか？"), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(role: .destructive) { Task { await remove() } } label: { Text(verbatim: "削除") }
            } message: { Text(verbatim: "参加者がいる場合は、Googleから取消通知が送られます。") }
        }
    }
    private func safeURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", url.user == nil, url.password == nil else { return nil }; return url
    }
    private func openSeries() async {
        guard let id = event.recurringEventId, let calendarId = event.calendarId else { return }
        busy = true; defer { busy = false }
        do {
            let path = try LAACalendarRequest.eventPath(id: id, calendarID: calendarId)
            let response: LAABridgeResponse<LAACalendarResponse.Event> = try await bridge.request(method: "GET", path: path)
            series = try response.data.value()
        } catch { message = LAATodayCalendar.message(for: error) }
    }
    private func remove() async {
        guard let id = event.googleID, let calendarId = event.calendarId, let etag = event.etag else { return }
        busy = true; defer { busy = false }
        do {
            struct Result: Decodable { let deleted: Bool }
            let body = try JSONSerialization.data(withJSONObject: ["calendarId": calendarId, "etag": etag])
            let _: LAABridgeResponse<Result> = try await bridge.request(method: "DELETE", path: try LAACalendarRequest.eventPath(id: id), jsonBody: body, idempotencyKey: LAABridgeIdempotencyKey())
            changed()
            if let onClose { onClose() } else { dismiss() }
        } catch { message = LAATodayCalendar.message(for: error) }
    }
}
#endif
