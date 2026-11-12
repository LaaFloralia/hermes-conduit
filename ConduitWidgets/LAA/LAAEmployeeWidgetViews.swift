#if LAA_BUILD
import AppIntents
import SwiftUI
import WidgetKit
#if LAA_WIDGET_TEST
@testable import Conduit
private final class LAAWidgetTestResources {}
#endif

extension LAAWidgetEmployee: AppEnum {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Employee")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .monet: "Monet", .monetUncensored: "Monet（無検閲）", .argus: "Argus", .cfo: "Morgan", .cio: "Sherlock",
        .cos: "Merlin", .cto: "Ada", .cso: "Talos"
    ]
}

struct LAAEmployeeWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Employee"
    static let description = IntentDescription("Open an employee's chat or call from the Home Screen.")
    @Parameter(title: "Employee", default: .monet) var employee: LAAWidgetEmployee
    init() { employee = .defaultEmployee }
}

struct LAAEmployeeWidgetEntry: TimelineEntry {
    let date: Date
    let freshnessAnchor: Date
    let employee: LAAWidgetEmployee
    let chat: WidgetLaunchLink
    let call: WidgetLaunchLink
    let usageLink: WidgetLaunchLink
    let usage: WidgetUsageSnapshot?

    static func make(employee: LAAWidgetEmployee, snapshot: WidgetSnapshot?, date: Date = Date(), freshnessAnchor: Date? = nil) -> Self {
        let usage = snapshot?.usage.map { usage in
            WidgetUsageSnapshot(meters: usage.displayableMeters, checkedAt: usage.checkedAt,
                                hasOtherUsage: usage.hasOtherUsage ?? false)
        }
        return Self(date: date, freshnessAnchor: freshnessAnchor ?? date, employee: employee,
             chat: LAAEmployeeWidgetLinks.link(employee: employee, action: .employeeChat, snapshot: snapshot),
             call: LAAEmployeeWidgetLinks.link(employee: employee, action: employee == .monetUncensored ? .employeeChat : .talk, snapshot: snapshot),
             usageLink: WidgetLaunchLink(action: .usage, workspace: nil, reference: nil)!,
             usage: usage)
    }

    func defaultLink(for family: WidgetFamily) -> WidgetLaunchLink {
        if family == .systemMedium { return usageLink }
        return family == .systemSmall ? chat : call
    }
}

struct LAAEmployeeTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> LAAEmployeeWidgetEntry { .make(employee: .defaultEmployee, snapshot: nil) }
    func snapshot(for configuration: LAAEmployeeWidgetIntent, in context: Context) async -> LAAEmployeeWidgetEntry {
        .make(employee: configuration.employee, snapshot: WidgetSnapshotStore.production?.read())
    }
    func timeline(for configuration: LAAEmployeeWidgetIntent, in context: Context) async -> Timeline<LAAEmployeeWidgetEntry> {
        Self.makeTimeline(configuration: configuration, snapshot: await LAAWidgetUsageRefresh.refresh())
    }

    static func makeTimeline(configuration: LAAEmployeeWidgetIntent, snapshot: WidgetSnapshot?) -> Timeline<LAAEmployeeWidgetEntry> {
        let entry = LAAEmployeeWidgetEntry.make(employee: configuration.employee, snapshot: snapshot)
        // Future entries update elapsed labels even if iOS delays the next
        // network reload. Refresh policy is independent of the last entry.
        let ageDates = stride(from: 300, through: 3600, by: 300).map { entry.date.addingTimeInterval(Double($0)) }
            + stride(from: 7200, through: 86400, by: 3600).map { entry.date.addingTimeInterval(Double($0)) }
        let futureDates = Set(ageDates + (entry.usage?.meters ?? []).flatMap { meter in
            [meter.freshUntil, meter.resetsAt,
             meter.observedAt.map { min($0, entry.freshnessAnchor).addingTimeInterval(10 * 60) }].compactMap { $0 }
        }
            .filter { $0 > entry.date }).sorted()
        let future = futureDates.map { LAAEmployeeWidgetEntry.make(employee: configuration.employee, snapshot: snapshot, date: $0, freshnessAnchor: entry.freshnessAnchor) }
        return Timeline(entries: [entry] + future, policy: .after(entry.date.addingTimeInterval(15 * 60)))
    }
}

