#if LAA_BUILD
import SwiftUI

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
                LAAColor.background.ignoresSafeArea()
                List {
                    VStack(alignment: .leading, spacing: LAASpacing.section) {
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
                    .padding(.horizontal, geometry.size.width < 360 ? LAASpacing.compactHorizontal : LAASpacing.horizontal)
                    .padding(.top, LAASpacing.x4)
                    .padding(.bottom, LAASpacing.x8)
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
        .tint(LAAColor.link)
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
        VStack(alignment: .leading, spacing: LAASpacing.x1) {
            Text(verbatim: "LAA")
                .laaTextStyle(.section).fontWeight(.bold).foregroundStyle(LAAColor.link)
            HStack(alignment: .center) {
                Text(verbatim: "Usage")
                    .font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
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
                        .frame(width: LAASpacing.minimumTouchTarget, height: LAASpacing.minimumTouchTarget)
                        .contentShape(Circle())
                }
                .accessibilityLabel(Text(verbatim: "その他の操作"))
                .accessibilityIdentifier("laa.usage.menu")
                Button { Task { await refresh() } } label: {
                    Group {
                        if state.isRefreshing { ProgressView() }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .frame(width: LAASpacing.minimumTouchTarget, height: LAASpacing.minimumTouchTarget)
                    .background(LAAColor.surface, in: Circle())
                    .overlay(Circle().strokeBorder(LAAColor.separator))
                }
                .disabled(state.isRefreshing || bridge.status != .paired)
                .accessibilityLabel(Text(verbatim: "使用状況を更新"))
                .accessibilityIdentifier("laa.usage.refresh")
            }
            Text(verbatim: "サービスごとの使用状況")
                .laaTextStyle(.body).foregroundStyle(LAAColor.secondaryText)
            Text(verbatim: "最終更新 " + time(state.updatedAt))
                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                .accessibilityIdentifier("laa.usage.updated")
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            Label { Text(verbatim: "未接続") } icon: { Image(systemName: "circle") }
                .foregroundStyle(LAAColor.secondaryText)
            Text(verbatim: bridge.status == .revoked || bridge.status == .unauthorized
                 ? "この端末の接続が無効になりました。新しいコードで接続してください。"
                 : bridge.status == .keychainError ? LAABridgeError.keychain.japaneseText : LAACopy.bridgeNotPairedBody)
                .foregroundStyle(LAAColor.text)
            if bridge.status != .keychainError {
                Button { showPairing = true } label: { Text(verbatim: "Macに接続する") }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("laa.bridge.openPairing")
            }
        }
        .padding(LAASpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(verbatim: title).laaTextStyle(.section).fontWeight(.bold).foregroundStyle(LAAColor.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }

    private func overviewCard(_ overview: LAAUsageOverview) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            sectionTitle("概要")
            VStack(alignment: .leading, spacing: LAASpacing.x3) {
                Text(verbatim: overview.label + " · " + overview.window)
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                HStack(alignment: .center, spacing: LAASpacing.x4) {
                    Text(verbatim: value(overview.remainingPercent, unit: "percent"))
                        .font(LAAType.usageValue).foregroundStyle(LAAColor.text)
                    Spacer(minLength: LAASpacing.x2)
                    ProgressView(value: overview.remainingPercent, total: 100)
                        .tint(LAAColor.link)
                        .frame(maxWidth: 130)
                        .accessibilityLabel(Text(verbatim: "残りの利用枠"))
                        .accessibilityValue(Text(verbatim: value(overview.remainingPercent, unit: "percent")))
                }
                Text(verbatim: "利用枠の残り · 確認時刻 " + time(overview.observedAt))
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                if overview.stale || overview.expired || state.retainedUsageIDs.contains(overview.itemID) {
                    Label { Text(verbatim: overview.expired ? "期限切れ" : "古い値・前回の値") }
                        icon: { Image(systemName: "exclamationmark.triangle") }
                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                }
            }
            .padding(LAASpacing.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
        }
    }

    private var services: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            sectionTitle("サービス別")
            sourceError(state.usage.error, previous: state.usage.fetchedAt)
            if let items = state.usage.value {
                if items.isEmpty { empty("表示できるサービスはありません。") }
                ForEach(LAAUsageGroup.groups(items)) { group in
                    Divider().overlay(LAAColor.separator)
                    VStack(alignment: .leading, spacing: LAASpacing.x2) {
                        Text(verbatim: group.label).laaTextStyle(.body).fontWeight(.medium)
                            .foregroundStyle(LAAColor.text)
                        ForEach(group.items) { item in
                            usageItem(item, retained: state.retainedUsageIDs.contains(item.id))
                        }
                    }
                    .padding(.vertical, LAASpacing.x2)
                    .accessibilityIdentifier("laa.usage.service.\(group.id)")
                }
                if !items.isEmpty { Divider().overlay(LAAColor.separator) }
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
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
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
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            sectionTitle("Hermesの実利用・費用（30日）")
            sourceError(state.analytics.error, previous: state.analytics.fetchedAt)
            if let rows = state.analytics.value {
                if rows.isEmpty { empty("実利用の記録はありません。") }
                ForEach(rows) { row in
                    Divider().overlay(LAAColor.separator)
                    VStack(alignment: .leading, spacing: LAASpacing.x2) {
                        Text(verbatim: (row.provider ?? "提供元不明") + " · " + row.model)
                            .laaTextStyle(.body).fontWeight(.medium).foregroundStyle(LAAColor.text)
                        metric("入力", value(row.inputTokens, unit: "tokens"))
                        metric("出力", value(row.outputTokens, unit: "tokens"))
                        metric("費用・記録済み実額", row.actualCost.map { value($0, unit: "usd") } ?? "不明")
                        metric("費用・推計", value(row.estimatedCost, unit: "usd"))
                    }.padding(.vertical, LAASpacing.x2)
                }
                if !rows.isEmpty { Divider().overlay(LAAColor.separator) }
                caption("取得時刻 " + time(state.analytics.fetchedAt))
            } else if !state.isRefreshing && state.analytics.error == nil { empty("未取得") }
        }
    }

    private var macStatus: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            sectionTitle("Mac mini")
            sourceError(state.mac.error, previous: state.mac.fetchedAt)
            if let items = state.mac.value {
                if items.isEmpty { empty("Macの状態はありません。") }
                ForEach(items) { item in
                    Divider().overlay(LAAColor.separator)
                    VStack(alignment: .leading, spacing: LAASpacing.x2) {
                        metric(item.label, item.availability == "available" ? value(item.availableValue, unit: item.unit) : unavailable(item))
                        if item.kind == "host.memory", let total = item.detail?.totalBytes, item.availableValue != nil {
                            caption("合計 " + value(total, unit: "bytes"))
                        }
                        if item.kind == "host.disk", let total = item.detail?.totalGb, item.availableValue != nil {
                            caption("合計 " + value(total, unit: "gb"))
                        }
                        itemFlags(item, retained: state.retainedMacIDs.contains(item.id))
                        caption("確認時刻 " + time(LAAUsageItem.date(item.observedAt)))
                    }.padding(.vertical, LAASpacing.x2)
                }
                if !items.isEmpty { Divider().overlay(LAAColor.separator) }
            } else if !state.isRefreshing { empty(state.mac.error == nil ? "未取得" : "利用できません。") }
        }
    }

    private func metric(_ label: String, _ result: String) -> some View {
        let isStatus = result == "未取得" || result == "不明" || result.hasPrefix("利用不可")
        return HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x3) {
            Text(verbatim: label).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: LAASpacing.x2)
            Text(verbatim: result).laaTextStyle(isStatus ? .secondary : .body).monospacedDigit()
                .foregroundStyle(isStatus ? LAAColor.secondaryText : LAAColor.text)
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
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
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
            .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
            .accessibilityIdentifier("laa.usage.error")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
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
