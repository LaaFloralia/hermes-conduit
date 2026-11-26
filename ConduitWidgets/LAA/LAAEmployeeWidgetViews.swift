#if LAA_BUILD
import AppIntents
import SwiftUI
import LAAKit
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
        // Only the six fixed rows render; a snapshot an older build saved is
        // reprojected onto them (its Codex and Claude weekly rows keep their
        // ids), and anything without a place there is dropped.
        let usage = snapshot?.usage.map { usage in
            WidgetUsageSnapshot(meters: LAAWidgetUsageBuilder.widgetMeters(usage), checkedAt: usage.checkedAt,
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
            // The employee keeps about 46% on the left; the quota rows take
            // the rest (T3's subscription list, 2026-11-25).
            let employeeWidth = max(0, (frame.size.width - LAASpacing.x3 * 2 - 1) * 0.46)
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
        // Six readings with their numbers need the column's width: past
        // xxLarge the names and periods alone would fill it.
        LAAWidgetUsageColumn(entry: entry, renderedAt: renderedAt, renderingMode: effectiveRenderingMode)
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
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

/// The medium widget's Usage column: six single-line readings in the owner's
/// order (Codex 7d, Claude 5h / 7d / Fable, Google 5h / 7d), each a label,
/// a value in tabular digits, a reset time on the weekly rows and a 4pt bar.
/// Room runs short in this order: the reset time shortens, then goes, and
/// only then does larger text give up rows (five-hour readings first).
struct LAAWidgetUsageColumn: View {
    let entry: LAAEmployeeWidgetEntry
    let renderedAt: Date
    var renderingMode: WidgetRenderingMode = .fullColor
    @Environment(\.laaThemeID) private var themeID
    @ScaledMetric(relativeTo: .caption) private var labelSize: CGFloat = 12
    @ScaledMetric(relativeTo: .caption2) private var noteSize: CGFloat = 11
    @ScaledMetric(relativeTo: .caption) private var providerWidth: CGFloat = 46
    @ScaledMetric(relativeTo: .caption) private var periodWidth: CGFloat = 31
    @ScaledMetric(relativeTo: .caption) private var rowPitch: CGFloat = 22

    private typealias Row = LAAWidgetUsageBuilder.Row

    /// How the weekly rows' reset reads; one form for the whole column, so
    /// the times line up.
    enum ResetForm: CaseIterable { case full, short, hidden }

    var body: some View {
        let rows = LAAWidgetUsageBuilder.widgetRows
        // The first layout whose natural width and height fit: all six rows
        // with the full reset, then shorter resets, then fewer rows.
        ViewThatFits(in: [.horizontal, .vertical]) {
            // One flat list: ViewThatFits needs each candidate's id unique.
            let forms = ResetForm.allCases
            ForEach(0..<(rows.count * forms.count), id: \.self) { candidate in
                usageList(rows: Self.rows(dropping: candidate / forms.count), reset: forms[candidate % forms.count])
            }
        }
        .laaTheme(themeID)
    }

    /// The rows left once `count` have given way, still in widget order.
    static func rows(dropping count: Int) -> [LAAWidgetUsageBuilder.Row] {
        let gone = Set(LAAWidgetUsageBuilder.dropOrder.prefix(count))
        return LAAWidgetUsageBuilder.widgetRows.filter { !gone.contains($0.id) }
    }

    private func usageList(rows: [Row], reset form: ResetForm) -> some View {
        let hidden = LAAWidgetUsageBuilder.widgetRows.count - rows.count
        return VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                // The provider is named once, on its first row.
                let named = index == 0 || rows[index - 1].provider != row.provider
                usageRow(row, named: named, reset: form).frame(maxHeight: rowPitch)
            }
            if hidden > 0 {
                Text(verbatim: "+\(hidden)")
                    .font(.system(size: noteSize, weight: .medium)).monospacedDigit()
                    .foregroundStyle(LAAColor.secondaryText).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .preference(key: LAAWidgetUsageRowsKey.self, value: rows.count)
    }

    /// The reading a row shows now: a recorded value whose reset is still
    /// ahead. Past the reset, or with nothing recorded, the row is unknown
    /// until a fresh observation arrives.
    static func shown(_ meter: WidgetUsageMeter?, at date: Date) -> WidgetUsageMeter? {
        guard let meter, meter.unit == .percent, meter.hasRecordedValue(at: date) else { return nil }
        if let reset = meter.resetsAt, !(date < reset) { return nil }
        return meter
    }

    private func usageRow(_ row: Row, named: Bool, reset form: ResetForm) -> some View {
        let meter = entry.usage?.meters.first { $0.id == row.id }
        let value = Self.shown(meter, at: renderedAt)
        let reset = row.showsReset ? value?.resetsAt : nil
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x1) {
                Text(verbatim: named ? row.name : "")
                    .font(.system(size: labelSize, weight: .medium)).foregroundStyle(LAAColor.text)
                    .lineLimit(1).frame(width: providerWidth, alignment: .leading)
                Text(verbatim: row.period.abbreviation)
                    .font(.system(size: labelSize)).foregroundStyle(LAAColor.secondaryText)
                    .lineLimit(1).frame(width: periodWidth, alignment: .leading)
                Spacer(minLength: 2)
                reading(value, reset: reset.flatMap { date in
                    switch form {
                    case .full: LAAUsageResetText.full(date, now: renderedAt)
                    case .short: LAAUsageResetText.short(date, now: renderedAt)
                    case .hidden: nil
                    }
                })
            }
            // A line never gives up height: squeezing it would shrink the
            // text and let ViewThatFits accept a list that does not fit.
            .fixedSize(horizontal: false, vertical: true)
            LAAUsageMeterTrack(fraction: value.map { $0.amount / 100 }, animates: false, renderingMode: renderingMode)
                .padding(.leading, providerWidth + LAASpacing.x1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: row.label))
        .accessibilityValue(Text(verbatim: accessibilityValue(value, reset: reset)))
        .accessibilityIdentifier("laa.widget.usage.\(row.id)")
    }

    private func reading(_ value: WidgetUsageMeter?, reset: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x1) {
            if let reset {
                Text(verbatim: reset).font(.system(size: labelSize)).monospacedDigit()
                    .foregroundStyle(LAAColor.secondaryText)
            }
            LAAUsageMeterMark(level: LAAMeterLevel(remainingPercent: value?.amount))
                .font(.system(size: labelSize))
            if let value {
                Text(verbatim: LAAEmployeeWidgetView.percentageText(value.amount))
                    .font(.system(size: labelSize, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(LAAColor.text)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func accessibilityValue(_ value: WidgetUsageMeter?, reset: Date?) -> String {
        guard let value else { return LAAShape.unknown }
        let text = LAAEmployeeWidgetView.displayValue(value, entryDate: entry.date, renderedAt: renderedAt,
                                                     anchor: entry.freshnessAnchor)
        return reset.map { text + "、リセット " + LAAUsageResetText.full($0, now: renderedAt) } ?? text
    }
}
#endif
