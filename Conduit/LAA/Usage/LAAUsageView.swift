#if LAA_BUILD
import SwiftUI
import Combine
import LAAKit

extension LAACopy {
    enum Usage {
        static let expires = "Expires"
        static let lapsed = "Expired"
        static let lowestWeekly = "Lowest weekly allowance"
        static let inUse = "Active"
        static let expanded = "Expanded"
        static let collapsed = "Collapsed"
        static let others = "Others"
        static let accounts = "Accounts"
        static let updated = "Updated"
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
    @Environment(\.laaThemeID) private var themeID
    @Environment(\.dismiss) private var dismiss
    private let locale = LAADateText.locale
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var state: LAAUsageState
    @State private var showPairing = false
    @State private var evaluatedAt = Date()
    /// Grouped services the owner opened (`provider.google-ai-pro`, and
    /// `others` for the folded rows below the cards), kept across launches.
    @AppStorage("laa.usage.expandedGroups") private var expandedGroups = ""
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
        .laaTheme(themeID)
        .background(LAAColor.background.ignoresSafeArea())
        .tint(LAAColor.link)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(laaDesktop ? .automatic : .hidden, for: .navigationBar)
        .toolbar {
            if !laaDesktop {
                ToolbarItem(placement: .topBarLeading) {
                    LAAToolbarIconButton(systemName: "chevron.left", label: "Back", identifier: "BackButton",
                                         tint: LAAColor.text, action: { dismiss() })
                }
            }
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
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: LAASpacing.x3) {
                usageTitle.fixedSize()
                Spacer(minLength: 0)
                refreshButton.fixedSize()
            }
            VStack(alignment: .leading, spacing: 0) {
                usageTitle
                refreshButton.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var usageTitle: some View {
        Text(verbatim: "Usage").laaTextStyle(.title).foregroundStyle(LAAColor.text)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(state.updatedAt == nil ? "" : LAACopy.Usage.updated)
            .accessibilityIdentifier("laa.usage.updated")
    }

    private var refreshButton: some View {
        Button { Task { await refresh() } } label: {
            HStack(spacing: LAASpace.s4) {
                if state.isRefreshing { LAARefreshGlyph(spinning: true) }
                Text(verbatim: "Sync").laaTextStyle(.body).fontWeight(.medium)
            }
            .foregroundStyle(state.isRefreshing || bridge.status != .paired ? LAAColor.secondaryText : LAAColor.link)
            .frame(minWidth: LAASpacing.minimumTouchTarget, minHeight: LAASpacing.minimumTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.isRefreshing || bridge.status != .paired)
        .accessibilityValue(state.isRefreshing ? AppLocalization.string("Syncing") : "")
        .accessibilityIdentifier("laa.usage.refresh")
    }

    private var connection: some View {
        HStack(spacing: LAASpacing.x3) {
            Text(verbatim: bridge.status == .revoked || bridge.status == .unauthorized
                 ? "接続が無効です。Macと再接続してください。" : "Macとの接続が必要です。「Connect」から設定してください。")
                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            Spacer(minLength: 0)
            Button { showPairing = true } label: { Text(verbatim: "Connect") }
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
                Button { Task { await refresh() } } label: { Text(verbatim: "Retry") }
                    .frame(minWidth: LAASpacing.minimumTouchTarget, minHeight: LAASpacing.minimumTouchTarget)
                    .disabled(state.isRefreshing)
            }
        }
    }

    private var groups: [LAAUsageGroup] {
        let reported = LAAUsageGroup.consoleGroups(state.usage.value ?? [])
        return LAAWidgetUsageBuilder.otherSlots.map { slot in
            reported.first(where: { $0.id == "provider.\(slot.provider)" })
                ?? LAAUsageGroup(id: "provider.\(slot.provider)", label: slot.name, items: [])
        }
    }

    private func isOpen(_ id: String) -> Bool { expandedGroups.split(separator: ",").contains { $0 == id } }

    private func toggle(_ id: String) {
        var open = Set(expandedGroups.split(separator: ",").map(String.init))
        if open.contains(id) { open.remove(id) } else { open.insert(id) }
        withAnimation(.smooth(duration: 0.25)) { expandedGroups = open.sorted().joined(separator: ",") }
    }

    /// The provider cards in one column (Codex, Claude, Google, Muse), then
    /// the other services folded into ruled rows below them.
    private var services: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.usage.value == nil && state.isRefreshing {
                LAALoadingDots()
            } else {
                let items = state.usage.value ?? []
                ForEach(LAAWidgetUsageBuilder.cardSlots, id: \.provider) { slot in
                    if slot.reading == .accountGroup {
                        accountCard(slot, accounts: LAAUsageCardModel.accounts(items, group: slot.provider))
                    } else {
                        let item = LAAUsageCardModel.item(slot.provider, in: items)
                        LAAUsageProviderCard(provider: slot.provider, name: slot.name,
                                             windows: LAAUsageCardModel.windows(provider: slot.provider, item: item, now: evaluatedAt),
                                             note: item.flatMap(age), now: evaluatedAt) { EmptyView() }
                    }
                }
                others
            }
        }
    }

