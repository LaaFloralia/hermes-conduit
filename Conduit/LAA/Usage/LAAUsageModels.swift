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
    struct ResetPasses: Decodable {
        let available: Bool
        let remaining: Double?
        let updatedAt: String?
        let expiresAt: String?
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
        let resetPasses: ResetPasses?
        let components: [Component]?
        let currency: String?
        let creditUnit: String?
        let grantedAmount: Double?
        let monthlyGrantedAmount: Double?
        let dailyRemaining: Double?
        let dailyGrantedAmount: Double?
        let fallbackAiCredits: Double?
        let usd: Double?
        let diem: Double?
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
              observed <= min(item.freshnessAnchor ?? now, now).addingTimeInterval(120) else { return true }
        let limit = min(observed, item.freshnessAnchor ?? now, now).addingTimeInterval(10 * 60)
        if item.detail?.sourceKind == "verified" { return true }
        if let raw = item.detail?.freshUntil {
            guard let deadline = LAAUsageItem.date(raw) else { return true }
            return min(deadline, limit) <= now
        }
        // Older Bridges do not supply freshUntil, but do send observedAt and stale.
        return limit <= now
    }

    static func windowExpired(_ window: LAAUsageItem.Window, at now: Date = Date()) -> Bool {
        LAAUsageItem.date(window.resetsAt).map { $0 <= now } ?? false
    }

    static func outdated(_ text: String?, at now: Date = Date()) -> Bool {
        guard let date = LAAUsageItem.date(text) else { return true }
        return date > now.addingTimeInterval(120) || now.timeIntervalSince(date) >= 10 * 60
    }

    static func extraNeedsAttention(_ item: LAAUsageItem, at now: Date = Date()) -> Bool {
        if let credits = item.detail?.credits, outdated(credits.updatedAt, at: now) { return true }
        if let passes = item.detail?.resetPasses {
            return !passes.available || outdated(passes.updatedAt, at: now) ||
                (LAAUsageItem.date(passes.expiresAt).map { $0 <= now } ?? true)
        }
        return false
    }
}
#endif
