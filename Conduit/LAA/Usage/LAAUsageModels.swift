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
        let totalBytes: Double?
        let availableBytes: Double?
        let swapUsedBytes: Double?
        let totalGb: Double?
        let expiresOnUtc: String?
        let renewsAt: String?
        let level: String?
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
#endif