struct LAAEmployeeWidget: Widget {
    static let supportedFamilies: [WidgetFamily] = [.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular]

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: ConduitWidgetKind.employee, intent: LAAEmployeeWidgetIntent.self, provider: LAAEmployeeTimelineProvider()) { entry in
            LAAEmployeeWidgetView(entry: entry)
        }
        .configurationDisplayName(Text(verbatim: LAACopy.widgetDisplayName))
        .description(Text(verbatim: LAACopy.widgetDescription))
        .supportedFamilies(Self.supportedFamilies)
        .contentMarginsDisabled()
    }
}

private extension LAACopy {
    static let widgetDisplayName = "LAA Employee"
    static let widgetDescription = "Open employee chats and calls, and check AI usage."
    static let widgetCall = "電話"
    static let widgetChat = "会話"
    static let widgetBrand = "LAA"
}

/// How many Usage rows the medium widget drew, so a test can tell a row the
/// layout dropped from one that was never there.
struct LAAWidgetUsageRowsKey: PreferenceKey {
    static let defaultValue: Int? = nil
    static func reduce(value: inout Int?, nextValue: () -> Int?) { value = nextValue() ?? value }
}

struct LAAEmployeeWidgetView: View {
    let entry: LAAEmployeeWidgetEntry
    var familyOverride: WidgetFamily? = nil
    var renderingModeOverride: WidgetRenderingMode? = nil
    var renderedAtOverride: Date? = nil
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    private var effectiveRenderingMode: WidgetRenderingMode { renderingModeOverride ?? renderingMode }
    private var renderedAt: Date { max(entry.date, renderedAtOverride ?? Date()) }

    static func isPast(_ meter: WidgetUsageMeter, entryDate: Date, renderedAt: Date, anchor: Date? = nil) -> Bool {
        meter.isPast(at: max(entryDate, renderedAt), anchor: anchor ?? entryDate)
    }

    var body: some View {
        Group {
            switch familyOverride ?? family {
            case .accessoryRectangular: rectangular
            case .accessoryCircular: circular
            case .systemMedium: medium
            default: small
            }
        }
        .containerBackground(for: .widget) { LAAColor.surface }
    }

