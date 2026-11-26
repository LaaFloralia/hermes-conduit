#if LAA_BUILD
import AppIntents
import Foundation
import WidgetKit

/// Passes the iPhone's Monet state (WatchPhoneContext.laaAmbient) to the
/// Monet widget: a relevant intent with the values, so the Smart Stack
/// raises the widget while a decision waits or a report is fresh, and a
/// reload so a widget already shown redraws. Nothing is stored.
@MainActor
enum LAAWatchAmbientRelay {
    private static var last: LAAWatchAmbient??

    static func receive(_ ambient: LAAWatchAmbient?) {
        guard last != .some(ambient) else { return }
        last = .some(ambient)
        let now = Date()
        let plan = LAAWatchAmbientPlan.make(ambient, now: now)
        Task {
            var intents: [RelevantIntent] = []
            if plan.score > 0 {
                let until = plan.until ?? now.addingTimeInterval(12 * 3600)
                intents.append(RelevantIntent(LAAMonetStatusIntent(ambient), widgetKind: LAAMonetWatchWidgetKind.kind,
                                              relevance: RelevantContext.date(from: now, to: until)))
            }
            try? await RelevantIntentManager.shared.updateRelevantIntents(intents)
            WidgetCenter.shared.reloadTimelines(ofKind: LAAMonetWatchWidgetKind.kind)
        }
    }
}
#endif
