#if LAA_BUILD
import SwiftUI

struct LAACalendarEditor: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.dismiss) private var dismiss
    let event: LAACalendarEvent?
    let calendars: [LAAGoogleCalendar]
    let saved: () -> Void
    @State private var title: String
    @State private var calendarId: String
    @State private var start: Date
    @State private var end: Date
    @State private var allDay: Bool
    @State private var location: String
    @State private var notes: String
    @State private var attendees: String
    @State private var recurrence: String
    @State private var reminder: Int = -1
    @State private var busy = false
    @State private var uncertain = false
    @State private var message: String?
    @State private var confirmSave = false
    @State private var key = LAABridgeIdempotencyKey()
    init(event: LAACalendarEvent?, calendars: [LAAGoogleCalendar], date: Date, saved: @escaping () -> Void) {
        self.event = event; self.calendars = calendars; self.saved = saved
        _title = State(initialValue: event?.title ?? "")
        _calendarId = State(initialValue: event?.calendarId ?? calendars.first(where: \.writable)?.id ?? "primary")
        _start = State(initialValue: event?.start ?? date)
        _end = State(initialValue: event?.end ?? date.addingTimeInterval(3600))
        _allDay = State(initialValue: event?.allDay ?? false)
        _location = State(initialValue: event?.location ?? "")
        _notes = State(initialValue: event?.notes ?? "")
        _attendees = State(initialValue: event?.attendees?.map(\.email).joined(separator: ", ") ?? "")
        _recurrence = State(initialValue: event?.recurrence?.joined(separator: "\n") ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(text: $title) { Text(verbatim: "タイトル") }
                    Picker(selection: $calendarId) {
                        ForEach(calendars.filter(\.writable)) { item in Text(verbatim: item.title).tag(item.id) }
                    } label: { Text(verbatim: "カレンダー") }.disabled(event != nil)
                    Toggle(isOn: $allDay) { Text(verbatim: "終日") }
                    DatePicker(selection: $start, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute]) { Text(verbatim: "開始") }
                    DatePicker(selection: $end, in: start..., displayedComponents: allDay ? [.date] : [.date, .hourAndMinute]) { Text(verbatim: allDay ? "終了（この日は含まない）" : "終了") }
                    TextField(text: $location) { Text(verbatim: "場所") }
                    TextField(text: $attendees, axis: .vertical) { Text(verbatim: "参加者のメール（カンマ区切り）") }
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField(text: $notes, axis: .vertical) { Text(verbatim: "メモ") }.lineLimit(4...12)
                }
                if event?.recurringEventId == nil {
                    Section {
                        Menu {
                            Button { recurrence = "" } label: { Text(verbatim: "繰り返さない") }
                            Button { recurrence = "RRULE:FREQ=DAILY" } label: { Text(verbatim: "毎日") }
                            Button { recurrence = "RRULE:FREQ=WEEKLY" } label: { Text(verbatim: "毎週") }
                            Button { recurrence = "RRULE:FREQ=MONTHLY" } label: { Text(verbatim: "毎月") }
                            Button { recurrence = "RRULE:FREQ=YEARLY" } label: { Text(verbatim: "毎年") }
                        } label: { Text(verbatim: "繰り返しを選択") }
                        TextField(text: $recurrence, axis: .vertical) { Text(verbatim: "繰り返しルール（RRULE）") }
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    } header: { Text(verbatim: "繰り返し") } footer: { Text(verbatim: "必要ならCOUNTやUNTILで終了条件を指定できます。") }
                }
                Picker(selection: $reminder) {
                    Text(verbatim: "Googleの既定").tag(-1)
                    Text(verbatim: "開始時刻").tag(0)
                    Text(verbatim: "10分前").tag(10)
                    Text(verbatim: "30分前").tag(30)
                    Text(verbatim: "1日前").tag(1440)
                } label: { Text(verbatim: "通知") }
                if let message { Text(verbatim: message).foregroundStyle(LAAColor.attention) }
                if busy { ProgressView() }
            }
            .navigationTitle(Text(verbatim: event == nil ? "予定を作成" : "予定を編集"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Text(verbatim: "キャンセル") }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { confirmSave = true } label: { Text(verbatim: "保存") }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || end <= start || busy || uncertain)
                }
            }
            .confirmationDialog(Text(verbatim: "Googleカレンダーに保存しますか？"), isPresented: $confirmSave, titleVisibility: .visible) {
                Button { Task { await save() } } label: { Text(verbatim: "保存") }
            } message: { Text(verbatim: "参加者がいる場合は、Googleから予定の通知が送られます。") }
        }.interactiveDismissDisabled(busy)
            .onChange(of: allDay) { _, value in
                if value {
                    let range = LAACalendarDates.allDayRange(start: start, end: end)
                    start = range.start; end = range.end
                }
            }
            .onChange(of: start) { _, value in
                if allDay && end <= value { end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: value))! }
            }
    }
    private func save() async {
        busy = true; defer { busy = false }
        do {
            let iso = ISO8601DateFormatter()
            let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
            var body: [String: Any] = ["calendarId": calendarId, "title": title, "allDay": allDay,
                "start": allDay ? formatter.string(from: start) : iso.string(from: start), "end": allDay ? formatter.string(from: end) : iso.string(from: end),
                "timeZone": event?.timeZone ?? TimeZone.current.identifier, "location": location, "description": notes,
                "attendees": attendees.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" }).map { ["email": $0.trimmingCharacters(in: .whitespacesAndNewlines)] }]
            if event?.recurringEventId == nil { body["recurrence"] = recurrence.split(separator: "\n").map(String.init) }
            // Existing reminders stay unchanged until the user changes this control.
            if event == nil || reminder != -1 { body["reminderMinutes"] = reminder < 0 ? NSNull() : reminder as Any }
            if let etag = event?.etag { body["etag"] = etag }
            let path = "/v1/calendar/events" + (event?.googleID.map { "/" + $0 } ?? "")
            let _: LAABridgeResponse<LAACalendarResponse.Event> = try await bridge.request(method: event == nil ? "POST" : "PATCH", path: path,
                jsonBody: JSONSerialization.data(withJSONObject: body), idempotencyKey: key)
            saved(); dismiss()
        } catch {
            if let http = error as? LAABridgeHTTPError, http.status < 500 {
                key = LAABridgeIdempotencyKey()
                message = http.code == "calendar_conflict" ? "別の場所で変更されています。閉じて再読み込みしてください。" : "保存できませんでした。入力と権限を確認してください。"
            } else {
                uncertain = true
                message = "保存結果を確認できません。重複を避けるため、閉じて予定を再読み込みしてください。"
            }
        }
    }
}
#endif