    private var medium: some View {
        GeometryReader { frame in
            // The Usage column takes a little more than half: a name and a
            // value share one line in each of its seven rows.
            let employeeWidth = max(0, (frame.size.width - LAASpacing.x3 * 2 - 1) * 0.48)
            HStack(spacing: LAASpacing.x3) {
                VStack(spacing: LAASpacing.x1) {
                    GeometryReader { geometry in
                        ZStack(alignment: .topLeading) {
                            employeeImage(entry.employee.heroImage)
                                .scaledToFit()
                                .frame(width: max(0, geometry.size.height - (entry.employee == .monetUncensored ? 28 : 0)),
                                       height: max(0, geometry.size.height - (entry.employee == .monetUncensored ? 28 : 0)))
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                                .accessibilityHidden(true)
                            HStack(spacing: LAASpacing.x2) {
                                companyIcon
                                Text(verbatim: entry.employee.name).font(LAAType.employeeName)
                                    .foregroundStyle(LAAColor.text).lineLimit(1)
                                    .minimumScaleFactor(entry.employee == .monetUncensored ? 0.55 : 1)
                            }
                        }
                    }
                    // Bare symbols, like the system's own widget controls: a
                    // filled plate reads as a hazy glow on tinted and clear Home
                    // Screens.
                    HStack(spacing: LAASpacing.x2) {
                        if entry.employee != .monetUncensored {
                            iconAction(entry.call.url, symbol: "phone.fill", label: LAACopy.widgetCall)
                        }
                        iconAction(entry.chat.url, symbol: "bubble.left.fill", label: LAACopy.widgetChat)
                    }
                }
                .frame(width: employeeWidth)
                Rectangle().fill(LAAColor.separator).frame(width: 1)
                usageSummary.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(LAASpacing.x3)
        .widgetURL(entry.usageLink.url)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }

    private var companyIcon: some View {
        Group {
            #if LAA_WIDGET_TEST
            let image = Image("LAAWidgetCompanyIcon", bundle: Bundle(for: LAAWidgetTestResources.self))
            #else
            let image = Image("LAAWidgetCompanyIcon")
            #endif
            if #available(iOS 18.0, *) {
                image.resizable().widgetAccentedRenderingMode(.accentedDesaturated)
            } else {
                image.resizable()
            }
        }
        .scaledToFit()
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityLabel(Text(verbatim: LAACopy.widgetBrand))
    }

    /// Its own view, so its text sizes read the medium widget's capped
    /// Dynamic Type rather than the environment above the cap.
    private var usageSummary: some View {
        LAAWidgetUsageColumn(entry: entry, renderedAt: renderedAt)
    }

    static func timeText(_ observation: Date, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = Calendar.current.isDate(observation, inSameDayAs: date) ? "HH:mm" : "M/d HH:mm"
        if Calendar.current.component(.year, from: observation) != Calendar.current.component(.year, from: date) {
            formatter.dateFormat = "yyyy/M/d HH:mm"
        }
        return formatter.string(from: observation) + " 時点"
    }

    static func displayValue(_ meter: WidgetUsageMeter, entryDate: Date, renderedAt: Date, anchor: Date? = nil) -> String {
        guard meter.hasRecordedValue(at: renderedAt) else { return "未取得" }
        let note = freshnessText(meter, at: max(entryDate, renderedAt), anchor: anchor ?? entryDate)
        return valueText(meter) + (note.map { " · " + $0 } ?? "")
    }

    static func freshnessText(_ meter: WidgetUsageMeter, at now: Date, anchor: Date? = nil) -> String? {
        guard meter.hasRecordedValue(at: now) else { return nil }
        if meter.resetsAt.map({ !(now < $0) }) == true, let observed = meter.observedAt {
            return LAAUsageAge.text(observed, at: now) + "・リセット済み"
        }
        guard meter.isPast(at: now, anchor: anchor), let observed = meter.observedAt else { return nil }
        return LAAUsageAge.text(observed, at: now)
    }

    static func valueText(_ meter: WidgetUsageMeter) -> String {
        switch meter.unit {
        case .percent: return percentageText(meter.amount)
        case .usd: return (meter.amount < 0 ? "-$" : "$") + abs(meter.amount).formatted(.number.precision(.fractionLength(2)))
        case .credits: return meter.amount.formatted(.number.locale(Locale(identifier: "ja_JP")).precision(.fractionLength(0...2)))
        }
    }

    static func percentageText(_ value: Double) -> String {
        if value > 0 && value < 0.01 { return "<0.01%" }
        if value < 100 && value > 99.99 { return ">99.99%" }
        return value.formatted(.number.precision(.fractionLength(0...2))) + "%"
    }

    private func iconAction(_ url: URL, symbol: String, label: String) -> some View {
        Link(destination: url) {
            Image(systemName: symbol).font(.title3).fontWeight(.semibold)
                .foregroundStyle(LAAColor.link)
                .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.employee.name), \(label)")
    }

    private var small: some View {
        VStack(spacing: LAASpacing.x2) {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    employeeImage(entry.employee.heroImage)
                        .scaledToFit()
                        .frame(width: geometry.size.height, height: geometry.size.height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .offset(y: -LAASpacing.x1)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: LAASpacing.x1) {
                        Text(entry.employee.name)
                            .font(LAAType.employeeName)
                            .foregroundStyle(LAAColor.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text(verbatim: LAACopy.widgetBrand)
                            .laaTextStyle(.section)
                            .fontWeight(.bold)
                            .foregroundStyle(LAAColor.link)
                    }
                    .frame(width: geometry.size.width * 0.45, alignment: .topLeading)
                }
            }
            HStack(spacing: LAASpacing.x2) {
                if entry.employee != .monetUncensored { action(entry.call.url, title: LAACopy.widgetCall, primary: true) }
                action(entry.chat.url, title: LAACopy.widgetChat, primary: false)
            }
        }
        .padding(LAASpacing.x3)
        .widgetURL(entry.defaultLink(for: .systemSmall).url)
    }

