#if LAA_BUILD
import SwiftUI
import Combine

/// A standalone screen: refreshing never replaces an observation with a loader.
struct LAAUsageView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.laaDesktop) private var laaDesktop
    @Environment(\.dismiss) private var dismiss
    private let locale = LAADateText.locale
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var state: LAAUsageState
    @State private var showPairing = false
    @State private var evaluatedAt = Date()
    private let automaticallyRefresh: Bool

    init(state: LAAUsageState, showsSettingsButton: Bool = true, onRequestSettings: @escaping () -> Void = {}) {
        automaticallyRefresh = true
        _state = ObservedObject(wrappedValue: state)
    }

    #if DEBUG
    init(snapshotState: LAAUsageState, onRequestSettings: @escaping () -> Void = {}) {
        automaticallyRefresh = false
        _state = ObservedObject(wrappedValue: snapshotState)
    }
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.section) {
                header
                if bridge.status != .paired {
                    connection
                } else {
                    feedError
                    services
                    storage
                }
            }
            .padding(.horizontal, LAASpacing.x5)
            .padding(.top, LAASpacing.x4)
            .padding(.bottom, LAASpacing.x8)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(LAAColor.background.ignoresSafeArea())
        .tint(LAAColor.link)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(laaDesktop ? .automatic : .hidden, for: .navigationBar)
        .toolbar {
            if !laaDesktop { LAABackToolbar(action: { dismiss() }) }
        }
        .navigationBarBackButtonHidden(!laaDesktop)
        .refreshable { await refresh() }
        .sheet(isPresented: $showPairing) {
            LAAPairingView().environmentObject(bridge).laaSheetSize(.form)
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { evaluatedAt = $0 }
        .onChange(of: state.updatedAt) { _, _ in evaluatedAt = Date() }
        .onAppear { if automaticallyRefresh { state.setPresented(true) } }
        .onDisappear { if automaticallyRefresh { state.setPresented(false) } }
        .task(id: "\(bridge.revision)|\(scenePhase == .active)") {
            guard automaticallyRefresh, scenePhase == .active else { return }
            evaluatedAt = Date()
            await state.refreshWhileVisible(bridge: bridge)
        }
        .accessibilityIdentifier(laaDesktop ? "laa.usage.desktop" : "laa.usage")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x3) {
            Text(verbatim: "Usage").font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
                .accessibilityAddTraits(.isHeader)
            Button { Task { await refresh() } } label: {
                Text(verbatim: state.updatedAt.map { LAAUsageAge.text($0, at: evaluatedAt) } ?? "—")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    .frame(minWidth: LAASpacing.minimumTouchTarget, minHeight: LAASpacing.minimumTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(state.isRefreshing || bridge.status != .paired)
            .accessibilityLabel(Text(verbatim: "更新"))
            .accessibilityValue(state.updatedAt.map { LAAUsageAge.text($0, at: evaluatedAt) } ?? "—")
            .accessibilityIdentifier("laa.usage.refresh")
            Spacer(minLength: 0)
        }
    }

    private var connection: some View {
        HStack(spacing: LAASpacing.x3) {
            Text(verbatim: bridge.status == .revoked || bridge.status == .unauthorized
                 ? "接続が無効になりました" : "Macに接続していません")
                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            Spacer(minLength: 0)
            Button { showPairing = true } label: { Text(verbatim: "接続") }
                .frame(minHeight: LAASpacing.minimumTouchTarget)
                .accessibilityIdentifier("laa.bridge.openPairing")
        }
    }

    @ViewBuilder private var feedError: some View {
        if let problem = state.usage.error {
            HStack(spacing: LAASpacing.x3) {
                Text(verbatim: problem.japaneseText)
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                    .accessibilityIdentifier("laa.usage.error")
                Spacer(minLength: 0)
                Button { Task { await refresh() } } label: { Text(verbatim: "再試行") }
                    .frame(minWidth: LAASpacing.minimumTouchTarget, minHeight: LAASpacing.minimumTouchTarget)
                    .disabled(state.isRefreshing)
            }
        }
    }

    private var groups: [LAAUsageGroup] {
        let reported = LAAUsageGroup.consoleGroups(state.usage.value ?? [])
        return LAAWidgetUsageBuilder.slots.map { slot in
            reported.first(where: { $0.id == "provider.\(slot.provider)" })
                ?? LAAUsageGroup(id: "provider.\(slot.provider)", label: slot.name, items: [])
        }
    }

    private var services: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            sectionTitle("AI")
            VStack(spacing: 0) {
                if state.usage.value == nil && state.isRefreshing {
                    LAALoadingDots()
                } else {
                    ForEach(groups) { group in
                        VStack(spacing: 0) {
                            if group.items.isEmpty {
                                readingRow(name: group.label, result: "—", age: nil, fraction: nil, note: nil)
                            } else {
                                ForEach(group.items) { item in serviceRow(item, name: group.label) }
                            }
                        }
                        .accessibilityIdentifier("laa.usage.service.\(group.id)")
                    }
                }
            }

        }
    }

    @ViewBuilder private func serviceRow(_ item: LAAUsageItem, name: String) -> some View {
        let age = age(item)
        if item.availability == "available", item.kind == "quota", let windows = item.detail?.windows, !windows.isEmpty {
            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                let label = windows.count > 1 ? name + " " + LAAUsageLabel.window(window) : name
                let reset = LAAUsageFreshness.windowExpired(window, at: evaluatedAt)
                readingRow(name: label, result: value(window.remainingPercent, unit: "percent"), age: age,
                           fraction: window.remainingPercent.map { $0 / 100 },
                           note: item.retainedReason.map { Self.unavailableReason($0) }
                               ?? (reset ? "リセット済み" : LAAUsageItem.date(window.resetsAt).map { resetTime($0) }))
            }
        } else {
            let amount = item.kind == "usage" ? item.detail?.recordedCostUsd : item.availableValue
            let unit = item.kind == "usage" ? "usd" : item.detail?.creditUnit ?? item.unit
            let fraction = item.detail?.grantedAmount.flatMap { granted in
                granted > 0 ? amount.map { $0 / granted } : nil
            }
            readingRow(name: name, result: value(amount, unit: unit), age: age, fraction: fraction,
                       note: reason(item) ?? (item.kind == "usage" ? "記録済み費用" : nil))
        }
    }

    private var storage: some View {
        let items = LAACapacity.items(state.usage.value ?? [])
        return VStack(alignment: .leading, spacing: LAASpacing.x2) {
            sectionTitle("Storage")
            VStack(spacing: 0) {
                if items.isEmpty {
                    readingRow(name: "容量", result: "—", age: nil, fraction: nil, note: nil)
                }
                ForEach(items) { item in
                    let reading = LAACapacity.reading(item, at: evaluatedAt, allowHistorical: true)
                    let result = reading.map { "空き " + LAACapacity.bytes($0.availableBytes, locale: locale) } ?? "—"
                    let note = reason(item) ?? reading.map {
                        "使用 " + LAACapacity.bytes($0.usedBytes, locale: locale) + " / " + LAACapacity.bytes($0.totalBytes, locale: locale)
                    }
                    readingRow(name: LAACapacity.name(item.id), result: result, age: age(item),
                               fraction: reading?.usedFraction, note: note,
                               alert: reading.map { $0.level == .warning || $0.level == .critical } ?? false)
                        .accessibilityIdentifier("laa.capacity.\(item.id)")
                }
            }

        }
        .accessibilityIdentifier("laa.capacity")
    }

    private func sectionTitle(_ text: String) -> some View {
        LAASectionHeader(text)
    }

    private func readingRow(name: String, result: String, age: String?, fraction: Double?, note: String?, alert: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x2) {
                    Text(verbatim: name).font(.body).foregroundStyle(LAAColor.text)
                    Spacer(minLength: LAASpacing.x2)
                    readingValue(result, age: age)
                }
                VStack(alignment: .leading, spacing: LAASpacing.x1) {
                    Text(verbatim: name).font(.body).foregroundStyle(LAAColor.text)
                    readingValue(result, age: age)
                }
            }
            if let fraction, fraction.isFinite {
                LAAUsageMeter(fraction: fraction, alert: alert)
                    .accessibilityLabel(name + " 利用枠")
                    .accessibilityValue(result)
            }
            if let note {
                Text(verbatim: note).laaTextStyle(.secondary).foregroundStyle(alert ? LAAColor.attention : LAAColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, LAASpacing.x3)
        .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumTouchTarget, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func readingValue(_ result: String, age: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x1) {
            let parts = result.hasSuffix(" credits") ? result.split(separator: " ", maxSplits: 1) : [result[...]]
            Text(verbatim: String(parts[0]))
                .font(result == "—" ? .system(size: 15) : LAAType.usageRowValue)
                .foregroundStyle(result == "—" ? LAAColor.secondaryText : LAAColor.text)
            if parts.count > 1 {
                Text(verbatim: String(parts[1])).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
            if let age { Text(verbatim: age).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText) }
        }
    }

    private func age(_ item: LAAUsageItem) -> String? {
        guard LAAUsageFreshness.isPast(item, at: evaluatedAt), let observed = LAAUsageItem.date(item.observedAt) else { return nil }
        return LAAUsageAge.text(observed, at: evaluatedAt)
    }

    private func reason(_ item: LAAUsageItem) -> String? {
        if let reason = item.retainedReason { return Self.unavailableReason(reason, kind: item.kind) }
        if item.availability != "available" { return Self.unavailable(item) }
        if item.kind != "quota", item.isExpired(now: evaluatedAt) { return "期限切れ" }
        return nil
    }

    private func resetTime(_ date: Date) -> String {
        LAADateText.string(date, .weekday) + " " + LAADateText.string(date, .time) + "に戻る"
    }

    private func refresh() async {
        await state.refreshAndPublish(bridge: bridge)
        evaluatedAt = Date()
    }

    static func unavailable(_ item: LAAUsageItem) -> String {
        unavailableReason(item.nullReason, kind: item.kind)
    }

    static func unavailableReason(_ reason: String?, kind: String = "") -> String {
        switch reason {
        case "not_configured": return kind == "cost" ? "管理者キー未設定" : "利用不可・未設定"
        case "not_auto": return "自動取得なし"
        case "freshness_unknown": return "使用額を確認できません"
        case "fetch_failed": return "取得できません"
        case "unsupported": return "取得経路なし"
        case "auth_required": return "認証が必要"
        default: return "未取得"
        }
    }

    private func value(_ number: Double?, unit: String) -> String {
        guard let number, number.isFinite else { return "—" }
        if unit == "usd" { return LAAUsageMoney.text(number, locale: locale) }
        if unit == "percent", number > 0, number < 0.01 { return "<0.01%" }
        if unit == "percent", number < 100, number > 99.99 { return ">99.99%" }
        let digits = number.formatted(.number.locale(locale).precision(.fractionLength(0...(unit == "percent" ? 2 : 6))))
        let shown = number > 0 && number < 0.000001 && unit != "percent" ? "<0.000001" : digits
        switch unit {
        case "percent": return shown + "%"
        case "jpy": return shown.hasPrefix("<") ? "<¥0.000001" : "¥" + shown
        case "credits": return shown + " credits"
        case "count": return shown + " 回"
        default: return shown + " " + unit
        }
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

    static let height: CGFloat = 4
    /// Tall enough for the tick, which stands 3pt above and below the track.
    static let totalHeight: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let clamped = fraction.isFinite ? min(max(fraction, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(LAAColor.subtleSurface).frame(height: Self.height)
                Capsule().fill(alert || clamped >= 0.9 ? LAAColor.attention : LAAColor.link)
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
