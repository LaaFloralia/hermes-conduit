#if LAA_BUILD && DEBUG && targetEnvironment(simulator)
import SwiftUI
import WidgetKit

/// `-laa-watch-monet-gallery`: the Monet widget's views (HO-06) at the
/// accessory sizes, for the three plans, so they can be photographed in
/// the app; it also hands the widget a waiting decision as a relevant
/// intent, so the Smart Stack on the face can be photographed after it.
struct LAAMonetWatchGallery: View {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("-laa-watch-monet-gallery") }

    private let now = Date()
    private var plans: [LAAWatchAmbientPlan] {
        [LAAWatchAmbientPlan.make(LAAWatchAmbient(waiting: 2, reportAt: nil), now: now),
         LAAWatchAmbientPlan.make(LAAWatchAmbient(waiting: 0, reportAt: now.addingTimeInterval(-25 * 60)), now: now),
         LAAWatchAmbientPlan.make(nil, now: now)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(plans.enumerated()), id: \.offset) { _, plan in
                    let entry = LAAMonetStatusEntry(date: now, plan: plan)
                    LAAMonetWatchView(entry: entry, familyOverride: .accessoryRectangular)
                        .frame(width: 186, height: 66, alignment: .leading)
                    HStack(spacing: 12) {
                        LAAMonetWatchView(entry: entry, familyOverride: .accessoryCircular)
                            .frame(width: 50, height: 50)
                            .clipShape(Circle())
                        LAAMonetWatchView(entry: entry, familyOverride: .accessoryInline)
                            .font(.footnote)
                            .lineLimit(1)
                    }
                    Divider()
                }
            }
            .padding(.horizontal, 4)
        }
        .accessibilityIdentifier("laa.watch.monetGallery")
        .onAppear { LAAWatchAmbientRelay.receive(LAAWatchAmbient(waiting: 2, reportAt: nil)) }
    }
}
#endif
