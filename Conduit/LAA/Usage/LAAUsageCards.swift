#if LAA_BUILD
import SwiftUI
import LAAKit

/// One quota window on a provider card: `5h`, `7d` or Claude's `Fable`.
/// `remainingPercent` nil is unknown (track and ○ only), never zero.
struct LAAUsageCardWindow: Equatable, Identifiable {
    let id: String
    let label: String
    let remainingPercent: Double?
    let resetsAt: Date?
}

/// What each Usage card shows, decided away from the view so it is testable.
enum LAAUsageCardModel {
    /// The provider's quota item from the usage feed.
    static func item(_ provider: String, in items: [LAAUsageItem]) -> LAAUsageItem? {
        items.first { $0.id.hasPrefix("provider.\(provider).") && $0.kind == "quota" && $0.source == "codexbar-usage-proxy" }
    }

    /// A grouped service's accounts in id order: Google AI Pro's Sub2・Sub3・
    /// Sub4, Muse's Muse1・Muse2・Muse3.
    static func accounts(_ items: [LAAUsageItem], group: String = LAAWidgetUsageBuilder.googleGroup) -> [LAAUsageItem] {
        items.filter { $0.group == group && $0.kind == "quota" && $0.source == "codexbar-usage-proxy" }
            .sorted { $0.id < $1.id }
    }

    /// "Sub2" from "Google Sub2": the card already says Google.
    static func accountName(_ item: LAAUsageItem) -> String {
        let label = item.label.hasPrefix("Google ") ? String(item.label.dropFirst("Google ".count)) : item.label
        return label.isEmpty ? item.id : label
    }

    /// The windows a card draws. Codex and Google show the 5h and 7d windows
    /// their reading has (both, unknown, when there is none); Claude always
    /// shows 5h and 7d, then Fable on the next row; Muse has only its weekly
    /// Free allowance.
    static func windows(provider: String, item: LAAUsageItem?, now: Date) -> [LAAUsageCardWindow] {
        let usable = item.map { $0.availability == "available" } ?? false
        func window(_ period: LAAWidgetUsageBuilder.Period) -> LAAUsageCardWindow? {
            guard let item, usable else { return nil }
            let remaining: Double?
            let reset: String?
            if period == .fable {
                guard let fable = item.fableWeekly(at: now) else { return nil }
                remaining = fable.remainingPercent; reset = fable.resetsAt
            } else {
                guard let found = item.ordinaryWindow(minutes: period.minutes) else { return nil }
                remaining = found.remainingPercent; reset = found.resetsAt
            }
            let resetDate = LAAUsageItem.date(reset)
            // A window whose reset has passed no longer holds that share.
            let current = resetDate.map { now < $0 } ?? true
            guard current, let remaining, remaining.isFinite, (0...100).contains(remaining) else {
                return unknown(period)
            }
            return LAAUsageCardWindow(id: period.rawValue, label: period.abbreviation, remainingPercent: remaining, resetsAt: resetDate)
        }
        func unknown(_ period: LAAWidgetUsageBuilder.Period) -> LAAUsageCardWindow {
            LAAUsageCardWindow(id: period.rawValue, label: period.abbreviation, remainingPercent: nil, resetsAt: nil)
        }
        if provider == "claude" {
            return [LAAWidgetUsageBuilder.Period.fiveHour, .weekly, .fable].map { window($0) ?? unknown($0) }
        }
        if provider == "muse" { return [window(.weekly) ?? unknown(.weekly)] }
        let present = [LAAWidgetUsageBuilder.Period.fiveHour, .weekly].compactMap(window)
        return present.isEmpty ? [unknown(.fiveHour), unknown(.weekly)] : present
    }
}

/// An Orca-style provider card (`component.card.provider`, class
/// `provider-card`): `surface`, radius 16, a 1px `rule` outline, padding 16,
/// gap 12. A header (mark 18 + name 16/500), then the windows in two columns
/// (one at accessibility sizes). The screen's one refresh lives in its
/// header; a card never carries its own.
struct LAAUsageProviderCard<Accessory: View, Extra: View>: View {
    let provider: String
    let name: String
    let windows: [LAAUsageCardWindow]
    let note: String?
    let now: Date
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var extra: () -> Extra

    /// The provider's line icon (usage-good: terminal, asterisk, G).
    static func symbol(_ provider: String) -> String {
        switch provider {
        case "codex": "terminal"
        case "claude": "asterisk"
        case "google-ai-pro": "g.circle"
        case "muse": "waveform"
        default: "circle.dashed"
        }
    }

