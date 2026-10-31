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
        .ciel: "Ciel", .argus: "Argus", .cfo: "Morgan", .cio: "Sherlock",
        .cmo: "Monet", .cos: "Merlin", .cto: "Ada", .cso: "Talos"
    ]
}

struct LAAEmployeeWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Employee"
    static let description = IntentDescription("ホーム画面から社員の会話や電話を開きます。")
    @Parameter(title: "Employee", default: .ciel) var employee: LAAWidgetEmployee
    init() { employee = .defaultEmployee }
}

struct LAAEmployeeWidgetEntry: TimelineEntry {
    let date: Date
    let employee: LAAWidgetEmployee
    let chat: WidgetLaunchLink
    let call: WidgetLaunchLink
    let mediumChat: WidgetLaunchLink
    let mediumCall: WidgetLaunchLink
    let usageLink: WidgetLaunchLink
    let usage: WidgetUsageSnapshot?

    static func make(employee: LAAWidgetEmployee, snapshot: WidgetSnapshot?, date: Date = Date()) -> Self {
        Self(date: date, employee: employee,
             chat: LAAEmployeeWidgetLinks.link(employee: employee, action: .employeeChat, snapshot: snapshot),
             call: LAAEmployeeWidgetLinks.link(employee: employee, action: .talk, snapshot: snapshot),
             mediumChat: LAAEmployeeWidgetLinks.link(employee: .ciel, action: .employeeChat, snapshot: snapshot),
             mediumCall: LAAEmployeeWidgetLinks.link(employee: .ciel, action: .talk, snapshot: snapshot),
             usageLink: WidgetLaunchLink(action: .usage, workspace: nil, reference: nil)!,
             usage: snapshot?.usage)
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
        let futureDates = Set((snapshot?.usage?.meters ?? []).flatMap { [$0.freshUntil, $0.resetsAt].compactMap { $0 } }
            .filter { $0 > entry.date }).sorted()
        let future = futureDates.map { LAAEmployeeWidgetEntry.make(employee: configuration.employee, snapshot: snapshot, date: $0) }
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
        .description("社員を選び、会話や電話を開きます。")
        .supportedFamilies(Self.supportedFamilies)
        .contentMarginsDisabled()
    }
}

private extension LAACopy {
    static let widgetDisplayName = "LAA Employee"
    static let widgetCall = "Call"
    static let widgetChat = "Chat"
    static let widgetBrand = "LAA"
}

