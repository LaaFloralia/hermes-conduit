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
        .ciel: "Ciel", .cielUncensored: "Ciel（無検閲）", .argus: "Argus", .cfo: "Morgan", .cio: "Sherlock",
        .cmo: "Monet", .cos: "Merlin", .cto: "Ada", .cso: "Talos"
    ]
}

struct LAAEmployeeWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Employee"
    static let description = IntentDescription("Open an employee's chat or call from the Home Screen.")
    @Parameter(title: "Employee", default: .ciel) var employee: LAAWidgetEmployee
    init() { employee = .defaultEmployee }
}

struct LAAEmployeeWidgetEntry: TimelineEntry {
    let date: Date
    let freshnessAnchor: Date
    let employee: LAAWidgetEmployee
    let chat: WidgetLaunchLink
    let call: WidgetLaunchLink
    let mediumChat: WidgetLaunchLink
    let mediumCall: WidgetLaunchLink
    let usageLink: WidgetLaunchLink
    let usage: WidgetUsageSnapshot?

    static func make(employee: LAAWidgetEmployee, snapshot: WidgetSnapshot?, date: Date = Date(), freshnessAnchor: Date? = nil) -> Self {
        let usage = snapshot?.usage.map { usage in
            WidgetUsageSnapshot(meters: usage.displayableMeters, checkedAt: usage.checkedAt,
                                hasOtherUsage: usage.hasOtherUsage ?? false)
        }
        return Self(date: date, freshnessAnchor: freshnessAnchor ?? date, employee: employee,
             chat: LAAEmployeeWidgetLinks.link(employee: employee, action: .employeeChat, snapshot: snapshot),
             call: LAAEmployeeWidgetLinks.link(employee: employee, action: employee == .cielUncensored ? .employeeChat : .talk, snapshot: snapshot),
             mediumChat: LAAEmployeeWidgetLinks.link(employee: .ciel, action: .employeeChat, snapshot: snapshot),
             mediumCall: LAAEmployeeWidgetLinks.link(employee: .ciel, action: .talk, snapshot: snapshot),
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
        Self.makeTimeline(configuration: configuration, snapshot: WidgetSnapshotStore.production?.read())
    }

    static func makeTimeline(configuration: LAAEmployeeWidgetIntent, snapshot: WidgetSnapshot?) -> Timeline<LAAEmployeeWidgetEntry> {
        let entry = LAAEmployeeWidgetEntry.make(employee: configuration.employee, snapshot: snapshot)
        let futureDates = Set((entry.usage?.meters ?? []).flatMap { meter in
            [meter.freshUntil, meter.resetsAt,
             meter.observedAt.map { min($0, entry.freshnessAnchor).addingTimeInterval(10 * 60) }].compactMap { $0 }
        }
            .filter { $0 > entry.date }).sorted()
        let future = futureDates.map { LAAEmployeeWidgetEntry.make(employee: configuration.employee, snapshot: snapshot, date: $0, freshnessAnchor: entry.freshnessAnchor) }
        return Timeline(entries: [entry] + future, policy: future.isEmpty ? .never : .atEnd)
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
    static let widgetCall = "Call"
    static let widgetChat = "Chat"
    static let widgetBrand = "LAA"
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
        HStack(spacing: LAASpacing.x3) {
            VStack(spacing: LAASpacing.x1) {
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        employeeImage(LAAWidgetEmployee.ciel.heroImage)
                            .scaledToFit()
                            .frame(width: geometry.size.height, height: geometry.size.height)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .accessibilityHidden(true)
                        HStack(spacing: LAASpacing.x2) {
                            companyIcon
                            Text(verbatim: LAAWidgetEmployee.ciel.name).font(LAAType.employeeName)
                                .foregroundStyle(LAAColor.text).lineLimit(1)
                        }
                    }
                }
                // Bare symbols, like the system's own widget controls: a
                // filled plate reads as a hazy glow on tinted and clear Home
                // Screens.
                HStack(spacing: LAASpacing.x2) {
                    iconAction(entry.mediumCall.url, symbol: "phone.fill", label: LAACopy.widgetCall)
                    iconAction(entry.mediumChat.url, symbol: "bubble.left.fill", label: LAACopy.widgetChat)
                }
            }
            .frame(maxWidth: .infinity)
            Rectangle().fill(LAAColor.separator).frame(width: 1)
            usageSummary.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    @ViewBuilder
    private var usageSummary: some View {
        let meters = entry.usage?.meters ?? []
        // The rows are already in the owner's priority order: show as many as
        // fit, from the top.
        ViewThatFits(in: .vertical) {
            usageList(meters: meters, limit: 8)
            usageList(meters: meters, limit: 7)
            usageList(meters: meters, limit: 6)
            usageList(meters: meters, limit: 5)
            usageList(meters: meters, limit: 4)
            usageList(meters: meters, limit: 3)
            usageList(meters: meters, limit: 2)
            usageList(meters: meters, limit: 1)
            usageList(meters: meters, limit: 0)
        }
    }

    private func usageList(meters: [WidgetUsageMeter], limit: Int) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x1 / 4) {
            Text(verbatim: "AI Usage").laaTextStyle(.section).fontWeight(.bold)
                .foregroundStyle(LAAColor.text).accessibilityAddTraits(.isHeader)
            if meters.isEmpty {
                Text(verbatim: LAACopy.notFetched)
                    .laaTextStyle(.section).foregroundStyle(LAAColor.secondaryText)
                    .lineLimit(2).minimumScaleFactor(0.8)
            } else {
                ForEach(Array(meters.prefix(limit))) { meter in usageRow(meter) }
                Spacer(minLength: 0)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func usageRow(_ meter: WidgetUsageMeter) -> some View {
        let past = Self.isPast(meter, entryDate: entry.date, renderedAt: renderedAt, anchor: entry.freshnessAnchor)
        let hasValue = meter.hasRecordedValue(at: renderedAt)
        return HStack(spacing: LAASpacing.x1) {
            Text(verbatim: meter.label).lineLimit(1).minimumScaleFactor(0.75)
            Spacer(minLength: LAASpacing.x1)
            Text(verbatim: hasValue ? Self.valueText(meter) : "未取得")
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75).layoutPriority(1)
        }
        .laaTextStyle(.section)
        .foregroundStyle(!hasValue ? LAAColor.attention : (past ? LAAColor.secondaryText : LAAColor.text))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hasValue ? "\(meter.label), \(Self.valueText(meter)), \(Self.timeText(meter.observedAt!, at: renderedAt))" : "\(meter.label), 未取得")
    }