    private var rectangular: some View {
        HStack(spacing: LAASpacing.x2) {
            Image(systemName: entry.employee == .monetUncensored ? "bubble.left.fill" : "phone.fill")
                .laaTextStyle(.body)
                .fontWeight(.semibold)
                .foregroundStyle(LAAColor.link)
                .frame(width: LAASpacing.minimumRowHeight, height: LAASpacing.minimumRowHeight)
                .background(Circle().fill(LAAColor.selectionFill))
            VStack(alignment: .leading, spacing: LAASpacing.x1) {
                Text(entry.employee.name)
                    .laaTextStyle(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(LAAColor.text)
                    .lineLimit(1)
                Text(verbatim: entry.employee == .monetUncensored ? LAACopy.widgetChat : LAACopy.widgetCall)
                    .laaTextStyle(.secondary)
                    .foregroundStyle(LAAColor.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(LAASpacing.x2)
        .widgetURL(entry.defaultLink(for: .accessoryRectangular).url)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.employee.name), \(entry.employee == .monetUncensored ? LAACopy.widgetChat : LAACopy.widgetCall)")
    }

    private var circular: some View {
        Image("LAAWidgetMark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(LAAColor.link)
            .padding(LAASpacing.x2)
            .widgetURL(entry.defaultLink(for: .accessoryCircular).url)
            .accessibilityLabel("\(entry.employee.name), \(entry.employee == .monetUncensored ? LAACopy.widgetChat : LAACopy.widgetCall)")
    }

    @ViewBuilder
    private func employeeImage(_ name: String) -> some View {
        #if LAA_WIDGET_TEST
        let image = Image(name, bundle: Bundle(for: LAAWidgetTestResources.self))
        #else
        let image = Image(name)
        #endif
        if #available(iOS 18.0, *) {
            image.resizable().widgetAccentedRenderingMode(.fullColor)
        } else {
            image.resizable()
        }
    }

    private func action(_ url: URL, title: String, primary: Bool) -> some View {
        Link(destination: url) {
            Text(verbatim: title)
                .laaTextStyle(.secondary)
                .fontWeight(.semibold)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumTouchTarget)
                .foregroundStyle(effectiveRenderingMode == .fullColor && primary ? LAAColor.filledButtonText : LAAColor.link)
                .background {
                    if effectiveRenderingMode == .fullColor {
                        RoundedRectangle(cornerRadius: LAARadius.control)
                            .fill(primary ? LAAColor.filledButton : LAAColor.subtleSurface)
                    } else {
                        RoundedRectangle(cornerRadius: LAARadius.control)
                            .fill(LAAColor.text.opacity(primary ? 0.24 : 0.14))
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.employee.name), \(title)")
    }
}

/// The medium widget's Usage column: the owner's rows in priority order.
private struct LAAWidgetUsageColumn: View {
    let entry: LAAEmployeeWidgetEntry
    let renderedAt: Date
    // The medium Usage column: one size for names and values, so seven rows
    // fit a Pro Max with the heading; the count of hidden rows is a step smaller.
    @ScaledMetric(relativeTo: .footnote) private var usageHeadingSize: CGFloat = 13
    @ScaledMetric(relativeTo: .caption) private var usageLabelSize: CGFloat = 12
    @ScaledMetric(relativeTo: .caption2) private var usageNoteSize: CGFloat = 11
    @ScaledMetric(relativeTo: .caption) private var usageRowPitch: CGFloat = 20

    var body: some View {
        let meters = entry.usage?.meters ?? []
        // The rows are already in the owner's priority order. All seven fit
        // a Pro Max under the heading; a smaller phone keeps the seven and
        // lets the heading go. Larger text then drops rows from the bottom,
        // and the heading says how many are left for the Usage screen.
        ViewThatFits(in: .vertical) {
            usageList(meters: meters, limit: meters.count, heading: true)
            if meters.count > 1 {
                usageList(meters: meters, limit: meters.count, heading: false)
            }
            ForEach((0..<max(meters.count, 1)).reversed(), id: \.self) { limit in
                usageList(meters: meters, limit: limit, heading: true)
            }
        }
    }

    private func usageList(meters: [WidgetUsageMeter], limit: Int, heading: Bool) -> some View {
        let shown = min(limit, meters.count)
        return VStack(alignment: .leading, spacing: 0) {
            if heading {
                HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x1) {
                    Text(verbatim: "Usage").font(.system(size: usageHeadingSize, weight: .bold))
                        .foregroundStyle(LAAColor.text).accessibilityAddTraits(.isHeader)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    if shown < meters.count {
                        // Large text leaves room only for the count.
                        ViewThatFits(in: .horizontal) {
                            Text(verbatim: "ほか\(meters.count - shown)件")
                            Text(verbatim: "+\(meters.count - shown)")
                        }
                        .font(.system(size: usageNoteSize, weight: .medium))
                        .foregroundStyle(LAAColor.secondaryText).lineLimit(1)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if meters.isEmpty {
                Text(verbatim: LAACopy.notFetched)
                    .font(.system(size: usageLabelSize, weight: .medium)).foregroundStyle(LAAColor.secondaryText)
                    .lineLimit(2).minimumScaleFactor(0.8)
            } else {
                ForEach(Array(meters.prefix(shown))) { meter in
                    // Each row may open up a little to fill the column, so
                    // seven rows and five rows keep the same rhythm.
                    usageRow(meter).frame(maxHeight: usageRowPitch, alignment: .center)
                }
            }
            Spacer(minLength: 0)
        }
        .preference(key: LAAWidgetUsageRowsKey.self, value: shown)
    }

    /// One line per provider: the name, then the value right-aligned so the
    /// numbers form a column, and a hairline meter under quotas, Magnific's
    /// grant and the money balances. No age is drawn (owner, 2026-11-12: no
    /// 「6日前」 in the widget); VoiceOver still reads it, and the Usage
    /// screen shows when each value was read. Every row keeps the meter's
    /// room, so rows with and without one share the same pitch.
    private func usageRow(_ meter: WidgetUsageMeter) -> some View {
        let hasValue = meter.hasRecordedValue(at: renderedAt)
        let fraction = hasValue ? meter.remainingFraction : nil
        return VStack(alignment: .leading, spacing: LAASpacing.x1 / 2) {
            HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x1) {
                Text(verbatim: meter.label.replacingOccurrences(of: " Weekly", with: ""))
                    .font(.system(size: usageLabelSize, weight: .medium))
                    // Truncates before it pushes the value out of the column.
                    .lineLimit(1).layoutPriority(1)
                Spacer(minLength: LAASpacing.x1)
                Text(verbatim: hasValue ? LAAEmployeeWidgetView.valueText(meter) : LAACopy.notFetched)
                    .font(.system(size: usageLabelSize, weight: hasValue ? .semibold : .regular))
                    .monospacedDigit().lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            // A line never gives up height: squeezing it would shrink the
            // text and let ViewThatFits accept a list that does not fit.
            .fixedSize(horizontal: false, vertical: true)
            ZStack(alignment: .leading) {
                if let fraction {
                    // The bar turns to the attention colour below a fifth, as in the app.
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(LAAColor.separator)
                            Capsule().fill(LAAUsageMeterRule.needsAttention(fraction, countsDown: true)
                                           ? LAAColor.attention : LAAColor.link)
                                .frame(width: max(geometry.size.width * fraction, fraction > 0 ? 2 : 0))
                        }
                    }
                }
            }
            .frame(height: 2)
            .accessibilityHidden(true)
        }
        .foregroundStyle(hasValue ? LAAColor.text : LAAColor.secondaryText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(meter.label), \(LAAEmployeeWidgetView.displayValue(meter, entryDate: entry.date, renderedAt: renderedAt, anchor: entry.freshnessAnchor))")
    }
}
#endif