    /// Google and Muse: the account in use (the one the feed marks active),
    /// its windows with their resets. Accounts are never averaged and no
    /// address is shown; opening the card lists every account's windows.
    @ViewBuilder private func accountCard(_ slot: LAAWidgetUsageBuilder.Slot, accounts: [LAAUsageItem]) -> some View {
        let id = "provider.\(slot.provider)"
        let open = isOpen(id)
        let active = LAAWidgetUsageBuilder.activeAccount(accounts)
        let note = active.map { account in
            LAAUsageCardModel.accountName(account) + (age(account).map { " · " + $0 } ?? "")
        }
        LAAUsageProviderCard(provider: slot.provider, name: slot.name,
                             windows: LAAUsageCardModel.windows(provider: slot.provider, item: active, now: evaluatedAt),
                             note: note, now: evaluatedAt) {
            if !accounts.isEmpty {
                Button { toggle(id) } label: {
                    Image(systemName: "chevron.down")
                        .laaTextStyle(.note).fontWeight(.semibold).foregroundStyle(LAAColor.secondaryText)
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .frame(width: 32, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: slot.name + " " + LAACopy.Usage.accounts))
                .accessibilityValue(Text(verbatim: open ? LAACopy.Usage.expanded : LAACopy.Usage.collapsed))
                .accessibilityIdentifier("laa.usage.group.\(id)")
            }
        } extra: {
            if open {
                ForEach(accounts) { account in
                    VStack(alignment: .leading, spacing: 8) {
                        Rectangle().fill(LAAColor.separator).frame(height: 1)
                        HStack(spacing: LAASpacing.x2) {
                            Text(verbatim: LAAUsageCardModel.accountName(account))
                                .laaTextStyle(.body).fontWeight(.medium).foregroundStyle(LAAColor.text)
                            if account.active == true {
                                Text(verbatim: LAACopy.Usage.inUse).laaTextStyle(.note).foregroundStyle(LAAColor.link)
                            }
                            Spacer(minLength: 0)
                            if let age = age(account) {
                                Text(verbatim: age).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                            }
                        }
                        LAAUsageWindowGrid(windows: LAAUsageCardModel.windows(provider: slot.provider, item: account, now: evaluatedAt),
                                           now: evaluatedAt)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("laa.usage.account.\(account.id)")
                }
            }
        }
    }

    /// OpenCode, Magnific, the API balances, Liquid AI and Venice: folded
    /// under one ruled header below the cards. A row that needs a look
    /// marks the closed header with ▲.
    @ViewBuilder private var others: some View {
        let open = isOpen("others")
        let groups = self.groups
        VStack(alignment: .leading, spacing: 0) {
            Button { toggle("others") } label: {
                HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x2) {
                    Text(verbatim: LAACopy.Usage.others).laaTextStyle(.body).foregroundStyle(LAAColor.text)
                    if !open, groups.contains(where: needsLook) {
                        LAAUsageMeterMark(level: .caution).laaTextStyle(.note)
                    }
                    Spacer(minLength: LAASpacing.x2)
                    Image(systemName: "chevron.down")
                        .laaTextStyle(.note).fontWeight(.semibold).foregroundStyle(LAAColor.secondaryText)
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.vertical, LAASpacing.x3)
                .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumTouchTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: LAACopy.Usage.others))
            .accessibilityValue(Text(verbatim: (open ? LAACopy.Usage.expanded : LAACopy.Usage.collapsed)
                                     + (!open && groups.contains(where: needsLook) ? ", attention" : "")))
            .accessibilityIdentifier("laa.usage.others")
            if open {
                ForEach(groups) { group in
                    VStack(spacing: 0) {
                        Rectangle().fill(LAAColor.separator).frame(height: 1)
                        if LAAUsageGroup.isAPI(group.id + ".") {
                            apiBalanceRow(group.items.first { $0.id == group.id + ".balance" },
                                          groupID: group.id, name: group.label)
                        } else if group.items.isEmpty {
                            readingRow(name: group.label, result: nil, age: nil, fraction: nil, note: nil)
                        } else {
                            ForEach(group.items) { item in serviceRow(item, name: group.label) }
                        }
                    }
                    .accessibilityIdentifier("laa.usage.service.\(group.id)")
                }
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(LAAColor.separator).frame(height: 1) }
        .padding(.top, LAASpacing.x2)
    }