    static func timeText(_ observation: Date, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = Calendar.current.isDate(observation, inSameDayAs: date) ? "HH:mm" : "M/d HH:mm"
        if Calendar.current.component(.year, from: observation) != Calendar.current.component(.year, from: date) {
            formatter.dateFormat = "yyyy/M/d HH:mm"
        }
        return formatter.string(from: observation) + "時点"
    }

    static func valueText(_ meter: WidgetUsageMeter) -> String {
        switch meter.unit {
        case .percent: return percentageText(meter.amount)
        case .usd: return "$" + meter.amount.formatted(.number.precision(.fractionLength(2)))
        case .credits: return meter.amount.formatted(.number.precision(.fractionLength(0...2))) + " credits"
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
        .accessibilityLabel("Ciel, \(label)")
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
                if entry.employee != .cielUncensored { action(entry.call.url, title: LAACopy.widgetCall, primary: true) }
                action(entry.chat.url, title: LAACopy.widgetChat, primary: false)
            }
        }
        .padding(LAASpacing.x3)
        .widgetURL(entry.defaultLink(for: .systemSmall).url)
    }

    private var rectangular: some View {
        HStack(spacing: LAASpacing.x2) {
            Image(systemName: entry.employee == .cielUncensored ? "bubble.left.fill" : "phone.fill")
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
                Text(verbatim: entry.employee == .cielUncensored ? LAACopy.widgetChat : LAACopy.widgetCall)
                    .laaTextStyle(.secondary)
                    .foregroundStyle(LAAColor.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(LAASpacing.x2)
        .widgetURL(entry.defaultLink(for: .accessoryRectangular).url)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.employee.name), \(entry.employee == .cielUncensored ? LAACopy.widgetChat : LAACopy.widgetCall)")
    }

    private var circular: some View {
        Image("LAAWidgetMark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(LAAColor.link)
            .padding(LAASpacing.x2)
            .widgetURL(entry.defaultLink(for: .accessoryCircular).url)
            .accessibilityLabel("\(entry.employee.name), \(entry.employee == .cielUncensored ? LAACopy.widgetChat : LAACopy.widgetCall)")
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
#endif
