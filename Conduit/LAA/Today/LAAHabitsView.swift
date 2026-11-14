#if LAA_BUILD
import SwiftUI

struct LAAHabitsView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.laaDesktop) private var desktop
    @ObservedObject var model: LAAHabitsModel
    @Binding var showCreate: Bool
    @State private var editing: LAAHabit?
    @State private var showHistory = false
    let connect: () -> Void
    var automaticallyRefresh = true
    var body: some View {
        Group {
            if desktop {
                LAAMacListDetail(listWidth: 440) { ScrollView { list.padding(LAASpacing.horizontal) } } detail: {
                    ScrollView { LAAHabitsHistoryView(model: model).padding(LAASpacing.horizontal) }
                }
            } else { list }
        }
        .sheet(isPresented: $showCreate) { LAAHabitEditor(habit: nil, model: model).environmentObject(bridge).laaSheetSize(.form) }
        .sheet(item: $editing) { LAAHabitEditor(habit: $0, model: model).environmentObject(bridge).laaSheetSize(.form) }
        .sheet(isPresented: $showHistory) {
            NavigationStack { ScrollView { LAAHabitsHistoryView(model: model).padding(LAASpacing.horizontal) }.navigationTitle(Text(verbatim: "履歴"))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button { showHistory = false } label: { Text(verbatim: "閉じる") } } } }.environmentObject(bridge).laaSheetSize(.page)
        }
        .task(id: model.selectedWeek) { if automaticallyRefresh { await model.refresh(bridge) } }
        .laaMacSectionCommands(LAAMacSectionCommands(newTitle: "習慣を追加", newShortcut: "n", newModifiers: [.command, .shift], canCreate: bridge.status == .paired, create: { showCreate = true }, canReload: true, reload: { Task { await model.refresh(bridge); await model.loadHistory(bridge) } }))
    }
    private var list: some View {
        VStack(alignment: .leading, spacing: LAASpacing.section) {
            HStack(spacing: LAASpacing.x1) {
                Button { model.selectedWeek = LAAHabitDates.move(model.selectedWeek, by: -1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .accessibilityLabel(Text(verbatim: "前の週")).accessibilityIdentifier("laa.habits.previous")
                Spacer(minLength: 0)
                let end = LAAHabitDates.day(LAAHabitDates.calendar.date(byAdding: .day, value: 6, to: LAAHabitDates.date(model.selectedWeek))!)
                Text(verbatim: LAAHabitDates.range(model.selectedWeek, end)).laaTextStyle(.secondary)
                Spacer(minLength: 0)
                Button { model.selectedWeek = LAAHabitDates.move(model.selectedWeek, by: 1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .accessibilityLabel(Text(verbatim: "次の週")).accessibilityIdentifier("laa.habits.next")
            }.buttonStyle(.plain)
            if model.selectedWeek != LAAHabitDates.monday(Date()) {
                Button { model.selectedWeek = LAAHabitDates.monday(Date()) } label: { Text(verbatim: "今週") }.laaButton(.secondary)
            }
            if let error = model.error { LAAInlineFailure(reason: error) { Task { await model.refresh(bridge) } }.accessibilityIdentifier("laa.habits.error") }
            if bridge.status != .paired { Button(action: connect) { Text(verbatim: "Macに接続") }.laaButton(.secondary) }
            if model.loading && model.value == nil { LAALoadingDots() }
            if let week = model.value {
                if week.items.isEmpty { LAAEmptyState(message: "習慣はまだありません") }
                ForEach(["do", "avoid"], id: \.self) { kind in
                    let items = week.items.filter { $0.kind == kind }
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: LAASpacing.x2) {
                            LAASectionHeader(kind == "do" ? "習慣" : "禁止習慣")
                            LAAListSurface {
                                ForEach(items) { item in
                                    if item.id != items.first?.id { LAAListDivider() }
                                    LAAHabitRow(habit: item, week: week, pending: model.pending.contains(item.id), edit: { editing = item }, toggle: { index in Task { await model.toggle(item, index: index, bridge: bridge) } })
                                }
                            }
                        }
                    }
                }
            }
            if !desktop { Button { showHistory = true } label: { Text(verbatim: "履歴") }.laaButton(.secondary).accessibilityIdentifier("laa.habits.history") }
        }.foregroundStyle(LAAColor.text)
    }
}
struct LAAHabitRow: View {
    let habit: LAAHabit
    let week: LAAHabitWeek
    let pending: Bool
    let edit: () -> Void
    let toggle: (Int) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            Button(action: edit) {
                HStack { Text(verbatim: habit.title).laaTextStyle(.rowTitle); Spacer(minLength: LAASpacing.x2); Text(verbatim: habit.tally).monospacedDigit().laaTextStyle(.secondary) }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("laa.habits.edit.\(habit.id)")
            HStack(spacing: 0) {
                ForEach(Array(week.week.days.enumerated()), id: \.element) { index, day in
                    let done = habit.days?.indices.contains(index) == true && habit.days?[index] == true
                    let enabled = LAAHabitDates.canCheck(day, today: LAAHabitDates.day(Date()), createdOn: habit.createdOn)
                    Button { toggle(index) } label: {
                        VStack(spacing: LAASpacing.x1) {
                            Text(verbatim: ["月", "火", "水", "木", "金", "土", "日"][index]).laaTextStyle(.note).foregroundStyle(day == week.today ? LAAColor.text : LAAColor.secondaryText).underline(day == week.today)
                            Text(verbatim: habit.kind == "avoid" ? (done ? "■" : "□") : (done ? "●" : "○"))
                        }.laaTextStyle(.secondary).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(!enabled || pending).opacity(enabled ? 1 : 0.35)
                        .accessibilityLabel(Text(verbatim: "\(habit.title)、\(day)、\(done ? "した" : "していない")"))
                        .accessibilityIdentifier("laa.habits.check.\(habit.id).\(day)")
                }
            }
            let hints = [habit.minutes.map { "\($0)分" }, habit.minimum.map { "最小: " + $0 }].compactMap { $0 }
            if !hints.isEmpty { Text(verbatim: hints.joined(separator: " · ")).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText) }
        }.padding(LAASpacing.x3)
    }
}
struct LAAHabitsHistoryView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @ObservedObject var model: LAAHabitsModel
    var automaticallyRefresh = true
    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.section) {
            if let error = model.historyError { LAAInlineFailure(reason: error) { Task { await model.loadHistory(bridge) } } }
            LAASectionHeader("過去の週")
            ForEach(model.history) { week in
                VStack(alignment: .leading, spacing: LAASpacing.x2) {
                    Text(verbatim: LAAHabitDates.range(week.start, week.end)).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    LAAListSurface {
                        ForEach(week.items) { item in
                            if item.id != week.items.first?.id { LAAListDivider() }
                            LAAListRow {
                                HStack {
                                    Text(verbatim: item.title)
                                    Spacer(minLength: LAASpacing.x2)
                                    Text(verbatim: LAAHabit.tally(kind: item.kind, count: item.count, target: item.target)).monospacedDigit()
                                }
                            }
                        }
                    }
                }
            }
            if !model.archived.isEmpty {
                LAASectionHeader("やめた習慣")
                ForEach(model.archived) { habit in
                    HStack { Text(verbatim: habit.title); Spacer(); Button { Task { await model.restore(habit, bridge: bridge) } } label: { Text(verbatim: "戻す") }.accessibilityIdentifier("laa.habits.restore.\(habit.id)") }
                }
            }
            LAASectionHeader("変更の記録")
            ForEach(model.events) { event in
                VStack(alignment: .leading, spacing: LAASpacing.x1) {
                    Text(verbatim: LAAHabitEventText.timestamp(event.at)).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    Text(verbatim: event.title + " · " + LAAHabitEventText.content(event))
                    Text(verbatim: LAAHabitEventText.actor(event)).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                }
            }
            if model.nextCursor != nil { Button { Task { await model.loadHistory(bridge, more: true) } } label: { Text(verbatim: "さらに読む") } }
        }.laaTextStyle(.body).task { if automaticallyRefresh { await model.loadHistory(bridge) } }
    }
}

#if DEBUG
struct LAAHabitsUITestScreen: View {
    @StateObject private var bridge = LAABridgeSession(credentialsForTesting: LAABridgeCredentials(baseURL: URL(string: "http://127.0.0.1:19684")!, deviceID: "habits-ui", token: "fixture"))
    var body: some View {
        NavigationStack { LAATodayView(openBrain: {}, onRequestSettings: {}) }.environmentObject(bridge)
    }
}
#endif
#endif
