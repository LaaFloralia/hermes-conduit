#if LAA_BUILD
import Foundation
import SwiftUI
import WidgetKit
#if canImport(UIKit)
import UIKit
#endif

enum LAAWidgetUsageBuilder {
    /// One ordered list for the app's AI Usage screen. The first four are the
    /// provider cards (Codex, Claude, Google, Muse); the rest are the ruled
    /// rows below them. Muse is the one card the widget does not show.
    struct Slot {
        /// `accountGroup`: the rows whose `group` is `provider`, one per
        /// account, shown together.
        enum Reading { case weeklyQuota, balance, credits, recordedUsage, accountGroup }
        let provider: String
        let name: String
        let reading: Reading
        /// Whether the home-screen widget lists this provider.
        let showsInWidget: Bool
        /// One of the Usage screen's provider cards (Orca layout).
        var card = false
        var isCard: Bool { showsInWidget || card }
    }

    static let slots: [Slot] = [
        Slot(provider: "codex", name: "Codex", reading: .weeklyQuota, showsInWidget: true),
        Slot(provider: "claude", name: "Claude", reading: .weeklyQuota, showsInWidget: true),
        // Sub2・Sub3・Sub4 (2026-11-23): the card shows the account in use.
        Slot(provider: "google-ai-pro", name: "Google", reading: .accountGroup, showsInWidget: true),
        // Muse1・Muse2・Muse3 (2026-11-26): the Free accounts LAA's harness
        // switches between for TTS and video, each one's weekly allowance.
        // App only: the widget's six rows stay as they are.
        Slot(provider: "muse", name: "Muse", reading: .accountGroup, showsInWidget: false, card: true),
        // Below the cards, folded (2026-11-25). OpenCode left the widget.
        Slot(provider: "opencode-go", name: "OpenCode", reading: .weeklyQuota, showsInWidget: false),
        Slot(provider: "magnific", name: "Magnific", reading: .credits, showsInWidget: false),
        Slot(provider: "openai-api", name: "GPT API", reading: .balance, showsInWidget: false),
        Slot(provider: "claude-api", name: "Claude API", reading: .balance, showsInWidget: false),
        Slot(provider: "liquid", name: "Liquid AI", reading: .recordedUsage, showsInWidget: false),
        Slot(provider: "venice", name: "Venice", reading: .balance, showsInWidget: false),
        // 2026-11-25: the official read-only /v1/credits balance is app-only;
        // Refuseless does not change the widget's six quota rows.
        Slot(provider: "refuseless", name: "Refuseless", reading: .balance, showsInWidget: false),
    ]

    static var widgetSlots: [Slot] { slots.filter(\.showsInWidget) }
    static var cardSlots: [Slot] { slots.filter(\.isCard) }
    static var otherSlots: [Slot] { slots.filter { !$0.isCard } }

    // MARK: The widget's six readings

    /// Which quota window a reading is.
    enum Period: String, CaseIterable {
        case fiveHour, weekly, fable
        /// The period's short name, the same in every language (5h, 7d, Fable).
        var abbreviation: String {
            switch self { case .fiveHour: "5h"; case .weekly: "7d"; case .fable: "Fable" }
        }
        var minutes: Double { self == .fiveHour ? 300 : 10_080 }
    }

    /// One fixed widget row. Its meter id is stable across builds: the two
    /// weekly ids are the ones the seven-row widget wrote, so a snapshot saved
    /// before this build still fills Codex 7d and Claude 7d.
    struct Row: Equatable, Identifiable {
        let provider: String
        let name: String
        let period: Period
        var id: String {
            let suffix: String
            switch period { case .fiveHour: suffix = "session"; case .weekly: suffix = "weekly"; case .fable: suffix = "fable" }
            return "provider.\(provider).quota.\(suffix)"
        }
        var label: String { name + " " + period.abbreviation }
        /// Only the weekly readings carry a reset time in the widget.
        var showsReset: Bool { period != .fiveHour }
    }

    static let googleGroup = "google-ai-pro"

    /// The widget's rows in the owner's order (2026-11-25): Codex 7d, Claude
    /// 5h / 7d / Fable, Google 5h / 7d.
    static let widgetRows: [Row] = [
        Row(provider: "codex", name: "Codex", period: .weekly),
        Row(provider: "claude", name: "Claude", period: .fiveHour),
        Row(provider: "claude", name: "Claude", period: .weekly),
        Row(provider: "claude", name: "Claude", period: .fable),
        Row(provider: googleGroup, name: "Google", period: .fiveHour),
        Row(provider: googleGroup, name: "Google", period: .weekly),
    ]

    /// Which rows give way first when larger text leaves no room for six:
    /// the five-hour readings, then Google's week, then Fable.
    static let dropOrder: [String] = [
        widgetRows[4].id, widgetRows[1].id, widgetRows[5].id, widgetRows[3].id, widgetRows[2].id, widgetRows[0].id,
    ]