    /// A folded row worth opening for: an empty or lapsed balance, or a
    /// quota window under a quarter left.
    private func needsLook(_ group: LAAUsageGroup) -> Bool {
        group.items.contains { item in
            if item.kind == "quota" {
                return item.availability == "available" && item.ordinaryWindows.contains {
                    [.caution, .critical].contains(LAAUsageBarLevel(remainingPercent: $0.remainingPercent))
                }
            }
            guard item.kind == "balance", item.id.hasSuffix(".balance"), let amount = item.availableValue else { return false }
            return !(amount > 0) || item.isExpired(now: evaluatedAt)
        }
    }

    @ViewBuilder private func serviceRow(_ item: LAAUsageItem, name: String) -> some View {
        let age = age(item)
        if item.availability == "available", item.kind == "quota", let windows = item.detail?.windows, !windows.isEmpty {
            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                let label = windows.count > 1 ? name + " " + LAAUsageLabel.period(window) : name
                let remaining = LAAUsageFreshness.windowExpired(window, at: evaluatedAt) ? nil : window.remainingPercent
                readingRow(name: label, result: value(remaining, unit: "percent"), age: age,
                           fraction: remaining.map { $0 / 100 }, note: remaining == nil ? nil :
                               LAAUsageItem.date(window.resetsAt).map { LAAUsageResetText.full($0, now: evaluatedAt) })
            }
        } else {
            let amount = item.isExpired(now: evaluatedAt) ? nil
                : (item.kind == "usage" ? item.detail?.recordedCostUsd : item.availableValue)
            let unit = item.kind == "usage" ? "usd" : item.detail?.creditUnit ?? item.unit
            let granted = item.kind == "usage" ? nil : item.detail?.grantedAmount ?? item.detail?.monthlyGrantedAmount
            // A money balance counts down from its level after the last
            // top-up; a credit grant from the grant.
            let money = item.kind == "balance" && unit == "usd"
            let fraction = money ? LAAUsageMeterRule.balanceFraction(remaining: amount, granted: granted)
                : LAAUsageMeterRule.grantFraction(remaining: amount, granted: granted)
            readingRow(name: name, result: value(amount, unit: unit), age: age,
                       fraction: fraction, note: nil)
        }
    }

    /// The day a credit lapses, as its billing page names it
    /// (a UTC date). Nil for anything that is not such a date.
    static func expiryNote(_ text: String?) -> String? {
        guard let text, text.count == 10 else { return nil }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, let month = parts[1], let day = parts[2], parts[0] != nil,
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        return LAACopy.Usage.expires + " \(month)/\(day)"
    }

    /// GPT API and Claude API: the credit left, never the spend. Neither
    /// provider publishes a balance API, so the reading is the billing page's,
    /// so the row has an empty meter until a reading has been recorded.
    @ViewBuilder private func apiBalanceRow(_ item: LAAUsageItem?, groupID: String, name: String) -> some View {
        let billing = LAAUsageGroup.billingURL(for: groupID + ".balance")
        let lapsed = item?.isExpired(now: evaluatedAt) == true
        let amount = lapsed ? nil : item?.availableValue
        let fraction = LAAUsageMeterRule.balanceFraction(remaining: amount, granted: item?.detail?.grantedAmount)
        readingRow(name: name, result: value(amount, unit: "usd"), age: item.flatMap(age), fraction: fraction,
                   note: lapsed ? LAACopy.Usage.lapsed : Self.expiryNote(item?.detail?.expiresOnUtc), nameLink: billing)
    }

    @ViewBuilder private var storage: some View {
        let items = LAACapacity.items(state.usage.value ?? [])
        let rows = VStack(alignment: .leading, spacing: LAASpacing.x2) {
            sectionTitle("Storage")
            VStack(spacing: 0) {
                if items.isEmpty {
                    readingRow(name: "Capacity", result: nil, age: nil, fraction: nil, note: nil)
                }
                ForEach(items) { item in
                    let reading = LAACapacity.reading(item, at: evaluatedAt, allowHistorical: true)
                    let result = reading.map { LAACapacity.bytes($0.availableBytes, locale: locale) }
                    let note = reading.map {
                        "Used " + LAACapacity.bytes($0.usedBytes, locale: locale) + " / " + LAACapacity.bytes($0.totalBytes, locale: locale)
                    }
                    readingRow(name: LAACapacity.name(item.id), result: result, age: age(item),
                               fraction: reading?.usedFraction, level: reading.map {
                                   switch $0.level {
                                   case .critical: .critical
                                   case .warning: .caution
                                   default: LAAMeterLevel(remaining: 1 - $0.usedFraction)
                                   }
                               }, note: note, valueLabel: "Free")
                        .accessibilityIdentifier("laa.capacity.\(item.id)")
                }
            }

        }
        #if DEBUG
        if LAALabCaptureFixture.enabled {
            // Keep the storage group and its individual capacity rows
            // addressable after scrolling in the capture XCTest.
            rows.accessibilityElement(children: .contain).accessibilityIdentifier("laa.capacity")
        } else {
            rows.accessibilityIdentifier("laa.capacity")
        }
        #else
        rows.accessibilityIdentifier("laa.capacity")
        #endif
    }

    private func sectionTitle(_ text: String) -> some View {
        LAASectionHeader(text)
    }

    private func readingRow(name: String, result: String?, age: String?, fraction: Double?,
                            level: LAAMeterLevel? = nil, note: String?, nameLink: URL? = nil,
                            valueLabel: String? = nil) -> some View {
        let status = level ?? LAAMeterLevel(remaining: fraction)
        return VStack(alignment: .leading, spacing: LAASpace.s8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: LAASpace.s8) {
                    readingName(name, link: nameLink).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: LAASpace.s8)
                    readingValue(result, label: valueLabel, age: age, level: status).fixedSize()
                }
                VStack(alignment: .leading, spacing: LAASpace.s4) {
                    readingName(name, link: nameLink)
                    readingValue(result, label: valueLabel, age: age, level: status)
                }
            }
            LAAUsageMeterTrack(fraction: fraction, level: level)
            if let note {
                Text(verbatim: note).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
        }
        .padding(.vertical, LAASpace.s12)
        .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumTouchTarget, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func readingName(_ name: String, link: URL?) -> some View {
        if let link {
            Link(destination: link) {
                Label { Text(verbatim: name).laaTextStyle(.body) } icon: { Image(systemName: "arrow.up.right").font(.caption2) }
                    .foregroundStyle(LAAColor.link)
                    .frame(minHeight: LAASpacing.minimumTouchTarget, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("laa.usage.billing")
        } else {
            Text(verbatim: name).laaTextStyle(.body).foregroundStyle(LAAColor.text)
        }
    }

    private func readingValue(_ result: String?, label: String?, age: String?, level: LAAMeterLevel) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: LAASpace.s4) {
                readingAmount(result, label: label, level: level)
                if result != nil, let age {
                    Text(verbatim: age).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                }
            }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: LAASpace.s4) {
                readingAmount(result, label: label, level: level)
                if result != nil, let age {
                    Text(verbatim: age).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                }
            }
        }
    }

    private func readingAmount(_ result: String?, label: String?, level: LAAMeterLevel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LAASpace.s4) {
            if result == nil || level != .unknown { LAAUsageMeterMark(level: level).laaTextStyle(.note) }
            if let result {
                if let label {
                    HStack(alignment: .firstTextBaseline, spacing: LAASpace.s4) {
                        Text(verbatim: label).laaTextStyle(.note).foregroundStyle(LAAColor.secondaryText)
                        amountText(result)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: "\(label) \(result)"))
                    .accessibilityIdentifier("laa.usage.capacity.free")
                } else {
                    amountText(result)
                }
            }
        }
    }

    private func amountText(_ amount: String) -> some View {
        Text(verbatim: amount).laaTextStyle(.secondary).monospacedDigit().foregroundStyle(LAAColor.text)
    }

    private func age(_ item: LAAUsageItem) -> String? {
        guard LAAUsageFreshness.isPast(item, at: evaluatedAt), let observed = LAAUsageItem.date(item.observedAt) else { return nil }
        return LAAUsageAge.text(observed, at: evaluatedAt)
    }

    private func refresh() async {
        await state.refreshAndPublish(bridge: bridge, manual: true)
        evaluatedAt = Date()
    }

    private func value(_ number: Double?, unit: String) -> String? {
        guard let number, number.isFinite else { return nil }
        if unit == "usd" { return LAAUsageMoney.text(number, locale: locale) }
        if unit == "percent", number > 0, number < 0.01 { return "<0.01%" }
        if unit == "percent", number < 100, number > 99.99 { return ">99.99%" }
        let digits = number.formatted(.number.locale(locale).precision(.fractionLength(0...(unit == "percent" ? 2 : 6))))
        let shown = number > 0 && number < 0.000001 && unit != "percent" ? "<0.000001" : digits
        switch unit {
        case "percent": return shown + "%"
        case "jpy": return shown.hasPrefix("<") ? "<¥0.000001" : "¥" + shown
        case "credits": return shown + " credits"
        case "count": return shown
        default: return shown + " " + unit
        }
    }

}

#endif
