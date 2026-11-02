#if LAA_BUILD
import SwiftUI

struct LAAWorkSkill: Decodable, Identifiable {
    let id: String
    let name: String
    let description: String
    let source: String
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

    var body: some View {
        List {
            if let failure {
                Text(verbatim: failure).foregroundStyle(LAAColor.attention)
                Button { Task { await load() } } label: { Text(verbatim: "読み直す") }
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
            if kind == .routines {
                ForEach(routines) { routine in
                    VStack(alignment: .leading, spacing: LAASpacing.x2) {
                        Text(verbatim: routine.name).fontWeight(.semibold)
                        Text(verbatim: routine.schedule ?? "時刻未確認").foregroundStyle(LAAColor.link)
                        detail("通知先", routine.destination ?? "未確認")
                        detail("最終実行", routine.lastRunAt.map(LAAWorkPresentation.date) ?? "未確認")
                        detail("状態", stateLabel(routine.state))
                        detail("業務結果", observationLabel(routine.businessStatus))
                        detail("配信", observationLabel(routine.notificationStatus))
                        if let result = routine.result { detail("最終結果", observationLabel(result)) }
                        if let next = routine.nextRunAt { detail("次回", LAAWorkPresentation.date(next)) }
                    }.padding(.vertical, LAASpacing.x2).listRowBackground(LAAColor.surface)
                }
            } else {
                ForEach(skills) { skill in
                    VStack(alignment: .leading, spacing: LAASpacing.x1) {
                        Text(verbatim: skill.name).fontWeight(.medium)
                        Text(verbatim: skill.description.isEmpty ? "説明なし" : skill.description)
                            .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText).lineLimit(2)
                    }
                    .padding(.vertical, LAASpacing.x2)
                    .listRowBackground(LAAColor.surface)
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
        .refreshable { await load() }
        .task(id: "\(bridge.revision)-\(kind == .routines)") { await load() }
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

    private func observationLabel(_ value: String?) -> String {
        switch value {
        case "success", "ok", "succeeded": "成功"
        case "completed": "完了"
        case "running": "実行中"
        case "failed", "error": "失敗"
        case "partial": "一部未完了"
        case "pending": "待機中"
        case "sent", "delivered": "配信済み"
        case "timeout": "時間切れ"
        case "unknown", nil: "未確認"
        default: value ?? "未確認"
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(verbatim: label).foregroundStyle(LAAColor.secondaryText)
            Spacer()
            Text(verbatim: value).multilineTextAlignment(.trailing)
        }.laaTextStyle(.secondary)
    }

    private func load() async {
        let epoch = UUID(); loadID = epoch
        let device = bridge.deviceID
        if device != deviceID { routines = []; skills = []; loaded = false; deviceID = device }
        guard bridge.status == .paired else { return }
        loading = true; failure = nil
        defer { if loadID == epoch { loading = false } }
        do {
            if kind == .routines {
                let page: LAAWorkPage<LAAWorkRoutine> = try await bridge.read("/v1/routines")
                guard loadID == epoch, device == bridge.deviceID, !Task.isCancelled else { return }
                guard page.nextCursor == nil else { throw LAABridgeError.invalidResponse }
                routines = page.items
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
#endif
