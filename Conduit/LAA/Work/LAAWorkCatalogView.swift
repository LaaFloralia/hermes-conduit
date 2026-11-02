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

    var group: String { category ?? "その他" }
    var explanation: String { summary ?? description }
}

struct LAAWorkCatalogView: View {
    enum Kind { case routines, skills }
    let kind: Kind
    @EnvironmentObject private var bridge: LAABridgeSession
    @State private var routines: [LAAWorkRoutine] = []
    @State private var skills: [LAAWorkSkill] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var failure: String?
    @State private var loadID = UUID()
    @State private var deviceID: String?
    @State private var fetchedAt: Date?

    var body: some View {
        List {
            if let failure {
                Text(verbatim: failure).foregroundStyle(LAAColor.attention)
                Button { Task { await load() } } label: { Text(verbatim: "読み直す") }
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
            if kind == .routines, LAAWorkFreshness.isStale(fetchedAt) {
                Text(verbatim: "最終取得 \(clock(fetchedAt))。最新ではない可能性があります。")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    .accessibilityIdentifier("work.routines.fetchedAt")
            }
            if kind == .routines {
                ForEach(routines.filter { $0.triggerKind == nil || $0.triggerKind == "scheduled" }) { routine in routineRow(routine) }
                let services = routines.filter { $0.triggerKind != nil && $0.triggerKind != "scheduled" }
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
                                    Text(verbatim: skill.name).fontWeight(.medium)
                                    Text(verbatim: skill.explanation.isEmpty ? "説明なし" : skill.explanation)
                                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText).lineLimit(2)
                                }.padding(.vertical, LAASpacing.x2)
                            }.listRowBackground(LAAColor.surface)
                        }
                    } header: { Text(verbatim: category) }
                }
            }
            if loaded && !loading && failure == nil && (kind == .routines ? routines.isEmpty : skills.isEmpty) {
                ContentUnavailableView {
                    Label { Text(verbatim: kind == .routines ? "定期実行はありません" : "スキルはありません") }
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
    }

    private var displayedSkills: [LAAWorkSkill] {
        var names = Set<String>()
        return skills.filter { names.insert($0.name).inserted }.sorted { $0.name < $1.name }
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
            Text(verbatim: routine.name).fontWeight(.semibold)
            Text(verbatim: routine.schedule ?? "時刻未確認").foregroundStyle(LAAColor.link)
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

    private func load() async {
        let epoch = UUID(); loadID = epoch
        let device = bridge.deviceID
        if device != deviceID { routines = []; skills = []; loaded = false; fetchedAt = nil; deviceID = device }
        guard bridge.status == .paired else { return }
        loading = true; failure = nil
        defer { if loadID == epoch { loading = false } }
        do {
            if kind == .routines {
                let page: LAAWorkPage<LAAWorkRoutine> = try await bridge.read("/v1/routines")
                guard loadID == epoch, device == bridge.deviceID, !Task.isCancelled else { return }
                guard page.nextCursor == nil else { throw LAABridgeError.invalidResponse }
                routines = page.items
                fetchedAt = LAAWorkFreshness.date(page.fetchedAt)
            } else {
                let page: LAAWorkPage<LAAWorkSkill> = try await bridge.read("/v1/skills")
                guard loadID == epoch, device == bridge.deviceID, !Task.isCancelled else { return }
                guard page.nextCursor == nil else { throw LAABridgeError.invalidResponse }
                skills = page.items
            }
            loaded = true
        } catch is CancellationError { return }
        catch {
            guard loadID == epoch, device == bridge.deviceID else { return }
            failure = loaded ? "最新の一覧を取得できません。前回の内容を表示しています。" : "一覧を取得できません。接続を確認してください。"
        }
    }
}
private struct LAAWorkSkillDetail: View {
    let skill: LAAWorkSkill
    var body: some View {
        List {
            Section {
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
