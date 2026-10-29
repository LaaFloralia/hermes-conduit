#if LAA_BUILD
import SwiftUI

/// Keep this screen's visual choices together until the shared v2 tokens land.
private enum LAAUsageStyle {
    static let background = color(0xF6F2E9, 0x0F1B1C)
    static let surface = color(0xFFFDF8, 0x172627)
    static let ink = color(0x213536, 0xECE7DC)
    static let muted = color(0x596968, 0xA8B7B4)
    static let accent = color(0x00585E, 0x75C3C3)
    static let line = color(0xD7D5CC, 0x385052)
    static let track = color(0xEBE6DC, 0x243638)
    static let warning = color(0x6C244C, 0xD49AB6)
    static let title = Font.custom("Georgia", size: 34, relativeTo: .largeTitle)
    static let number = Font.custom("Georgia", size: 36, relativeTo: .largeTitle).monospacedDigit()
    static let value = Font.custom("Georgia", size: 20, relativeTo: .body).monospacedDigit()
    static let body = Font.body
    static let caption = Font.footnote
    static let section = Font.system(.caption, design: .default).weight(.bold)
    static let radius: CGFloat = 16
    static let inset: CGFloat = 24
    static let narrowInset: CGFloat = 16

    private static func color(_ light: Int, _ dark: Int) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xff) / 255,
                           green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }
}

