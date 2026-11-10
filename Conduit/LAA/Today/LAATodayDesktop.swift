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
        return LAACalendarMode.agendaDays(events: calendar.events, now: calendar.selectedDate)
    }

    var body: some View {
        LAAMacListDetail(listWidth: 440) {
            VStack(spacing: 0) {
                controls
                Rectangle().fill(LAAColor.separator).frame(height: 1)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: LAASpacing.section) {
                        if calendar.isLoading && !calendar.loaded { LAALoadingDots() }
                        ForEach(days, id: \.timeIntervalSince1970) { day in daySection(day) }

                    }.padding(LAASpacing.horizontal)
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
            // An event is not the window's one new thing — ⇧⌘N keeps ⌘N free
            // for the menu's per-section new item, and ⌘R reloads from the
            // menu like every other section.
            .laaMacSectionCommands(LAAMacSectionCommands(
                newTitle: "予定を追加",
                newShortcut: "n",
                newModifiers: [.command, .shift],
                canCreate: calendar.calendars.contains(where: \.writable),
                create: { showNewEvent = true },
                canReload: true,
                reload: { Task { await calendar.refresh(bridge: bridge) } }
            ))
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
            LAAScreenHeader(title: "Today", identifier: "laa.today.title")
            Picker(selection: $calendar.mode) {
                ForEach(LAACalendarMode.visibleModes, id: \.self) { mode in
                    Text(verbatim: mode.title).tag(mode)
                }
            } label: { Text(verbatim: "表示") }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("laa.calendar.mode")

            if calendar.mode != .list {
            HStack(spacing: LAASpacing.x2) {
                Button { moveDate(-1) } label: { Image(systemName: "chevron.left") }
                    .frame(width: 44, height: 44)
                    .accessibilityLabel(Text(verbatim: "前へ"))
                    .macTooltip("前へ")
                DatePicker(selection: $calendar.selectedDate, displayedComponents: .date) {
                    Text(verbatim: "日付")
                }
                .labelsHidden()
                .frame(maxWidth: 190)
                Button { calendar.selectedDate = Date(); selectedEventID = nil } label: { Text(verbatim: "今日") }
                Button { moveDate(1) } label: { Image(systemName: "chevron.right") }
                    .frame(width: 44, height: 44)
                    .accessibilityLabel(Text(verbatim: "次へ"))
                    .macTooltip("次へ")
                Spacer(minLength: 0)
            }
            }

            if !calendar.calendars.isEmpty {
                LAASectionHeader("カレンダー") {
                    ForEach(calendar.calendars) { item in
                        Button {
                            if calendar.selectedCalendarIDs.contains(item.id) { calendar.selectedCalendarIDs.remove(item.id) }
                            else { calendar.selectedCalendarIDs.insert(item.id) }
                        } label: {
                            Label { Text(verbatim: item.title) }
                            icon: { Image(systemName: calendar.selectedCalendarIDs.contains(item.id) ? "checkmark.circle.fill" : "circle") }
                        }
                    }
                }
            }

            if let message = calendar.errorMessage {
                LAAInlineFailure(reason: message) { Task { await calendar.refresh(bridge: bridge) } }
            }
            if calendar.skippedCount > 0 {
                Text(verbatim: "読み取れない予定を\(calendar.skippedCount)件除外しました。")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
            }
        }
        .padding(LAASpacing.horizontal)
    }

    private func daySection(_ day: Date) -> some View {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        let events = calendar.events.filter { $0.overlaps(start: day, end: end) }
        return VStack(alignment: .leading, spacing: LAASpacing.x2) {
            LAASectionHeader(Calendar.current.isDateInToday(day)
                 ? "今日 · " + day.formatted(.dateTime.month().day())
                 : day.formatted(.dateTime.weekday(.wide).month().day()))
            if events.isEmpty {
                LAAEmptyState(message: "予定はありません")
            } else {
                LAAListSurface {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        if index > 0 { LAAListDivider() }
                        eventRow(event)
                    }
                }
            }
        }
    }

    private func eventRow(_ event: LAACalendarEvent) -> some View {
        Button { selectedEventID = event.id } label: {
            HStack(alignment: .top, spacing: LAASpacing.x3) {
                RoundedRectangle(cornerRadius: 2).fill(color(for: event)).frame(width: 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: event.allDay ? "終日" : event.start.formatted(date: .omitted, time: .shortened) + "–" + event.end.formatted(date: .omitted, time: .shortened))
                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    Text(verbatim: event.title).laaTextStyle(.rowTitle)
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
            .padding(.vertical, 8)
            .background(rowBackground(event.id))
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
                Button { Task { await calendar.refresh(bridge: bridge) } } label: { Text(verbatim: "再試行") }
                    .laaGlassButton(prominent: true)
            }
            .padding(LAASpacing.x8).frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LAAMacEmptyDetail(symbol: "calendar", title: LAACopy.macNoEventTitle)
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
            .laaReadableWidth(LAADesktopMetrics.readingWidth)
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
                    Text(verbatim: "\(count)件")
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