    /// The snapshot keeps the weekly readings first, so a reader that knows
    /// one row per provider (the previous widget binary during an update)
    /// meets Codex and Claude's weekly values before anything else.
    static let snapshotOrder: [Row] = widgetRows.filter { $0.period == .weekly }
        + widgetRows.filter { $0.period != .weekly }

    /// The snapshot's meters the widget draws, in widget order. Rows saved by
    /// an older build that no longer have a place (OpenCode, the balances, a
    /// retired provider) never render; a missing row is unknown.
    static func widgetMeters(_ snapshot: WidgetUsageSnapshot?) -> [WidgetUsageMeter] {
        guard let snapshot else { return [] }
        return widgetRows.compactMap { row in snapshot.meters.first { $0.id == row.id } }
    }

    static func make(items: [LAAUsageItem], receivedAt: Date = Date(), previous: WidgetUsageSnapshot? = nil) -> WidgetUsageSnapshot {
        let feed = items.filter { $0.source == "codexbar-usage-proxy" }
        let meters = snapshotOrder.compactMap { row -> WidgetUsageMeter? in
            let reading = meter(for: row, feed: feed, receivedAt: receivedAt)
            let prior = previous?.meters.first { $0.id == row.id && $0.hasRecordedValue(at: receivedAt) }
            switch reading {
            case .value(let current):
                if let prior, let oldDate = prior.observedAt, let newDate = current.observedAt, newDate < oldDate {
                    return prior
                }
                return current
            case .unknown:
                // The provider answered but this reading is not usable now
                // (Fable expired, no account in use): unknown, never a
                // number carried over from an earlier answer.
                return .missing(id: row.id, label: row.label)
            case .unanswered(let reported):
                return prior?.lastKnown(label: row.label) ?? (reported ? .missing(id: row.id, label: row.label) : nil)
            }
        }
        // The feed can be cached even when the app has just contacted Bridge.
        // Only show a confirmation time if all displayed readings have one.
        let observations = meters.filter(\.available).compactMap(\.observedAt)
        let checkedAt = observations.isEmpty ? nil : observations.min()
        return WidgetUsageSnapshot(meters: meters, checkedAt: checkedAt)
    }

    private enum Reading {
        case value(WidgetUsageMeter)
        /// The provider's item is fresh but holds no usable reading here.
        case unknown
        /// The provider gave no fresh item; `reported` when it sent one at all.
        case unanswered(reported: Bool)
    }

    private static func meter(for row: Row, feed: [LAAUsageItem], receivedAt: Date) -> Reading {
        let item: LAAUsageItem
        if row.provider == googleGroup {
            let accounts = feed.filter { $0.group == googleGroup && $0.kind == "quota" }
            guard !accounts.isEmpty else { return .unanswered(reported: false) }
            guard let active = activeAccount(accounts) else { return .unknown }
            item = active
        } else {
            guard let found = feed.first(where: { $0.id.hasPrefix("provider.\(row.provider).") && $0.kind == "quota" }) else {
                return .unanswered(reported: false)
            }
            item = found
        }
        guard item.availability == "available", LAAUsageItem.date(item.observedAt).map({
            !(receivedAt.addingTimeInterval(120) < $0)
        }) == true else { return .unanswered(reported: true) }
        let remaining: Double?
        let reset: String?
        switch row.period {
        case .fable:
            guard let fable = item.fableWeekly(at: receivedAt) else { return .unknown }
            remaining = fable.remainingPercent; reset = fable.resetsAt
        case .fiveHour, .weekly:
            // An item with no windows at all answered nothing.
            guard !item.ordinaryWindows.isEmpty else { return .unanswered(reported: true) }
            guard let window = item.ordinaryWindow(minutes: row.period.minutes) else { return .unknown }
            remaining = window.remainingPercent; reset = window.resetsAt
        }
        guard let remaining, remaining.isFinite, (0...100).contains(remaining) else { return .unknown }
        return .value(meter(id: row.id, label: row.label, amount: remaining, item: item,
                            resetsAt: LAAUsageItem.date(reset), receivedAt: receivedAt))
    }

    /// Google AI Pro's account in use: the one row the feed marks active.
    /// None or several marked is ambiguous, so unknown; accounts are never
    /// averaged and the account's address never leaves the feed.
    static func activeAccount(_ accounts: [LAAUsageItem]) -> LAAUsageItem? {
        let active = accounts.filter { $0.active == true }
        return active.count == 1 ? active[0] : nil
    }

    private static func meter(id: String, label: String, amount: Double, item: LAAUsageItem,
                              resetsAt: Date?, receivedAt: Date) -> WidgetUsageMeter {
        let freshUntil = item.detail?.freshUntil
        let observed = LAAUsageItem.date(item.observedAt)
        let verified = item.detail?.sourceKind == "verified"
        let upstreamDeadline = LAAUsageItem.date(freshUntil)
        let limit = observed.map { min($0, item.freshnessAnchor ?? receivedAt, receivedAt).addingTimeInterval(10 * 60) }
        let deadline: Date?
        if freshUntil == nil {
            deadline = verified ? nil : limit
        } else {
            deadline = upstreamDeadline.flatMap { upstream in limit.map { min($0, upstream) } }
        }
        return WidgetUsageMeter(id: id, label: label, unit: .percent, amount: amount,
                                observedAt: observed, freshUntil: deadline, resetsAt: resetsAt,
                                stale: item.stale || item.retainedReason != nil || (freshUntil != nil && deadline == nil),
                                retained: false, verified: verified,
                                legacyFreshness: freshUntil == nil && !verified)
    }
}