struct LAAUsageView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @StateObject private var state = LAAUsageState()
    @State private var showPairing = false
    let onRequestSettings: () -> Void

    private struct Scope: Hashable {
        let revision: Int
        let dashboardID: UUID?
        let profile: String
    }

    private var scope: Scope {
        .init(revision: bridge.revision, dashboardID: appState.activeDashboardID, profile: appState.activeProfile)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LAAUsageStyle.background.ignoresSafeArea()
                List {
                    VStack(alignment: .leading, spacing: 32) {
                        header
                        if bridge.status != .paired { connectionCard }
                        if bridge.status == .paired || state.usage.value != nil || state.mac.value != nil {
                            if let items = state.usage.value, let overview = LAAUsageOverview.first(from: items) {
                                overviewCard(overview)
                            }
                            services
                            dashboard
                            macStatus
                        }
                    }
                    .padding(.horizontal, geometry.size.width < 360 ? LAAUsageStyle.narrowInset : LAAUsageStyle.inset)
                    .padding(.top, 16)
                    .padding(.bottom, 32)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable { await refresh() }
            }
        }
        .tint(LAAUsageStyle.accent)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showPairing) { LAAPairingView().environmentObject(bridge) }
        .task(id: scope) {
            guard bridge.status == .paired else { return }
            let changed = state.selectScope(bridgeRevision: bridge.revision,
                                            dashboardScope: "\(appState.activeDashboardID?.uuidString ?? "")|\(appState.activeProfile)")
            if changed { await state.waitUntilIdle() }
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: "LAA")
                .font(LAAUsageStyle.section).foregroundStyle(LAAUsageStyle.accent)
            HStack(alignment: .center) {
                Text(verbatim: "Usage")
                    .font(LAAUsageStyle.title).foregroundStyle(LAAUsageStyle.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Menu {
                    if bridge.status == .paired {
                        Button { showPairing = true } label: { Text(verbatim: "Macとの接続") }
                            .accessibilityIdentifier("laa.bridge.manage")
                    }
                    Button(action: onRequestSettings) { Text(verbatim: "設定") }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .accessibilityLabel(Text(verbatim: "その他の操作"))
                .accessibilityIdentifier("laa.usage.menu")
                Button { Task { await refresh() } } label: {
                    Group {
                        if state.isRefreshing { ProgressView() }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .frame(width: 44, height: 44)
                    .background(LAAUsageStyle.surface, in: Circle())
                    .overlay(Circle().strokeBorder(LAAUsageStyle.line))
                }
                .disabled(state.isRefreshing || bridge.status != .paired)
                .accessibilityLabel(Text(verbatim: "使用状況を更新"))
                .accessibilityIdentifier("laa.usage.refresh")
            }
            Text(verbatim: "サービスごとの使用状況")
                .font(LAAUsageStyle.body).foregroundStyle(LAAUsageStyle.muted)
            Text(verbatim: "最終更新 " + time(state.updatedAt))
                .font(LAAUsageStyle.caption).foregroundStyle(LAAUsageStyle.muted)
                .accessibilityIdentifier("laa.usage.updated")
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label { Text(verbatim: "未接続") } icon: { Image(systemName: "circle") }
                .foregroundStyle(LAAUsageStyle.muted)
            Text(verbatim: bridge.status == .revoked || bridge.status == .unauthorized
                 ? "この端末の接続が無効になりました。新しいコードで接続してください。"
                 : bridge.status == .keychainError ? LAABridgeError.keychain.japaneseText : LAACopy.bridgeNotPairedBody)
                .foregroundStyle(LAAUsageStyle.ink)
            if bridge.status != .keychainError {
                Button { showPairing = true } label: { Text(verbatim: "Macに接続する") }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("laa.bridge.openPairing")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LAAUsageStyle.surface, in: RoundedRectangle(cornerRadius: LAAUsageStyle.radius))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(verbatim: title).font(LAAUsageStyle.section).foregroundStyle(LAAUsageStyle.muted)
            .accessibilityAddTraits(.isHeader)
    }

    private func overviewCard(_ overview: LAAUsageOverview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("概要")
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: overview.label + " · " + overview.window)
                    .font(LAAUsageStyle.caption).foregroundStyle(LAAUsageStyle.muted)
                HStack(alignment: .center, spacing: 16) {
                    Text(verbatim: value(overview.remainingPercent, unit: "percent"))
                        .font(LAAUsageStyle.number).foregroundStyle(LAAUsageStyle.ink)
                    Spacer(minLength: 8)
                    ProgressView(value: overview.remainingPercent, total: 100)
                        .tint(LAAUsageStyle.accent)
                        .frame(maxWidth: 130)
                        .accessibilityLabel(Text(verbatim: "残りの利用枠"))
                        .accessibilityValue(Text(verbatim: value(overview.remainingPercent, unit: "percent")))
                }
                Text(verbatim: "利用枠の残り · 確認時刻 " + time(overview.observedAt))
                    .font(LAAUsageStyle.caption).foregroundStyle(LAAUsageStyle.muted)
                if overview.stale || overview.expired || state.retainedUsageIDs.contains(overview.itemID) {
                    Label { Text(verbatim: overview.expired ? "期限切れ" : "古い値・前回の値") }
                        icon: { Image(systemName: "exclamationmark.triangle") }
                        .font(LAAUsageStyle.caption).foregroundStyle(LAAUsageStyle.warning)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LAAUsageStyle.surface, in: RoundedRectangle(cornerRadius: LAAUsageStyle.radius))
        }
    }

    private var services: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("サービス別")
            sourceError(state.usage.error, previous: state.usage.fetchedAt)
            if let items = state.usage.value {
                if items.isEmpty { empty("表示できるサービスはありません。") }
                ForEach(LAAUsageGroup.groups(items)) { group in
                    Divider().overlay(LAAUsageStyle.line)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: group.label).font(LAAUsageStyle.body.weight(.medium))
                            .foregroundStyle(LAAUsageStyle.ink)
                        ForEach(group.items) { item in
                            usageItem(item, retained: state.retainedUsageIDs.contains(item.id))
                        }
                    }
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("laa.usage.service.\(group.id)")
                }
                if !items.isEmpty { Divider().overlay(LAAUsageStyle.line) }
            } else if !state.isRefreshing {
                empty(state.usage.error == nil ? "未取得" : "利用できません。")
            }
        }
    }

    @ViewBuilder
    private func usageItem(_ item: LAAUsageItem, retained: Bool) -> some View {
        if item.kind == "quota", let windows = item.detail?.windows, !windows.isEmpty {
            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                metric(window.label + " · 残り", item.availability == "available" ? value(window.remainingPercent, unit: "percent") : unavailable(item))
                Text(verbatim: "更新予定 " + time(LAAUsageItem.date(window.resetsAt)))
                    .font(LAAUsageStyle.caption).foregroundStyle(LAAUsageStyle.muted)
                if let reset = LAAUsageItem.date(window.resetsAt), reset < Date(), !item.isExpired() {
                    caption("期限切れ")
                }
            }
        } else {
            metric(itemTitle(item), item.availability == "available" ? value(item.availableValue, unit: item.unit) : unavailable(item))
        }
        itemFlags(item, retained: retained)
        if let renews = LAAUsageItem.date(item.detail?.renewsAt) {
            caption("更新予定 " + time(renews))
        }
        if let expires = item.detail?.expiresOnUtc { caption("有効期限 " + expires) }
        caption("確認時刻 " + time(LAAUsageItem.date(item.observedAt)))
    }

    private func itemTitle(_ item: LAAUsageItem) -> String {
        switch item.kind {
        case "quota": return "利用枠の残り"
        case "balance": return "残高"
        case "usage": return "実利用"
        case "cost": return item.estimated ? "費用（推計を含む）" : "費用"
        default: return item.label
        }
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Hermesの実利用・費用（30日）")
            sourceError(state.analytics.error, previous: state.analytics.fetchedAt)
            if let rows = state.analytics.value {
                if rows.isEmpty { empty("実利用の記録はありません。") }
                ForEach(rows) { row in
                    Divider().overlay(LAAUsageStyle.line)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: (row.provider ?? "提供元不明") + " · " + row.model)
                            .font(LAAUsageStyle.body.weight(.medium)).foregroundStyle(LAAUsageStyle.ink)
                        metric("入力", value(row.inputTokens, unit: "tokens"))
                        metric("出力", value(row.outputTokens, unit: "tokens"))
                        metric("費用・記録済み実額", row.actualCost.map { value($0, unit: "usd") } ?? "不明")
                        metric("費用・推計", value(row.estimatedCost, unit: "usd"))
                    }.padding(.vertical, 8)
                }
                if !rows.isEmpty { Divider().overlay(LAAUsageStyle.line) }
                caption("取得時刻 " + time(state.analytics.fetchedAt))
            } else if !state.isRefreshing && state.analytics.error == nil { empty("未取得") }
        }
    }

    private var macStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Mac mini")
            sourceError(state.mac.error, previous: state.mac.fetchedAt)
            if let items = state.mac.value {
                if items.isEmpty { empty("Macの状態はありません。") }
                ForEach(items) { item in
                    Divider().overlay(LAAUsageStyle.line)
                    VStack(alignment: .leading, spacing: 8) {
                        metric(item.label, item.availability == "available" ? value(item.availableValue, unit: item.unit) : unavailable(item))
                        if item.kind == "host.memory", let total = item.detail?.totalBytes, item.availableValue != nil {
                            caption("合計 " + value(total, unit: "bytes"))
                        }
                        if item.kind == "host.disk", let total = item.detail?.totalGb, item.availableValue != nil {
                            caption("合計 " + value(total, unit: "gb"))
                        }
                        itemFlags(item, retained: state.retainedMacIDs.contains(item.id))
                        caption("確認時刻 " + time(LAAUsageItem.date(item.observedAt)))
                    }.padding(.vertical, 8)
                }
                if !items.isEmpty { Divider().overlay(LAAUsageStyle.line) }
            } else if !state.isRefreshing { empty(state.mac.error == nil ? "未取得" : "利用できません。") }
        }
    }

    private func metric(_ label: String, _ result: String) -> some View {
        let isStatus = result == "未取得" || result == "不明" || result.hasPrefix("利用不可")
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: label).font(LAAUsageStyle.caption).foregroundStyle(LAAUsageStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(verbatim: result).font(isStatus ? LAAUsageStyle.caption : LAAUsageStyle.value)
                .foregroundStyle(isStatus ? LAAUsageStyle.muted : LAAUsageStyle.ink)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func itemFlags(_ item: LAAUsageItem, retained: Bool) -> some View {
        let flags = [retained ? "更新失敗・前回の値" : nil, item.stale ? "古い値" : nil,
                     item.isExpired() ? "期限切れ" : nil, item.estimated ? "推計を含む" : nil].compactMap { $0 }
        return Group {
            if !flags.isEmpty {
                Label { Text(verbatim: flags.joined(separator: "・")).fixedSize(horizontal: false, vertical: true) }
                    icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(LAAUsageStyle.caption).foregroundStyle(LAAUsageStyle.warning)
            }
        }
    }

    @ViewBuilder
    private func sourceError(_ problem: LAAUsageProblem?, previous: Date?) -> some View {
        if let problem {
            Label {
                Text(verbatim: problem.message + (previous.map { " 前回取得 " + time($0) } ?? ""))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: { Image(systemName: "exclamationmark.triangle") }
            .font(LAAUsageStyle.caption).foregroundStyle(LAAUsageStyle.warning)
            .accessibilityIdentifier("laa.usage.error")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text).font(LAAUsageStyle.caption).foregroundStyle(LAAUsageStyle.muted)
    }

    private func empty(_ text: String) -> some View { caption(text) }

    private func unavailable(_ item: LAAUsageItem) -> String {
        switch item.nullReason {
        case "not_configured": return "利用不可・未設定"
        case "fetch_failed": return "利用不可・取得失敗"
        case "unsupported": return "利用不可・未対応"
        case "auth_required": return "利用不可・認証が必要"
        default: return "利用不可"
        }
    }

    private func value(_ number: Double?, unit: String) -> String {
        guard let number, number.isFinite else { return "未取得" }
        if unit == "bytes" {
            guard number >= 0, number < Double(Int64.max) else { return "未取得" }
            return ByteCountFormatter.string(fromByteCount: Int64(number), countStyle: .memory)
        }
        let digits = number.formatted(.number.locale(locale).precision(.fractionLength(0...2)))
        switch unit {
        case "percent": return digits + "%"
        case "usd": return "$" + digits
        case "jpy": return "¥" + digits
        case "gb": return digits + " GB"
        case "credits": return digits + " credits"
        case "tokens": return digits + " tokens"
        case "count": return digits + " 回"
        default: return digits + " " + unit
        }
    }

    private func time(_ date: Date?) -> String {
        guard let date else { return "未取得" }
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.locale = locale
        style.timeZone = .autoupdatingCurrent
        return date.formatted(style)
    }

    private func refresh() async {
        guard bridge.status == .paired else { return }
        await state.refresh(usage: { try await loadPages("/v1/usage") },
                            mac: { try await loadPages("/v1/mac/status") },
                            analytics: { try await LAADashboardUsage.load(from: appState) })
    }

    private func loadPages(_ path: String) async throws -> [LAAUsageItem] {
        var items: [LAAUsageItem] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            var route = path
            if let cursor {
                var parts = URLComponents()
                parts.path = path
                parts.queryItems = [URLQueryItem(name: "cursor", value: cursor)]
                guard let encoded = parts.string else { throw LAABridgeError.invalidResponse }
                route = encoded
            }
            let page: LAAUsagePage = try await bridge.read(route)
            items.append(contentsOf: page.items)
            cursor = page.nextCursor
            if let cursor, !seen.insert(cursor).inserted || seen.count > 100 { throw LAABridgeError.invalidResponse }
        } while cursor != nil
        return items
    }
}
#endif
