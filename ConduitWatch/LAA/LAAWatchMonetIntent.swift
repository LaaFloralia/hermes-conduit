#if LAA_BUILD
import AppIntents
import Foundation
import WidgetKit

/// The Monet widget's configuration (HO-06). watchOS shows no configuration
/// screen: the widget is offered through `recommendations()`, and the Watch
/// app fills these values in a relevant intent so the Smart Stack shows the
/// widget with Monet's current state (LAAWatchAmbientRelay). Built into the
/// Watch app and its widget extension, like TalkToHermesIntent.
struct LAAMonetStatusIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Monet"
    static let description = IntentDescription("Monet's decisions and reports.")

    @Parameter(title: "Waiting", default: 0)
    var waiting: Int

    @Parameter(title: "Report")
    var reportAt: Date?

    init() {}

    init(_ ambient: LAAWatchAmbient?) {
        waiting = ambient?.waiting ?? 0
        reportAt = ambient?.reportDate
    }

    var ambient: LAAWatchAmbient { LAAWatchAmbient(waiting: waiting, reportAt: reportAt) }
}

enum LAAMonetWatchWidgetKind {
    static let kind = "com.laa-inc.laa.watch.monet"
}
#endif
