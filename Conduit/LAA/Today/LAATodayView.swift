#if LAA_BUILD
import SwiftUI

struct LAATodayView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var calendar: LAATodayCalendar
    @State private var showPairing = false
    private let automaticallyRefresh: Bool
    let openBrain: () -> Void
    let onRequestSettings: () -> Void

    init(openBrain: @escaping () -> Void, onRequestSettings: @escaping () -> Void) {
        self.openBrain = openBrain
        self.onRequestSettings = onRequestSettings
        self.automaticallyRefresh = true
        _calendar = StateObject(wrappedValue: LAATodayCalendar())
    }
    #if DEBUG
    init(snapshot: LAATodayCalendar) {
        openBrain = {}; onRequestSettings = {}; automaticallyRefresh = false
        _calendar = StateObject(wrappedValue: snapshot)
    }
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x6) {
                VStack(alignment: .leading, spacing: LAASpacing.x2) {
                    LAATabHeading(title: "Today", identifier: "laa.today.title")
                    Text(verbatim: "Googleカレンダー · 今日から7日間")
                        .font(.subheadline).foregroundStyle(LAAColor.secondaryText)
                }
                if calendar.isLoading {
                    ProgressView().accessibilityLabel(Text(verbatim: "予定を読み込み中"))
                } else if let message = calendar.errorMessage {
                    VStack(alignment: .leading, spacing: LAASpacing.x3) {
                        Text(verbatim: message).accessibilityIdentifier("laa.today.error")
                        if bridge.status != .paired {
                            Button { showPairing = true } label: { Text(verbatim: "Macに接続") }
                                .laaGlassButton(prominent: true)
                        } else {
                            Button { Task { await refresh() } } label: { Text(verbatim: "再読み込み") }
                                .laaGlassButton()
                        }
                    }
                } else if calendar.loaded {
                    ForEach(0..<7) { offset in day(offset) }
                }
                VStack(alignment: .leading, spacing: LAASpacing.x2) {
                    Text(verbatim: "今日のノート").fontWeight(.semibold)
                    Button(action: openBrain) { Text(verbatim: "Brainを開く") }
                        .laaGlassButton()
                    Text(verbatim: "今日のノートへの直接移動は準備中です。")
                        .foregroundStyle(LAAColor.secondaryText)
                }
            }.frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(LAASpacing.horizontal)
        }
        .background(LAAColor.background)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { LAASettingsButton(action: onRequestSettings) } }
        .sheet(isPresented: $showPairing) { LAAPairingView().environmentObject(bridge) }
        .refreshable { await refresh() }
        .task(id: bridge.revision) { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    private func refresh() async {
        guard automaticallyRefresh else { return }
        await calendar.refresh(bridge: bridge)
    }

    private func day(_ offset: Int) -> some View {
        let start = Calendar.current.startOfDay(for: Date())
        let first = Calendar.current.date(byAdding: .day, value: offset, to: start) ?? start
        let last = Calendar.current.date(byAdding: .day, value: 1, to: first) ?? first
        let events = calendar.events.filter { $0.overlaps(start: first, end: last) }
        let title = offset == 0 ? "今日" : offset == 1 ? "明日" : first.formatted(.dateTime.month().day().weekday().locale(Locale(identifier: "ja_JP")))
        return VStack(alignment: .leading, spacing: LAASpacing.x3) {
            Text(verbatim: title).fontWeight(.semibold)
            if events.isEmpty { Text(verbatim: "予定はありません").foregroundStyle(LAAColor.secondaryText) }
            ForEach(events) { event in
                VStack(alignment: .leading, spacing: LAASpacing.x1) {
                    Text(verbatim: event.allDay ? "終日" : timeRange(event, dayStart: first, dayEnd: last))
                        .font(.subheadline).foregroundStyle(LAAColor.secondaryText)
                    Text(verbatim: event.title)
                    if let location = event.location, !location.isEmpty {
                        Text(verbatim: location).font(.subheadline).foregroundStyle(LAAColor.secondaryText)
                    }
                }.accessibilityElement(children: .combine)
            }
        }
    }

    private func timeRange(_ event: LAACalendarEvent, dayStart: Date, dayEnd: Date) -> String {
        let start = event.start < dayStart ? event.start.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "ja_JP")))
            : event.start.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "ja_JP")))
        let end = event.end >= dayEnd ? event.end.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "ja_JP")))
            : event.end.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "ja_JP")))
        return "\(start)–\(end)"
    }
}
#endif
