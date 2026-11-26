#if LAA_BUILD
import Foundation

/// Monet's state for the Apple Watch (HO-06): how many decisions wait on the
/// owner and when Monet's last report arrived. The iPhone app sends it in
/// the existing WatchConnectivity application context
/// (`WatchPhoneContext.laaAmbient`); the Watch app hands it to its widget as
/// a relevant intent, so no server, App Group or new capability is involved.
/// Counts and times only: no title, body or link leaves the iPhone.
struct LAAWatchAmbient: Codable, Equatable {
    /// Open decisions on the board, as the Work tab's badge last read them.
    var waiting: Int
    /// When Monet's last report notification arrived, in seconds since 1970.
    var reportAt: Double?

    var reportDate: Date? { reportAt.map(Date.init(timeIntervalSince1970:)) }

    init(waiting: Int, reportAt: Date?) {
        self.waiting = max(0, waiting)
        self.reportAt = reportAt?.timeIntervalSince1970
    }
}

/// What the Watch's Monet widget shows and how strongly the Smart Stack
/// should surface it. Pure, so the choice is tested on the iPhone.
struct LAAWatchAmbientPlan: Equatable {
    enum Kind: String, Equatable { case decisions, report, idle }

    let kind: Kind
    /// One short line under Monet's name.
    let line: String
    /// The Smart Stack's relevance: 0 never pushes it up.
    let score: Float
    /// Until when this plan holds (a report stops being news).
    let until: Date?

    /// A report is news for this long.
    static let reportWindow: TimeInterval = 6 * 3600

    /// Decisions first (they need the owner), then a fresh report, else
    /// Monet at rest with the call entry.
    static func make(_ ambient: LAAWatchAmbient?, now: Date) -> LAAWatchAmbientPlan {
        if let ambient, ambient.waiting > 0 {
            return LAAWatchAmbientPlan(kind: .decisions, line: "判断待ち \(ambient.waiting)件",
                                       score: 80 + Float(min(ambient.waiting, 5)), until: nil)
        }
        if let report = ambient?.reportDate, !(report > now), now.timeIntervalSince(report) < reportWindow {
            let age = now.timeIntervalSince(report)
            // Fresh news ranks highest and fades over the window.
            let score = Float(70 * (1 - age / reportWindow)).rounded()
            return LAAWatchAmbientPlan(kind: .report, line: "報告 \(time(report))",
                                       score: max(10, score), until: report.addingTimeInterval(reportWindow))
        }
        return LAAWatchAmbientPlan(kind: .idle, line: "話しかける", score: 0, until: nil)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = .current
        formatter.dateFormat = "H:mm"
        return formatter.string(from: date)
    }
}
#endif
