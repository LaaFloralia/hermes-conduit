#if LAA_BUILD
import Foundation
import UIKit

/// The iPhone side of the Watch's Monet widget (HO-06): the decision count
/// the Work tab's badge last read (`laa.work.decisionCount`) and the time the
/// notification extension recorded for Monet's last report
/// (LAAMonetReportLedger). Sent in the existing application context by
/// `AppState.shareWatchCallVoices`, which this asks to run again when either
/// value changes while the app runs or comes back to the screen.
@MainActor
enum LAAWatchAmbientSource {
    static let decisionCountKey = "laa.work.decisionCount"

    static func current(defaults: UserDefaults = .standard,
                        reports: UserDefaults? = NotificationSharedSettings.defaults) -> LAAWatchAmbient {
        LAAWatchAmbient(waiting: defaults.integer(forKey: decisionCountKey),
                        reportAt: LAAMonetReportLedger.lastReport(defaults: reports))
    }

    private static var observers: [NSObjectProtocol] = []
    private static var shared: LAAWatchAmbient?

    /// Calls `share` whenever the values differ from the last ones shared.
    /// Registers once; later calls only note what was just shared.
    static func observe(shared ambient: LAAWatchAmbient, share: @escaping @MainActor () -> Void) {
        shared = ambient
        guard observers.isEmpty else { return }
        let check: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated {
                if current() != shared { share() }
            }
        }
        observers = [
            NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: UserDefaults.standard,
                                                   queue: .main, using: check),
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                                   queue: .main, using: check),
        ]
    }
}
#endif
