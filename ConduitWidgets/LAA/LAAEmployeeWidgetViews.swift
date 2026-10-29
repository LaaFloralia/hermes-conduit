#if LAA_BUILD
import AppIntents
import SwiftUI
import WidgetKit
#if LAA_WIDGET_TEST
@testable import Conduit
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

    static func make(employee: LAAWidgetEmployee, snapshot: WidgetSnapshot?) -> Self {
        Self(date: Date(), employee: employee,
             chat: LAAEmployeeWidgetLinks.link(employee: employee, action: .employeeChat, snapshot: snapshot),
             call: LAAEmployeeWidgetLinks.link(employee: employee, action: .talk, snapshot: snapshot))
    }

    func defaultLink(for family: WidgetFamily) -> WidgetLaunchLink {
        family == .systemSmall ? chat : call
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
        return Timeline(entries: [entry], policy: .never)
    }
}

struct LAAEmployeeWidget: Widget {
    static let supportedFamilies: [WidgetFamily] = [.systemSmall, .accessoryRectangular, .accessoryCircular]

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
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Group {
            switch familyOverride ?? family {
            case .accessoryRectangular: rectangular
            case .accessoryCircular: circular
            default: small
            }
        }
        .containerBackground(for: .widget) { LAAColor.surface }
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
        if #available(iOS 18.0, *) {
            Image(name).resizable().widgetAccentedRenderingMode(.fullColor)
        } else {
            Image(name).resizable()
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
