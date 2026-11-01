#if LAA_BUILD
import SwiftUI
import EventKit

struct LAATodayView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var calendar = LAATodayCalendar()
    let openTasks: () -> Void
    let openBrain: () -> Void
    let onRequestSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x6) {
                Text(verbatim: "Today").font(LAAType.screenTitle).accessibilityIdentifier("laa.today.title")
                if calendar.status == .notDetermined {
                    Button { Task { await calendar.request() } } label: { Text(verbatim: "Allow calendar access") }
                    Text(verbatim: "iPhoneのカレンダーに同期された予定を表示します。")
                } else if calendar.status != .fullAccess {
                    Text(verbatim: "予定を表示するには、設定でカレンダーへのフルアクセスを許可してください。")
                } else {
                    day(0, title: "Today")
                    day(1, title: "Tomorrow")
                }
                VStack(alignment: .leading, spacing: LAASpacing.x2) {
                    Text(verbatim: "Tasks").fontWeight(.semibold)
                    Button(action: openTasks) { Text(verbatim: "Open tasks") }
                }
                VStack(alignment: .leading, spacing: LAASpacing.x2) {
                    Text(verbatim: "Daily note").fontWeight(.semibold)
                    Button(action: openBrain) { Text(verbatim: "Open Brain") }
                    Text(verbatim: "今日のノートへの直接移動は準備中です。")
                        .foregroundStyle(LAAColor.secondaryText)
                }
            }.frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(LAASpacing.horizontal)
        }
        .background(LAAColor.background)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { LAASettingsButton(action: onRequestSettings) } }
        .task {
            if calendar.status == .notDetermined { await calendar.request() } else { calendar.refresh() }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { calendar.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in calendar.refresh() }
    }

    private func day(_ offset: Int, title: String) -> some View {
        let start = Calendar.current.startOfDay(for: Date())
        let first = Calendar.current.date(byAdding: .day, value: offset, to: start) ?? start
        let last = Calendar.current.date(byAdding: .day, value: 1, to: first) ?? first
        let events = calendar.events.filter { $0.overlaps(start: first, end: last) }
        return VStack(alignment: .leading, spacing: LAASpacing.x2) {
            Text(verbatim: title).fontWeight(.semibold)
            if events.isEmpty { Text(verbatim: "予定はありません").foregroundStyle(LAAColor.secondaryText) }
            ForEach(events) { event in
                VStack(alignment: .leading) {
                    Text(verbatim: event.allDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened)).foregroundStyle(LAAColor.secondaryText)
                    Text(verbatim: event.title)
                    if let location = event.location, !location.isEmpty { Text(verbatim: location).foregroundStyle(LAAColor.secondaryText) }
                }.accessibilityElement(children: .combine)
            }
        }
    }
}
#endif
