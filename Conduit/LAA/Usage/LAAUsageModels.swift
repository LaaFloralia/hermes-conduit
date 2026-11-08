#if LAA_BUILD
import Foundation

struct LAAUsagePage: Decodable {
    let items: [LAAUsageItem]
    let nextCursor: String?
}

struct LAAUsageItem: Decodable, Identifiable {
    struct Window: Decodable {
        let label: String
        let remainingPercent: Double?
        let resetsAt: String?
        let windowMinutes: Double?
    }
    struct Component: Decodable {
        let kind: String
        let amount: Double
        let grantedAmount: Double?
        let expiresOnUtc: String?
    }
    struct Credits: Decodable {
        let remaining: Double?
        let updatedAt: String?
    }
    struct RecordedUsage: Decodable {
        let inputTokens: Double?
        let outputTokens: Double?
    }
    struct Detail: Decodable {
        let windows: [Window]?
        let sourceKind: String?
        let freshUntil: String?
        let credits: Credits?
        let components: [Component]?
        let currency: String?
        let creditUnit: String?
        let grantedAmount: Double?
        let monthlyGrantedAmount: Double?
        let dailyRemaining: Double?
        let dailyGrantedAmount: Double?
        let fallbackAiCredits: Double?
        let usd: Double?
        let monthlyRemainingPercent: Double?
        let recordedCostUsd: Double?
        let recordedRequestCount: Double?
        let lastRecordedAt: String?
        let models: [RecordedUsage]?
        let expiresOnUtc: String?
        let renewsAt: String?
        let sourceLag: String?
        let periodTimezone: String?
        let totalBytes: Double?
        let availableBytes: Double?
        let status: String?
        let warningFreeBytes: Double?
        let criticalFreeBytes: Double?
    }
    let id: String
    let kind: String
    let label: String
    let value: Double?
    let unit: String
    let source: String
    let observedAt: String?
    let availability: String
    let stale: Bool
    let estimated: Bool
    let expired: Bool
    let nullReason: String?
    let detail: Detail?
    // Set locally on receipt; it is never decoded from the remote response.
    var freshnessAnchor: Date? = nil

    private enum CodingKeys: String, CodingKey {
        case id, kind, label, value, unit, source, observedAt, availability, stale, estimated, expired, nullReason, detail
    }

    var availableValue: Double? { availability == "available" ? value : nil }

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    func isExpired(now: Date = Date()) -> Bool {
        if expired { return true }
        guard let expires = detail?.expiresOnUtc, expires.count == 10,
              let endOfDay = Self.date(expires + "T23:59:59Z") else { return false }
        return endOfDay < now
    }
}

enum LAAUsageFreshness {
    static func isStale(_ item: LAAUsageItem, at now: Date = Date()) -> Bool {
        if item.stale { return true }
        guard let observed = LAAUsageItem.date(item.observedAt),
              !(min(item.freshnessAnchor ?? now, now).addingTimeInterval(120) < observed) else { return true }
        let limit = min(observed, item.freshnessAnchor ?? now, now).addingTimeInterval(10 * 60)
        if item.detail?.sourceKind == "verified" { return true }
        if let raw = item.detail?.freshUntil {
            guard let deadline = LAAUsageItem.date(raw) else { return true }
            return !(now < min(deadline, limit))
        }
        // Older Bridges do not supply freshUntil, but do send observedAt and stale.
        return !(now < limit)
    }

    static func windowExpired(_ window: LAAUsageItem.Window, at now: Date = Date()) -> Bool {
        LAAUsageItem.date(window.resetsAt).map { !(now < $0) } ?? false
    }

    static func outdated(_ text: String?, at now: Date = Date()) -> Bool {
        guard let date = LAAUsageItem.date(text) else { return true }
        return date > now.addingTimeInterval(120) || now.timeIntervalSince(date) >= 10 * 60
    }

    static func extraNeedsAttention(_ item: LAAUsageItem, at now: Date = Date()) -> Bool {
        if let credits = item.detail?.credits, outdated(credits.updatedAt, at: now) { return true }
        return false
    }

    static func reachedUTCDate(_ text: String?, at now: Date = Date()) -> Bool {
        guard let text, text.count == 10, let start = LAAUsageItem.date(text + "T00:00:00Z") else { return false }
        return !(now < start)
    }

    static func needsRenewal(_ item: LAAUsageItem, at now: Date = Date()) -> Bool {
        if extraNeedsAttention(item, at: now) { return true }
        if LAAUsageItem.date(item.detail?.renewsAt).map({ !(now < $0) }) == true { return true }
        if reachedUTCDate(item.detail?.expiresOnUtc, at: now) { return true }
        return (item.detail?.components ?? []).contains { $0.amount > 0 && reachedUTCDate($0.expiresOnUtc, at: now) }
    }

