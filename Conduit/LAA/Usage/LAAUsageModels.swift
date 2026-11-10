#if LAA_BUILD
import Foundation

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

    static func reading(_ item: LAAUsageItem, at now: Date = Date(), allowHistorical: Bool = false) -> LAACapacityReading? {
        guard item.kind == "capacity", item.unit == "bytes", item.availability == "available",
              (!LAAUsageFreshness.isStale(item, at: now) || allowHistorical),
              let observed = LAAUsageItem.date(item.observedAt), !(now.addingTimeInterval(120) < observed),
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
