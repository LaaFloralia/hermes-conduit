#if LAA_BUILD
import SwiftUI

struct LAAWorkSkill: Codable, Identifiable {
    let id: String
    let name: String
    let description: String
    let source: String
    let category: String?
    let summary: String?
    let detail: String?
    /// The short number the owner says ("K3"). Absent from an older Bridge.
    let ref: String?

    var group: String { category ?? "その他" }
    var explanation: String { summary ?? description }
}

/// One chat the routines deliver to. The owner asks what arrives where and at
/// what time, so the list is grouped by destination and each row names its
/// next delivery.
struct LAAWorkRoutineGroup: Identifiable {
    let destination: String
    let routines: [LAAWorkRoutine]
    var id: String { destination }
}

enum LAAWorkRoutineGrouping {
    /// Scheduled routines by destination: earliest next delivery first, a
    /// routine without a destination last so it is still visible.
    static func groups(_ routines: [LAAWorkRoutine], now: Date = Date()) -> [LAAWorkRoutineGroup] {
        let byDestination = Dictionary(grouping: routines) { $0.destination ?? "配信先なし" }
        return byDestination.map { LAAWorkRoutineGroup(destination: $0.key, routines: $0.value.sorted { left, right in
            let l = LAAWorkRoutineTime.date(left.nextRunAt) ?? .distantFuture
            let r = LAAWorkRoutineTime.date(right.nextRunAt) ?? .distantFuture
            return l == r ? left.name < right.name : l < r
        }) }.sorted { left, right in
            if (left.destination == "配信先なし") != (right.destination == "配信先なし") { return right.destination == "配信先なし" }
            let l = left.routines.compactMap { LAAWorkRoutineTime.date($0.nextRunAt) }.min() ?? .distantFuture
            let r = right.routines.compactMap { LAAWorkRoutineTime.date($0.nextRunAt) }.min() ?? .distantFuture
            return l == r ? left.destination < right.destination : l < r
        }
    }
}

/// What the routines list says when a read did not produce a list. The Bridge
/// answers 503 while its first `laa-console jobs` run is still going, which is
/// not the same as a broken connection or an empty schedule.
enum LAAWorkCatalogFailure: Equatable {
    case warming
    case stale
    case unavailable

    static func classify(loaded: Bool, error: Error) -> LAAWorkCatalogFailure {
        if loaded { return .stale }
        if let http = error as? LAABridgeHTTPError, http.status == 503, http.code == "routines_unavailable" {
            return .warming
        }
        return .unavailable
    }

    var japaneseText: String {
        switch self {
        case .warming: return "定期実行の一覧を準備しています。少し待つと表示されます。"
        case .stale: return "最新の一覧を取得できません。前回の内容を表示しています。"
        case .unavailable: return "一覧を取得できません。接続を確認してください。"
        }
    }
}

enum LAAWorkRoutineTime {
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter(); plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    /// "09:00" today, "11/4 09:00" later, "時刻未確認" when the Bridge has none.
    static func next(_ text: String?, now: Date = Date()) -> String {
        guard let date = date(text) else { return "時刻未確認" }
        let calendar = Calendar.autoupdatingCurrent
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let clock = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        guard !calendar.isDate(date, inSameDayAs: now) else { return "今日 " + clock }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "明日 " + clock }
        let day = calendar.dateComponents([.month, .day], from: date)
        return "\(day.month ?? 0)/\(day.day ?? 0) " + clock
    }
}

extension LAAWorkRoutineTime {
    /// The day part of the next run: "今日", "明日" or "11/4"; nil when the
    /// Bridge has no time. The tree already shows the clock beside the name.
    static func nextDay(_ text: String?, now: Date = Date()) -> String? {
        guard let date = date(text) else { return nil }
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDate(date, inSameDayAs: now) { return "今日" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "明日" }
        let day = calendar.dateComponents([.month, .day], from: date)
        return "\(day.month ?? 0)/\(day.day ?? 0)"
    }

