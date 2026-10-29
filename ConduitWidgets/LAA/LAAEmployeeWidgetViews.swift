#if LAA_BUILD
import AppIntents
import SwiftUI
import WidgetKit
#if LAA_WIDGET_TEST
@testable import Conduit
#endif

extension LAAWidgetEmployee: AppEnum {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "社員")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .ciel: "Ciel", .argus: "Argus", .cfo: "Morgan", .cio: "Sherlock",
        .cmo: "Monet", .cos: "Merlin", .cto: "Ada", .cso: "Talos"
    ]
}

struct LAAEmployeeWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "社員"
    static let description = IntentDescription("ホーム画面から社員の会話や電話を開きます。")
    @Parameter(title: "社員", default: .ciel) var employee: LAAWidgetEmployee
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
    static let supportedFamilies: [WidgetFamily] = [.systemSmall, .accessoryCircular]

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: ConduitWidgetKind.employee, intent: LAAEmployeeWidgetIntent.self, provider: LAAEmployeeTimelineProvider()) { entry in
            LAAEmployeeWidgetView(entry: entry)
        }
        .configurationDisplayName("LAA 社員")
        .description("社員を選び、会話や電話を開きます。")
        .supportedFamilies(Self.supportedFamilies)
        .contentMarginsDisabled()
    }
}

private enum LAAEmployeeWidgetStyle {
    static let lightBackground = Color(red: 246/255, green: 242/255, blue: 233/255)
    static let darkBackground = Color(red: 15/255, green: 27/255, blue: 28/255)
    static let actionBackground = Color(red: 0/255, green: 88/255, blue: 94/255)
    static let actionForeground = Color.white
    static let primaryForeground = Color.primary
    static let nameFont = Font.custom("Georgia", size: 19)
    static let actionIconFont = Font.system(size: 15, weight: .semibold)
    static let actionLabelFont = Font.system(size: 10, weight: .semibold)
    static let actionDiameter: CGFloat = 44
    static let actionOutlineWidth: CGFloat = 1.5
    static let namePadding: CGFloat = 12
    static let actionSpacing: CGFloat = 18
    static let bottomPadding: CGFloat = 8
    static let heroActionClearance: CGFloat = 4
}

struct LAAEmployeeWidgetView: View {
    let entry: LAAEmployeeWidgetEntry
    var familyOverride: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            switch familyOverride ?? family {
            case .accessoryCircular: circular
            default: small
            }
        }
        .containerBackground(for: .widget) { background }
    }

    private var background: Color {
        colorScheme == .dark ? LAAEmployeeWidgetStyle.darkBackground : LAAEmployeeWidgetStyle.lightBackground
    }

    private var small: some View {
        GeometryReader { geometry in
            let isFullColor = renderingMode == .fullColor
            let heroHeight = isFullColor ? geometry.size.height * 0.86 : max(0,
                geometry.size.height - LAAEmployeeWidgetStyle.actionDiameter
                    - LAAEmployeeWidgetStyle.bottomPadding - LAAEmployeeWidgetStyle.heroActionClearance)
            ZStack {
                employeeImage(entry.employee.heroImage)
                    .scaledToFit()
                    .frame(width: geometry.size.width * 0.9, height: heroHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isFullColor ? .bottom : .top)
                    .accessibilityHidden(true)

                VStack {
                    HStack {
                        Text(entry.employee.name)
                            .font(LAAEmployeeWidgetStyle.nameFont)
                            .foregroundStyle(LAAEmployeeWidgetStyle.primaryForeground)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, LAAEmployeeWidgetStyle.namePadding)
                    .padding(.top, LAAEmployeeWidgetStyle.namePadding)
                    Spacer(minLength: 0)
                    HStack(spacing: LAAEmployeeWidgetStyle.actionSpacing) {
                        action(entry.call.url, title: "Call", symbol: "phone.fill")
                        action(entry.chat.url, title: "Chat", symbol: "bubble.left.fill")
                    }
                    .padding(.bottom, LAAEmployeeWidgetStyle.bottomPadding)
                }
            }
        }
        .widgetURL(entry.chat.url)
    }

    private var circular: some View {
        Image("LAAWidgetMark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .padding(8)
            .widgetURL(entry.call.url)
            .accessibilityLabel("\(entry.employee.name), Call")
    }

    @ViewBuilder
    private func employeeImage(_ name: String) -> some View {
        if #available(iOS 18.0, *) {
            Image(name).resizable().widgetAccentedRenderingMode(.fullColor)
        } else {
            Image(name).resizable()
        }
    }

    private func action(_ url: URL, title: String, symbol: String) -> some View {
        Link(destination: url) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(LAAEmployeeWidgetStyle.actionIconFont)
                Text(title)
                    .font(LAAEmployeeWidgetStyle.actionLabelFont)
                    .lineLimit(1)
            }
            .frame(width: LAAEmployeeWidgetStyle.actionDiameter, height: LAAEmployeeWidgetStyle.actionDiameter)
            .foregroundStyle(renderingMode == .fullColor ? LAAEmployeeWidgetStyle.actionForeground : LAAEmployeeWidgetStyle.primaryForeground)
            .background {
                if renderingMode == .fullColor {
                    Circle().fill(LAAEmployeeWidgetStyle.actionBackground)
                } else {
                    Circle().strokeBorder(LAAEmployeeWidgetStyle.primaryForeground, lineWidth: LAAEmployeeWidgetStyle.actionOutlineWidth)
                }
            }
        }
        .accessibilityLabel("\(entry.employee.name), \(title)")
    }
}
#endif
