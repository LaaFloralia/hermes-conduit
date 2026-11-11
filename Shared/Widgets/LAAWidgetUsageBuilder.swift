#if LAA_BUILD
import Foundation

enum LAAWidgetUsageBuilder {
    /// One ordered list for the app's AI Usage screen and the widget. The
    /// widget leaves out Liquid AI, so the list fits the largest widget without
    /// dropping a row silently.
    struct Slot {
        enum Reading { case weeklyQuota, balance, credits, recordedUsage }
        let provider: String
        let name: String
        let reading: Reading
        /// Whether the home-screen widget lists this provider.
        let showsInWidget: Bool

        /// Only the reading this slot shows may fill it, so a snapshot written
        /// when the API rows were spend never fills a balance slot.
        func owns(_ meterID: String) -> Bool {
            let prefix = "provider.\(provider)."
            switch reading {
            case .weeklyQuota: return meterID.hasPrefix(prefix + "quota")
            case .balance: return meterID == prefix + "balance"
            case .credits: return meterID.hasPrefix(prefix + "credits")
            case .recordedUsage: return meterID.hasPrefix(prefix + "usage")
            }
        }
    }

    static let slots: [Slot] = [
        Slot(provider: "codex", name: "Codex", reading: .weeklyQuota, showsInWidget: true),
        Slot(provider: "opencode-go", name: "OpenCode", reading: .weeklyQuota, showsInWidget: true),
        Slot(provider: "claude", name: "Claude", reading: .weeklyQuota, showsInWidget: true),
        Slot(provider: "magnific", name: "Magnific", reading: .credits, showsInWidget: true),
        Slot(provider: "openai-api", name: "GPT API", reading: .balance, showsInWidget: true),
        Slot(provider: "claude-api", name: "Claude API", reading: .balance, showsInWidget: true),
        Slot(provider: "liquid", name: "Liquid AI", reading: .recordedUsage, showsInWidget: false),
        Slot(provider: "venice", name: "Venice", reading: .balance, showsInWidget: true),
    ]

    /// The rows the widget draws, in the owner's priority order.
    static var widgetSlots: [Slot] { slots.filter(\.showsInWidget) }

    static func make(items: [LAAUsageItem], receivedAt: Date = Date(), previous: WidgetUsageSnapshot? = nil) -> WidgetUsageSnapshot {
        let feed = items.filter { $0.source == "codexbar-usage-proxy" }
        let meters = widgetSlots.compactMap { slot -> WidgetUsageMeter? in
            let current = meter(for: slot, feed: feed, receivedAt: receivedAt)
            let prior = previous?.displayableMeters.first(where: {
                slot.owns($0.id) && $0.hasRecordedValue(at: receivedAt)
            })
            if let current, current.hasRecordedValue(at: receivedAt) {
                if let prior, let oldDate = prior.observedAt, let newDate = current.observedAt, newDate < oldDate {
                    return prior
                }
                return current
            }
            return prior?.lastKnown(label: slot.name) ?? current
        }
        // The feed can be cached even when the app has just contacted Bridge.
        // Only show a confirmation time if all displayed readings have one.
        let observations = meters.filter(\.available).compactMap(\.observedAt)
        let checkedAt = observations.isEmpty ? nil : observations.min()
        return WidgetUsageSnapshot(meters: meters, checkedAt: checkedAt)
    }