    var body: some View {
        let tokens = LAAComponentToken.ProviderCard.self
        VStack(alignment: .leading, spacing: tokens.gap) {
            HStack(alignment: .center, spacing: LAASpace.s8) {
                // A monochrome line icon, no disc or tile (usage-good).
                Image(systemName: Self.symbol(provider))
                    .font(.system(size: tokens.headerIcon))
                    .foregroundStyle(LAAColor.secondaryText)
                    .frame(width: tokens.headerIcon, height: tokens.headerIcon)
                    .accessibilityHidden(true)
                Text(verbatim: name).laaFont(tokens.headerName, weight: .medium).foregroundStyle(LAAColor.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: LAASpacing.x2)
                if let note {
                    Text(verbatim: note).laaTextStyle(.note).monospacedDigit()
                        .foregroundStyle(LAAColor.secondaryText).lineLimit(1)
                }
                accessory()
            }
            LAAUsageWindowGrid(windows: windows, now: now)
            extra()
        }
        .padding(tokens.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: tokens.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: tokens.radius, style: .continuous)
                .strokeBorder(LAAColor.separator, lineWidth: tokens.outline)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("laa.usage.card.\(provider)")
    }
}

extension LAAUsageProviderCard where Extra == EmptyView {
    init(provider: String, name: String, windows: [LAAUsageCardWindow], note: String?, now: Date,
         @ViewBuilder accessory: @escaping () -> Accessory) {
        self.init(provider: provider, name: name, windows: windows, note: note, now: now,
                  accessory: accessory, extra: { EmptyView() })
    }
}

/// The windows in a 2-column grid (column gap 12, row gap 8); a third window
/// starts the next row. One column at accessibility text sizes.
struct LAAUsageWindowGrid: View {
    let windows: [LAAUsageCardWindow]
    let now: Date
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The provider's line icon (usage-good: terminal, asterisk, G).
    static func symbol(_ provider: String) -> String {
        switch provider {
        case "codex": "terminal"
        case "claude": "asterisk"
        case "google-ai-pro": "g.circle"
        case "muse": "waveform"
        default: "circle.dashed"
        }
    }

    var body: some View {
        let tokens = LAAComponentToken.ProviderCard.self
        let columns = typeSize.isAccessibilitySize ? 1 : tokens.windowColumns
        Grid(alignment: .topLeading, horizontalSpacing: tokens.windowColumnGap, verticalSpacing: tokens.windowRowGap) {
            ForEach(Array(stride(from: 0, to: windows.count, by: columns)), id: \.self) { start in
                GridRow {
                    ForEach(windows[start..<min(start + columns, windows.count)]) { window in
                        LAAUsageWindowCell(window: window, now: now)
                    }
                    if columns == 2, start + 1 >= windows.count {
                        Color.clear.frame(height: 0).gridCellUnsizedAxes([.vertical])
                    }
                }
            }
        }
    }
}

/// One window: label 12 muted and the value 13/500 in tabular digits on a
/// line, the 4pt square bar, and the reset 12 muted below. Unknown draws
/// the track and ○ only.
struct LAAUsageWindowCell: View {
    let window: LAAUsageCardWindow
    let now: Date

    /// The provider's line icon (usage-good: terminal, asterisk, G).
    static func symbol(_ provider: String) -> String {
        switch provider {
        case "codex": "terminal"
        case "claude": "asterisk"
        case "google-ai-pro": "g.circle"
        case "muse": "waveform"
        default: "circle.dashed"
        }
    }

    var body: some View {
        let tokens = LAAComponentToken.ProviderCard.self
        VStack(alignment: .leading, spacing: LAASpace.s4) {
            HStack(alignment: .firstTextBaseline, spacing: LAASpace.s4) {
                Text(verbatim: window.label).laaFont(tokens.windowLabel).foregroundStyle(LAAColor.secondaryText)
                Spacer(minLength: LAASpace.s4)
                LAAUsageMeterMark(level: LAAMeterLevel(remainingPercent: window.remainingPercent))
                    .laaTextStyle(.note)
                if let remaining = window.remainingPercent {
                    Text(verbatim: LAAEmployeeUsageText.percent(remaining))
                        .laaFont(tokens.windowValue, weight: .medium).monospacedDigit().foregroundStyle(LAAColor.text)
                }
            }
            LAAUsageMeterTrack(fraction: window.remainingPercent.map { $0 / 100 })
            if let reset = window.resetsAt {
                Text(verbatim: LAAUsageResetText.full(reset, now: now))
                    .laaFont(tokens.windowLabel).monospacedDigit().foregroundStyle(LAAColor.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: window.label))
        .accessibilityValue(Text(verbatim: accessibilityValue))
        .accessibilityIdentifier("laa.usage.window.\(window.id)")
    }

    private var accessibilityValue: String {
        guard let value = window.remainingPercent else { return LAAShape.unknown }
        let text = LAAEmployeeUsageText.percent(value)
        return window.resetsAt.map { text + ", Reset " + LAAUsageResetText.full($0, now: now) } ?? text
    }
}

/// Percent text shared by the cards: two decimals at most, never rounded
/// to 0% or 100% when it is not.
enum LAAEmployeeUsageText {
    static func percent(_ value: Double) -> String {
        if value > 0 && value < 0.01 { return "<0.01%" }
        if value < 100 && value > 99.99 { return ">99.99%" }
        return value.formatted(.number.locale(Locale(identifier: "ja_JP")).precision(.fractionLength(0...2))) + "%"
    }
}
#endif
