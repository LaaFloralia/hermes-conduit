#if LAA_BUILD
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

/// Monet on the Watch face and in the Smart Stack (HO-06): Monet's mascot,
/// her name and one line — decisions waiting, the time of a fresh report, or
/// 話しかける when there is nothing new. The Smart Stack raises it while a decision
/// waits or a report is fresh (LAAWatchAmbientRelay, TimelineEntryRelevance).
/// A widget a person placed on a face has no relevant intent and shows the
/// resting line; tapping opens the app.
struct LAAMonetWatchWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: LAAMonetWatchWidgetKind.kind, intent: LAAMonetStatusIntent.self,
                               provider: LAAMonetStatusProvider()) { entry in
            LAAMonetWatchView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Monet")
        .description("判断待ちと報告を知らせます。")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

struct LAAMonetStatusEntry: TimelineEntry {
    let date: Date
    let plan: LAAWatchAmbientPlan
    var relevance: TimelineEntryRelevance? { plan.score > 0 ? TimelineEntryRelevance(score: plan.score) : nil }
}

struct LAAMonetStatusProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> LAAMonetStatusEntry {
        LAAMonetStatusEntry(date: .now, plan: LAAWatchAmbientPlan.make(nil, now: .now))
    }

    func snapshot(for configuration: LAAMonetStatusIntent, in context: Context) async -> LAAMonetStatusEntry {
        LAAMonetStatusEntry(date: .now, plan: LAAWatchAmbientPlan.make(configuration.ambient, now: .now))
    }

    /// The plan now and, when a report stops being news, the resting line.
    func timeline(for configuration: LAAMonetStatusIntent, in context: Context) async -> Timeline<LAAMonetStatusEntry> {
        let now = Date()
        let plan = LAAWatchAmbientPlan.make(configuration.ambient, now: now)
        var entries = [LAAMonetStatusEntry(date: now, plan: plan)]
        if let until = plan.until {
            entries.append(LAAMonetStatusEntry(date: until, plan: LAAWatchAmbientPlan.make(nil, now: until)))
        }
        return Timeline(entries: entries, policy: .never)
    }

    func recommendations() -> [AppIntentRecommendation<LAAMonetStatusIntent>] {
        [AppIntentRecommendation(intent: LAAMonetStatusIntent(), description: "Monet")]
    }
}

struct LAAMonetWatchView: View {
    let entry: LAAMonetStatusEntry
    var familyOverride: WidgetFamily?
    @Environment(\.widgetFamily) private var environmentFamily

    init(entry: LAAMonetStatusEntry, familyOverride: WidgetFamily? = nil) {
        self.entry = entry
        self.familyOverride = familyOverride
    }

    private var family: WidgetFamily { familyOverride ?? environmentFamily }
    private var spoken: String { "Monet \(entry.plan.line)" }

    var body: some View {
        switch family {
        case .accessoryCorner:
            LAAMonetMascot(size: 32)
                .widgetLabel { Text(verbatim: entry.plan.line) }
                .accessibilityLabel(Text(verbatim: spoken))
        case .accessoryRectangular:
            HStack(spacing: 8) {
                LAAMonetMascot(size: 40)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: "Monet")
                        .font(.headline)
                    Text(verbatim: entry.plan.line)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(entry.plan.kind == .idle ? .secondary : .primary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: spoken))
        case .accessoryInline:
            Text(verbatim: "Monet · \(entry.plan.line)")
        default:
            ZStack {
                AccessoryWidgetBackground()
                LAAMonetMascot(size: 40)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: spoken))
        }
    }
}

/// Monet's still, copied into the widget at build time
/// (scripts/laa/watch-staff-avatars.sh → staff/monet.png). Without it the
/// widget keeps the waveform the Talk complication uses.
struct LAAMonetMascot: View {
    let size: CGFloat

    static let image: UIImage? = Bundle.main.path(forResource: "monet", ofType: "png", inDirectory: "staff")
        .flatMap(UIImage.init(contentsOfFile:))

    var body: some View {
        if let image = Self.image {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .widgetAccentable(false)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "waveform")
                .font(.system(size: size * 0.5, weight: .semibold))
                .accessibilityHidden(true)
        }
    }
}
#endif