    /// Minutes after midnight the routine runs at: its next run, else the
    /// first "HH:MM" in its schedule text ("毎日 07:30"), else nil.
    static func minutes(_ routine: LAAWorkRoutine, calendar: Calendar = .autoupdatingCurrent) -> Int? {
        if let date = date(routine.nextRunAt) {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
        guard let schedule = routine.schedule,
              let match = schedule.range(of: #"(?<![0-9])([01]?[0-9]|2[0-3]):[0-5][0-9]"#, options: .regularExpression) else { return nil }
        let parts = schedule[match].split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        return hour * 60 + minute
    }
}

/// The routines as a day: morning to late night, each part with its own
/// point on the line, and the routines in it by the clock.
enum LAAWorkRoutineTree {
    enum Band: Int, CaseIterable {
        case morning, daytime, evening, lateNight, unknown

        static func of(_ minutes: Int?) -> Band {
            guard let minutes else { return .unknown }
            switch minutes / 60 {
            case 5..<11: return .morning
            case 11..<17: return .daytime
            case 17..<24: return .evening
            default: return .lateNight
            }
        }

        var title: String {
            switch self {
            case .morning: String("朝")
            case .daytime: String("昼")
            case .evening: String("夜")
            case .lateNight: String("深夜")
            case .unknown: String("時刻未確認")
            }
        }

        var range: String? {
            switch self {
            case .morning: "5–11時"
            case .daytime: "11–17時"
            case .evening: "17–24時"
            case .lateNight: "0–5時"
            case .unknown: nil
            }
        }
    }

    enum Entry {
        case band(Band)
        case routine(LAAWorkRoutine, clock: String?)
    }

    static func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    /// Band points and routines in reading order; an empty band is left out.
    static func entries(_ routines: [LAAWorkRoutine], calendar: Calendar = .autoupdatingCurrent) -> [Entry] {
        let timed = routines.map { ($0, LAAWorkRoutineTime.minutes($0, calendar: calendar)) }
        var result: [Entry] = []
        for band in Band.allCases {
            let rows = timed.filter { Band.of($0.1) == band }.sorted { left, right in
                left.1 == right.1 ? left.0.name < right.0.name : (left.1 ?? 0) < (right.1 ?? 0)
            }
            guard !rows.isEmpty else { continue }
            result.append(.band(band))
            result += rows.map { .routine($0.0, clock: $0.1.map(clock)) }
        }
        return result
    }
}

/// One row on a tree: a node on the left rail and the row's content beside
/// it. The rail is drawn behind the whole row, so consecutive rows join into
/// one line however tall an opened row grows.
struct LAAWorkTreeRow<Node: View, Content: View>: View {
    let top: Bool
    let bottom: Bool
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    @ViewBuilder let node: () -> Node
    @ViewBuilder let content: () -> Content
    /// The status mark's own box (16 pt and its ring), scaled the same way.
    @ScaledMetric(relativeTo: .footnote) private var nodeBox: CGFloat = 20
    private var rail: CGFloat { 24 }

    var body: some View {
        HStack(alignment: .top, spacing: LAASpacing.x2) {
            node().frame(width: rail, height: nodeBox)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
        .background(alignment: .leading) {
            LAAWorkRail(top: top, bottom: bottom, nodeY: topPadding + nodeBox / 2)
                .stroke(LAAColor.separator, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: rail)
                .accessibilityHidden(true)
        }
    }
}

private struct LAAWorkRail: Shape {
    let top: Bool
    let bottom: Bool
    let nodeY: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if top { path.move(to: CGPoint(x: rect.midX, y: rect.minY)); path.addLine(to: CGPoint(x: rect.midX, y: nodeY)) }
        if bottom { path.move(to: CGPoint(x: rect.midX, y: nodeY)); path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY)) }
        return path
    }
}

struct LAAWorkCatalogView: View {
    enum Kind { case routines, skills }
    let kind: Kind
    /// The Work hub's search on the phone; the Mac column keeps its own field.
    var query = ""
    @EnvironmentObject private var bridge: LAABridgeSession
    @StateObject private var cache: ComposerDraftStore

    @MainActor init(kind: Kind, query: String = "") {
        self.kind = kind; self.query = query
        let name = kind == .routines ? "routines" : "skills"
        _cache = StateObject(wrappedValue: LAAWorkDrafts.makeStore(fileURL: LAAWorkDrafts.fileURL.deletingLastPathComponent().appendingPathComponent("catalog-" + name + "-cache-v1.json")))
    }
    @State private var routines: [LAAWorkRoutine] = []
    @State private var skills: [LAAWorkSkill] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var failure: String?
    @State private var loadID = UUID()
    @State private var deviceID: String?
    /// Rows the Bridge skipped in the last routines read; any makes the list
    /// partial, so the screen says so instead of calling it complete.
    @State private var skipped = 0
    @State private var expandedRoutines = Set<String>()
    @State private var servicesOpen = false
    /// A first read the Bridge was still preparing is asked again, so a cold
    /// cache does not leave "could not load" on screen until someone taps.
    @State private var retryTask: Task<Void, Never>?
    @State private var retryToken = UUID()

