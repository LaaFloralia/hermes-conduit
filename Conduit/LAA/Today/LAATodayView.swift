#if LAA_BUILD
import SwiftUI

struct LAATodayView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var calendar: LAATodayCalendar
    @State private var showPairing = false
    @State private var showNewEvent = false
    @State private var selectedEvent: LAACalendarEvent?
    private let initialEventID: String?
    private let initialCalendarID: String?
    @State private var deepLinkError: String?
    private let automaticallyRefresh: Bool
    let openBrain: () -> Void
    let onRequestSettings: () -> Void

    init(openBrain: @escaping () -> Void, onRequestSettings: @escaping () -> Void, initialEventID: String? = nil, initialCalendarID: String? = nil) {
        self.openBrain = openBrain; self.onRequestSettings = onRequestSettings; automaticallyRefresh = true
        self.initialEventID = initialEventID; self.initialCalendarID = initialCalendarID
        _calendar = StateObject(wrappedValue: LAATodayCalendar())
    }
    #if DEBUG
    init(snapshot: LAATodayCalendar) {
        openBrain = {}; onRequestSettings = {}; automaticallyRefresh = false
        initialEventID = nil; initialCalendarID = nil
        _calendar = StateObject(wrappedValue: snapshot)
    }
    #endif
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x4) {
                LAATabHeading(title: "Today", identifier: "laa.today.title")
                Picker(selection: $calendar.mode) {
                    ForEach(LAACalendarMode.allCases, id: \.self) { mode in Text(verbatim: mode.title).tag(mode) }
                } label: { Text(verbatim: "表示") }
                .pickerStyle(.segmented).accessibilityIdentifier("laa.calendar.mode")
                HStack {
                    Button { move(-1) } label: { Image(systemName: "chevron.left") }.frame(minWidth: 44, minHeight: 44)
                    DatePicker(selection: $calendar.selectedDate, displayedComponents: .date) { Text(verbatim: "日付") }.labelsHidden()
                    Button { calendar.selectedDate = Date() } label: { Text(verbatim: "今日") }
                    Button { move(1) } label: { Image(systemName: "chevron.right") }.frame(minWidth: 44, minHeight: 44)
                }
                if !calendar.calendars.isEmpty {
                    Menu {
                        ForEach(calendar.calendars) { item in
                            Button {
                                if calendar.selectedCalendarIDs.contains(item.id) { calendar.selectedCalendarIDs.remove(item.id) }
                                else { calendar.selectedCalendarIDs.insert(item.id) }
                            } label: {
                                Label { Text(verbatim: item.title) } icon: { Image(systemName: calendar.selectedCalendarIDs.contains(item.id) ? "checkmark.circle.fill" : "circle") }
                            }
                        }
                    } label: { Label { Text(verbatim: "カレンダーの表示") } icon: { Image(systemName: "calendar") } }
                }
                if let deepLinkError { Text(verbatim: deepLinkError).foregroundStyle(LAAColor.attention) }
                if calendar.isLoading { ProgressView().accessibilityLabel(Text(verbatim: "予定を読み込み中")) }
                if let message = calendar.errorMessage {
                    Text(verbatim: message).foregroundStyle(LAAColor.attention).accessibilityIdentifier("laa.today.error")
                    if calendar.loaded { Text(verbatim: "保存済みの予定です。最新の変更は未確認です。").font(.caption) }
                    Button { Task { await refresh() } } label: { Text(verbatim: "再読み込み") }.laaGlassButton()
                    if bridge.status != .paired { Button { showPairing = true } label: { Text(verbatim: "Macに接続") }.laaGlassButton() }
                }
                if calendar.skippedCount > 0 { Text(verbatim: "読み取れない予定を\(calendar.skippedCount)件除外しました。").font(.caption).foregroundStyle(LAAColor.attention) }
                if calendar.mode == .month { monthGrid }
                if calendar.loaded {
                    let range = calendar.mode == .month ? LAACalendarMode.day.range(containing: calendar.selectedDate) : calendar.mode.range(containing: calendar.selectedDate)
                    let days = Calendar.current.dateComponents([.day], from: range.start, to: range.end).day ?? 1
                    ForEach(0..<days, id: \.self) { offset in
                        day(Calendar.current.date(byAdding: .day, value: offset, to: range.start)!)
                    }
                }
                Button(action: openBrain) { Text(verbatim: "Brainを開く") }.laaGlassButton()
            }.frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                .padding(LAASpacing.horizontal)
        }
        .background(LAAColor.background)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showNewEvent = true } label: { Image(systemName: "plus") }
                    .disabled(!calendar.calendars.contains(where: \.writable))
                    .accessibilityLabel(Text(verbatim: "予定を作成"))
                    .accessibilityIdentifier("laa.calendar.create")
            }
            ToolbarItem(placement: .topBarTrailing) { LAASettingsButton(action: onRequestSettings) }
        }
        .sheet(isPresented: $showPairing) { LAAPairingView().environmentObject(bridge) }
        .sheet(isPresented: $showNewEvent) {
            LAACalendarEditor(event: nil, calendars: calendar.calendars, date: calendar.selectedDate) { Task { await refresh() } }.environmentObject(bridge)
        }
        .sheet(item: $selectedEvent) { event in
            LAACalendarDetail(event: event, calendars: calendar.calendars) { Task { await refresh() } }.environmentObject(bridge)
        }
        .task(id: "\(initialCalendarID ?? ""): dedupe:\(initialEventID ?? ""): rev:\(bridge.revision)") { await openLinkedEvent() }
        .refreshable { await refresh() }
        .task(id: bridge.revision) { await refresh() }
        .task(id: "\(calendar.mode.rawValue):\(Calendar.current.startOfDay(for: calendar.selectedDate).timeIntervalSince1970):\(calendar.selectedCalendarIDs.sorted().joined())") { await refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await refresh() } } }
    }
    private func openLinkedEvent() async {
        guard let id = initialEventID, let calendarId = initialCalendarID, bridge.status == .paired else { return }
        selectedEvent = calendar.events.first { $0.googleID == id && $0.calendarId == calendarId }
        do {
            let path = try LAACalendarRequest.eventPath(id: id, calendarID: calendarId)
            let response: LAABridgeResponse<LAACalendarResponse.Event> = try await bridge.request(method: "GET", path: path)
            selectedEvent = try response.data.value(); deepLinkError = nil
        } catch { deepLinkError = LAATodayCalendar.message(for: error) }
    }
    private func refresh() async { if automaticallyRefresh { await calendar.refresh(bridge: bridge) } }
    private func move(_ direction: Int) {
        let component: Calendar.Component = calendar.mode == .month ? .month : .day
        let step = calendar.mode == .week || calendar.mode == .list ? 7 : 1
        calendar.selectedDate = Calendar.current.date(byAdding: component, value: direction * step, to: calendar.selectedDate) ?? calendar.selectedDate
    }
    private var monthGrid: some View {
        let range = LAACalendarMode.month.range(containing: calendar.selectedDate)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: LAASpacing.x1) {
            ForEach(0..<42, id: \.self) { offset in
                let date = Calendar.current.date(byAdding: .day, value: offset, to: range.start)!
                let end = Calendar.current.date(byAdding: .day, value: 1, to: date)!
                let count = calendar.events.filter { $0.overlaps(start: date, end: end) }.count
                Button { calendar.selectedDate = date } label: {
                    VStack(spacing: 2) {
                        Text(verbatim: date.formatted(.dateTime.day()))
                        Circle().fill(count > 0 ? LAAColor.link : .clear).frame(width: 4, height: 4)
                    }.frame(maxWidth: .infinity, minHeight: 44)
                        .background(Calendar.current.isDate(date, inSameDayAs: calendar.selectedDate) ? LAAColor.subtleSurface : .clear, in: RoundedRectangle(cornerRadius: LAARadius.card))
                }.accessibilityLabel(Text(verbatim: date.formatted(date: .complete, time: .omitted) + " · \(count)件"))
            }
        }
    }
    private func day(_ first: Date) -> some View {
        let last = Calendar.current.date(byAdding: .day, value: 1, to: first)!
        let events = calendar.events.filter { $0.overlaps(start: first, end: last) }
        return VStack(alignment: .leading, spacing: LAASpacing.x3) {
            Text(verbatim: Calendar.current.isDateInToday(first) ? "今日" : first.formatted(.dateTime.month().day().weekday())).fontWeight(.semibold)
            if events.isEmpty { Text(verbatim: "予定はありません").foregroundStyle(LAAColor.secondaryText) }
            ForEach(events) { event in
                Button { selectedEvent = event } label: {
                    HStack(alignment: .top, spacing: LAASpacing.x3) {
                        RoundedRectangle(cornerRadius: 2).fill(color(for: event)).frame(width: 4)
                        VStack(alignment: .leading, spacing: LAASpacing.x1) {
                            Text(verbatim: event.allDay ? "終日" : event.start.formatted(date: .omitted, time: .shortened) + "–" + event.end.formatted(date: .omitted, time: .shortened))
                                .font(.subheadline).foregroundStyle(LAAColor.secondaryText)
                            Text(verbatim: event.title).foregroundStyle(LAAColor.text)
                            if let location = event.location, !location.isEmpty { Text(verbatim: location).font(.caption).foregroundStyle(LAAColor.secondaryText) }
                        }
                        Spacer(minLength: 0)
                    }.padding(LAASpacing.x3).background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
                }.buttonStyle(.plain).accessibilityIdentifier("laa.calendar.event.\(event.googleID ?? event.id)")
            }
        }
    }
    private func color(for event: LAACalendarEvent) -> Color {
        guard let hex = calendar.calendars.first(where: { $0.id == event.calendarId })?.color,
              let value = UInt(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else { return LAAColor.link }
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}
#endif