// MARK: The Usage bar (app cards and widget)

/// The quota bar's colour band: accent, `caution` under 25% left, `critical`
/// under 10% left (DESIGN `theme.semantic.meter`). Unknown draws the track only.
enum LAAUsageBarLevel: Equatable {
    case normal, caution, critical, unknown

    static let cautionBelow = 25.0
    static let criticalBelow = 10.0

    init(remainingPercent: Double?) {
        guard let value = remainingPercent, value.isFinite else { self = .unknown; return }
        if value < Self.criticalBelow { self = .critical }
        else if value < Self.cautionBelow { self = .caution }
        else { self = .normal }
    }

    var color: Color {
        switch self {
        case .normal, .unknown: LAAColor.link
        case .caution: LAAUsageBar.caution
        case .critical: LAAUsageBar.critical
        }
    }
}

/// The Usage screen's and widget's own meter (`component.meter.bar`): a
/// square-ended track the full width, filled to the share left. Elsewhere
/// the app keeps its line-and-dot meter.
struct LAAUsageBar: View {
    /// 0...100; nil draws the track alone.
    let remainingPercent: Double?
    var height: CGFloat = LAAUsageBar.height
    var animates = true
    /// The widget's own mode when a capture overrides it; otherwise WidgetKit's.
    var renderingMode: WidgetRenderingMode? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.widgetRenderingMode) private var environmentRenderingMode
    @State private var appeared = false

    static let height: CGFloat = 4

    #if canImport(UIKit)
    static let caution = dynamic(light: (0x8A, 0x5A, 0x0B), dark: (0xE2, 0xB4, 0x5C))
    static let critical = dynamic(light: (0xA2, 0x3B, 0x2A), dark: (0xEE, 0x8E, 0x7C))

    private static func dynamic(light: (Int, Int, Int), dark: (Int, Int, Int)) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
        })
    }
    #else
    static let caution = Color(red: 0x8A / 255, green: 0x5A / 255, blue: 0x0B / 255)
    static let critical = Color(red: 0xA2 / 255, green: 0x3B / 255, blue: 0x2A / 255)
    #endif

    private var fraction: Double {
        guard let value = remainingPercent, value.isFinite else { return 0 }
        return min(max(value / 100, 0), 1)
    }

    var body: some View {
        let level = LAAUsageBarLevel(remainingPercent: remainingPercent)
        let paint = Paint(mode: renderingMode ?? environmentRenderingMode, level: level)
        GeometryReader { proxy in
            let drawn = !animates || appeared || reduceMotion ? fraction : 0
            ZStack(alignment: .leading) {
                Rectangle().fill(paint.track)
                if level != .unknown {
                    Rectangle().fill(paint.fill)
                        // A nonzero share keeps a sliver visible.
                        .frame(width: max(proxy.size.width * drawn, fraction > 0 ? min(2, proxy.size.width) : 0))
                        .widgetAccentable()
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
        .animation(animates && !reduceMotion ? .smooth(duration: 0.45) : nil, value: fraction)
        .onAppear {
            guard animates, !appeared else { return }
            if reduceMotion { appeared = true } else { withAnimation(.easeOut(duration: 0.35)) { appeared = true } }
        }
    }
}

extension LAAUsageBar {
    /// Track and fill for a rendering mode. On tinted and clear Home Screens
    /// (`accented`) WidgetKit keeps only each view's opacity, and in
    /// `vibrant` (StandBy, the lock screen, a Mac desktop in the background)
    /// only its brightness; an opaque track in its own colour then read the
    /// same as the fill, so every bar looked full. Outside full colour the
    /// track is a faint white and the fill solid white in the accent group.
    struct Paint {
        let track: Color
        let fill: Color

        static let tintedTrackOpacity = 0.28

        init(mode: WidgetRenderingMode, level: LAAUsageBarLevel) {
            if mode == .fullColor {
                track = LAAColor.separator
                fill = level.color
            } else {
                track = Color.white.opacity(Self.tintedTrackOpacity)
                fill = Color.white
            }
        }
    }
}

/// Reset times on the cards and the widget: `11/25 18:00`, the time alone
/// when it is today, and a shorter form when room is short.
enum LAAUsageResetText {
    static func full(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        format(date, calendar.isDate(date, inSameDayAs: now) ? "H:mm" : "M/d H:mm", calendar: calendar)
    }

    /// Within a day the time, otherwise the date.
    static func short(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        format(date, date.timeIntervalSince(now) < 86_400 ? "H:mm" : "M/d", calendar: calendar)
    }

    private static func format(_ date: Date, _ pattern: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
#endif