    /// One answer for the app list and the widget: a reading that is stale, or
    /// whose shape the app cannot vouch for, carries no number.
    static func isPast(_ item: LAAUsageItem, at now: Date = Date()) -> Bool {
        // A billing-page balance has no feed freshness: its date is shown instead.
        if item.detail?.sourceKind == "verified", item.kind == "balance", item.unit == "usd" { return false }
        if isStale(item, at: now) { return true }
        if item.kind == "cost" {
            let lag: String
            if item.id.hasPrefix("provider.claude-api.") { lag = "typical-5m" }
            else if item.id.hasPrefix("provider.openai-api.") { lag = "undisclosed" }
            else { return true }
            if item.detail?.sourceLag != lag || item.detail?.periodTimezone != "UTC" { return true }
        }
        // A quota item's expired bit describes only its lowest remaining window.
        return item.kind != "quota" && (item.isExpired(now: now) || needsRenewal(item, at: now))
    }
}

/// One capacity reading the screen may draw. Only a fresh item whose used,
/// free and total bytes agree exactly becomes one; anything else shows no number.
struct LAACapacityReading: Equatable {
    /// `recorded` is a fresh reading with no thresholds: it is not called normal.
    enum Level: Equatable { case normal, recorded, warning, critical }
    let usedBytes: Double
    let availableBytes: Double
    let totalBytes: Double
    let warningFreeBytes: Double?
    let criticalFreeBytes: Double?
    let level: Level

    var usedFraction: Double { usedBytes / totalBytes }
    /// Where the warning threshold sits on the used-bytes track.
    var warningFraction: Double? { warningFreeBytes.map { (totalBytes - $0) / totalBytes } }
}

enum LAACapacity {
    /// Code-owned order and names; the feed's labels are not shown.
    static let slots: [(id: String, name: String)] = [
        ("capacity.mac-mini.memory", "Mac mini メモリ"),
        ("capacity.mac-mini.ssd", "Mac mini SSD"),
        ("capacity.google-drive", "Google Drive"),
        ("capacity.macbook.memory", "MacBook メモリ"),
        ("capacity.macbook.ssd", "MacBook SSD"),
        ("capacity.icloud", "iCloud"),
    ]

    static func name(_ id: String) -> String { slots.first { $0.id == id }?.name ?? id }

    /// Capacity rows in display order; they never join an AI service group.
    static func items(_ items: [LAAUsageItem]) -> [LAAUsageItem] {
        slots.compactMap { slot in items.first { $0.id == slot.id && $0.kind == "capacity" } }
    }

    /// A device with no reading path yet: listed quietly, never as zero.
    static func isUnconnected(_ item: LAAUsageItem) -> Bool {
        item.availability != "available" && item.nullReason == "unsupported"
    }

    static func reading(_ item: LAAUsageItem, at now: Date = Date()) -> LAACapacityReading? {
        guard item.kind == "capacity", item.unit == "bytes", item.availability == "available",
              !LAAUsageFreshness.isStale(item, at: now),
              let used = item.value, let detail = item.detail,
              let total = detail.totalBytes, let available = detail.availableBytes,
              [used, total, available].allSatisfy({ $0.isFinite && $0 >= 0 }),
              total > 0, available <= total,
              (item.id == "capacity.google-drive"
               ? available == max(0, total - used)
               : used <= total && used + available == total) else { return nil }
        let warning = threshold(detail.warningFreeBytes, total: total)
        let critical = threshold(detail.criticalFreeBytes, total: total)
        let local: LAACapacityReading.Level = critical.map { available < $0 } == true ? .critical
            : warning.map { available < $0 } == true ? .warning
            : (warning != nil || critical != nil) ? .normal : .recorded
        let reported: LAACapacityReading.Level? = switch detail.status ?? "" {
        case "critical": .critical
        case "warning": .warning
        default: nil
        }
        // The worse of the Bridge's status and the app's own check wins.
        let level = [local, reported].compactMap { $0 }.max { severity($0) < severity($1) } ?? local
        return LAACapacityReading(usedBytes: used, availableBytes: available, totalBytes: total,
                                  warningFreeBytes: warning, criticalFreeBytes: critical, level: level)
    }

    private static func threshold(_ value: Double?, total: Double) -> Double? {
        guard let value, value.isFinite, value > 0, value < total else { return nil }
        return value
    }

    private static func severity(_ level: LAACapacityReading.Level) -> Int {
        switch level { case .normal, .recorded: 0; case .warning: 1; case .critical: 2 }
    }

    /// Binary units, as the Bridge counts them: GiB below 1 TiB, TiB above.
    static func bytes(_ value: Double, locale: Locale = Locale(identifier: "ja_JP")) -> String {
        let gib = value / 1_073_741_824
        if gib >= 1024 {
            return (gib / 1024).formatted(.number.locale(locale).precision(.fractionLength(0...2))) + " TiB"
        }
        let digits = gib >= 100 ? 0 : gib >= 10 ? 1 : 2
        return gib.formatted(.number.locale(locale).precision(.fractionLength(0...digits))) + " GiB"
    }
}
#endif