struct LAAEmployeeWidgetView: View {
    let entry: LAAEmployeeWidgetEntry
    var familyOverride: WidgetFamily? = nil
    var renderingModeOverride: WidgetRenderingMode? = nil
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var effectiveRenderingMode: WidgetRenderingMode { renderingModeOverride ?? renderingMode }

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
                        Text(verbatim: LAAWidgetEmployee.ciel.name).font(LAAType.employeeName)
                            .foregroundStyle(LAAColor.text).lineLimit(1)
                    }
                }
                HStack(spacing: LAASpacing.x2) {
                    iconAction(entry.mediumCall.url, symbol: "phone.fill", label: LAACopy.widgetCall, primary: true)
                    iconAction(entry.mediumChat.url, symbol: "bubble.left.fill", label: LAACopy.widgetChat, primary: false)
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

    @ViewBuilder
    private var usageSummary: some View {
        if dynamicTypeSize.isAccessibilitySize {
            accessibleUsageSummary
        } else {
            regularUsageSummary
        }
    }

    private var regularUsageSummary: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x1) {
            Text(verbatim: "AI Usage").laaTextStyle(.section).fontWeight(.bold)
                .foregroundStyle(LAAColor.text).accessibilityAddTraits(.isHeader)
            if let usage = entry.usage, !usage.meters.isEmpty {
                let displayed = usage.meters
                ForEach(displayed) { meter in
                    let past = meter.isPast(at: entry.date)
                    let percentage = percentageText(meter.remainingPercent)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: LAASpacing.x1) {
                            Text(verbatim: meter.label).lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                            Text(verbatim: percentage)
                                .font(LAAType.employeeName).monospacedDigit()
                        }
                        .laaTextStyle(.section)
                        .foregroundStyle(past ? LAAColor.attention : LAAColor.text)
                        ProgressView(value: meter.remainingPercent, total: 100)
                            .tint(past ? LAAColor.attention : LAAColor.link)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(meter.label), 残り \(percentage)\(past ? ", 最終取得、要確認" : "")")
                }
                Spacer(minLength: 0)
                if displayed.contains(where: { $0.isPast(at: entry.date) }) {
                    Text(verbatim: "一部 最終取得・要確認").laaTextStyle(.section)
                        .foregroundStyle(LAAColor.attention).lineLimit(1).minimumScaleFactor(0.8)
                } else if displayed.contains(where: { $0.legacyFreshness == true || ($0.freshUntil == nil && $0.verified != true) }) {
                    Text(verbatim: displayed.contains(where: { $0.verified == true }) ? "鮮度は目安・一部手動確認" : "旧Bridge・鮮度は目安").laaTextStyle(.section)
                        .foregroundStyle(LAAColor.attention).lineLimit(1).minimumScaleFactor(0.8)
                } else if displayed.contains(where: { $0.verified == true }) {
                    Text(verbatim: "画面確認・自動更新なし").laaTextStyle(.section)
                        .foregroundStyle(LAAColor.secondaryText).lineLimit(1).minimumScaleFactor(0.8)
                }
                if let checked = usage.checkedAt {
                    Text("データ確認 \(checked, format: .dateTime.month().day().hour().minute())")
                        .laaTextStyle(.section).foregroundStyle(LAAColor.secondaryText)
                        .lineLimit(1).minimumScaleFactor(0.75)
                } else {
                    Text(verbatim: "確認時刻 未取得").laaTextStyle(.section).foregroundStyle(LAAColor.secondaryText)
                }
            } else {
                Text(verbatim: entry.usage?.hasOtherUsage == true ? "枠は未取得・他のUsageあり" : LAACopy.notFetched)
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                if let checked = entry.usage?.checkedAt {
                    Text("データ確認 \(checked, format: .dateTime.month().day().hour().minute())")
                        .laaTextStyle(.section).foregroundStyle(LAAColor.secondaryText)
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // A widget cannot grow with Dynamic Type. Keep the requested text size,
    // showing one meter when two would push the freshness or time offscreen.
    private var accessibleUsageSummary: some View {
        ViewThatFits(in: .vertical) {
            accessibleUsageLayout(maxMeters: 2).fixedSize(horizontal: false, vertical: true)
            accessibleUsageLayout(maxMeters: 1).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func accessibleUsageLayout(maxMeters: Int) -> some View {
        let notice = entry.usage.flatMap { Self.accessibleNotice(for: $0.meters, at: entry.date) }
        return VStack(alignment: .leading, spacing: LAASpacing.x1) {
            HStack(spacing: LAASpacing.x1) {
                Text(verbatim: "Usage").laaTextStyle(.section).fontWeight(.bold)
                    .foregroundStyle(LAAColor.text).accessibilityAddTraits(.isHeader)
                if let notice {
                    Spacer(minLength: 0)
                    Text(verbatim: notice.compactText).laaTextStyle(.section)
                        .foregroundStyle(notice == .manual ? LAAColor.secondaryText : LAAColor.attention)
                        .lineLimit(1).layoutPriority(1)
                        .accessibilityLabel(notice.text)
                }
            }
            if let usage = entry.usage, !usage.meters.isEmpty {
                ForEach(Array(usage.meters.prefix(maxMeters))) { meter in
                    let past = meter.isPast(at: entry.date)
                    let percentage = percentageText(meter.remainingPercent)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: LAASpacing.x1) {
                            Text(verbatim: meter.label.components(separatedBy: " · ").first ?? meter.label)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(verbatim: percentage).font(LAAType.employeeName).monospacedDigit()
                        }
                        .laaTextStyle(.section)
                        .foregroundStyle(past ? LAAColor.attention : LAAColor.text)
                        ProgressView(value: meter.remainingPercent, total: 100)
                            .tint(past ? LAAColor.attention : LAAColor.link)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(meter.label), 残り \(percentage)\(past ? ", 最終取得、要確認" : "")")
                }
            } else {
                let hasOtherUsage = entry.usage?.hasOtherUsage == true
                Text(verbatim: hasOtherUsage ? "枠未取得" : LAACopy.notFetched)
                    .laaTextStyle(.section).foregroundStyle(LAAColor.secondaryText)
                    .lineLimit(1)
                    .accessibilityLabel(hasOtherUsage ? "枠は未取得、他のUsageあり" : LAACopy.notFetched)
            }
            if let checked = entry.usage?.checkedAt {
                let parts = Self.accessibleCheckedParts(checked, relativeTo: entry.date)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: parts.date)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text(verbatim: "確認 \(parts.time)")
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                .laaTextStyle(.section).foregroundStyle(LAAColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("確認 \(parts.date) \(parts.time)")
            } else {
                Text(verbatim: "未確認").laaTextStyle(.section)
                    .foregroundStyle(LAAColor.secondaryText).lineLimit(1)
                    .accessibilityLabel("確認時刻は未取得")
            }
        }
    }

    enum AccessibleNotice: Equatable {
        case stale, uncertain, manual

        var text: String {
            switch self {
            case .stale: return "古い・要確認"
            case .uncertain: return "要確認"
            case .manual: return "手動確認"
            }
        }

        var compactText: String {
            switch self {
            case .stale: return "古い"
            case .uncertain: return "注意"
            case .manual: return "手動"
            }
        }
    }

    static func accessibleNotice(for meters: [WidgetUsageMeter], at date: Date) -> AccessibleNotice? {
        // A hidden stale meter must not make the overall snapshot look fresh.
        if meters.contains(where: { $0.isPast(at: date) }) { return .stale }
        if meters.contains(where: { $0.legacyFreshness == true || ($0.freshUntil == nil && $0.verified != true) }) {
            return .uncertain
        }
        if meters.contains(where: { $0.verified == true }) { return .manual }
        return nil
    }

    static func accessibleCheckedParts(_ checked: Date, relativeTo reference: Date,
                                       calendar: Calendar = .autoupdatingCurrent) -> (date: String, time: String) {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: checked)
        let time = String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
        let month = components.month ?? 0
        let day = components.day ?? 0
        if components.year == calendar.component(.year, from: reference) {
            return ("\(month)/\(day)", time)
        }
        return ("\(components.year ?? 0)/\(month)/\(day)", time)
    }

    private func percentageText(_ value: Double) -> String {
        if value > 0 && value < 0.01 { return "<0.01%" }
        if value < 100 && value > 99.99 { return ">99.99%" }
        return value.formatted(.number.precision(.fractionLength(0...2))) + "%"
    }

    private func iconAction(_ url: URL, symbol: String, label: String, primary: Bool) -> some View {
        Link(destination: url) {
            Image(systemName: symbol).laaTextStyle(.body).fontWeight(.semibold)
                .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumTouchTarget)
                .foregroundStyle(effectiveRenderingMode == .fullColor && primary ? LAAColor.filledButtonText : LAAColor.link)
                .background {
                    if effectiveRenderingMode == .fullColor {
                        RoundedRectangle(cornerRadius: LAARadius.control)
                            .fill(primary ? LAAColor.filledButton : LAAColor.subtleSurface)
                    } else {
                        RoundedRectangle(cornerRadius: LAARadius.control).strokeBorder(LAAColor.text, lineWidth: 1)
                    }
                }
        }
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
                action(entry.call.url, title: LAACopy.widgetCall, primary: true)
                action(entry.chat.url, title: LAACopy.widgetChat, primary: false)
            }
        }
        .padding(LAASpacing.x3)
        .widgetURL(entry.defaultLink(for: .systemSmall).url)
    }

    private var rectangular: some View {
        HStack(spacing: LAASpacing.x2) {
            Image(systemName: "phone.fill")
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
                Text(verbatim: LAACopy.widgetCall)
                    .laaTextStyle(.secondary)
                    .foregroundStyle(LAAColor.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(LAASpacing.x2)
        .widgetURL(entry.defaultLink(for: .accessoryRectangular).url)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.employee.name), \(LAACopy.widgetCall)")
    }

    private var circular: some View {
        Image("LAAWidgetMark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(LAAColor.link)
            .padding(LAASpacing.x2)
            .widgetURL(entry.defaultLink(for: .accessoryCircular).url)
            .accessibilityLabel("\(entry.employee.name), \(LAACopy.widgetCall)")
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
                .foregroundStyle(renderingMode == .fullColor && primary ? LAAColor.filledButtonText : LAAColor.link)
                .background {
                    if renderingMode == .fullColor {
                        RoundedRectangle(cornerRadius: LAARadius.control)
                            .fill(primary ? LAAColor.filledButton : LAAColor.subtleSurface)
                    } else {
                        RoundedRectangle(cornerRadius: LAARadius.control)
                            .strokeBorder(LAAColor.text, lineWidth: 1)
                    }
                }
        }
        .accessibilityLabel("\(entry.employee.name), \(title)")
    }
}
#endif
