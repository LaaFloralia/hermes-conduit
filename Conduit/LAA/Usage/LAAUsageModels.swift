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
#endif
