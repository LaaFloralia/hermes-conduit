#if LAA_BUILD
import SwiftUI
import Combine

extension LAACopy {
    enum Usage {
        static let noAutomaticBalance = "自動取得できる残高がありません"
        static let billingReading = "請求画面の確認値"
        static let noBalanceLeft = "残高なし"
        static let granted = "付与"
        static let toppedUp = "補充後"
        static let left = "残り"
        static let meter = "利用枠"
        static let lowestWeekly = "週間の残りが最も少ない枠"
    }
}

/// The refresh glyph, turning while a read is in flight (still with Reduce
/// Motion, where it stays put and only the label changes).
struct LAARefreshGlyph: View {
    let spinning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Double = 0

    var body: some View {
        Image(systemName: "arrow.clockwise")
            .font(.system(size: 13, weight: .bold))
            .rotationEffect(.degrees(angle))
            .onChange(of: spinning, initial: true) { _, now in
                guard now, !reduceMotion else { withAnimation(.easeOut(duration: 0.2)) { angle = 0 }; return }
                angle = 0
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { angle = 360 }
            }
    }
}

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

    /// The title, the age of the last reading, and the refresh as a button
    /// that looks like one (owner, 2026-11-11: "今すぐ更新" had disappeared into
    /// the age text, which nobody reads as pressable).
    private var header: some View {
        HStack(alignment: .center, spacing: LAASpacing.x3) {
            Text(verbatim: "Usage").font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: state.updatedAt.map { LAAUsageAge.text($0, at: evaluatedAt) } ?? "—")
                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                .monospacedDigit()
                .accessibilityLabel(Text(verbatim: "最終取得"))
                .accessibilityValue(state.updatedAt.map { LAAUsageAge.text($0, at: evaluatedAt) } ?? "未取得")
                .accessibilityIdentifier("laa.usage.updated")
            Spacer(minLength: 0)
            refreshButton
        }
    }

    private var refreshButton: some View {
        Button { Task { await refresh() } } label: {
            HStack(spacing: 6) {
                LAARefreshGlyph(spinning: state.isRefreshing)
                Text(verbatim: state.isRefreshing ? "更新中" : "今すぐ更新")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(state.isRefreshing ? LAAColor.secondaryText : LAAColor.link)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .conduitGlassControl(cornerRadius: 18, tint: LAAColor.link.opacity(state.isRefreshing ? 0 : 0.08),
                                 interactive: !state.isRefreshing)
            .contentShape(Capsule())
            .frame(minHeight: LAASpacing.minimumTouchTarget)
        }
        .buttonStyle(.plain)
        .disabled(state.isRefreshing || bridge.status != .paired)
        .opacity(bridge.status == .paired ? 1 : 0.45)
        .accessibilityLabel(Text(verbatim: "今すぐ更新"))
        .accessibilityValue(state.updatedAt.map { LAAUsageAge.text($0, at: evaluatedAt) } ?? "—")
        .accessibilityIdentifier("laa.usage.refresh")
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
                            if LAAUsageGroup.isAPI(group.id + ".") {
                                apiBalanceRow(group.items.first { $0.id == group.id + ".balance" },
                                              groupID: group.id, name: group.label)
                            } else if group.items.isEmpty {
                                readingRow(name: group.label, result: LAACopy.notFetched, age: nil, fraction: nil, note: nil)
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
                           fraction: window.remainingPercent.map { $0 / 100 }, countsDown: true,
                           note: item.retainedReason.map { Self.unavailableReason($0) }
                               ?? (reset ? "リセット済み" : LAAUsageItem.date(window.resetsAt).map { resetTime($0) }))
            }
        } else {
            let amount = item.kind == "usage" ? item.detail?.recordedCostUsd : item.availableValue
            let unit = item.kind == "usage" ? "usd" : item.detail?.creditUnit ?? item.unit
            let granted = item.kind == "usage" ? nil : item.detail?.grantedAmount ?? item.detail?.monthlyGrantedAmount
            // A money balance counts down from its level after the last
            // top-up; a credit grant from the grant.
            let money = item.kind == "balance" && unit == "usd"
            let fraction = money ? LAAUsageMeterRule.balanceFraction(remaining: amount, granted: granted)
                : LAAUsageMeterRule.grantFraction(remaining: amount, granted: granted)
            readingRow(name: name, result: value(amount, unit: unit), age: age, fraction: fraction, countsDown: true,
                       note: reason(item) ?? (item.kind == "usage" ? "記録済み費用" : grantNote(granted, fraction: fraction, money: money)))
        }
    }

    /// What a meter counts down from, so the bar has a scale: a credit grant,
    /// or a balance's level after its last top-up.
    private func grantNote(_ granted: Double?, fraction: Double?, money: Bool = false) -> String? {
        guard let granted, let fraction else { return nil }
        let total = money ? LAAUsageMoney.text(granted, locale: locale)
            : granted.formatted(.number.locale(locale).precision(.fractionLength(0...2)))
        let left = (fraction * 100).formatted(.number.locale(locale).precision(.fractionLength(0)))
        return (money ? LAACopy.Usage.toppedUp : LAACopy.Usage.granted) + " " + total + " · " + LAACopy.Usage.left + " " + left + "%"
    }

    /// GPT API and Claude API: the credit left, never the spend. Neither
    /// provider publishes a balance API, so the reading is the billing page's,
    /// carried with the moment it was checked; without one the row still
    /// stands, reads 未取得 and links to that page.
    @ViewBuilder private func apiBalanceRow(_ item: LAAUsageItem?, groupID: String, name: String) -> some View {
        let billing = LAAUsageGroup.billingURL(for: groupID + ".balance")
        if let item, let amount = item.availableValue {
            let checked = item.detail?.sourceKind == "verified"
                ? LAAUsageItem.date(item.observedAt).map { LAACopy.Usage.billingReading + " " + LAADateText.string($0, .monthDayTime) }
                : nil
            let empty = !(amount > 0)
            // The meter the other rows draw: what is left since the last
            // top-up, and an empty bar when nothing is.
            let granted = item.detail?.grantedAmount
            let fraction = LAAUsageMeterRule.balanceFraction(remaining: amount, granted: granted)
            let parts = [item.retainedReason.map { Self.unavailableReason($0) }, empty ? LAACopy.Usage.noBalanceLeft : nil,
                         empty ? nil : grantNote(granted, fraction: fraction, money: true), checked]
            let note = parts.compactMap { $0 }.joined(separator: " · ")
            readingRow(name: name, result: value(amount, unit: "usd"), age: age(item), fraction: fraction, countsDown: true,
                       note: note.isEmpty ? nil : note, noteLink: billing, alert: empty)
        } else {
            let note = item.map { $0.nullReason == "not_auto" || $0.nullReason == nil ? LAACopy.Usage.noAutomaticBalance : Self.unavailable($0) }
                ?? LAACopy.Usage.noAutomaticBalance
            readingRow(name: name, result: LAACopy.notFetched, age: nil, fraction: nil, note: note, noteLink: billing)
        }
    }

    private var storage: some View {
        let items = LAACapacity.items(state.usage.value ?? [])
        return VStack(alignment: .leading, spacing: LAASpacing.x2) {
            sectionTitle("Storage")
            VStack(spacing: 0) {
                if items.isEmpty {
                    readingRow(name: "容量", result: LAACopy.notFetched, age: nil, fraction: nil, note: nil)
                }
                ForEach(items) { item in
                    let reading = LAACapacity.reading(item, at: evaluatedAt, allowHistorical: true)
                    let result = reading.map { "空き " + LAACapacity.bytes($0.availableBytes, locale: locale) } ?? LAACopy.notFetched
                    let note = reason(item) ?? reading.map {
                        "使用 " + LAACapacity.bytes($0.usedBytes, locale: locale) + " / " + LAACapacity.bytes($0.totalBytes, locale: locale)
                    }
                    readingRow(name: LAACapacity.name(item.id), result: result, age: age(item),
                               fraction: reading?.usedFraction, tick: reading?.warningFraction, note: note,
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

    private func readingRow(name: String, result: String, age: String?, fraction: Double?, countsDown: Bool = false,
                            tick: Double? = nil, note: String?, noteLink: URL? = nil, alert: Bool = false) -> some View {
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
                LAAUsageMeter(fraction: fraction, countsDown: countsDown, alert: alert, tick: tick)
                    .accessibilityLabel(name + " " + LAACopy.Usage.meter)
                    .accessibilityValue(result)
            }
            if let note {
                let text = Text(verbatim: note).laaTextStyle(.secondary)
                    .foregroundStyle(alert ? LAAColor.attention : LAAColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let noteLink {
                    Link(destination: noteLink) {
                        HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x1) {
                            text
                            Image(systemName: "arrow.up.right").font(.caption2.weight(.semibold))
                                .foregroundStyle(LAAColor.secondaryText).accessibilityHidden(true)
                        }
                        .frame(minHeight: LAASpacing.minimumTouchTarget / 2, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("laa.usage.billing")
                } else {
                    text
                }
            }
        }
        .padding(.vertical, LAASpacing.x3)
        .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumTouchTarget, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func readingValue(_ result: String, age: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x1) {
            let parts = result.hasSuffix(" credits") ? result.split(separator: " ", maxSplits: 1) : [result[...]]
            let missing = result == LAACopy.notFetched || result == LAACopy.never
            Text(verbatim: String(parts[0]))
                .font(missing ? .system(size: 15) : LAAType.usageRowValue)
                .foregroundStyle(missing ? LAAColor.secondaryText : LAAColor.text)
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
        guard let number, number.isFinite else { return LAACopy.notFetched }
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
///
/// The bar follows the reading: it grows to its value when the row appears and
/// slides to each new value a refresh brings, and its colour says whether the
/// value needs a look. A quota or a credit grant counts down (`countsDown`),
/// so it turns to the attention colour below a fifth left; storage counts up
/// and turns past nine tenths used or at its warning level (`alert`).
struct LAAUsageMeter: View {
    /// 0...1; values outside are clamped.
    let fraction: Double
    /// True for a share left (quotas, credits); false for a share used.
    var countsDown = false
    var alert = false
    /// Where a threshold begins, drawn as a short tick across the track.
    var tick: Double? = nil
    /// A nonzero amount keeps a sliver visible even when it rounds to nothing.
    var showsSliver = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    static let height: CGFloat = 4
    /// Tall enough for the tick, which stands 3pt above and below the track.
    static let totalHeight: CGFloat = 10

    private var clamped: Double { fraction.isFinite ? min(max(fraction, 0), 1) : 0 }
    var needsAttention: Bool { alert || LAAUsageMeterRule.needsAttention(clamped, countsDown: countsDown) }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let drawn = appeared || reduceMotion ? clamped : 0
            ZStack(alignment: .leading) {
                Capsule().fill(LAAColor.subtleSurface).frame(height: Self.height)
                Capsule().fill(needsAttention ? LAAColor.attention : LAAColor.link)
                    .frame(width: max(width * drawn, showsSliver && clamped > 0 ? Self.height : 0),
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
        // Grows to its value once, then slides between readings; Reduce
        // Motion draws each value in place.
        .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: clamped)
        .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: needsAttention)
        .onAppear {
            guard !appeared else { return }
            if reduceMotion { appeared = true } else { withAnimation(.easeOut(duration: 0.35)) { appeared = true } }
        }
    }
}
#endif
