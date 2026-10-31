#if LAA_BUILD
import SwiftUI
import WidgetKit

private extension LAACopy {
    static let usageConnection = "Connection"
    static let usageRefresh = "Refresh"
    static let usageConnect = "Connect to Mac"
    static let usageMore = "More"
}

struct LAAUsageView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.locale) private var locale
    @StateObject private var state: LAAUsageState
    @State private var showPairing = false
    let onRequestSettings: () -> Void
    private let automaticallyRefresh: Bool

    init(onRequestSettings: @escaping () -> Void) {
        self.onRequestSettings = onRequestSettings
        self.automaticallyRefresh = true
        _state = StateObject(wrappedValue: LAAUsageState())
    }

    #if DEBUG
    init(snapshotState: LAAUsageState, onRequestSettings: @escaping () -> Void = {}) {
        self.onRequestSettings = onRequestSettings
        self.automaticallyRefresh = false
        _state = StateObject(wrappedValue: snapshotState)
    }
    #endif

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LAAColor.background.ignoresSafeArea()
                List {
                    VStack(alignment: .leading, spacing: LAASpacing.section) {
                        header
                        if bridge.status != .paired { connectionCard }
                        else { services }
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
        .task(id: bridge.revision) {
            guard automaticallyRefresh else { return }
            let changed = state.selectScope(bridgeRevision: bridge.revision, dashboardScope: "usage")
            if changed || bridge.status != .paired { publish(nil) }
            guard bridge.status == .paired else { return }
            if changed { await state.waitUntilIdle() }
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x1) {
            Text(verbatim: "LAA").laaTextStyle(.section).fontWeight(.bold).foregroundStyle(LAAColor.link)
            HStack(alignment: .center) {
                Text(verbatim: LAACopy.tabTitle(.usage)).font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Menu {
                    if bridge.status == .paired {
                        Button { showPairing = true } label: { Text(verbatim: LAACopy.usageConnection) }
                            .accessibilityIdentifier("laa.bridge.manage")
                    }
                    Button(action: onRequestSettings) { Text(verbatim: LAACopy.settings) }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: LAASpacing.minimumTouchTarget, height: LAASpacing.minimumTouchTarget)
                        .contentShape(Circle())
                }
                .accessibilityLabel(Text(verbatim: LAACopy.usageMore))
                .accessibilityIdentifier("laa.usage.menu")
                Button { Task { await refresh() } } label: {
                    Group { if state.isRefreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") } }
                        .frame(width: LAASpacing.minimumTouchTarget, height: LAASpacing.minimumTouchTarget)
                        .background(LAAColor.surface, in: Circle())
                        .overlay(Circle().strokeBorder(LAAColor.separator))
                }
                .disabled(state.isRefreshing || bridge.status != .paired)
                .accessibilityLabel(Text(verbatim: LAACopy.usageRefresh))
                .accessibilityIdentifier("laa.usage.refresh")
            }
            Text(verbatim: "サービスごとの残り枠・残高")
                .laaTextStyle(.body).foregroundStyle(LAAColor.secondaryText)
            Text(verbatim: "最終確認 " + time(state.updatedAt))
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
                Button { showPairing = true } label: { Text(verbatim: LAACopy.usageConnect) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("laa.bridge.openPairing")
            }
        }
        .padding(LAASpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
    }

    private var services: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x4) {
            Text(verbatim: "AI Usage").laaTextStyle(.section).fontWeight(.bold)
                .foregroundStyle(LAAColor.secondaryText).accessibilityAddTraits(.isHeader)
            if let problem = state.usage.error {
                Label {
                    Text(verbatim: problem.message + (state.usage.fetchedAt.map { " 前回取得 " + time($0) } ?? ""))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: { Image(systemName: "exclamationmark.triangle") }
                .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                .accessibilityIdentifier("laa.usage.error")
            }
            if let items = state.usage.value {
                let groups = LAAUsageGroup.consoleGroups(items)
                if groups.isEmpty { caption("表示できるサービスはありません。") }
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: LAASpacing.x3) {
                        Text(verbatim: group.label).laaTextStyle(.body).fontWeight(.semibold)
                            .foregroundStyle(LAAColor.text).accessibilityAddTraits(.isHeader)
                        ForEach(group.items) { item in usageItem(item) }
                    }
                    .padding(LAASpacing.x4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
                    .accessibilityIdentifier("laa.usage.service.\(group.id)")
                }
            } else if !state.isRefreshing {
                caption(state.usage.error == nil ? "未取得" : "利用できません。")
            } else { ProgressView().accessibilityLabel("読み込み中") }
        }
    }

    @ViewBuilder
    private func usageItem(_ item: LAAUsageItem) -> some View {
        if item.availability != "available" {
            caption(unavailable(item))
        } else if item.kind == "quota", let windows = item.detail?.windows, !windows.isEmpty {
            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                meter(window, item: item)
            }
            if let credits = item.detail?.credits {
                metric("追加クレジット", value(credits.remaining, unit: "credits"))
                caption((outdated(credits.updatedAt) ? "古い値・要確認 " : "確認 ") + time(LAAUsageItem.date(credits.updatedAt)) + " · 枠の%とは別単位")
            }
            if let passes = item.detail?.resetPasses {
                metric("リセットパス", passes.available ? value(passes.remaining, unit: "count") : "利用不可")
                caption((outdated(passes.updatedAt) || (LAAUsageItem.date(passes.expiresAt).map { $0 <= Date() } ?? false) ? "要確認 · " : "") + "期限 " + time(LAAUsageItem.date(passes.expiresAt)) + " · 手動確認 " + time(LAAUsageItem.date(passes.updatedAt)))
            }
        } else if item.id == "provider.liquid.usage" {
            metric("記録済み費用", money(item.detail?.recordedCostUsd, precision: 12))
            if let count = item.detail?.recordedRequestCount { metric("API応答記録", value(count, unit: "count")) }
            caption("最新の記録 " + time(LAAUsageItem.date(item.detail?.lastRecordedAt)))
        } else if item.kind == "balance" {
            metric("残り", value(item.availableValue, unit: item.detail?.creditUnit ?? item.unit))
            if let granted = item.detail?.grantedAmount, granted > 0, let remaining = item.availableValue {
                ProgressView(value: min(max(remaining / granted, 0), 1)).tint(LAAColor.link)
                caption("付与 " + value(granted, unit: item.detail?.creditUnit ?? item.unit))
            }
            if let daily = item.detail?.dailyRemaining { metric("今日の残り", value(daily, unit: item.detail?.creditUnit ?? "credits")) }
            if let granted = item.detail?.dailyGrantedAmount { metric("今日の付与", value(granted, unit: item.detail?.creditUnit ?? "credits")) }
            if let monthly = item.detail?.monthlyGrantedAmount { metric("月間付与", value(monthly, unit: item.detail?.creditUnit ?? "credits")) }
            if let fallback = item.detail?.fallbackAiCredits { metric("AI credits", value(fallback, unit: "credits")) }
            if let diem = item.detail?.diem { metric("DIEM", value(diem, unit: "DIEM")) }
            if let usd = item.detail?.usd, item.unit != "usd" { metric("USD", value(usd, unit: "usd")) }
            if let monthly = item.detail?.monthlyRemainingPercent {
                metric("月間の残り", value(monthly, unit: "percent"))
                ProgressView(value: monthly, total: 100).tint(LAAColor.link)
            }
            ForEach(Array((item.detail?.components ?? []).enumerated()), id: \.offset) { _, component in
                metric(componentLabel(component.kind), value(component.amount, unit: item.unit))
                if let granted = component.grantedAmount { caption("付与 " + value(granted, unit: item.unit)) }
                if let expiry = component.expiresOnUtc {
                    caption((reachedUTCDate(expiry) ? "期限到来・最終取得 " : "期限 ") + expiry + " UTC")
                }
            }
        }
        flags(item)
        if let renews = LAAUsageItem.date(item.detail?.renewsAt) { caption("更新予定 " + time(renews)) }
        if let expires = item.detail?.expiresOnUtc { caption("有効期限 " + expires + " UTC") }
        if item.availability == "available" {
            caption((item.detail?.sourceKind == "verified" ? "画面確認・自動更新なし " : "データ確認 ") + time(LAAUsageItem.date(item.observedAt)))
        }
    }

    private func meter(_ window: LAAUsageItem.Window, item: LAAUsageItem) -> some View {
        let expired = LAAUsageItem.date(window.resetsAt).map { $0 <= Date() } ?? false
        return VStack(alignment: .leading, spacing: LAASpacing.x2) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: window.label).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                Spacer()
                Text(verbatim: value(window.remainingPercent, unit: "percent"))
                    .font(LAAType.usageValue).foregroundStyle(LAAColor.text)
            }
            if let remaining = window.remainingPercent, remaining.isFinite, (0...100).contains(remaining) {
                ProgressView(value: remaining, total: 100)
                    .tint(expired || past(item) ? LAAColor.attention : LAAColor.link)
                    .accessibilityLabel(Text(verbatim: item.label + " " + window.label + " 残り"))
                    .accessibilityValue(Text(verbatim: value(remaining, unit: "percent")))
            }
            caption((expired ? "リセット時刻経過・最終取得 " : "リセット ") + time(LAAUsageItem.date(window.resetsAt)))
        }
        .padding(.vertical, LAASpacing.x1)
    }

    private func past(_ item: LAAUsageItem) -> Bool {
        if item.stale || item.isExpired() || needsRenewal(item) || state.retainedUsageIDs.contains(item.id) || state.usage.error != nil { return true }
        if item.detail?.sourceKind == "verified" {
            guard let observed = LAAUsageItem.date(item.observedAt) else { return true }
            return observed.timeIntervalSinceNow > 60
        }
        guard let until = LAAUsageItem.date(item.detail?.freshUntil) else { return true }
        return until <= Date()
    }

    private func outdated(_ text: String?) -> Bool {
        guard let date = LAAUsageItem.date(text) else { return true }
        return date.timeIntervalSinceNow > 60 || Date().timeIntervalSince(date) > 20 * 60
    }

    private func reachedUTCDate(_ text: String?) -> Bool {
        guard let text, text.count == 10, let start = LAAUsageItem.date(text + "T00:00:00Z") else { return false }
        return start <= Date()
    }

    private func needsRenewal(_ item: LAAUsageItem) -> Bool {
        if LAAUsageItem.date(item.detail?.renewsAt).map({ $0 <= Date() }) == true { return true }
        if reachedUTCDate(item.detail?.expiresOnUtc) { return true }
        return (item.detail?.components ?? []).contains { $0.amount > 0 && reachedUTCDate($0.expiresOnUtc) }
    }

    @ViewBuilder private func flags(_ item: LAAUsageItem) -> some View {
        if item.availability == "available" {
            let flags = [state.retainedUsageIDs.contains(item.id) || state.usage.error != nil ? "更新失敗・前回の値" : nil,
                         item.isExpired() ? "期限切れ" : nil,
                         needsRenewal(item) && !item.isExpired() ? "期限・更新到来・要確認" : nil,
                         past(item) && !item.isExpired() && !needsRenewal(item) ? "古い値または鮮度不明" : nil].compactMap { $0 }
            if !flags.isEmpty {
                Label { Text(verbatim: flags.joined(separator: "・")) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
            }
        }
    }

    private func metric(_ label: String, _ result: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x3) {
            Text(verbatim: label).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            Spacer(minLength: LAASpacing.x2)
            Text(verbatim: result).laaTextStyle(.body).monospacedDigit().foregroundStyle(LAAColor.text)
                .multilineTextAlignment(.trailing)
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func componentLabel(_ kind: String) -> String {
        switch kind { case "monthly": return "月次付与"; case "purchased": return "購入分"; case "promotional": return "プロモーション"; default: return "内訳" }
    }

    private func unavailable(_ item: LAAUsageItem) -> String {
        switch item.nullReason {
        case "not_configured": return "利用不可・未設定"
        case "fetch_failed": return "未取得・取得失敗"
        case "unsupported": return "利用不可・未対応"
        case "auth_required": return "利用不可・認証が必要"
        default: return "未取得"
        }
    }

    private func money(_ number: Double?, precision: Int = 2) -> String {
        guard let number, number.isFinite else { return "未取得" }
        if number != 0 && abs(number) < pow(10, -Double(precision)) { return number > 0 ? "<$0.000000000001" : "未取得" }
        return "$" + number.formatted(.number.locale(locale).precision(.fractionLength(0...precision)))
    }

    private func value(_ number: Double?, unit: String) -> String {
        guard let number, number.isFinite else { return "未取得" }
        if unit == "percent", number > 0, number < 0.01 { return "<0.01%" }
        if unit == "percent", number < 100, number > 99.99 { return ">99.99%" }
        let digits = number.formatted(.number.locale(locale).precision(.fractionLength(0...(unit == "percent" ? 2 : 6))))
        let shown = number > 0 && number < 0.000001 && unit != "percent" ? "<0.000001" : digits
        switch unit {
        case "percent": return shown + "%"
        case "usd": return shown.hasPrefix("<") ? "<$0.000001" : "$" + shown
        case "jpy": return shown.hasPrefix("<") ? "<¥0.000001" : "¥" + shown
        case "credits": return shown + " credits"
        case "count": return shown + " 回"
        default: return shown + " " + unit
        }
    }

    private func time(_ date: Date?) -> String {
        guard let date else { return "未取得" }
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.locale = locale; style.timeZone = .autoupdatingCurrent
        return date.formatted(style)
    }

    private func publish(_ snapshot: WidgetUsageSnapshot?) {
        guard let store = WidgetSnapshotStore.production else { return }
        do { if try store.writeUsage(snapshot) { WidgetCenter.shared.reloadTimelines(ofKind: ConduitWidgetKind.employee) } }
        catch { /* The last valid widget snapshot remains intact. */ }
    }

    private func refresh() async {
        guard bridge.status == .paired else { return }
        await state.refreshUsage { try await loadPages() }
        guard !Task.isCancelled, bridge.status == .paired else { return }
        if let items = state.usage.value {
            publish(LAAWidgetUsageBuilder.make(items: items, retained: state.retainedUsageIDs,
                                               failed: state.usage.error != nil, checkedAt: state.usage.fetchedAt))
        } else if state.usage.error != nil, let old = WidgetSnapshotStore.production?.read()?.usage {
            let meters = old.meters.map { meter in
                WidgetUsageMeter(id: meter.id, label: meter.label, remainingPercent: meter.remainingPercent,
                                 observedAt: meter.observedAt, freshUntil: meter.freshUntil, resetsAt: meter.resetsAt,
                                 stale: meter.stale, retained: true)
            }
            publish(WidgetUsageSnapshot(meters: meters, checkedAt: old.checkedAt))
        }
    }

    private func loadPages() async throws -> [LAAUsageItem] {
        var items: [LAAUsageItem] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            var parts = URLComponents(); parts.path = "/v1/usage"
            if let cursor { parts.queryItems = [URLQueryItem(name: "cursor", value: cursor)] }
            guard let route = parts.string else { throw LAABridgeError.invalidResponse }
            let page: LAAUsagePage = try await bridge.read(route)
            items.append(contentsOf: page.items)
            cursor = page.nextCursor
            if let cursor, !seen.insert(cursor).inserted || seen.count > 100 { throw LAABridgeError.invalidResponse }
        } while cursor != nil
        return items
    }
}
#endif
