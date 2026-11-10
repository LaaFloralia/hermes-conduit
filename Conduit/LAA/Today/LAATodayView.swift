#if LAA_BUILD
import SwiftUI

struct LAATodayView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.laaDesktop) private var laaDesktop
    @StateObject private var calendar: LAATodayCalendar
    @State private var showPairing = false
    @State private var showNewEvent = false
    @State private var selectedEvent: LAACalendarEvent?
    @State private var selectedEventID: String?
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
        Group {
            if laaDesktop { desktopBody } else { phoneBody }
        }
        .background(LAAColor.background)
        .environment(\.locale, LAADateText.locale)
        .toolbar {
            LAAScreenToolbar(createLabel: "予定を追加", createIdentifier: "laa.calendar.create",
                             canCreate: calendar.calendars.contains(where: \.writable),
                             create: { showNewEvent = true }, settings: onRequestSettings)
        }
        .sheet(isPresented: $showPairing) { LAAPairingView().environmentObject(bridge) }
        .sheet(isPresented: $showNewEvent) {
            LAACalendarEditor(event: nil, calendars: calendar.calendars, date: calendar.selectedDate) { Task { await refresh() } }.environmentObject(bridge)
                .laaSheetSize(.form)
        }
        .sheet(item: $selectedEvent) { event in
            LAACalendarDetail(event: event, calendars: calendar.calendars) { Task { await refresh() } }.environmentObject(bridge)
                .laaSheetSize(.page)
        }
        .task(id: "\(initialCalendarID ?? ""): dedupe:\(initialEventID ?? ""): rev:\(bridge.revision)") { await openLinkedEvent() }
        .refreshable { await refresh() }
        .task(id: "\(bridge.revision):\(calendar.mode.rawValue):\(Calendar.current.startOfDay(for: calendar.selectedDate).timeIntervalSince1970):\(calendar.selectedCalendarIDs.sorted().joined())") { await refresh() }
        .onChange(of: calendar.mode) { _, mode in
            if mode == .list { calendar.selectedDate = Date() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !calendar.updateToday() { Task { await refresh() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            calendar.updateToday()
        }
        .task(id: scenePhase) {
            guard automaticallyRefresh, scenePhase == .active else { return }
            calendar.updateToday()
            while !Task.isCancelled {
                let now = Date()
                let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
                do { try await Task.sleep(for: .seconds(max(1, midnight.timeIntervalSince(now)))) } catch { return }
                calendar.updateToday()
            }
        }
    }

    private var phoneBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.section) {
                LAATabHeading(title: "Today", identifier: "laa.today.title")
                LAASegmentedControl(values: LAACalendarMode.visibleModes, selection: $calendar.mode, title: \.title)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("laa.calendar.mode")
                if calendar.mode != .list {
                    dateNavigation
                }
                if let deepLinkError { Text(verbatim: deepLinkError).foregroundStyle(LAAColor.attention) }
                if calendar.isLoading && !calendar.loaded { LAALoadingDots() }
                if let message = calendar.errorMessage {
                    LAAInlineFailure(reason: message) { Task { await refresh() } }
                        .accessibilityIdentifier("laa.today.error")
                    if bridge.status != .paired { Button { showPairing = true } label: { Text(verbatim: "Macに接続") }.laaButton(.secondary) }
                }
                if calendar.skippedCount > 0 { Text(verbatim: "読み取れない予定を\(calendar.skippedCount)件除外しました。").font(.caption).foregroundStyle(LAAColor.attention) }
                if calendar.mode == .month { monthGrid }
                if calendar.loaded {
                    let days = displayedDays
                    ForEach(days, id: \.timeIntervalSince1970) { date in
                        day(date, showsCalendarMenu: date == days.first)
                    }
                }
            }.laaPageWidth()
                .padding(LAASpacing.horizontal)
        }
    }

    @ViewBuilder private var desktopBody: some View {
        if bridge.status != .paired {
            VStack(spacing: LAASpacing.x4) {
                Image(systemName: "desktopcomputer").font(.largeTitle).foregroundStyle(LAAColor.secondaryText)
                Text(verbatim: "Macに未接続").fontWeight(.semibold)
                Text(verbatim: "設定からMacに接続してください")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                Button { showPairing = true } label: { Text(verbatim: LAACopy.WorkTab.connect) }
                    .laaGlassButton(prominent: true)
                    .accessibilityIdentifier("work.connect")
            }
            .padding(LAASpacing.horizontal)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                LAAScreenHeader(title: "Today", identifier: "laa.today.title").padding(LAASpacing.horizontal)
            }
        } else {
            LAATodayDesktopView(calendar: calendar, selectedEventID: $selectedEventID,
                                showNewEvent: $showNewEvent, openBrain: openBrain)
                .environmentObject(bridge)
        }
    }
    private func openLinkedEvent() async {
        guard let id = initialEventID, let calendarId = initialCalendarID, bridge.status == .paired else { return }
        selectedEvent = calendar.events.first { $0.googleID == id && $0.calendarId == calendarId }
        selectedEventID = selectedEvent?.id
        do {
            let path = try LAACalendarRequest.eventPath(id: id, calendarID: calendarId)
            let response: LAABridgeResponse<LAACalendarResponse.Event> = try await bridge.request(method: "GET", path: path)
            selectedEvent = try response.data.value(); selectedEventID = selectedEvent?.id; deepLinkError = nil
        } catch { deepLinkError = LAATodayCalendar.message(for: error) }
    }
    private func refresh() async { if automaticallyRefresh { await calendar.refresh(bridge: bridge) } }
    private func move(_ direction: Int) {
        let component: Calendar.Component = calendar.mode == .month ? .month : .day
        let step = calendar.mode == .week || calendar.mode == .list ? 7 : 1
        calendar.selectedDate = Calendar.current.date(byAdding: component, value: direction * step, to: calendar.selectedDate) ?? calendar.selectedDate
    }
    private var dateNavigation: some View {
        HStack {
            Button { move(-1) } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }.accessibilityLabel(Text(verbatim: "前へ"))
            Spacer(minLength: 4)
            if calendar.mode == .month {
                Text(verbatim: LAADateText.string(calendar.selectedDate, .yearMonth))
                    .laaTextStyle(.section)
            } else {
                DatePicker(selection: $calendar.selectedDate, displayedComponents: .date) {
                    Text(verbatim: "日付")
                }.labelsHidden()
                Button { calendar.selectedDate = .now } label: { Text(verbatim: "今日") }
            }
            Spacer(minLength: 4)
            Button { move(1) } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 44)
            }.accessibilityLabel(Text(verbatim: "次へ"))
        }
        .buttonStyle(.plain)
        .foregroundStyle(LAAColor.text)
    }

    private var monthGrid: some View {
        let range = LAACalendarMode.month.range(containing: calendar.selectedDate)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: LAASpacing.x1) {
            ForEach(["日", "月", "火", "水", "木", "金", "土"], id: \.self) { weekday in
                Text(verbatim: weekday).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
            ForEach(0..<42, id: \.self) { offset in
                let date = Calendar.current.date(byAdding: .day, value: offset, to: range.start)!
                let end = Calendar.current.date(byAdding: .day, value: 1, to: date)!
                let count = calendar.events.filter { $0.overlaps(start: date, end: end) }.count
                let inMonth = Calendar.current.isDate(date, equalTo: calendar.selectedDate, toGranularity: .month)
                let selected = Calendar.current.isDate(date, inSameDayAs: calendar.selectedDate)
                let today = Calendar.current.isDateInToday(date)
                Button { calendar.selectedDate = date } label: {
                    VStack(spacing: 2) {
                        Text(verbatim: LAADateText.string(date, .dayNumber))
                            .foregroundStyle(inMonth ? LAAColor.text : LAAColor.secondaryText)
                        Circle().fill(count > 0 ? LAAColor.link : .clear).frame(width: 4, height: 4)
                    }.frame(maxWidth: .infinity, minHeight: 44)
                        .background(today ? LAAColor.selectionFill : selected ? LAAColor.subtleSurface : .clear,
                                    in: RoundedRectangle(cornerRadius: LAARadius.card))
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityLabel(Text(verbatim: LAADateText.string(date, .day) + " · \(count)件"))
            }
        }
    }
    private var displayedDays: [Date] {
        if calendar.mode == .list { return LAACalendarMode.agendaDays(events: calendar.events, now: calendar.selectedDate) }
        if calendar.mode == .month { return [Calendar.current.startOfDay(for: calendar.selectedDate)] }
        let range = calendar.mode.range(containing: calendar.selectedDate)
        return (0..<(Calendar.current.dateComponents([.day], from: range.start, to: range.end).day ?? 1))
            .compactMap { Calendar.current.date(byAdding: .day, value: $0, to: range.start) }
    }
    private func day(_ first: Date, showsCalendarMenu: Bool) -> some View {
        let last = Calendar.current.date(byAdding: .day, value: 1, to: first)!
        let events = calendar.events.filter { $0.overlaps(start: first, end: last) }
        return LAATodayDaySection(date: first, events: events, select: { selectedEvent = $0 }) {
            if showsCalendarMenu && !calendar.calendars.isEmpty {
                Menu {
                    ForEach(calendar.calendars) { item in
                        Button {
                            if calendar.selectedCalendarIDs.contains(item.id) { calendar.selectedCalendarIDs.remove(item.id) }
                            else { calendar.selectedCalendarIDs.insert(item.id) }
                        } label: {
                            Label { Text(verbatim: item.title) } icon: {
                                Image(systemName: calendar.selectedCalendarIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text(verbatim: "表示するカレンダー"))
            }
        }
    }
}

private struct LAATodayDaySection<MenuContent: View>: View {
    let date: Date
    let events: [LAACalendarEvent]
    let select: (LAACalendarEvent) -> Void
    @ViewBuilder let menu: MenuContent
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                let day = LAADateText.string(date, .day)
                LAASectionHeader(Calendar.current.isDateInToday(date) ? "今日 · " + day : day)
                menu
            }
            if events.isEmpty { LAAEmptyState(message: "予定はありません") }
            else {
                LAAListSurface {
                    ForEach(events) { event in
                        if event.id != events.first?.id { LAAListDivider() }
                        LAAListRow(action: { select(event) }) {
                            HStack(alignment: .top, spacing: 12) {
                                Text(verbatim: event.allDay ? "終日" : LAADateText.string(event.start, .time))
                                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText).frame(minWidth: 48, alignment: .leading)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(verbatim: event.title).laaTextStyle(.rowTitle)
                                    if let location = event.location, !location.isEmpty {
                                        Text(verbatim: location).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                        }.accessibilityIdentifier("laa.calendar.event.\(event.googleID ?? event.id)")
                    }
                }
            }
        }
    }
}
#endif
