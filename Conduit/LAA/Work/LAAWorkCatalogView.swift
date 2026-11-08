#if LAA_BUILD
import SwiftUI

struct LAAWorkSkill: Decodable, Identifiable {
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

    var message: String {
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
        guard !calendar.isDate(date, inSameDayAs: now) else { return clock }
        let day = calendar.dateComponents([.month, .day], from: date)
        return "\(day.month ?? 0)/\(day.day ?? 0) " + clock
    }
}

struct LAAWorkCatalogView: View {
    enum Kind { case routines, skills }
    let kind: Kind
    /// The Work hub's search on the phone; the Mac column keeps its own field.
    var query = ""
    @EnvironmentObject private var bridge: LAABridgeSession
    @State private var routines: [LAAWorkRoutine] = []
    @State private var skills: [LAAWorkSkill] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var failure: String?
    @State private var loadID = UUID()
    @State private var deviceID: String?
    @State private var fetchedAt: Date?
    /// Rows the Bridge skipped in the last routines read; any makes the list
    /// partial, so the screen says so instead of calling it complete.
    @State private var skipped = 0
    /// A first read the Bridge was still preparing is asked again, so a cold
    /// cache does not leave "could not load" on screen until someone taps.
    @State private var retryTask: Task<Void, Never>?
    @State private var retryToken = UUID()

    var body: some View {
        List {
            if let failure {
                Text(verbatim: failure).foregroundStyle(LAAColor.attention)
                Button { Task { await load() } } label: { Text(verbatim: "読み直す") }
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
            if kind == .routines, skipped > 0 {
                Text(verbatim: "一部の定期実行を読み取れませんでした（\(skipped)件）。この一覧は完全ではありません。")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                    .accessibilityIdentifier("work.routines.partial")
            }
            if kind == .routines, LAAWorkFreshness.isStale(fetchedAt) {
                Text(verbatim: "最終取得 \(clock(fetchedAt))。最新ではない可能性があります。")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    .accessibilityIdentifier("work.routines.fetchedAt")
            }
            if kind == .routines {
                ForEach(LAAWorkRoutineGrouping.groups(shownRoutines.filter { $0.triggerKind == nil || $0.triggerKind == "scheduled" })) { group in
                    Section {
                        ForEach(group.routines) { routine in routineRow(routine) }
                    } header: {
                        Text(verbatim: group.destination).accessibilityIdentifier("work.routines.group")
                    }
                }
                let services = shownRoutines.filter { $0.triggerKind != nil && $0.triggerKind != "scheduled" }
                if !services.isEmpty {
                    DisclosureGroup {
                        ForEach(services) { routine in routineRow(routine) }
                    } label: { Text(verbatim: "常駐・手動・時刻未確認（\(services.count)）") }
                        .accessibilityIdentifier("work.routines.services")
                }
            } else {
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
            }
            if showsEmptyState {
                ContentUnavailableView {
                    Label { Text(verbatim: filtering ? (kind == .routines ? "一致する定期実行はありません" : "一致するスキルはありません")
                                                     : (kind == .routines ? "定期実行はありません" : "スキルはありません")) }
                    icon: { Image(systemName: kind == .routines ? "clock" : "sparkles") }
                }.listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel(Text(verbatim: "読み直す"))
                    .accessibilityIdentifier("work.catalog.refresh")
                    .disabled(loading)
            }
        }
        .refreshable { await load() }
        .task(id: "\(bridge.revision)-\(kind == .routines)") { await load() }
        .onDisappear { retryTask?.cancel(); retryTask = nil }
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

    private func routineRow(_ routine: LAAWorkRoutine) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x2) {
                LAAWorkRefLabel(ref: routine.ref)
                Text(verbatim: routine.name).fontWeight(.semibold)
            }
            Text(verbatim: routine.schedule ?? "時刻未確認").foregroundStyle(LAAColor.link)
            detail("次回", LAAWorkRoutineTime.next(routine.nextRunAt))
            detail("配信先チャット", routine.destination ?? "設定なし・未確認")
            detail("状態", stateLabel(routine.state))
            detail("前回", routine.previousRunSummary(), singleLine: true)
        }.padding(.vertical, LAASpacing.x2).listRowBackground(LAAColor.surface)
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

    private func clock(_ date: Date?) -> String {
        guard let date else { return "時刻不明" }
        let parts = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
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
        if device != deviceID { routines = []; skills = []; loaded = false; fetchedAt = nil; skipped = 0; deviceID = device }
        guard bridge.status == .paired else { return nil }
        loading = true; failure = nil
        defer { if loadID == epoch { loading = false } }
        do {
            if kind == .routines {
                let page: LAAWorkPage<LAAWorkRoutine> = try await bridge.read("/v1/routines")
                guard loadID == epoch, device == bridge.deviceID, !Task.isCancelled else { return nil }
                guard page.nextCursor == nil else { throw LAABridgeError.invalidResponse }
                routines = page.items
                skipped = max(0, page.skipped ?? 0)
                fetchedAt = LAAWorkFreshness.date(page.fetchedAt)
            } else {
                let page: LAAWorkPage<LAAWorkSkill> = try await bridge.read("/v1/skills")
                guard loadID == epoch, device == bridge.deviceID, !Task.isCancelled else { return nil }
                guard page.nextCursor == nil else { throw LAABridgeError.invalidResponse }
                skills = page.items
            }
            loaded = true
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            guard loadID == epoch, device == bridge.deviceID else { return nil }
            let reason = LAAWorkCatalogFailure.classify(loaded: loaded, error: error)
            failure = reason.message
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