    var body: some View {
        Group {
            if kind == .routines { routineTree } else { skillList }
        }
        .refreshable { await load() }
        .task(id: "\(bridge.revision)-\(kind == .routines)") { await load() }
        .onDisappear { retryTask?.cancel(); retryTask = nil }
    }

    // MARK: Routines

    /// The day as one tree: a line down the left, a tan point for each part
    /// of the day and a node per routine whose mark is its last result. The
    /// owner reads when something runs and whether it went well in one pass.
    private var routineTree: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x3) {
                if failure != nil {
                    LAAWorkFailure(text: "一覧を取得できません") { Task { await load() } }
                }
                if loading && !loaded { LAALoadingDots() }
                if skipped > 0 {
                    Text(verbatim: "一部（\(skipped)件）を読み取れませんでした。表示は前回の内容です。")
                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                        .accessibilityIdentifier("work.routines.partial")
                }
                let scheduled = shownRoutines.filter { $0.triggerKind == nil || $0.triggerKind == "scheduled" }
                let entries = LAAWorkRoutineTree.entries(scheduled)
                if !entries.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(entries.indices, id: \.self) { index in
                            treeRow(entries[index], first: index == 0, last: index == entries.count - 1)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("work.routines.tree")
                }
                let services = shownRoutines.filter { $0.triggerKind != nil && $0.triggerKind != "scheduled" }
                if !services.isEmpty { servicesGroup(services) }
                if showsEmptyState {
                    ContentUnavailableView {
                        Label { Text(verbatim: filtering ? "一致する定期実行はありません" : "定期実行はありません") }
                        icon: { Image(systemName: "clock") }
                    }
                }
            }
            .padding(.horizontal, LAASpacing.horizontal)
            .padding(.bottom, LAASpacing.x8)
        }
        .accessibilityIdentifier("work.routines")
    }

    /// Persistent, manual and unscheduled jobs stay folded under the day:
    /// they do not run at a time, so they have no place on it.
    private func servicesGroup(_ services: [LAAWorkRoutine]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy) { servicesOpen.toggle() } } label: {
                HStack(spacing: LAASpacing.x2) {
                    Text(verbatim: "常駐・手動・時刻未確認（\(services.count)）")
                        .laaTextStyle(.section).foregroundStyle(LAAColor.secondaryText)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LAAColor.secondaryText)
                        .rotationEffect(.degrees(servicesOpen ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .frame(minHeight: LAASpacing.minimumTouchTarget).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(verbatim: servicesOpen ? "開いています" : "閉じています"))
            .accessibilityIdentifier("work.routines.services")
            if servicesOpen {
                ForEach(services.indices, id: \.self) { index in
                    treeRow(.routine(services[index], clock: nil), first: index == 0, last: index == services.count - 1)
                }
            }
        }
        .padding(.top, LAASpacing.x2)
    }

    @ViewBuilder private func treeRow(_ entry: LAAWorkRoutineTree.Entry, first: Bool, last: Bool) -> some View {
        switch entry {
        case .band(let band):
            LAAWorkTreeRow(top: !first, bottom: !last, topPadding: first ? 0 : LAASpacing.x4, bottomPadding: LAASpacing.x1) {
                Circle().fill(LAAColor.decorativeTan).frame(width: 9, height: 9)
            } content: {
                HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x2) {
                    Text(verbatim: band.title).laaTextStyle(.section).foregroundStyle(LAAColor.text)
                        .accessibilityAddTraits(.isHeader)
                    if let range = band.range {
                        Text(verbatim: range).laaTextStyle(.secondary).monospacedDigit()
                            .foregroundStyle(LAAColor.secondaryText)
                    }
                }
            }
        case .routine(let routine, let clock):
            routineRow(routine, clock: clock, top: !first, bottom: !last)
        }
    }

    private func routineRow(_ routine: LAAWorkRoutine, clock: String?, top: Bool, bottom: Bool) -> some View {
        let status = LAAWorkStatus.routine(routine)
        let open = expandedRoutines.contains(routine.id)
        return LAAWorkTreeRow(top: top, bottom: bottom, topPadding: LAASpacing.x2, bottomPadding: LAASpacing.x2) {
            LAAWorkStatusMark(status: status, background: LAAColor.background)
        } content: {
            VStack(alignment: .leading, spacing: LAASpacing.x2) {
                Button { withAnimation(.snappy) { expandedRoutines.formSymmetricDifference([routine.id]) } } label: {
                    HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x3) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x2) {
                                if let clock {
                                    Text(verbatim: clock).laaTextStyle(.secondary).fontWeight(.semibold)
                                        .monospacedDigit().foregroundStyle(LAAColor.secondaryText)
                                }
                                Text(verbatim: routine.name).laaTextStyle(.body).fontWeight(.medium)
                                    .foregroundStyle(LAAColor.text).multilineTextAlignment(.leading)
                            }
                            routineMeta(routine, status: status)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        LAAWorkRefLabel(ref: routine.ref)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(open ? String("詳細を表示中") : String("詳細を閉じています"))
                if open {
                    VStack(alignment: .leading, spacing: LAASpacing.x1) {
                        detail("予定", routine.schedule ?? "時刻未確認")
                        detail("状態", stateLabel(routine.state))
                        detail("前回", routine.previousRunSummary())
                        if routine.runId != nil || routine.reasonCode != nil {
                            detail("開始", LAAWorkRoutine.recordedTime(routine.startedAt))
                            detail("終了", LAAWorkRoutine.recordedTime(routine.finishedAt))
                            detail("端末受信", LAAWorkRoutine.recordedTime(routine.notificationReceivedAt))
                        }
                    }
                    .padding(LAASpacing.x3)
                    .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card, style: .continuous))
                }
            }
        }
    }

    /// Where it goes and when it runs next; an error names itself in red, the
    /// one word the node's colour already announced.
    private func routineMeta(_ routine: LAAWorkRoutine, status: LAAWorkStatus) -> some View {
        let line = [routine.destination, LAAWorkRoutineTime.nextDay(routine.nextRunAt).map { "次回 " + $0 }]
            .compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: LAASpacing.x1) {
            if status == .error || status == .running {
                Text(verbatim: status.label).fontWeight(.semibold).foregroundStyle(status.color)
                if !line.isEmpty { Text(verbatim: "·").foregroundStyle(LAAColor.secondaryText).accessibilityHidden(true) }
            }
            if !line.isEmpty { Text(verbatim: line).foregroundStyle(LAAColor.secondaryText) }
        }
        .laaTextStyle(.secondary).lineLimit(1)
    }

    // MARK: Skills

    private var skillList: some View {
        List {
            if failure != nil {
                LAAWorkFailure(text: "一覧を取得できません") { Task { await load() } }
            }
            if loading && !loaded { LAALoadingDots().listRowBackground(Color.clear) }
            ForEach(skillGroups, id: \.self) { category in
                Section {
                    ForEach(displayedSkills.filter { $0.group == category }) { skill in
                        NavigationLink {
                            LAAWorkSkillDetail(skill: skill)
                        } label: {
                            VStack(alignment: .leading, spacing: LAASpacing.x1) {
                                HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x2) {
                                    LAAWorkRefLabel(ref: skill.ref)
                                    Text(verbatim: skill.name).fontWeight(.medium)
                                }
                                Text(verbatim: skill.explanation.isEmpty ? "説明なし" : skill.explanation)
                                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText).lineLimit(2)
                            }.padding(.vertical, LAASpacing.x2)
                        }.listRowBackground(LAAColor.surface)
                    }
                } header: { Text(verbatim: category) }
            }
            if showsEmptyState {
                ContentUnavailableView {
                    Label { Text(verbatim: filtering ? "一致するスキルはありません" : "スキルはありません") }
                    icon: { Image(systemName: "sparkles") }
                }.listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped).textCase(nil)
        .scrollContentBackground(.hidden)
    }

    private var filtering: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// "No routines" is only true of a complete read: an unread, failed or
    /// partly read list must not be printed as an empty schedule.
    private var showsEmptyState: Bool {
        guard loaded, !loading, failure == nil else { return false }
        if kind == .routines { return skipped == 0 && shownRoutines.isEmpty }
        return displayedSkills.isEmpty
    }

    /// The routines the hub's search left, on the phone. A search by short
    /// number also finds a routine whose name says nothing about it.
    private var shownRoutines: [LAAWorkRoutine] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return routines }
        return routines.filter {
            LAAWorkRef.matches(query, ref: $0.ref, text: [$0.name, $0.destination ?? "", $0.schedule ?? ""])
        }
    }

    private var displayedSkills: [LAAWorkSkill] {
        var names = Set<String>()
        return skills
            .filter { LAAWorkRef.matches(query, ref: $0.ref, text: [$0.name, $0.explanation]) }
            .filter { names.insert($0.name).inserted }.sorted { $0.name < $1.name }
    }

    private var skillGroups: [String] {
        let order = ["日常業務", "調査・要約", "トレード", "経理・会計", "発信・営業", "デザイン・資料", "動画・音声", "開発・運用", "その他"]
        return Set(displayedSkills.map(\.group)).sorted {
            let a = order.firstIndex(of: $0) ?? order.count
            let b = order.firstIndex(of: $1) ?? order.count
            return a == b ? $0 < $1 : a < b
        }
    }

    private func stateLabel(_ value: String?) -> String {
        switch value {
        case "running": "実行中"
        case "paused": "一時停止"
        case "error": "要確認"
        case "scheduled": "実行待ち"
        default: "未確認"
        }
    }

    private func detail(_ label: String, _ value: String, singleLine: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(verbatim: label).foregroundStyle(LAAColor.secondaryText)
            Spacer()
            Text(verbatim: value).multilineTextAlignment(.trailing)
                .lineLimit(singleLine ? 1 : nil).minimumScaleFactor(singleLine ? 0.75 : 1)
        }.laaTextStyle(.secondary)
    }

    /// A read from the view (opening the list, pull, the refresh button): one
    /// attempt plus a bounded retry chain while the Bridge builds its first
    /// answer, so a cold cache is not left as "could not load".
    private func load() async {
        retryTask?.cancel(); retryTask = nil
        if let reason = await readList(), reason != .stale { scheduleRetry() }
    }

    /// One attempt. Returns why it failed, or nil when the list was read (or
    /// the view moved on, which needs neither a message nor a retry).
    private func readList() async -> LAAWorkCatalogFailure? {
        let epoch = UUID(); loadID = epoch
        let device = bridge.deviceID
        if device != deviceID {
            routines = LAAWorkSessionCache.read([LAAWorkRoutine].self, store: cache, device: device, target: "routines") ?? []
            skills = LAAWorkSessionCache.read([LAAWorkSkill].self, store: cache, device: device, target: "skills") ?? []
            loaded = kind == .routines ? !routines.isEmpty : !skills.isEmpty
            skipped = 0; deviceID = device
        }
        guard bridge.status == .paired else { return nil }
        loading = true; failure = nil
        defer { if loadID == epoch { loading = false } }
        do {
            if kind == .routines {
                let page: LAAWorkPage<LAAWorkRoutine> = try await bridge.read("/v1/routines")
                guard loadID == epoch, device == bridge.deviceID, !Task.isCancelled else { return nil }
                guard page.nextCursor == nil else { throw LAABridgeError.invalidResponse }
                routines = page.items
                LAAWorkSessionCache.save(routines, store: cache, device: device, target: "routines")
                skipped = max(0, page.skipped ?? 0)
            } else {
                let page: LAAWorkPage<LAAWorkSkill> = try await bridge.read("/v1/skills")
                guard loadID == epoch, device == bridge.deviceID, !Task.isCancelled else { return nil }
                guard page.nextCursor == nil else { throw LAABridgeError.invalidResponse }
                skills = page.items
                LAAWorkSessionCache.save(skills, store: cache, device: device, target: "skills")
            }
            loaded = true
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            guard loadID == epoch, device == bridge.deviceID else { return nil }
            let reason = LAAWorkCatalogFailure.classify(loaded: loaded, error: error)
            failure = reason.japaneseText
            return reason
        }
    }

    /// Two more asks cover the Bridge's cold-cache window (its first Console
    /// read). A read answer stops the chain; leaving the screen cancels it.
    private func scheduleRetry() {
        retryTask?.cancel()
        let token = UUID(); retryToken = token
        retryTask = Task {
            for seconds in [2.0, 6.0] {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, retryToken == token, !loaded else { return }
                guard await readList() != nil else { return }
                guard !Task.isCancelled, retryToken == token else { return }
            }
        }
    }
}
private struct LAAWorkSkillDetail: View {
    let skill: LAAWorkSkill
    var body: some View {
        List {
            Section {
                LAAWorkRefLabel(ref: skill.ref)
                Text(verbatim: skill.explanation.isEmpty ? "説明なし" : skill.explanation).fontWeight(.medium)
                if let detail = skill.detail, !detail.isEmpty, detail != skill.explanation { Text(verbatim: detail) }
            } header: { Text(verbatim: skill.group) }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text(verbatim: skill.name))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("work.skill.detail")
    }
}

#endif