    private static func meter(for slot: Slot, feed: [LAAUsageItem], receivedAt: Date) -> WidgetUsageMeter? {
        let prefix = "provider.\(slot.provider)."
        let available = { (item: LAAUsageItem) in
            item.availability == "available" && LAAUsageItem.date(item.observedAt).map {
                !((receivedAt.addingTimeInterval(120)) < $0)
            } == true
        }
        switch slot.reading {
        case .weeklyQuota:
            guard let item = feed.first(where: { $0.id.hasPrefix(prefix) && $0.kind == "quota" }) else { return nil }
            let window = weeklyWindow(item.detail?.windows ?? [])
            guard available(item), let window,
                  let remaining = window.remainingPercent, remaining.isFinite, (0...100).contains(remaining) else {
                return .missing(id: "\(item.id).weekly", label: slot.name)
            }
            return meter(id: "\(item.id).weekly", label: slot.name, unit: .percent, amount: remaining,
                         item: item, freshUntil: item.detail?.freshUntil,
                         resetsAt: LAAUsageItem.date(window.resetsAt), receivedAt: receivedAt)
        case .balance:
            // A balance the feed does not carry is left out rather than drawn
            // with no number: a spend figure never appears in its place.
            // A billing-page reading can be negative (an unpaid balance).
            guard let item = feed.first(where: { $0.id == "\(prefix)balance" }) else {
                // The API rows stay listed even when the feed has no reading.
                return ["openai-api", "claude-api"].contains(slot.provider) ? .missing(id: "\(prefix)balance", label: slot.name) : nil
            }
            guard available(item), item.unit == "usd", let amount = item.value, amount.isFinite else {
                return .missing(id: item.id, label: slot.name)
            }
            return meter(id: item.id, label: slot.name, unit: .usd, amount: amount,
                         item: item, freshUntil: item.detail?.freshUntil, resetsAt: nil, receivedAt: receivedAt)
        case .credits:
            guard let item = feed.first(where: { $0.id == "\(prefix)credits" }) else { return nil }
            guard available(item), item.unit == "credits", let amount = item.value, amount.isFinite, amount >= 0 else {
                return .missing(id: item.id, label: slot.name)
            }
            return meter(id: item.id, label: slot.name, unit: .credits, amount: amount,
                         item: item, freshUntil: item.detail?.freshUntil, resetsAt: nil, receivedAt: receivedAt,
                         granted: item.detail?.grantedAmount ?? item.detail?.monthlyGrantedAmount)
        case .recordedUsage:
            guard let item = feed.first(where: { $0.id.hasPrefix(prefix) && $0.kind == "usage" }) else { return nil }
            guard available(item), let amount = item.detail?.recordedCostUsd, amount.isFinite else {
                return .missing(id: item.id, label: slot.name)
            }
            return meter(id: item.id, label: slot.name, unit: .usd, amount: amount,
                         item: item, freshUntil: item.detail?.freshUntil, resetsAt: nil, receivedAt: receivedAt)
        }
    }

    /// The window the owner means by "Weekly": the 7-day quota when the feed
    /// names its duration, otherwise the window the feed itself calls Weekly.
    private static func weeklyWindow(_ windows: [LAAUsageItem.Window]) -> LAAUsageItem.Window? {
        windows.first { window in
            if let minutes = window.windowMinutes { return minutes == 10_080 }
            return LAAUsageLabel.isWeekly(window.label)
        }
    }

    private static func meter(id: String, label: String, unit: WidgetUsageMeter.Unit, amount: Double,
                              item: LAAUsageItem, freshUntil: String?, resetsAt: Date?,
                              receivedAt: Date, granted: Double? = nil) -> WidgetUsageMeter {
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
        return WidgetUsageMeter(id: id, label: label, unit: unit, amount: amount,
                                observedAt: observed, freshUntil: deadline, resetsAt: resetsAt,
                                stale: item.stale || item.retainedReason != nil || (freshUntil != nil && deadline == nil),
                                retained: false, verified: verified,
                                legacyFreshness: freshUntil == nil && !verified, granted: granted)
    }
}

/// One naming rule for the quota windows, shared by the app list and the widget.
enum LAAUsageLabel {
    static func isWeekly(_ label: String) -> Bool {
        ["weekly", "週間", "週次", "週刊", "ウィークリー"].contains(label.lowercased()) || label.hasPrefix("週次")
    }

    /// Display name for one window. A duration the feed reports wins, so a 7-day
    /// pool reads 週間 whatever the proxy calls it.
    static func window(_ window: LAAUsageItem.Window) -> String {
        if let minutes = window.windowMinutes {
            if minutes == 10_080 { return "週間" }
            if minutes == 43_200 { return "月間" }
        }
        if isWeekly(window.label) { return "週間" }
        if ["monthly", "月間", "マンスリー"].contains(window.label.lowercased()) {
            return "月間"
        }
        return window.label
    }
}


#endif
