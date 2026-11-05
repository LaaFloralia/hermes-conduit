#if LAA_BUILD
import SwiftUI

/// Today on the Mac: a persistent agenda column on the left, the selected
/// event (or a wide month overview) on the right.
struct LAATodayDesktopView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @ObservedObject var calendar: LAATodayCalendar
    @Binding var selectedEventID: String?
    @Binding var showNewEvent: Bool
    let openBrain: () -> Void
    @State private var hoveredEventID: String?
    @FocusState private var listFocused: Bool

    private var selectedEvent: LAACalendarEvent? {
        calendar.events.first { $0.id == selectedEventID }
    }

    private var days: [Date] {
        let calendarValue = Calendar.current
        if calendar.mode == .month { return [calendarValue.startOfDay(for: calendar.selectedDate)] }
        let range = calendar.mode.range(containing: calendar.selectedDate)
        let count = calendarValue.dateComponents([.day], from: range.start, to: range.end).day ?? 1
        let all = (0..<max(1, count)).compactMap { calendarValue.date(byAdding: .day, value: $0, to: range.start) }
        guard calendar.mode == .list else { return all }
        let populated = all.filter { day in
            let end = calendarValue.date(byAdding: .day, value: 1, to: day) ?? day
            return calendar.events.contains { $0.overlaps(start: day, end: end) }
        }
        return populated.isEmpty ? [calendarValue.startOfDay(for: calendar.selectedDate)] : populated
    }

    var body: some View {
        LAAMacListDetail(listWidth: 440) {
            VStack(spacing: 0) {
                controls
                Rectangle().fill(LAAColor.separator).frame(height: 1)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if calendar.isLoading && !calendar.loaded { ProgressView().padding(LAASpacing.x4) }
                        ForEach(days, id: \.timeIntervalSince1970) { day in daySection(day) }
                        if calendar.loaded && calendar.events.isEmpty && calendar.errorMessage == nil {
                            Text(verbatim: "No events in this range.")
                                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                                .padding(LAASpacing.x4)
                        }
                        Button(action: openBrain) { Text(verbatim: "Docを開く") }
                            .laaGlassButton()
                            .padding(LAASpacing.x4)
                    }
                }
            }
            .background(LAAColor.background)
            .accessibilityIdentifier("laa.today.desktop.list")
            .focusable()
            .focused($listFocused)
            .onAppear { listFocused = true }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.escape) { selectedEventID = nil; return .handled }
            .onKeyPress(.init("n"), phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                showNewEvent = true; return .handled
            }
            .onKeyPress(.init("r"), phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                Task { await calendar.refresh(bridge: bridge) }; return .handled
            }
        } detail: {
            detail
        }
        .accessibilityIdentifier("laa.today.desktop")
        .onChange(of: calendar.events.map(\.id), initial: true) { _, ids in
            if let selectedEventID, !ids.contains(selectedEventID) { self.selectedEventID = nil }
            if selectedEventID == nil, let first = calendar.events.first { selectedEventID = first.id }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            Text(verbatim: "Today").font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("laa.today.title")
            Picker(selection: $calendar.mode) {
                ForEach(LAACalendarMode.allCases, id: \.self) { mode in
                    Text(verbatim: mode.title).tag(mode)
                }
            } label: { Text(verbatim: "表示") }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("laa.calendar.mode")

            HStack(spacing: LAASpacing.x2) {
                Button { moveDate(-1) } label: { Image(systemName: "chevron.left") }
                    .frame(width: 36, height: 36)
                    .accessibilityLabel(Text(verbatim: "Previous"))
                DatePicker(selection: $calendar.selectedDate, displayedComponents: .date) {
                    Text(verbatim: "日付")
                }
                .labelsHidden()
                .frame(maxWidth: 190)
                Button { calendar.selectedDate = Date(); selectedEventID = nil } label: { Text(verbatim: "今日") }
                Button { moveDate(1) } label: { Image(systemName: "chevron.right") }
                    .frame(width: 36, height: 36)
                    .accessibilityLabel(Text(verbatim: "Next"))
                Spacer(minLength: 0)
                Button { showNewEvent = true } label: { Image(systemName: "plus") }
                    .frame(width: 36, height: 36)
                    .accessibilityLabel(Text(verbatim: "予定を作成"))
                    .macTooltip("New event (⌘N)")
                    .disabled(!calendar.calendars.contains(where: \.writable))
            }

            HStack(spacing: LAASpacing.x2) {
                Menu {
                    ForEach(calendar.calendars) { item in
                        Button {
                            if calendar.selectedCalendarIDs.contains(item.id) { calendar.selectedCalendarIDs.remove(item.id) }
                            else { calendar.selectedCalendarIDs.insert(item.id) }
                        } label: {
                            Label { Text(verbatim: item.title) }
                            icon: { Image(systemName: calendar.selectedCalendarIDs.contains(item.id) ? "checkmark.circle.fill" : "circle") }
                        }
                    }
                } label: { Label { Text(verbatim: "Calendars") } icon: { Image(systemName: "calendar") } }
                    .macTooltip("Choose visible calendars")
                Spacer(minLength: 0)
            }

            if let message = calendar.errorMessage {
                Text(verbatim: message).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                HStack {
                    Button { Task { await calendar.refresh(bridge: bridge) } } label: { Text(verbatim: "再読み込み") }
                    if bridge.status != .paired {
                        Button { Task { await calendar.refresh(bridge: bridge) } } label: { Text(verbatim: "Macに接続") }
                    }
                }
            }
            if calendar.skippedCount > 0 {
                Text(verbatim: "読み取れない予定を\(calendar.skippedCount)件除外しました。")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
            }
        }
        .padding(LAASpacing.x3)
    }

    private func daySection(_ day: Date) -> some View {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        let events = calendar.events.filter { $0.overlaps(start: day, end: end) }
        return VStack(alignment: .leading, spacing: LAASpacing.x1) {
            Text(verbatim: Calendar.current.isDateInToday(day)
                 ? "TODAY · " + day.formatted(.dateTime.month().day())
                 : day.formatted(.dateTime.weekday(.wide).month().day()))
                .laaTextStyle(.section).fontWeight(.semibold).foregroundStyle(LAAColor.secondaryText)
                .padding(.horizontal, LAASpacing.x4).padding(.top, LAASpacing.x3)
            if events.isEmpty {
                Text(verbatim: "予定はありません").laaTextStyle(.secondary)
                    .foregroundStyle(LAAColor.secondaryText)
                    .padding(.horizontal, LAASpacing.x4).padding(.vertical, LAASpacing.x2)
            }
            ForEach(events) { event in eventRow(event) }
        }
    }

    private func eventRow(_ event: LAACalendarEvent) -> some View {
        Button { selectedEventID = event.id } label: {
            HStack(alignment: .top, spacing: LAASpacing.x3) {
                RoundedRectangle(cornerRadius: 2).fill(color(for: event)).frame(width: 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: event.allDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened) + "–" + event.end.formatted(date: .omitted, time: .shortened))
                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    Text(verbatim: event.title).laaTextStyle(.body).fontWeight(.medium)
                        .foregroundStyle(LAAColor.text).lineLimit(2)
                    if let location = event.location, !location.isEmpty {
                        Text(verbatim: location).laaTextStyle(.secondary)
                            .foregroundStyle(LAAColor.secondaryText).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, LAASpacing.x4)
            .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
            .background(rowBackground(event.id), in: RoundedRectangle(cornerRadius: LAARadius.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredEventID = $0 ? event.id : (hoveredEventID == event.id ? nil : hoveredEventID) }
        .accessibilityAddTraits(selectedEventID == event.id ? .isSelected : [])
        .accessibilityIdentifier("laa.calendar.event.\(event.googleID ?? event.id)")
    }

    @ViewBuilder private var detail: some View {
        if let selectedEvent {
            LAACalendarDetail(event: selectedEvent, calendars: calendar.calendars, changed: {
                Task { await calendar.refresh(bridge: bridge) }
            }, onClose: { selectedEventID = nil })
        } else if calendar.mode == .month {
            monthOverview
        } else if let message = calendar.errorMessage {
            VStack(spacing: LAASpacing.x3) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 36, weight: .light)).foregroundStyle(LAAColor.secondaryText)
                Text(verbatim: message).multilineTextAlignment(.center).foregroundStyle(LAAColor.text)
                Button { Task { await calendar.refresh(bridge: bridge) } } label: { Text(verbatim: "再読み込み") }
                    .buttonStyle(.borderedProminent)
            }
            .padding(LAASpacing.x8).frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LAAMacEmptyDetail(symbol: "calendar", title: "Select an event",
                              message: "Choose an event on the left to see its details and edit it here.")
        }
    }

    private var monthOverview: some View {
        let monthRange = LAACalendarMode.month.range(containing: calendar.selectedDate)
        let days = (0..<42).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: monthRange.start) }
        let month = calendar.selectedDate.formatted(.dateTime.month(.wide).year())
        return ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x4) {
                Text(verbatim: month).font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 7), spacing: 1) {
                    ForEach(Calendar.current.shortWeekdaySymbols, id: \.self) { symbol in
                        Text(verbatim: symbol).laaTextStyle(.secondary).fontWeight(.semibold)
                            .foregroundStyle(LAAColor.secondaryText)
                            .frame(maxWidth: .infinity, minHeight: 26)
                    }
                    ForEach(days, id: \.timeIntervalSince1970) { day in
                        monthCell(day, inMonth: Calendar.current.isDate(day, equalTo: calendar.selectedDate, toGranularity: .month))
                    }
                }
                .background(LAAColor.separator)
                .clipShape(RoundedRectangle(cornerRadius: LAARadius.card))
            }
            .padding(LAASpacing.x8)
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(LAAColor.surface)
    }

    private func monthCell(_ day: Date, inMonth: Bool) -> some View {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        let count = calendar.events.filter { $0.overlaps(start: day, end: end) }.count
        let selected = Calendar.current.isDate(day, inSameDayAs: calendar.selectedDate)
        let today = Calendar.current.isDateInToday(day)
        return Button {
            calendar.selectedDate = day; selectedEventID = nil
        } label: {
            VStack(alignment: .leading, spacing: LAASpacing.x1) {
                Text(verbatim: day.formatted(.dateTime.day()))
                    .font(.system(size: 15, weight: selected ? .semibold : .regular))
                    .foregroundStyle(inMonth ? LAAColor.text : LAAColor.secondaryText.opacity(0.55))
                if count > 0 {
                    Text(verbatim: "\(count) event\(count == 1 ? "" : "s")")
                        .font(.system(size: 10)).foregroundStyle(LAAColor.link).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(LAASpacing.x2)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
            .background(selected ? LAAColor.selectionFill : (today ? LAAColor.subtleSurface : LAAColor.surface))
            .overlay(alignment: .topTrailing) {
                if today { Circle().fill(LAAColor.link).frame(width: 5, height: 5).padding(LAASpacing.x2) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: day.formatted(date: .complete, time: .omitted) + " · \(count)件"))
    }

    private func rowBackground(_ id: String) -> Color {
        if selectedEventID == id { return LAAColor.selectionFill }
        if hoveredEventID == id { return LAAColor.subtleSurface }
        return .clear
    }

    private func moveDate(_ direction: Int) {
        let component: Calendar.Component = calendar.mode == .month ? .month : .day
        let step = calendar.mode == .week || calendar.mode == .list ? 7 : 1
        calendar.selectedDate = Calendar.current.date(byAdding: component, value: direction * step, to: calendar.selectedDate) ?? calendar.selectedDate
        selectedEventID = nil
    }

    private func move(_ delta: Int) {
        let ids = calendar.events.map(\.id)
        let current = selectedEventID.flatMap { ids.firstIndex(of: $0) }
        if let next = LAAWorkDesktopList.next(current: current, count: ids.count, delta: delta) {
            selectedEventID = ids[next]
        }
    }

    private func color(for event: LAACalendarEvent) -> Color {
        guard let hex = calendar.calendars.first(where: { $0.id == event.calendarId })?.color,
              let value = UInt(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else { return LAAColor.link }
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}
#endif
