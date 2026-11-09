#if LAA_BUILD
import SwiftUI
import Combine

private extension LAACopy {
    static let usageConnection = "Connection"
    static let usageRefresh = "Refresh"
    static let usageConnect = "Connect to Mac"
    static let usageMore = "More"
    static let usageOpenService = "Open service"
    static let usageBilling = "Check billing"
}

struct LAAUsageView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.laaDesktop) private var laaDesktop
    @Environment(\.locale) private var locale
    @ObservedObject private var state: LAAUsageState
    @State private var showPairing = false
    @State private var evaluatedAt = Date()
    @State private var showsUnconnected = false
    private let automaticallyRefresh: Bool
    /// Work shows Usage inside its own bar, which already carries Settings.
    private let showsSettingsButton: Bool
    let onRequestSettings: () -> Void
    init(state: LAAUsageState, showsSettingsButton: Bool = true, onRequestSettings: @escaping () -> Void) {
        self.onRequestSettings = onRequestSettings
        self.automaticallyRefresh = true
        self.showsSettingsButton = showsSettingsButton
        _state = ObservedObject(wrappedValue: state)
    }

    #if DEBUG
    init(snapshotState: LAAUsageState, onRequestSettings: @escaping () -> Void = {}) {
        self.onRequestSettings = onRequestSettings
        self.automaticallyRefresh = false
        self.showsSettingsButton = true
        _state = ObservedObject(wrappedValue: snapshotState)
    }
    #endif

    /// The Mac page: three cards at the grid's minimum, centred. A fourth
    /// column would squeeze each card's meter and its numbers, so the measure
    /// is three card widths plus their gaps, plus the page's own insets.
    private static var desktopWidth: CGFloat {
        LAADesktopMetrics.gridItemMinWidth * 3 + LAASpacing.x6 * 2 + LAASpacing.x8 * 2
    }

    var body: some View {
        Group {
            if laaDesktop { desktopBody } else { phoneBody }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { evaluatedAt = $0 }
        .tint(LAAColor.link)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // The phone hides the bar's paper; on the Mac the window's own toolbar
        // keeps the system look (rules: 標準のガラスを潰さない).
        .toolbarBackground(laaDesktop ? .automatic : .hidden, for: .navigationBar)
        .toolbar {
            if showsSettingsButton {
                ToolbarItem(placement: .topBarTrailing) { LAASettingsButton(action: onRequestSettings) }
            }
        }
        .sheet(isPresented: $showPairing) {
            LAAPairingView().environmentObject(bridge).laaSheetSize(.form)
        }
        .onAppear {
            guard automaticallyRefresh else { return }
            state.setPresented(true)
        }
        .task(id: bridge.revision) {
            guard automaticallyRefresh else { return }
            await state.refreshOnTabOpen(bridge: bridge)
        }
        .onDisappear { if automaticallyRefresh { state.setPresented(false) } }
    }

    // MARK: Phone

    private var phoneBody: some View {
        GeometryReader { geometry in
            ZStack {
                LAAColor.background.ignoresSafeArea()
                List {
                    VStack(alignment: .leading, spacing: LAASpacing.section) {
                        header
                        if bridge.status != .paired { connectionCard }
                        else {
                            feedError
                            capacity
                            services
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
    }

    // MARK: Mac

    /// The Mac page keeps the phone's order of information but puts the
    /// services in a card grid and gives the page one centred measure.
    private var desktopBody: some View {
        ZStack {
            LAAColor.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: LAASpacing.section) {
                    header
                    if bridge.status != .paired { connectionCard }
                    else {
                        feedError
                        servicesGrid
                        capacity
                    }
                }
                .padding(.horizontal, LAASpacing.x8)
                .padding(.top, LAASpacing.x6)
                .padding(.bottom, LAASpacing.x8)
                .laaReadableWidth(Self.desktopWidth)
            }
            .refreshable { await refresh() }
        }
        .accessibilityIdentifier("laa.usage.desktop")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x1) {
            Text(verbatim: "LAA").laaTextStyle(.section).fontWeight(.bold).foregroundStyle(LAAColor.link)
            HStack(alignment: .center) {
                Text(verbatim: LAACopy.tabTitle(.usage)).font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if bridge.status == .paired {
                    Menu {
                        Button { showPairing = true } label: { Text(verbatim: LAACopy.usageConnection) }
                            .accessibilityIdentifier("laa.bridge.manage")
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: LAASpacing.minimumTouchTarget, height: LAASpacing.minimumTouchTarget)
                            .contentShape(Circle())
                    }
                    .accessibilityLabel(Text(verbatim: LAACopy.usageMore))
                    .macTooltip(LAACopy.usageMore)
                    .accessibilityIdentifier("laa.usage.menu")
                }
                Button { Task { await refresh() } } label: {
                    Group { if state.isRefreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") } }
                        .frame(width: LAASpacing.minimumTouchTarget, height: LAASpacing.minimumTouchTarget)
                        .background(laaDesktop ? Color.clear : LAAColor.surface, in: Circle())
                        .overlay {
                            if !laaDesktop { Circle().strokeBorder(LAAColor.separator) }
                        }
                        .contentShape(Circle())
                }
                // The button only re-reads the feed. Borderless keeps the List
                // row from claiming the tap, so no other control can fire.
                .buttonStyle(.borderless)
                .disabled(state.isRefreshing || bridge.status != .paired)
                .accessibilityLabel(Text(verbatim: LAACopy.usageRefresh))
                .macTooltip(LAACopy.usageRefresh)
                .accessibilityIdentifier("laa.usage.refresh")
            }
            Text(verbatim: "更新時刻のあるAI利用枠と容量")
                .laaTextStyle(.body).foregroundStyle(LAAColor.secondaryText)
            Text(verbatim: "更新 " + time(state.updatedAt))
                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                .accessibilityIdentifier("laa.usage.updated")
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            Label { Text(verbatim: LAACopy.notConnected) } icon: { Image(systemName: "circle") }
                .foregroundStyle(LAAColor.secondaryText)
            Text(verbatim: bridge.status == .revoked || bridge.status == .unauthorized
                 ? "この端末の接続が無効になりました。新しいコードで接続してください。"
                 : bridge.status == .keychainError ? LAABridgeError.keychain.japaneseText : LAACopy.bridgeNotPairedBody)
                .foregroundStyle(LAAColor.text)
            if bridge.status != .keychainError {
                Button { showPairing = true } label: { Text(verbatim: LAACopy.usageConnect) }
                    .laaGlassButton(prominent: true)
                    .accessibilityIdentifier("laa.bridge.openPairing")
            }
        }
        .padding(LAASpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
    }

    // MARK: Services

    /// The phone's list: one card per provider, in the order the console sends.
    private var services: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x4) {
            servicesHeading
            if let items = state.usage.value {
                let groups = LAAUsageGroup.consoleGroups(items)
                if groups.isEmpty { caption("表示できるサービスはありません。") }
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: LAASpacing.x3) {
                        groupHeader(group)
                        if group.items.isEmpty { caption("残量を取得できません。") }
                        ForEach(group.items) { item in usageItem(item) }
                        serviceLink(group)
                    }
                    .padding(LAASpacing.x4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
                    .accessibilityIdentifier("laa.usage.service.\(group.id)")
                }
            } else if !state.isRefreshing {
                caption(state.usage.error == nil ? LAACopy.notFetched : "利用できません。")
                ForEach(LAAWidgetUsageBuilder.slots, id: \.provider) { slot in
                    let group = LAAUsageGroup(id: "provider.\(slot.provider)", label: slot.name, items: [])
                    if let url = group.serviceURL {
                        Link(destination: url) { Text(verbatim: group.label) }
                            .laaTextStyle(.body)
                            .frame(minHeight: LAASpacing.minimumTouchTarget)
                            .accessibilityIdentifier("laa.usage.open.\(group.id)")
                    }
                }
            } else { ProgressView().accessibilityLabel(Text(verbatim: LAACopy.loading)) }
        }
    }

    /// The Mac's card grid; each card divides its own rows with hairlines.
    private var servicesGrid: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x4) {
            servicesHeading
            if let items = state.usage.value {
                let groups = LAAUsageGroup.consoleGroups(items)
                if groups.isEmpty {
                    caption("表示できるサービスはありません。")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: LAADesktopMetrics.gridItemMinWidth),
                                             spacing: LAASpacing.x6, alignment: .top)],
                          alignment: .leading, spacing: LAASpacing.x6) {
                    ForEach(groups) { group in serviceCard(group) }
                }
            } else if !state.isRefreshing {
                caption(state.usage.error == nil ? LAACopy.notFetched : "利用できません。")
                HStack(spacing: LAASpacing.x4) {
                    ForEach(LAAWidgetUsageBuilder.slots, id: \.provider) { slot in
                        let group = LAAUsageGroup(id: "provider.\(slot.provider)", label: slot.name, items: [])
                        if let url = group.serviceURL {
                            Link(destination: url) { Text(verbatim: group.label) }
                                .laaTextStyle(.body)
                                .frame(minHeight: LAASpacing.minimumTouchTarget)
                                .accessibilityIdentifier("laa.usage.open.\(group.id)")
                        }
                    }
                }
            } else { ProgressView().accessibilityLabel(Text(verbatim: LAACopy.loading)) }
        }
    }

    private var servicesHeading: some View {
        Text(verbatim: "AI").laaTextStyle(.section).fontWeight(.bold)
            .foregroundStyle(LAAColor.secondaryText).accessibilityAddTraits(.isHeader)
    }

    private func groupHeader(_ group: LAAUsageGroup) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x2) {
            Text(verbatim: group.label).laaTextStyle(.body).fontWeight(.semibold)
                .foregroundStyle(LAAColor.text).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let warning = groupWarning(group) {
                Text(verbatim: warning).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    @ViewBuilder private func serviceLink(_ group: LAAUsageGroup) -> some View {
        if let url = LAAUsageGroup.billingURL(for: Self.apiBalanceID(group.id)) {
            Link(destination: url) { Text(verbatim: LAACopy.usageBilling) }
                .laaTextStyle(.secondary)
                .frame(minHeight: LAASpacing.minimumTouchTarget)
                .accessibilityIdentifier("laa.usage.billing.\(group.id)")
        } else if let url = group.serviceURL,
                  group.items.contains(where: { $0.availability != "available" || past($0) }) {
            Link(destination: url) { Text(verbatim: LAACopy.usageOpenService) }
                .laaTextStyle(.secondary)
                .frame(minHeight: LAASpacing.minimumTouchTarget)
                .accessibilityIdentifier("laa.usage.open.\(group.id)")
        }
    }

    private func serviceCard(_ group: LAAUsageGroup) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            groupHeader(group)
            if group.items.isEmpty {
                caption("残量を取得できません。")
            } else {
                VStack(alignment: .leading, spacing: LAASpacing.x3) {
                    ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Rectangle().fill(LAAColor.separator).frame(height: 1) }
                        usageItem(item)
                    }
                }
            }
            serviceLink(group)
        }
        .padding(LAASpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
        .accessibilityIdentifier("laa.usage.service.\(group.id)")
    }

    @ViewBuilder private var feedError: some View {
        if let problem = state.usage.error {
            Label {
                Text(verbatim: problem.message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: { Image(systemName: "exclamationmark.triangle") }
            .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
            .accessibilityIdentifier("laa.usage.error")
        }
    }

    /// Memory and storage, apart from the AI services: one card, rows divided
    /// by hairlines, and the shape of each mark carries its state.
    private var capacity: some View {
        let items = LAACapacity.items(state.usage.value ?? [])
        let shown = items.filter { !LAACapacity.isUnconnected($0) }
        let unconnected = items.filter(LAACapacity.isUnconnected)
        return VStack(alignment: .leading, spacing: LAASpacing.x3) {
            HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x2) {
                Text(verbatim: "容量").laaTextStyle(.section).fontWeight(.bold)
                    .foregroundStyle(LAAColor.secondaryText).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Text(verbatim: "● 取得済み　▲ 要確認　○ 未取得")
                    .laaTextStyle(.section).foregroundStyle(LAAColor.secondaryText)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .accessibilityLabel(Text(verbatim: "凡例 取得済みは●、要確認は▲、未取得は○"))
            }
            VStack(alignment: .leading, spacing: 0) {
                if shown.isEmpty && unconnected.isEmpty {
                    caption(state.isRefreshing ? LAACopy.loading : LAACopy.notFetched)
                        .padding(.vertical, LAASpacing.x3)
                }
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Rectangle().fill(LAAColor.separator).frame(height: 1) }
                    capacityRow(item)
                }
                if !unconnected.isEmpty {
                    if !shown.isEmpty { Rectangle().fill(LAAColor.separator).frame(height: 1) }
                    DisclosureGroup(isExpanded: $showsUnconnected) {
                        VStack(alignment: .leading, spacing: LAASpacing.x1) {
                            ForEach(unconnected) { item in
                                caption("○ " + LAACapacity.name(item.id) + " · 取得経路なし")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, LAASpacing.x2)
                    } label: {
                        Text(verbatim: "○ 未接続 " + unconnected.map { LAACapacity.name($0.id) }.joined(separator: "・"))
                            .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    .frame(minHeight: LAASpacing.minimumTouchTarget)
                    .accessibilityIdentifier("laa.capacity.unconnected")
                }
            }
            .padding(.horizontal, LAASpacing.x4)
            .padding(.vertical, LAASpacing.x1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
        }
        .accessibilityIdentifier("laa.capacity")
    }

    @ViewBuilder
    private func capacityRow(_ item: LAAUsageItem) -> some View {
        let reading = LAACapacity.reading(item, at: evaluatedAt)
        let name = LAACapacity.name(item.id)
        let alert = reading.map { $0.level == .warning || $0.level == .critical } ?? false
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x2) {
                Text(verbatim: reading == nil ? "○" : alert ? "▲" : "●")
                    .laaTextStyle(.secondary)
                    .foregroundStyle(alert ? LAAColor.attention : reading == nil ? LAAColor.secondaryText : LAAColor.link)
                    .accessibilityHidden(true)
                Text(verbatim: name).laaTextStyle(.body).fontWeight(.semibold).foregroundStyle(LAAColor.text)
                Spacer(minLength: LAASpacing.x2)
                Text(verbatim: reading.map { "空き " + LAACapacity.bytes($0.availableBytes, locale: locale) } ?? capacityMissing(item))
                    .laaTextStyle(.body).monospacedDigit()
                    .foregroundStyle(alert ? LAAColor.attention : reading == nil ? LAAColor.secondaryText : LAAColor.text)
                    .multilineTextAlignment(.trailing)
            }
            if item.id == "capacity.google-drive" { caption("Drive・Gmail・フォトの共有容量") }
            if let reading {
                capacityMeter(reading, alert: alert)
                    .accessibilityLabel(Text(verbatim: name + " 使用量"))
                    .accessibilityValue(Text(verbatim: capacityAccessibility(reading)))
                if let warning = capacityWarning(reading, item: item) {
                    Text(verbatim: warning).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                }
                caption("使用 " + LAACapacity.bytes(reading.usedBytes, locale: locale) + " / "
                        + LAACapacity.bytes(reading.totalBytes, locale: locale)
                        + " · 取得 " + clockTime(LAAUsageItem.date(item.observedAt)))
            } else if item.availability == "available" {
                caption("最終取得 " + time(LAAUsageItem.date(item.observedAt)))
            }
        }
        .padding(.vertical, LAASpacing.x3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("laa.capacity.\(item.id)")
    }

    /// Used bytes on the screen's one meter; the tick marks where the warning threshold begins.
    private func capacityMeter(_ reading: LAACapacityReading, alert: Bool) -> some View {
        LAAUsageMeter(fraction: reading.usedFraction, alert: alert, tick: reading.warningFraction,
                      showsSliver: reading.usedBytes > 0)
    }

    private func capacityWarning(_ reading: LAACapacityReading, item: LAAUsageItem) -> String? {
        if item.id == "capacity.google-drive" {
            if reading.usedBytes >= reading.totalBytes { return "▲ 容量の上限に達しています" }
            if reading.level == .critical { return "▲ 容量の98%以上を使用" }
            if reading.level == .warning { return "▲ 容量の90%以上を使用" }
        }
        switch reading.level {
        case .critical: return "▲ 危険 · 空き " + (reading.criticalFreeBytes.map { LAACapacity.bytes($0, locale: locale) } ?? "") + " 未満"
        case .warning: return "▲ 要確認 · 空き " + (reading.warningFreeBytes.map { LAACapacity.bytes($0, locale: locale) } ?? "") + " 未満"
        case .normal, .recorded: return nil
        }
    }

    private func capacityAccessibility(_ reading: LAACapacityReading) -> String {
        let level = switch reading.level { case .normal: "正常"; case .recorded: "取得済み"; case .warning: "要確認"; case .critical: "危険" }
        return level + "、空き " + LAACapacity.bytes(reading.availableBytes, locale: locale)
            + "、使用 " + LAACapacity.bytes(reading.usedBytes, locale: locale)
            + "、合計 " + LAACapacity.bytes(reading.totalBytes, locale: locale)
    }

    private func capacityMissing(_ item: LAAUsageItem) -> String {
        if item.availability == "available" { return "更新待ち" }
        switch item.nullReason {
        case "auth_required": return "認証が必要"
        case "unsupported": return "未接続"
        default: return "未取得"
        }
    }

    /// The API group's billing page, keyed by the group's provider id.
    static func apiBalanceID(_ groupID: String) -> String {
        ["provider.openai-api", "provider.claude-api"].contains(groupID) ? groupID + ".balance" : ""
    }

    @ViewBuilder
    private func usageItem(_ item: LAAUsageItem) -> some View {
        let warning = past(item)
        if item.availability == "available", item.kind == "balance", item.detail?.sourceKind == "verified" {
            metric("残り", value(item.availableValue, unit: "usd"), prominent: true)
            caption("請求画面の確認値 · 確認 " + time(LAAUsageItem.date(item.observedAt)))
        } else if item.availability != "available" || warning {
            caption(item.availability == "available" ? "更新待ち・取得できません" : Self.unavailable(item))
        } else if item.kind == "quota", let windows = item.detail?.windows, !windows.isEmpty {
            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                meter(window, item: item)
            }
            if let credits = item.detail?.credits {
                if outdated(credits.updatedAt) { caption("追加クレジットは取得待ち") }
                else {
                    metric("追加クレジット", value(credits.remaining, unit: "credits"))
                    caption("取得 " + clockTime(LAAUsageItem.date(credits.updatedAt)) + " · 枠の%とは別単位")
                }
            }
        } else if item.id == "provider.liquid.usage" {
            metric("記録済み費用", money(item.detail?.recordedCostUsd, precision: 12), warning: warning, prominent: true)
            if let input = item.detail?.models?.first?.inputTokens { metric("記録済み入力", value(input, unit: "tokens"), warning: warning) }
            if let output = item.detail?.models?.first?.outputTokens { metric("記録済み出力", value(output, unit: "tokens"), warning: warning) }
            if let count = item.detail?.recordedRequestCount { metric("API応答記録", value(count, unit: "count"), warning: warning) }
            caption("最新の記録 " + time(LAAUsageItem.date(item.detail?.lastRecordedAt)))
        } else if item.kind == "balance" {
            metric("残り", value(item.availableValue, unit: item.detail?.creditUnit ?? item.unit), warning: warning, prominent: true)
            if let granted = item.detail?.grantedAmount, granted > 0, let remaining = item.availableValue {
                LAAUsageMeter(fraction: remaining / granted, alert: warning)
                    .accessibilityLabel(Text(verbatim: item.label + " 残り"))
                    .accessibilityValue(Text(verbatim: value(min(max(remaining / granted, 0), 1) * 100, unit: "percent")))
                caption("付与 " + value(granted, unit: item.detail?.creditUnit ?? item.unit))
            }
            if let daily = item.detail?.dailyRemaining { metric("今日の残り", value(daily, unit: item.detail?.creditUnit ?? "credits"), warning: warning) }
            if let granted = item.detail?.dailyGrantedAmount { metric("今日の付与", value(granted, unit: item.detail?.creditUnit ?? "credits"), warning: warning) }
            if let monthly = item.detail?.monthlyGrantedAmount { metric("月間付与", value(monthly, unit: item.detail?.creditUnit ?? "credits"), warning: warning) }
            if let fallback = item.detail?.fallbackAiCredits { metric("AI credits", value(fallback, unit: "credits"), warning: warning) }
            if let usd = item.detail?.usd, item.unit != "usd" { metric("USD", value(usd, unit: "usd"), warning: warning) }
            if let monthly = item.detail?.monthlyRemainingPercent {
                metric("月間の残り", value(monthly, unit: "percent"), warning: warning)
                LAAUsageMeter(fraction: monthly / 100, alert: warning)
                    .accessibilityLabel(Text(verbatim: item.label + " 月間の残り"))
                    .accessibilityValue(Text(verbatim: value(monthly, unit: "percent")))
            }
            ForEach(Array((item.detail?.components ?? []).enumerated()), id: \.offset) { _, component in
                metric(componentLabel(component.kind), value(component.amount, unit: item.id == "provider.venice.balance" ? "credits" : item.unit), warning: warning || reachedUTCDate(component.expiresOnUtc))
                if let granted = component.grantedAmount { caption("付与 " + value(granted, unit: item.unit)) }
                if let expiry = component.expiresOnUtc {
                    caption((reachedUTCDate(expiry) ? "期限到来・最終取得 " : "期限 ") + expiry + " UTC")
                }
            }
        }
        if item.availability == "available" && !warning && item.detail?.sourceKind != "verified" {
            flags(item)
            if let renews = LAAUsageItem.date(item.detail?.renewsAt) { caption("更新予定 " + time(renews)) }
            if let expires = item.detail?.expiresOnUtc { caption("有効期限 " + expires + " UTC") }
            caption("取得 " + clockTime(LAAUsageItem.date(item.observedAt)))
        }
    }

    private func meter(_ window: LAAUsageItem.Window, item: LAAUsageItem) -> some View {
        let expired = LAAUsageFreshness.windowExpired(window, at: evaluatedAt)
        let stale = past(item)
        return VStack(alignment: .leading, spacing: LAASpacing.x2) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: LAASpacing.x1) {
                    // One window needs no name: the card already says which service it is.
                    if (item.detail?.windows?.count ?? 0) > 1 {
                        Text(verbatim: windowLabel(window)).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    }
                    if expired || stale {
                        Text(verbatim: expired ? "リセット時刻経過" : "更新待ち")
                            .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                    }
                }
                Spacer()
                Text(verbatim: expired || stale ? "未取得" : value(window.remainingPercent, unit: "percent"))
                    .font(LAAType.usageValue).foregroundStyle(expired || stale ? LAAColor.attention : LAAColor.text)
            }
            if !expired && !stale, let remaining = window.remainingPercent, remaining.isFinite, (0...100).contains(remaining) {
                LAAUsageMeter(fraction: remaining / 100, alert: false)
                    .accessibilityLabel(Text(verbatim: item.label + " " + windowLabel(window) + " 残り"))
                    .accessibilityValue(Text(verbatim: value(remaining, unit: "percent")))
            }
            caption((expired ? "リセット時刻経過・最終取得 " : "リセット ") + time(LAAUsageItem.date(window.resetsAt)))
        }
        .padding(.vertical, LAASpacing.x1)
    }

    private func past(_ item: LAAUsageItem) -> Bool {
        LAAUsageFreshness.isPast(item, at: evaluatedAt)
    }

    private func outdated(_ text: String?) -> Bool {
        LAAUsageFreshness.outdated(text, at: evaluatedAt)
    }

    private func reachedUTCDate(_ text: String?) -> Bool {
        LAAUsageFreshness.reachedUTCDate(text, at: evaluatedAt)
    }

    private func needsRenewal(_ item: LAAUsageItem) -> Bool {
        LAAUsageFreshness.needsRenewal(item, at: evaluatedAt)
    }

    @ViewBuilder private func flags(_ item: LAAUsageItem) -> some View {
        if item.availability == "available" {
            let expiredWindow = item.kind == "quota" && (item.detail?.windows ?? []).contains { LAAUsageFreshness.windowExpired($0, at: evaluatedAt) }
            let flags = [expiredWindow ? "一部の枠がリセット済み" : nil,
                         item.kind != "quota" && item.isExpired(now: evaluatedAt) ? "期限切れ" : nil,
                         needsRenewal(item) ? "追加項目・期限を要確認" : nil,
                         LAAUsageFreshness.isStale(item, at: evaluatedAt) ? "古い値・取得時刻が不明" : nil].compactMap { $0 }
            if !flags.isEmpty {
                Label { Text(verbatim: flags.joined(separator: "・")) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
            }
        }
    }

    private func groupWarning(_ group: LAAUsageGroup) -> String? {
        if group.items.contains(where: { LAAUsageFreshness.isStale($0, at: evaluatedAt) && $0.availability == "available" && $0.detail?.sourceKind != "verified" }) { return "更新待ち" }
        if group.items.contains(where: { $0.kind == "quota" && ($0.detail?.windows ?? []).contains { LAAUsageFreshness.windowExpired($0, at: evaluatedAt) } }) { return "一部の枠がリセット済み" }
        if group.items.contains(where: { $0.availability == "available" && ($0.isExpired(now: evaluatedAt) || needsRenewal($0)) }) { return "期限・追加項目 要確認" }
        if group.items.contains(where: { $0.availability == "available" && $0.detail?.sourceKind != "verified" && $0.detail?.freshUntil == nil }) { return "古い値・未取得は目安です" }
        return nil
    }

    private func windowLabel(_ window: LAAUsageItem.Window) -> String {
        LAAUsageLabel.window(window)
    }

    private func metric(_ label: String, _ result: String, warning: Bool = false, prominent: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x3) {
            Text(verbatim: label).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            Spacer(minLength: LAASpacing.x2)
            Group {
                if prominent {
                    Text(verbatim: result).font(LAAType.usageValue).lineLimit(1).minimumScaleFactor(0.6)
                } else {
                    Text(verbatim: result).laaTextStyle(.body).monospacedDigit()
                }
            }
            .foregroundStyle(warning ? LAAColor.attention : LAAColor.text)
            .multilineTextAlignment(.trailing)
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func componentLabel(_ kind: String) -> String {
        switch kind { case "DIEM": return "DIEM"; case "BUNDLED_CREDITS": return "Bundled credits"; case "monthly": return "月次付与"; case "purchased": return "購入分"; case "promotional": return "プロモーション"; default: return "内訳" }
    }

    static func unavailable(_ item: LAAUsageItem) -> String {
        switch item.nullReason {
        case "not_configured": return item.kind == "cost" ? "管理者キー未設定" : "利用不可・未設定"
        case "not_auto": return "自動取得なし"
        case "freshness_unknown": return "使用額を確認できません"
        case "fetch_failed": return "未取得・取得失敗"
        case "unsupported": return "利用不可・未対応"
        case "auth_required": return "利用不可・認証が必要"
        default: return "未取得"
        }
    }

    private func money(_ number: Double?, precision: Int = 2) -> String {
        guard let number, number.isFinite else { return "未取得" }
        if number != 0 && abs(number) < pow(10, -Double(precision)) { return number > 0 ? "<$0.000000000001" : "未取得" }
        return "$" + number.formatted(.number.locale(locale).precision(.fractionLength(2...precision)))
    }

    private func value(_ number: Double?, unit: String) -> String {
        guard let number, number.isFinite else { return "未取得" }
        if unit == "percent", number > 0, number < 0.01 { return "<0.01%" }
        if unit == "percent", number < 100, number > 99.99 { return ">99.99%" }
        let digits = number.formatted(.number.locale(locale).precision(.fractionLength((unit == "usd" ? 2 : 0)...(unit == "percent" ? 2 : 6))))
        let shown = number > 0 && number < 0.000001 && unit != "percent" ? "<0.000001" : digits
        switch unit {
        case "percent": return shown + "%"
        case "usd":
            if shown.hasPrefix("-") { return "-$" + shown.dropFirst() }
            return shown.hasPrefix("<") ? "<$0.000001" : "$" + shown
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

    private func clockTime(_ date: Date?) -> String {
        guard let date else { return "未取得" }
        let calendar = Calendar.autoupdatingCurrent
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    private func clockTimeJST(_ date: Date?) -> String {
        guard let date else { return "未取得" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 60 * 60)!
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    private func refresh() async {
        await state.refreshAndPublish(bridge: bridge)
    }
}

/// The Usage screen's one meter: AI limits, balances and storage share its
/// track, height and colors, so every bar on the screen reads the same. The
/// threshold tick is drawn over the track rather than laid out with it: it was
/// the extra height of that tick that made the rows with a mark twice as thick.
struct LAAUsageMeter: View {
    /// 0...1; values outside are clamped.
    let fraction: Double
    var alert = false
    /// Where a threshold begins, drawn as a short tick across the track.
    var tick: Double? = nil
    /// A nonzero amount keeps a sliver visible even when it rounds to nothing.
    var showsSliver = true

    static let height: CGFloat = 8
    /// Tall enough for the tick, which stands 3pt above and below the track.
    static let totalHeight: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let clamped = fraction.isFinite ? min(max(fraction, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(LAAColor.subtleSurface).frame(height: Self.height)
                Capsule().fill(alert ? LAAColor.attention : LAAColor.link)
                    .frame(width: max(width * clamped, showsSliver && clamped > 0 ? Self.height : 0),
                           height: Self.height)
            }
            .frame(width: width, height: Self.height)
            .frame(maxHeight: .infinity, alignment: .center)
            .overlay(alignment: .leading) {
                if let tick, tick > 0, tick < 1 {
                    Capsule().fill(LAAColor.secondaryText.opacity(0.55))
                        .frame(width: 2, height: Self.totalHeight)
                        .offset(x: width * tick - 1)
                }
            }
        }
        .frame(height: Self.totalHeight)
        .accessibilityElement()
    }
}
#endif
