#if LAA_BUILD
import Foundation

struct LAAUsagePage: Codable {
    let items: [LAAUsageItem]
    let nextCursor: String?
}

struct LAAUsageItem: Codable, Identifiable {
    struct Window: Codable {
        let label: String
        let remainingPercent: Double?
        let resetsAt: String?
        let windowMinutes: Double?
    }
    struct Component: Codable {
        let kind: String
        let amount: Double
        let grantedAmount: Double?
        let expiresOnUtc: String?
    }
    struct Credits: Codable {
        let remaining: Double?
        let updatedAt: String?
    }
    struct RecordedUsage: Codable {
        let inputTokens: Double?
        let outputTokens: Double?
    }
    struct Detail: Codable {
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
    var retainedReason: String? = nil

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
        if item.stale || item.retainedReason != nil { return true }
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

    /// Historical observations keep their number and receive an age label.
    static func isPast(_ item: LAAUsageItem, at now: Date = Date()) -> Bool {
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

/// What a meter's length means, for the app list and the widget alike. Quota
/// windows and granted credits count down, so a short bar is the warning;
/// storage counts up, so a long one is. Before 2026-11-11 every bar turned to
/// the attention colour at 90%, which painted a nearly full Magnific grant as
/// a problem and an empty Codex week as fine.
enum LAAUsageMeterRule {
    static let lowRemaining = 0.2
    static let highUse = 0.9

    static func needsAttention(_ fraction: Double, countsDown: Bool) -> Bool {
        guard fraction.isFinite else { return false }
        return countsDown ? fraction < lowRemaining : !(fraction < highUse)
    }

    /// The share of a grant still left, when the feed names the grant.
    static func grantFraction(remaining: Double?, granted: Double?) -> Double? {
        guard let remaining, let granted, remaining.isFinite, granted.isFinite, granted > 0 else { return nil }
        return min(max(remaining / granted, 0), 1)
    }
}

/// A historical observation keeps its timestamp; a fetch attempt never ages it forward.
enum LAAUsageAge {
    static func text(_ observed: Date, at now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(observed) / 60))
        if minutes == 0 { return "たった今" }
        if minutes < 60 { return "\(minutes)分前" }
        if minutes < 1440 { return "\(minutes / 60)時間前" }
        return "\(minutes / 1440)日前"
    }
}
#endif
